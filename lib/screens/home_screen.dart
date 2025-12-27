import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_static/shelf_static.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:mime/mime.dart';
import '../models/disk_info.dart';
import '../models/log_entry.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<LogEntry> _logs = [];
  final ScrollController _logScrollController = ScrollController();

  List<DiskInfo> _disks = [];
  DiskInfo? _selectedDisk;

  List<NetworkInterface> _interfaces = [];
  String? _selectedIP;

  HttpServer? _server;
  bool _isRunning = false;
  final int _port = 8080;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    _log("App initializing...");
    await _requestPermissions();
    await _refreshDisks();
    await _refreshInterfaces();
  }

  void _log(String message, {bool isError = false}) {
    setState(() {
      _logs.add(LogEntry(message, isError: isError));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _requestPermissions() async {
    _log("Requesting permissions...");
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt >= 30) {
        if (!await Permission.manageExternalStorage.isGranted) {
          await Permission.manageExternalStorage.request();
        }
      } else {
        await [Permission.storage].request();
      }

      if (!await Permission.ignoreBatteryOptimizations.isGranted) {
        _log("Requesting to ignore battery optimizations...");
        await Permission.ignoreBatteryOptimizations.request();
      }
    }
  }

  Future<void> _refreshDisks() async {
    _log("Scanning for disks (Root)...");
    List<DiskInfo> disks = [];

    disks.add(
      DiskInfo(
        name: "Internal Storage",
        path: "/storage/emulated/0",
        icon: Icons.phone_android,
      ),
    );

    final scanPaths = ["/storage", "/mnt/media_rw"];

    for (final scanPath in scanPaths) {
      try {
        final result = await Process.run('su', ['-c', 'ls $scanPath']);

        if (result.exitCode == 0) {
          final output = result.stdout.toString();
          final lines = output.split('\n');

          for (var line in lines) {
            line = line.trim();
            if (line.isEmpty) continue;

            if (line == 'emulated' || line == 'self' || line == 'knox-emulated')
              continue;

            final path = "$scanPath/$line";

            if (!disks.any((d) => d.name == line)) {
              disks.add(DiskInfo(name: line, path: path, icon: Icons.usb));
            }
          }
        }
      } catch (e) {
        _log("Scan error on $scanPath: $e", isError: true);
      }
    }

    _log("Root scan found ${disks.length} volumes total.");

    setState(() {
      _disks = disks;
      if (_selectedDisk != null) {
        final stillExists = _disks.any((d) => d.path == _selectedDisk!.path);
        if (!stillExists) {
          _selectedDisk = _disks.isNotEmpty ? _disks.first : null;
        }
      } else if (_disks.isNotEmpty) {
        _selectedDisk = _disks.first;
      }
    });
  }

  Future<void> _refreshInterfaces() async {
    _log("Refreshing network interfaces...");
    try {
      final interfaces = await NetworkInterface.list();
      setState(() {
        _interfaces = interfaces;
        for (var interface in interfaces) {
          for (var addr in interface.addresses) {
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
              _selectedIP = addr.address;
              break;
            }
          }
          if (_selectedIP != null) break;
        }
      });
    } catch (e) {
      _log("Error fetching interfaces: $e", isError: true);
    }
  }

  Future<void> _toggleServer() async {
    if (_isRunning) {
      await _stopServer();
    } else {
      await _startServer();
    }
  }

  Future<void> _startServer() async {
    if (_selectedDisk == null || _selectedIP == null) {
      _log("Error: Please select disk and interface", isError: true);
      return;
    }

    final rootPath = _selectedDisk!.path;
    final useRoot =
        rootPath.startsWith('/mnt/') || rootPath.startsWith('/data/');

    try {
      Handler handler;

      if (useRoot) {
        _log("Using Root Handler for $rootPath");
        handler = (Request request) => _handleRootRequest(request, rootPath);
      } else {
        handler = createStaticHandler(
          rootPath,
          defaultDocument: 'index.html',
          listDirectories: true,
        );
      }

      final pipeline = const Pipeline()
          .addMiddleware(
            logRequests(logger: (msg, isError) => _log(msg, isError: isError)),
          )
          .addHandler(handler);

      _server = await io.serve(pipeline, _selectedIP!, _port);

      setState(() {
        _isRunning = true;
      });

      _log("Server started on http://$_selectedIP:$_port");
      _log("Serving: $rootPath");
    } catch (e) {
      _log("Failed to start server: $e", isError: true);
    }
  }

  Future<Response> _handleRootRequest(Request request, String rootPath) async {
    final segments = request.url.pathSegments;
    if (segments.any((s) => s == '..' || s.contains('/') || s.contains('\\'))) {
      return Response.forbidden('Invalid path');
    }

    final relativePath = request.url.path;
    final decodedRelative = Uri.decodeComponent(relativePath);
    var fullPath = "$rootPath/$decodedRelative";

    fullPath = fullPath.replaceAll('//', '/');
    if (fullPath.endsWith('/') && fullPath.length > 1) {
      fullPath = fullPath.substring(0, fullPath.length - 1);
    }

    final checkDir = await Process.run('su', ['-c', '[ -d "$fullPath" ]']);
    final isDir = checkDir.exitCode == 0;

    if (isDir) {
      final result = await Process.run('su', ['-c', 'ls -1p "$fullPath"']);
      if (result.exitCode != 0) {
        return Response.notFound('Directory not found or access denied');
      }

      final buffer = StringBuffer();
      buffer.writeln('<html><head><title>Index of $relativePath</title>');
      buffer.writeln(
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
      );
      buffer.writeln(
        '<style>body{font-family:sans-serif;padding:20px;background:#0F172A;color:#F8FAFC} a{color:#38BDF8;text-decoration:none;display:block;padding:8px 0;border-bottom:1px solid #1E293B} a:hover{color:#fff}</style>',
      );
      buffer.writeln('</head><body>');
      buffer.writeln('<h2>Index of /$decodedRelative</h2><hr>');

      if (relativePath.isNotEmpty && relativePath != '/') {
        buffer.writeln('<a href="../">../</a>');
      }

      final lines = result.stdout.toString().split('\n');
      for (var line in lines) {
        line = line.trim();
        if (line.isEmpty) continue;

        final isFolder = line.endsWith('/');
        final displayName = line;
        final href = Uri.encodeComponent(line.replaceAll('/', ''));

        buffer.writeln(
          '<a href="$href${isFolder ? '/' : ''}">$displayName</a>',
        );
      }

      buffer.writeln('</body></html>');
      return Response.ok(
        buffer.toString(),
        headers: {'content-type': 'text/html'},
      );
    } else {
      final checkFile = await Process.run('su', ['-c', '[ -f "$fullPath" ]']);
      if (checkFile.exitCode != 0) {
        return Response.notFound('File not found');
      }

      final mimeType = lookupMimeType(fullPath) ?? 'application/octet-stream';
      final process = await Process.start('su', ['-c', 'cat "$fullPath"']);

      return Response.ok(
        process.stdout,
        headers: {
          'content-type': mimeType,
          'content-disposition':
              'inline; filename="${fullPath.split('/').last}"',
        },
      );
    }
  }

  Future<void> _stopServer() async {
    try {
      await _server?.close(force: true);
      setState(() {
        _isRunning = false;
        _server = null;
      });

      _log("Server stopped");
    } catch (e) {
      _log("Error stopping server: $e", isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    const bgCol = Color(0xFF0F172A);
    const cardCol = Color(0xFF1E293B);
    const accentCol = Color(0xFF38BDF8);
    const textCol = Color(0xFFF8FAFC);
    const subTextCol = Color(0xFF94A3B8);

    return Scaffold(
      backgroundColor: bgCol,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "WLAN Share",
                        style: TextStyle(
                          color: textCol,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.5,
                        ),
                      ),
                      Text(
                        "Local File Server",
                        style: TextStyle(color: subTextCol, fontSize: 13),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _isRunning
                          ? const Color(0xFF22C55E).withOpacity(0.15)
                          : const Color(0xFFEF4444).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _isRunning
                            ? const Color(0xFF22C55E).withOpacity(0.3)
                            : const Color(0xFFEF4444).withOpacity(0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 8,
                          color: _isRunning
                              ? const Color(0xFF22C55E)
                              : const Color(0xFFEF4444),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _isRunning ? "ONLINE" : "OFFLINE",
                          style: TextStyle(
                            color: _isRunning
                                ? const Color(0xFF22C55E)
                                : const Color(0xFFEF4444),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 30),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "STORAGE VOLUME",
                    style: TextStyle(
                      color: subTextCol,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  InkWell(
                    onTap: _isRunning ? null : _refreshDisks,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.refresh, size: 14, color: accentCol),
                          const SizedBox(width: 4),
                          Text(
                            "SCAN",
                            style: TextStyle(
                              color: accentCol,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 64,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _disks.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (ctx, i) {
                    final d = _disks[i];
                    final sel = _selectedDisk == d;
                    return Material(
                      color: sel ? accentCol.withOpacity(0.15) : cardCol,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        onTap: _isRunning
                            ? null
                            : () => setState(() => _selectedDisk = d),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: sel
                                  ? accentCol.withOpacity(0.5)
                                  : Colors.transparent,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                d.icon,
                                color: sel ? accentCol : subTextCol,
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                d.name,
                                style: TextStyle(
                                  color: sel ? textCol : subTextCol,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 24),

              Text(
                "NETWORK INTERFACE",
                style: TextStyle(
                  color: subTextCol,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: cardCol,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedIP,
                    isExpanded: true,
                    dropdownColor: cardCol,
                    icon: Icon(Icons.expand_more_rounded, color: subTextCol),
                    style: TextStyle(color: textCol, fontSize: 14),
                    items: _interfaces
                        .expand(
                          (i) => i.addresses
                              .where((a) => a.type == InternetAddressType.IPv4)
                              .map(
                                (a) => DropdownMenuItem(
                                  value: a.address,
                                  child: Text("${i.name}: ${a.address}"),
                                ),
                              ),
                        )
                        .toList(),
                    onChanged: _isRunning
                        ? null
                        : (v) => setState(() => _selectedIP = v),
                  ),
                ),
              ),

              const SizedBox(height: 30),

              SizedBox(
                height: 54,
                child: FilledButton(
                  onPressed: _toggleServer,
                  style: FilledButton.styleFrom(
                    backgroundColor: _isRunning
                        ? const Color(0xFFEF4444)
                        : accentCol,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _isRunning
                            ? Icons.stop_rounded
                            : Icons.power_settings_new_rounded,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isRunning ? "STOP SERVER" : "START SERVER",
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 30),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "SYSTEM LOGS",
                          style: TextStyle(
                            color: subTextCol,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                          ),
                        ),
                        if (_logs.isNotEmpty)
                          InkWell(
                            onTap: () => setState(() => _logs.clear()),
                            child: Padding(
                              padding: const EdgeInsets.all(4.0),
                              child: Text(
                                "CLEAR",
                                style: TextStyle(
                                  color: accentCol,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.05),
                          ),
                        ),
                        child: ListView.builder(
                          padding: const EdgeInsets.all(12),
                          controller: _logScrollController,
                          itemCount: _logs.length,
                          itemBuilder: (ctx, i) {
                            final l = _logs[i];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: RichText(
                                text: TextSpan(
                                  children: [
                                    TextSpan(
                                      text: "> ",
                                      style: TextStyle(
                                        color: subTextCol,
                                        fontSize: 12,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                    TextSpan(
                                      text: l.message,
                                      style: TextStyle(
                                        color: l.isError
                                            ? const Color(0xFFEF4444)
                                            : textCol.withOpacity(0.9),
                                        fontSize: 13,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
