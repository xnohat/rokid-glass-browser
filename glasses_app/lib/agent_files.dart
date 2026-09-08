import 'dart:convert';
import 'dart:io';

import 'agent_vision.dart';

/// Sandboxed file tools for the agent: everything is confined to a single
/// "workspace" directory inside the app's private storage. Paths are resolved
/// canonically and rejected if they escape the workspace (no .. traversal, no
/// symlink break-out), so the agent can never touch app credentials or files
/// outside its box.
class AgentFiles {
  AgentFiles(this._vision, this._filesDirProvider);
  final AgentVision _vision;
  // Returns the app's private files dir (from native getFilesDir()).
  final Future<String?> Function() _filesDirProvider;

  Directory? _root;
  // Per-agent-turn download cap so a runaway loop can't fill storage.
  static const _maxDownloadBytes = 25 * 1024 * 1024; // 25 MB
  static const _maxReadTextBytes = 200 * 1024; // 200 KB for text reads

  Future<Directory> _workspace() async {
    if (_root != null) return _root!;
    final basePath = await _filesDirProvider();
    if (basePath == null || basePath.isEmpty) {
      throw StateError('No app storage available');
    }
    final ws = Directory('$basePath/agent_workspace');
    if (!ws.existsSync()) ws.createSync(recursive: true);
    _root = Directory(ws.resolveSymbolicLinksSync());
    return _root!;
  }

  /// Resolve [rel] inside the workspace, rejecting anything that escapes it.
  Future<File> _resolveFile(String rel) async {
    final ws = await _workspace();
    final f = _safeJoin(ws.path, rel);
    return File(f);
  }

  String _safeJoin(String rootPath, String rel) {
    final cleaned = rel.replaceAll('\\', '/').trim();
    if (cleaned.isEmpty) throw const FormatException('Empty path');
    final joined = Uri.parse('file://$rootPath/')
        .resolve(cleaned)
        .toFilePath();
    // Normalise .. / . and ensure still under root.
    final norm = File(joined).uri.normalizePath().toFilePath();
    final rootNorm = rootPath.endsWith('/') ? rootPath : '$rootPath/';
    if (!('$norm/').startsWith(rootNorm) && norm != rootPath) {
      throw const FormatException('Path escapes the workspace');
    }
    return norm;
  }

  Future<Map<String, dynamic>> listDir(String rel) async {
    final ws = await _workspace();
    final dir = rel.trim().isEmpty ? ws : Directory(_safeJoin(ws.path, rel));
    if (!dir.existsSync()) return {'ok': true, 'entries': <String>[]};
    final entries = <Map<String, dynamic>>[];
    for (final e in dir.listSync()) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final isDir = e is Directory;
      entries.add({
        'name': name,
        'type': isDir ? 'dir' : 'file',
        if (!isDir) 'bytes': (e as File).lengthSync(),
      });
    }
    return {'ok': true, 'entries': entries};
  }

  Future<Map<String, dynamic>> writeFile(String rel, String content,
      {bool append = false}) async {
    final f = await _resolveFile(rel);
    f.parent.createSync(recursive: true);
    await f.writeAsString(content,
        mode: append ? FileMode.append : FileMode.write);
    return {'ok': true, 'path': _rel(f.path), 'bytes': f.lengthSync()};
  }

  Future<Map<String, dynamic>> deleteFile(String rel) async {
    final f = await _resolveFile(rel);
    if (f.existsSync()) {
      f.deleteSync();
    } else {
      final d = Directory(f.path);
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
    return {'ok': true, 'path': _rel(f.path)};
  }

  /// Read a file. Text files return their content; images/audio/video are
  /// understood via Gemini and their description is returned.
  Future<Map<String, dynamic>> readFile(String rel, String question) async {
    final f = await _resolveFile(rel);
    if (!f.existsSync()) return {'error': 'file not found'};
    final ext = _ext(f.path);
    if (_isImage(ext)) {
      final bytes = await f.readAsBytes();
      final desc = await _vision.describeBytes(
          bytes, _mimeFor(ext), question,
          kind: 'image');
      return {'ok': true, 'type': 'image', 'observation': desc};
    }
    if (_isAudio(ext)) {
      final bytes = await f.readAsBytes();
      final desc = await _vision.describeBytes(
          bytes, _mimeFor(ext), question,
          kind: 'audio');
      return {'ok': true, 'type': 'audio', 'observation': desc};
    }
    if (_isVideo(ext)) {
      final bytes = await f.readAsBytes();
      final desc = await _vision.describeBytes(
          bytes, _mimeFor(ext), question,
          kind: 'video');
      return {'ok': true, 'type': 'video', 'observation': desc};
    }
    // Treat as text.
    final len = f.lengthSync();
    final raw = await f.readAsBytes();
    final slice = raw.length > _maxReadTextBytes
        ? raw.sublist(0, _maxReadTextBytes)
        : raw;
    String text;
    try {
      text = utf8.decode(slice);
    } catch (_) {
      return {'error': 'not a text/image/audio/video file'};
    }
    return {
      'ok': true,
      'type': 'text',
      'text': text,
      'truncated': len > _maxReadTextBytes,
      'bytes': len,
    };
  }

  /// Download a URL into the workspace (validated http/https, size-capped).
  Future<Map<String, dynamic>> download(String url, String rel) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return {'error': 'only http/https URLs allowed'};
    }
    final f = await _resolveFile(rel.trim().isEmpty ? _nameFrom(uri) : rel);
    f.parent.createSync(recursive: true);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(uri);
      req.maxRedirects = 5;
      final res = await req.close().timeout(const Duration(seconds: 90));
      if (res.statusCode ~/ 100 != 2) {
        return {'error': 'HTTP ${res.statusCode}'};
      }
      final sink = f.openWrite();
      var total = 0;
      var overflow = false;
      await for (final chunk in res) {
        total += chunk.length;
        if (total > _maxDownloadBytes) {
          overflow = true;
          break;
        }
        sink.add(chunk);
      }
      await sink.close();
      if (overflow) {
        if (f.existsSync()) f.deleteSync();
        return {'error': 'file exceeds ${_maxDownloadBytes ~/ (1024 * 1024)}MB cap'};
      }
      return {'ok': true, 'path': _rel(f.path), 'bytes': f.lengthSync()};
    } catch (e) {
      return {'error': e.toString()};
    } finally {
      client.close(force: true);
    }
  }

  String _rel(String abs) {
    final r = _root?.path ?? '';
    return abs.startsWith('$r/') ? abs.substring(r.length + 1) : abs;
  }

  String _nameFrom(Uri uri) {
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final n = segs.isEmpty ? 'download' : segs.last;
    return n.contains('.') ? n : '$n.bin';
  }

  static String _ext(String p) {
    final i = p.lastIndexOf('.');
    return i < 0 ? '' : p.substring(i + 1).toLowerCase();
  }

  static bool _isImage(String e) =>
      {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'}.contains(e);
  static bool _isAudio(String e) =>
      {'wav', 'mp3', 'm4a', 'aac', 'ogg', 'flac'}.contains(e);
  static bool _isVideo(String e) =>
      {'mp4', 'mov', 'webm', 'mkv', '3gp'}.contains(e);

  static String _mimeFor(String e) {
    switch (e) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
      case 'aac':
        return 'audio/mp4';
      case 'ogg':
        return 'audio/ogg';
      case 'flac':
        return 'audio/flac';
      case 'wav':
        return 'audio/wav';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'webm':
        return 'video/webm';
      default:
        return 'application/octet-stream';
    }
  }
}
