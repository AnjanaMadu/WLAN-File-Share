import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:mime/mime.dart';
import '../models/disk_info.dart';

class NasServer {
  HttpServer? _server;
  bool _isRunning = false;
  final int _port = 8080;
  final Function(String, {bool isError}) _logger;

  // Cache for the HTML template
  String? _htmlTemplate;

  NasServer(this._logger);

  bool get isRunning => _isRunning;
  int get port => _port;

  Future<void> start(String ip, List<DiskInfo> disks) async {
    if (_isRunning) return;

    try {
      // Pre-load template if needed
      if (_htmlTemplate == null) {
        try {
          _htmlTemplate = await rootBundle.loadString('assets/index.html');
        } catch (e) {
          _logger("Error loading HTML template: $e", isError: true);
          // Fallback minimal template
          _htmlTemplate =
              "<html><body><h1>Error loading template</h1>{{FILE_LIST}}</body></html>";
        }
      }

      final handler = const Pipeline()
          .addMiddleware(
            logRequests(
              logger: (msg, isError) => _logger(msg, isError: isError),
            ),
          )
          .addHandler((req) => _handleRequest(req, disks));

      _server = await io.serve(handler, ip, _port);
      _isRunning = true;
      _logger("Nas Server started on http://$ip:$_port");
      _logger("Serving ${disks.length} disks");
    } catch (e) {
      _logger("Failed to start server: $e", isError: true);
      rethrow;
    }
  }

  Future<void> stop() async {
    try {
      await _server?.close(force: true);
      _server = null;
      _isRunning = false;
      _logger("Server stopped");
    } catch (e) {
      _logger("Error stopping server: $e", isError: true);
    }
  }

  Future<Response> _handleRequest(Request request, List<DiskInfo> disks) async {
    final path = request.url.path;

    // API: Create Directory
    if (path == 'api/mkdir' && request.method == 'POST') {
      final targetPath = request.url.queryParameters['path'];
      if (targetPath == null) return Response.badRequest(body: 'Missing path');
      return _handleMkdir(targetPath, disks);
    }

    // API: Delete
    if (path == 'api/delete' && request.method == 'DELETE') {
      final targetPath = request.url.queryParameters['path'];
      if (targetPath == null) return Response.badRequest(body: 'Missing path');
      return _handleDelete(targetPath, disks);
    }

    if (path == '' || path == '/') {
      return _serveDiskList(disks);
    }

    // Disk routing
    final segments = request.url.pathSegments;
    if (segments.isEmpty) return _serveDiskList(disks);

    final diskId = segments.first;
    final disk = disks.firstWhere(
      (d) =>
          (d.uuid == diskId) ||
          (diskId == 'internal' && d.path == '/storage/emulated/0'),
      orElse: () => DiskInfo(name: '', path: '', icon: Icons.error),
    );

    if (disk.path.isEmpty) {
      return Response.notFound('Disk not found');
    }

    final relativePath = segments.skip(1).join('/');
    final bool isInternal = disk.uuid == null; // internal has no uuid

    // Handle Methods
    if (request.method == 'PUT') {
      return _handleUpload(request, disk.path, relativePath, isInternal);
    }

    return _handleDiskRequest(
      request,
      disk.path,
      relativePath,
      request.url.path,
      isInternal,
    );
  }

  Future<Response> _serveDiskList(List<DiskInfo> disks) async {
    final buffer = StringBuffer();
    buffer.writeln('<div class="list-header">Available Disks</div>');

    for (var disk in disks) {
      final id = disk.uuid ?? 'internal';
      buffer.writeln('''
        <div class="file-item">
            <div class="icon">💾</div>
            <a href="/$id/" class="name">${disk.friendlyName} <span style="color:#64748B;font-size:12px;">($id)</span></a>
        </div>
      ''');
    }

    final html = _htmlTemplate!
        .replaceFirst('{{FILE_LIST}}', buffer.toString())
        .replaceFirst('{{CURRENT_PATH}}', 'Root')
        .replaceFirst('{{CURRENT_PATH_ENCODED}}', '/');

    return Response.ok(html, headers: {'content-type': 'text/html'});
  }

  Future<Response> _handleDiskRequest(
    Request request,
    String rootPath,
    String relativePath,
    String originalUrl,
    bool isInternal,
  ) async {
    if (relativePath.contains('..')) return Response.forbidden('Invalid path');

    var fullPath = "$rootPath/$relativePath";
    fullPath = fullPath.replaceAll('//', '/');
    if (fullPath.endsWith('/') && fullPath.length > 1) {
      fullPath = fullPath.substring(0, fullPath.length - 1);
    }

    // 1. Check if Directory
    bool isDir = false;
    if (!isInternal) {
      final res = await Process.run('su', ['-c', '[ -d "$fullPath" ]']);
      isDir = res.exitCode == 0;
    } else {
      isDir = await Directory(fullPath).exists();
    }

    if (isDir) {
      return _serveDirectory(
        rootPath,
        fullPath,
        relativePath,
        originalUrl,
        !isInternal,
      );
    }

    // 2. Check if File
    bool isFile = false;
    if (!isInternal) {
      final res = await Process.run('su', ['-c', '[ -f "$fullPath" ]']);
      isFile = res.exitCode == 0;
    } else {
      isFile = await File(fullPath).exists();
    }

    if (isFile) {
      final mimeType = lookupMimeType(fullPath) ?? 'application/octet-stream';

      if (!isInternal) {
        final process = await Process.start('su', ['-c', 'cat "$fullPath"']);
        return Response.ok(
          process.stdout,
          headers: {
            'content-type': mimeType,
            'content-disposition':
                'inline; filename="${fullPath.split('/').last}"',
          },
        );
      } else {
        final file = File(fullPath);
        return Response.ok(
          file.openRead(),
          headers: {
            'content-type': mimeType,
            'content-disposition':
                'inline; filename="${fullPath.split('/').last}"',
          },
        );
      }
    }

    return Response.notFound('Not found');
  }

  Future<Response> _serveDirectory(
    String rootPath,
    String fullPath,
    String relativePath,
    String originalUrl,
    bool useRoot,
  ) async {
    List<String> lines = [];

    if (useRoot) {
      final res = await Process.run('su', ['-c', 'ls -1p "$fullPath"']);
      if (res.exitCode == 0) {
        lines = res.stdout.toString().split('\n');
      }
    } else {
      try {
        final dir = Directory(fullPath);
        final entities = await dir.list().toList();
        lines = entities.map((e) {
          final name = e.path.split(Platform.pathSeparator).last;
          return (e is Directory) ? "$name/" : name;
        }).toList();
      } catch (e) {
        _logger("Native list error: $e", isError: true);
      }
    }

    final buffer = StringBuffer();

    if (relativePath.isNotEmpty && relativePath != '/') {
      buffer.writeln('''
            <div class="file-item">
                <div class="icon">📁</div>
                <a href="../" class="name">..</a>
            </div>
         ''');
    } else {
      buffer.writeln('''
            <div class="file-item">
                <div class="icon">🏠</div>
                <a href="/" class="name">All Disks</a>
            </div>
         ''');
    }

    lines = lines.where((l) => l.trim().isNotEmpty).toList();
    lines.sort((a, b) {
      final aIsDir = a.endsWith('/');
      final bIsDir = b.endsWith('/');
      if (aIsDir && !bIsDir) return -1;
      if (!aIsDir && bIsDir) return 1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });

    for (var line in lines) {
      line = line.trim();
      final isDir = line.endsWith('/');
      final name = isDir ? line.substring(0, line.length - 1) : line;
      final icon = isDir ? '📁' : '📄';
      final href = Uri.encodeComponent(name);
      final link = isDir ? '$href/' : href;

      buffer.writeln('''
            <div class="file-item">
                <div class="icon">$icon</div>
                <a href="$link" class="name">$name</a>
                <div class="actions">
                     <button class="action-btn" onclick="deleteItem('$name')" title="Delete">🗑️</button>
                </div>
            </div>
         ''');
    }

    final html = _htmlTemplate!
        .replaceFirst('{{FILE_LIST}}', buffer.toString())
        .replaceFirst(
          '{{CURRENT_PATH}}',
          relativePath.isEmpty ? '/' : relativePath,
        )
        .replaceFirst('{{CURRENT_PATH_ENCODED}}', originalUrl);

    return Response.ok(html, headers: {'content-type': 'text/html'});
  }

  Future<Response> _handleUpload(
    Request request,
    String rootPath,
    String relativePath,
    bool isInternal,
  ) async {
    var fullPath = "$rootPath/$relativePath";
    fullPath = fullPath.replaceAll('//', '/');

    try {
      if (!isInternal) {
        final process = await Process.start('su', ['-c', 'cat > "$fullPath"']);
        await process.stdin.addStream(request.read());
        await process.stdin.close();
        final exitCode = await process.exitCode;
        if (exitCode != 0) throw "Exit code $exitCode";
      } else {
        final file = File(fullPath);
        final sink = file.openWrite();
        await sink.addStream(request.read());
        await sink.close();
      }
      return Response.ok('Uploaded');
    } catch (e) {
      _logger("Upload failed: $e", isError: true);
      return Response.internalServerError(body: "Upload failed: $e");
    }
  }

  Future<Response> _handleMkdir(
    String virtualPath,
    List<DiskInfo> disks,
  ) async {
    final segments = Uri.parse(virtualPath).pathSegments;
    if (segments.isEmpty) return Response.badRequest();

    final diskId = segments.first;
    final disk = disks.firstWhere(
      (d) =>
          (d.uuid == diskId) ||
          (diskId == 'internal' && d.path == '/storage/emulated/0'),
      orElse: () => DiskInfo(name: '', path: '', icon: Icons.error),
    );

    if (disk.path.isEmpty) return Response.notFound("Disk not found");

    final rel = segments.skip(1).join('/');
    final fullPath = "${disk.path}/$rel".replaceAll('//', '/');
    final bool isInternal = disk.uuid == null;

    try {
      if (!isInternal) {
        await Process.run('su', ['-c', 'mkdir -p "$fullPath"']);
      } else {
        await Directory(fullPath).create(recursive: true);
      }
      return Response.ok('Created');
    } catch (e) {
      return Response.internalServerError(body: "$e");
    }
  }

  Future<Response> _handleDelete(
    String virtualPath,
    List<DiskInfo> disks,
  ) async {
    final segments = Uri.parse(virtualPath).pathSegments;
    if (segments.isEmpty) return Response.badRequest();

    final diskId = segments.first;
    final disk = disks.firstWhere(
      (d) =>
          (d.uuid == diskId) ||
          (diskId == 'internal' && d.path == '/storage/emulated/0'),
      orElse: () => DiskInfo(name: '', path: '', icon: Icons.error),
    );

    if (disk.path.isEmpty) return Response.notFound("Disk not found");

    final rel = segments.skip(1).join('/');
    final fullPath = "${disk.path}/$rel".replaceAll('//', '/');
    final bool isInternal = disk.uuid == null;

    try {
      if (!isInternal) {
        await Process.run('su', ['-c', 'rm -rf "$fullPath"']);
      } else {
        final type = await FileSystemEntity.type(fullPath);
        if (type == FileSystemEntityType.file) {
          await File(fullPath).delete();
        } else if (type == FileSystemEntityType.directory) {
          await Directory(fullPath).delete(recursive: true);
        }
      }
      return Response.ok('Deleted');
    } catch (e) {
      return Response.internalServerError(body: "$e");
    }
  }
}
