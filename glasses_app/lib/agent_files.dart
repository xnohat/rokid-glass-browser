import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'agent_vision.dart';

/// Sandboxed file tools for the agent: everything is confined to a single
/// "workspace" directory inside the app's private storage. Paths are resolved
/// canonically and rejected if they escape the workspace (no .. traversal, no
/// symlink break-out), so the agent can never touch app credentials or files
/// outside its box.
class AgentFiles {
  AgentFiles(this._vision, this._filesDirProvider, this._methodChannel);
  final AgentVision _vision;
  // Returns the app's private files dir (from native getFilesDir()).
  final Future<String?> Function() _filesDirProvider;
  final MethodChannel _methodChannel;

  Directory? _root;
  // Per-agent-turn download cap so a runaway loop can't fill storage.
  static const _maxDownloadBytes = 25 * 1024 * 1024; // 25 MB
  static const _maxReadTextBytes = 200 * 1024; // 200 KB for text reads
  static const _maxShellOutputBytes = 64 * 1024;
  static const _maxShellMs = 10000;
  static const _shellCommands = {
    'ls',
    'cat',
    'head',
    'tail',
    'grep',
    'find',
    'pwd',
    'wc',
    'sort',
    'uniq',
    'cut',
    'tr',
    'echo',
    'printf',
    'date',
    'uname',
    'id',
  };

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
    final joined = Uri.parse('file://$rootPath/').resolve(cleaned).toFilePath();
    // Normalise .. / . and ensure still under root.
    final norm = File(joined).uri.normalizePath().toFilePath();
    final rootNorm = rootPath.endsWith('/') ? rootPath : '$rootPath/';
    if (!('$norm/').startsWith(rootNorm) && norm != rootPath) {
      throw const FormatException('Path escapes the workspace');
    }
    return norm;
  }

  /// Run one allowlisted Android toybox applet inside agent_workspace only.
  /// No shell parser, pipes, redirects, globbing, env injection, or absolute paths.
  Future<Map<String, dynamic>> runShell(
    String command, {
    int timeoutMs = _maxShellMs,
  }) async {
    final ws = await _workspace();
    final parts = command.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty ||
        parts.first.isEmpty ||
        !_shellCommands.contains(parts.first)) {
      return {
        'error':
            'Only allowlisted Android toybox applets are available: ${_shellCommands.join(', ')}',
      };
    }
    if (parts.any(
      (p) =>
          p.contains('/') ||
          p.contains('..') ||
          p.contains('\\') ||
          p.contains(';') ||
          p.contains('|') ||
          p.contains('>') ||
          p.contains('<') ||
          p.contains('&'),
    )) {
      return {
        'error':
            'Shell syntax, absolute paths, traversal, and separators are not allowed',
      };
    }
    final args = parts.skip(1).toList();
    final safeArgs = <String>[];
    for (final arg in args) {
      if (arg.startsWith('-')) {
        safeArgs.add(arg);
        continue;
      }
      final candidate = File(_safeJoin(ws.path, arg));
      final canonical = candidate.parent.resolveSymbolicLinksSync();
      final root = ws.resolveSymbolicLinksSync();
      if (!(canonical == root || canonical.startsWith('$root/')))
        return {'error': 'Path escapes agent_workspace'};
      if (candidate.existsSync() &&
          candidate.resolveSymbolicLinksSync() != candidate.path)
        return {'error': 'Symlink paths are not allowed'};
      safeArgs.add(_rel(candidate.path));
    }
    final result =
        await Process.run('/system/bin/toybox', [
          parts.first,
          ...safeArgs,
        ], workingDirectory: ws.path).timeout(
          Duration(milliseconds: timeoutMs.clamp(100, _maxShellMs)),
          onTimeout: () => ProcessResult(-1, -1, '', 'Command timed out'),
        );
    String clip(Object value) {
      final text = value.toString();
      return text.length > _maxShellOutputBytes
          ? '${text.substring(0, _maxShellOutputBytes)}…'
          : text;
    }

    return {
      'ok': result.exitCode == 0,
      'exitCode': result.exitCode,
      'stdout': clip(result.stdout),
      'stderr': clip(result.stderr),
    };
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

  Future<Map<String, dynamic>> runGit({
    required String action,
    String path = '.',
    String message = 'Agent commit',
    List<String> files = const ['.'],
    int max = 10,
  }) async {
    final ws = await _workspace();
    try {
      final raw = await _native.invokeMethod<Map<dynamic, dynamic>>('runGit', {
        'workspaceDir': ws.path,
        'action': action,
        'path': path,
        'message': message,
        'files': files,
        'max': max,
      });
      return Map<String, dynamic>.from(raw ?? const {});
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> writeFile(
    String rel,
    String content, {
    bool append = false,
  }) async {
    final f = await _resolveFile(rel);
    f.parent.createSync(recursive: true);
    await f.writeAsString(
      content,
      mode: append ? FileMode.append : FileMode.write,
    );
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
        bytes,
        _mimeFor(ext),
        question,
        kind: 'image',
      );
      return {'ok': true, 'type': 'image', 'observation': desc};
    }
    if (_isAudio(ext)) {
      final bytes = await f.readAsBytes();
      final desc = await _vision.describeBytes(
        bytes,
        _mimeFor(ext),
        question,
        kind: 'audio',
      );
      return {'ok': true, 'type': 'audio', 'observation': desc};
    }
    if (_isVideo(ext)) {
      final bytes = await f.readAsBytes();
      final desc = await _vision.describeBytes(
        bytes,
        _mimeFor(ext),
        question,
        kind: 'video',
      );
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
        return {
          'error': 'file exceeds ${_maxDownloadBytes ~/ (1024 * 1024)}MB cap',
        };
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

  // ---------------------------------------------------------------------------
  // Node.js runner (Node 18.20.4 / nodejs-mobile v18.20.4)
  // ---------------------------------------------------------------------------

  /// Limits shared by [runNode].
  static const _maxNodeOutputBytes = 64 * 1024; // 64 KB per stream
  static const _maxNodeMs = 30000; // 30 s default
  static const _maxNodeMsHard = 120000; // 2 min ceiling
  static const _maxWorkspaceBytes = 100 * 1024 * 1024; // 100 MB disk quota

  /// Run a pure-JavaScript file inside the workspace using the bundled
  /// Node.js 18.20.4 runtime (JaneaSystems nodejs-mobile v18.20.4, arm64-v8a).
  ///
  /// The script runs in a dedicated Android service process (:node) that is
  /// killed with System.exit() after each invocation — V8 is never re-entered
  /// in the same process instance (disposable-process pattern).
  ///
  /// Limits:
  ///   - [timeoutMs]: wall-clock limit (default 30 s, max 120 s).
  ///   - stdout/stderr are each capped at 64 KB.
  ///   - Total workspace disk usage must be ≤ 100 MB before the run starts.
  ///
  /// npm / npx:
  ///   Pass [isNpm]=true (or let the tool detect "npm"/"npx" prefix) to have
  ///   this method prepend "--ignore-scripts" to the effective npm invocation,
  ///   preventing lifecycle hooks (preinstall, postinstall, prepare …) from
  ///   running.  npm itself must be present in the workspace
  ///   (e.g. workspace/node_modules/.bin/npm or workspace/npm/cli.js).
  ///
  /// WARNING – Node 18.20.4 is Maintenance release (official v18.20.4).  Do not use it to
  /// execute untrusted code; it receives no security patches.  See
  /// docs/NODE_RUNTIME.md for details.
  Future<Map<String, dynamic>> runNode(
    String scriptRel, {
    List<String> scriptArgs = const [],
    List<String> nodeFlags = const [],
    int timeoutMs = _maxNodeMs,
    bool isNpm = false,
  }) async {
    final ws = await _workspace();

    // Validate script path stays inside workspace.
    final File scriptFile;
    try {
      scriptFile = await _resolveFile(scriptRel);
    } on FormatException catch (e) {
      return {'error': e.message};
    }
    if (!scriptFile.existsSync()) {
      return {'error': 'Script not found: $scriptRel'};
    }

    // Disk quota check.
    final wsSize = ws
        .listSync(recursive: true)
        .fold<int>(0, (sum, e) => sum + (e is File ? e.lengthSync() : 0));
    if (wsSize > _maxWorkspaceBytes) {
      return {
        'error':
            'Workspace disk quota exceeded '
            '(${wsSize ~/ 1024 ~/ 1024} MB > '
            '${_maxWorkspaceBytes ~/ 1024 ~/ 1024} MB). '
            'Delete files before running Node.',
      };
    }

    // For npm/npx: inject --ignore-scripts to disable lifecycle hooks.
    // effectiveFlags go before the script path (Node VM flags).
    // effectiveArgs go after the script path (script's process.argv).
    final effectiveFlags = <String>[...nodeFlags];
    final effectiveArgs = <String>[
      ...scriptArgs,
      if (isNpm) '--ignore-scripts',
    ];

    final clampedMs = timeoutMs.clamp(1000, _maxNodeMsHard);

    try {
      final result = await _methodChannel.invokeMethod<Map>('runNode', {
        'scriptPath': scriptFile.path,
        'timeoutMs': clampedMs,
        'nodeArgs': effectiveFlags,
        'scriptArgs': effectiveArgs,
        'workspaceDir': ws.path,
      });
      if (result == null) return {'error': 'runNode returned null'};

      String clip(String s) => s.length > _maxNodeOutputBytes
          ? '${s.substring(0, _maxNodeOutputBytes)}…[truncated]'
          : s;

      final timedOut = result['timedOut'] as bool? ?? false;
      final diskQuota = result['diskQuota'] as bool? ?? false;
      if (diskQuota) {
        return {'error': 'Disk quota exceeded (checked server-side).'};
      }
      return {
        'ok': (result['exitCode'] as int? ?? -1) == 0,
        'exitCode': result['exitCode'] ?? -1,
        'stdout': clip((result['stdout'] as String?) ?? ''),
        'stderr': clip((result['stderr'] as String?) ?? ''),
        if (timedOut) 'timedOut': true,
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }
}
