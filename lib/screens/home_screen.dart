import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import '../models/disk_info.dart';
import '../models/log_entry.dart';
import '../services/nas_server.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<LogEntry> _logs = [];
  final ScrollController _logScrollController = ScrollController();

  List<DiskInfo> _disks = [];

  List<NetworkInterface> _interfaces = [];
  String? _selectedIP;

  NasServer? _nasServer;
  bool get _isRunning => _nasServer?.isRunning ?? false;

  @override
  void initState() {
    super.initState();
    _nasServer = NasServer(_log);
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

    // internal storage
    disks.add(
      DiskInfo(
        name: "Internal Storage",
        path: "/storage/emulated/0",
        icon: Icons.phone_android,
        vendor: "Internal",
        model: "Storage",
      ),
    );

    // scan with blkid
    try {
      final result = await Process.run('su', ['-c', 'blkid']);
      if (result.exitCode == 0) {
        final output = result.stdout.toString();
        final lines = output.split('\n');

        for (var line in lines) {
          line = line.trim();
          if (line.isEmpty) continue;

          // example: /dev/block/sdg1: UUID="..."
          final parts = line.split(':');
          if (parts.length < 2) continue;

          final deviceNode = parts[0].trim(); // /dev/block/sdg1
          final attributes = parts[1].trim();

          // getting uuid
          final uuidMatch = RegExp(r'UUID="([^"]+)"').firstMatch(attributes);
          if (uuidMatch == null) continue;
          final uuid = uuidMatch.group(1)!;

          // checking if mounted in media_rw
          final mountPath = "/mnt/media_rw/$uuid";
          final checkDir = await Process.run('su', [
            '-c',
            '[ -d "$mountPath" ]',
          ]);
          if (checkDir.exitCode != 0) {
            // not mounted properly
            continue;
          }

          // finding friendly name
          // need 'sdg' from /dev/block/sdg1
          final nodeName = deviceNode.split('/').last;
          // remove partition number
          final baseName = nodeName.replaceAll(RegExp(r'\d+$'), '');

          String? vendor;
          String? model;

          try {
            final vendorRes = await Process.run('su', [
              '-c',
              'cat /sys/block/$baseName/device/vendor',
            ]);
            if (vendorRes.exitCode == 0) {
              vendor = vendorRes.stdout.toString().trim();
            }

            final modelRes = await Process.run('su', [
              '-c',
              'cat /sys/block/$baseName/device/model',
            ]);
            if (modelRes.exitCode == 0) {
              model = modelRes.stdout.toString().trim();
            }
          } catch (e) {
            _log("Error reading vendor/model for $baseName: $e", isError: true);
          }

          disks.add(
            DiskInfo(
              name: "$vendor $model".trim().isEmpty
                  ? uuid
                  : "$vendor $model".trim(),
              path: mountPath,
              icon: Icons.usb,
              uuid: uuid,
              vendor: vendor,
              model: model,
            ),
          );
        }
      } else {
        _log("blkid failed: ${result.stderr}", isError: true);
      }
    } catch (e) {
      _log("Scan failed: $e", isError: true);
    }

    _log("Root scan found ${disks.length} volumes total.");

    setState(() {
      _disks = disks;
      // serving everything now
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
    if (_nasServer!.isRunning) {
      await _stopServer();
    } else {
      await _startServer();
    }
  }

  Future<void> _startServer() async {
    if (_selectedIP == null) {
      _log("Error: Please select network interface", isError: true);
      return;
    }

    try {
      await _nasServer!.start(_selectedIP!, _disks);
      setState(() {}); // update UI
    } catch (e) {
      // logged in service
    }
  }

  Future<void> _stopServer() async {
    await _nasServer!.stop();
    setState(() {}); // update UI
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
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.separated(
                  shrinkWrap: true,
                  // vertical list
                  itemCount: _disks.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) {
                    final d = _disks[i];
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: cardCol,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.05),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(d.icon, color: accentCol, size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  d.friendlyName,
                                  style: TextStyle(
                                    color: textCol,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  ),
                                ),
                                if (d.uuid != null)
                                  Text(
                                    "${d.uuid}",
                                    style: TextStyle(
                                      color: subTextCol,
                                      fontSize: 11,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
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
