import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'browser_agent.dart';
import 'agent_settings.dart';

typedef RemoteCommandHandler =
    FutureOr<void> Function(Map<String, dynamic> command);
typedef RemoteCapture =
    Future<Uint8List?> Function(int maxWidth, int maxHeight);

enum WebRemoteStatus { stopped, waiting, paired }

/// Owner-started, same-LAN browser remote. It deliberately binds one RFC1918
/// address instead of a wildcard and treats Host + Origin as authentication
/// boundary inputs, not merely as hints.
class WebRemoteServer {
  WebRemoteServer({
    required this.onCommand,
    required this.state,
    required this.onCapture,
    required this.pageHtml,
    this.onStatusChanged,
    InternetAddress? bindAddress,
    this.pairingLifetime = const Duration(minutes: 5),
    this.reconnectGrace = const Duration(seconds: 60),
    this.preferredPort = 8765,
    bool allowLoopbackForTesting = false,
  }) : _requestedAddress = bindAddress,
       _allowLoopbackForTesting = allowLoopbackForTesting;

  final RemoteCommandHandler onCommand;
  final Map<String, dynamic> Function() state;
  final RemoteCapture onCapture;
  String pageHtml;
  final void Function(WebRemoteStatus status)? onStatusChanged;
  final Duration pairingLifetime;
  final Duration reconnectGrace;

  /// Preferred listening port (bookmarkable). 0 = OS assigned.
  final int preferredPort;
  Timer? _graceTimer;
  int _generation = 0;
  bool _paused = false;
  final InternetAddress? _requestedAddress;
  final bool _allowLoopbackForTesting;

  final Random _random = Random.secure();
  final Map<String, List<DateTime>> _pairAttempts = {};
  HttpServer? _server;
  WebSocket? _controller;
  StreamSubscription<HttpRequest>? _requests;
  Timer? _authTimer;
  Timer? _frameTimer;
  Timer? _ackTimer;
  String? _sessionToken;
  bool _controllerReserved = false;
  bool _authenticated = false;
  bool _captureBusy = false;
  bool _awaitingAck = false;
  int _frameId = 0;
  int _commandsInWindow = 0;
  DateTime _commandWindow = DateTime.fromMillisecondsSinceEpoch(0);
  int _captureWidth = 480;
  int _captureHeight = 640;
  late String pairingCode;
  late DateTime pairingExpiresAt;

  bool get running => _server != null;
  bool get paired => _authenticated;
  String get address => _server == null
      ? ''
      : 'http://${_server!.address.address}:${_server!.port}';
  String get origin => address;

  static bool isPrivateIPv4(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) return false;
    final b = address.rawAddress;
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }

  static Future<InternetAddress?> findPrivateIPv4() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final candidates = <({InternetAddress address, String name})>[
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (isPrivateIPv4(address))
            (address: address, name: interface.name.toLowerCase()),
    ];
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      int rank(String name) =>
          name == 'wlan0' || name.startsWith('wifi') ? 0 : 1;
      return rank(a.name).compareTo(rank(b.name));
    });
    return candidates.first.address;
  }

  Future<void>? _starting;
  Future<void> start() async {
    if (running) return;
    // Serialize concurrent starts (auto-start on launch + a Start tap can race
    // across the awaits below and bind twice). All callers await one attempt.
    if (_starting != null) return _starting;
    final done = _start();
    _starting = done;
    try {
      await done;
    } finally {
      _starting = null;
    }
  }

  Future<void> _start() async {
    if (running) return;
    final bindAddress = _requestedAddress ?? await findPrivateIPv4();
    if (bindAddress == null ||
        (!isPrivateIPv4(bindAddress) &&
            !(_allowLoopbackForTesting && bindAddress.isLoopback))) {
      throw StateError('No private IPv4 Wi-Fi/LAN address is available');
    }
    _rotateCredentials();
    // Fixed port so the phone can bookmark the address; fall back to an OS
    // assigned port only if it is taken.
    HttpServer server;
    try {
      server = await HttpServer.bind(bindAddress, preferredPort, shared: false);
    } on SocketException {
      server = await HttpServer.bind(bindAddress, 0, shared: false);
    }
    _server = server;
    _requests = server.listen(
      _handle,
      onError: (Object error, StackTrace stack) => unawaited(stop()),
      cancelOnError: true,
    );
    onStatusChanged?.call(WebRemoteStatus.waiting);
  }

  void _rotateCredentials() {
    pairingCode = (_random.nextInt(900000) + 100000).toString();
    pairingExpiresAt = DateTime.now().add(pairingLifetime);
    _graceTimer?.cancel();
    _sessionToken = null;
    _pairAttempts.clear();
  }

  void _securityHeaders(HttpResponse response) {
    response.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store, max-age=0')
      ..set(HttpHeaders.pragmaHeader, 'no-cache')
      ..set('referrer-policy', 'no-referrer')
      ..set('x-content-type-options', 'nosniff')
      ..set('x-frame-options', 'DENY')
      ..set(
        'content-security-policy',
        "default-src 'none'; img-src blob:; style-src 'unsafe-inline'; "
            "script-src 'unsafe-inline'; connect-src 'self'; "
            "form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
      );
  }

  bool _exactHost(HttpRequest request) =>
      request.headers.host == _server!.address.address &&
      (request.headers.port ?? 80) == _server!.port;

  bool _exactOrigin(HttpRequest request) =>
      request.headers.value('origin') == origin;

  Future<void> _reject(HttpRequest request, int status, String message) async {
    _securityHeaders(request.response);
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'error': message}));
    await request.response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    _securityHeaders(request.response);
    if (!_exactHost(request)) {
      await _reject(request, HttpStatus.forbidden, 'Invalid Host');
      return;
    }
    if (request.method == 'GET' &&
        (request.uri.path == '/' || request.uri.path == '/index.html')) {
      request.response
        ..headers.contentType = ContentType.html
        ..write(pageHtml);
      await request.response.close();
      return;
    }
    if (request.method == 'POST' && request.uri.path == '/pair') {
      await _pair(request);
      return;
    }
    if (request.method == 'GET' && request.uri.path == '/ws') {
      await _upgrade(request);
      return;
    }
    await _reject(request, HttpStatus.notFound, 'Not found');
  }

  Future<void> _pair(HttpRequest request) async {
    if (!_exactOrigin(request)) {
      await _reject(request, HttpStatus.forbidden, 'Invalid or missing Origin');
      return;
    }
    final contentType = request.headers.contentType;
    if (contentType?.mimeType != 'application/json') {
      await _reject(request, HttpStatus.unsupportedMediaType, 'JSON required');
      return;
    }
    final remote = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final now = DateTime.now();
    final attempts = _pairAttempts.putIfAbsent(
      remote,
      () => <DateTime>[],
    )..removeWhere((time) => now.difference(time) > const Duration(minutes: 1));
    if (attempts.length >= 20) {
      await _reject(request, HttpStatus.tooManyRequests, 'Try again later');
      return;
    }
    attempts.add(now);
    try {
      final bytes = await request.fold<List<int>>(<int>[], (all, chunk) {
        if (all.length + chunk.length > 256) {
          throw const FormatException('Pair request too large');
        }
        return all..addAll(chunk);
      });
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map ||
          decoded.keys.any((key) => key != 'code' && key != 'force')) {
        throw const FormatException('Invalid pair schema');
      }
      // Owner decision 2026-09-07: no pairing code. Knowing the LAN address
      // + random port (shown only on the glasses) is the credential; the owner
      // can still revoke/stop from the glasses, and only one controller is
      // admitted at a time. The optional code is still honoured if supplied.
      final code = decoded['code'];
      if (code is String &&
          code.isNotEmpty &&
          !_constantTimeEquals(code, pairingCode)) {
        await _reject(
          request,
          HttpStatus.unauthorized,
          'Incorrect pairing code',
        );
        return;
      }
      // No pairing code (owner decision): a fresh /pair simply REPLACES the
      // previous controller. A phone that refreshed after being backgrounded
      // must be able to reconnect immediately instead of waiting for the old
      // session's grace period to expire.
      // A LIVE, authenticated controller keeps its seat (prevents two tabs
      // from stealing the session back and forth). Only a dead/grace session
      // is replaced, which is the "backgrounded Safari tab" case.
      final force = decoded['force'] == true;
      if (_controller != null && _authenticated && !force) {
        await _reject(
          request,
          HttpStatus.conflict,
          'A controller is already paired',
        );
        return;
      }
      if (_controller != null || _controllerReserved) {
        final old = _controller;
        _releaseController(old, hard: false);
        try {
          await old?.close(
            WebSocketStatus.goingAway,
            'Replaced by a new controller',
          );
        } catch (_) {}
      }
      _sessionToken = base64Url.encode(
        List<int>.generate(32, (_) => _random.nextInt(256)),
      );
      _startGrace();
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'token': _sessionToken}));
      await request.response.close();
    } on FormatException catch (error) {
      await _reject(request, HttpStatus.badRequest, error.message);
    } catch (_) {
      await _reject(request, HttpStatus.badRequest, 'Invalid pair request');
    }
  }

  bool _constantTimeEquals(String a, String b) {
    final aa = utf8.encode(a);
    final bb = utf8.encode(b);
    var difference = aa.length ^ bb.length;
    final length = max(aa.length, bb.length);
    for (var i = 0; i < length; i++) {
      difference |= (i < aa.length ? aa[i] : 0) ^ (i < bb.length ? bb[i] : 0);
    }
    return difference == 0;
  }

  Future<void> _upgrade(HttpRequest request) async {
    if (!_exactOrigin(request)) {
      await _reject(request, HttpStatus.forbidden, 'Invalid or missing Origin');
      return;
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      await _reject(
        request,
        HttpStatus.badRequest,
        'WebSocket upgrade required',
      );
      return;
    }
    // This reservation is made before the asynchronous upgrade. Dart's event loop
    // cannot admit two controllers through this point in the same isolate.
    if (_controllerReserved || _controller != null || _sessionToken == null) {
      await _reject(request, HttpStatus.conflict, 'Controller unavailable');
      return;
    }
    _controllerReserved = true;
    final generation = _generation;
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      if (!running || generation != _generation || _sessionToken == null) {
        await socket.close(WebSocketStatus.policyViolation);
        return;
      }
      _controller = socket;
      socket.listen(
        (message) => _message(socket, message),
        onDone: () => _releaseController(socket),
        onError: (_) => _releaseController(socket),
        cancelOnError: true,
      );
      _authTimer = Timer(const Duration(seconds: 5), () {
        if (!_authenticated && identical(_controller, socket)) {
          _sendError('auth_timeout', 'Authentication timed out');
          unawaited(socket.close(WebSocketStatus.policyViolation));
        }
      });
    } catch (_) {
      if (generation == _generation) _controllerReserved = false;
    }
  }

  void _message(WebSocket socket, dynamic raw) {
    if (!identical(socket, _controller)) return;
    if (raw is! String || raw.length > 4096) {
      _sendError('invalid_message', 'Text message too large or invalid');
      return;
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Object required');
      }
      if (!_authenticated) {
        if (value.length != 2 ||
            value['type'] != 'auth' ||
            value['token'] is! String ||
            !_constantTimeEquals(
              value['token'] as String,
              _sessionToken ?? '',
            )) {
          _sendError('unauthorized', 'Authentication failed');
          unawaited(socket.close(WebSocketStatus.policyViolation));
          return;
        }
        _authTimer?.cancel();
        _graceTimer?.cancel();
        _authenticated = true;
        onStatusChanged?.call(WebRemoteStatus.paired);
        _send({'type': 'ready', 'maxFps': 5});
        publishState();
        _scheduleFrame(Duration.zero);
        return;
      }
      if (value['type'] == 'pause' || value['type'] == 'resume') {
        if (value.length != 1) {
          throw const FormatException('Invalid visibility schema');
        }
        final wasPaused = _paused;
        _paused = value['type'] == 'pause';
        if (!_paused && !wasPaused) return;
        if (_paused) {
          _frameTimer?.cancel();
          _ackTimer?.cancel();
        } else if (_awaitingAck) {
          _armAckTimeout(socket);
        } else {
          _scheduleFrame(Duration.zero);
        }
        return;
      }
      if (value['type'] == 'ack') {
        if (value.length != 2 ||
            value['frameId'] != _frameId ||
            !_awaitingAck) {
          throw const FormatException('Invalid frame ACK');
        }
        _ackTimer?.cancel();
        _awaitingAck = false;
        _scheduleFrame(const Duration(milliseconds: 200));
        return;
      }
      if (value['type'] == 'viewport') {
        if (value.length != 3 ||
            value['width'] is! num ||
            value['height'] is! num) {
          throw const FormatException('Invalid viewport');
        }
        _captureWidth = (value['width'] as num).round().clamp(160, 960);
        _captureHeight = (value['height'] as num).round().clamp(160, 1280);
        return;
      }
      final command = _validateCommand(value);
      if (!_takeCommandRateSlot()) {
        _sendError('rate_limited', 'Too many commands');
        return;
      }
      if (command['action'] == 'exit_app') {
        _send({'type': 'bye', 'reason': 'exit'});
        unawaited(
          Future<void>(() async {
            await stop();
            await onCommand(command);
          }),
        );
        return;
      }
      Future<void>.sync(() => onCommand(command))
          .then((_) {
            if (!identical(socket, _controller)) return;
            _send({'type': 'command_ok', 'requestId': command['requestId']});
          })
          .catchError((Object error) {
            if (!identical(socket, _controller)) return;
            _sendError(
              'command_failed',
              error.toString(),
              command['requestId'],
            );
          });
    } on FormatException catch (error) {
      _sendError('invalid_command', error.message);
    } catch (_) {
      _sendError('invalid_json', 'Malformed message');
    }
  }

  bool _takeCommandRateSlot() {
    final now = DateTime.now();
    if (now.difference(_commandWindow) >= const Duration(seconds: 1)) {
      _commandWindow = now;
      _commandsInWindow = 0;
    }
    if (_commandsInWindow >= 30) return false;
    _commandsInWindow++;
    return true;
  }

  Map<String, dynamic> _validateCommand(Map<String, dynamic> value) {
    if (value['type'] != 'command' || value['action'] is! String) {
      throw const FormatException('Command type/action required');
    }
    final action = value['action'] as String;
    final allowedKeys = <String>{'type', 'action', 'requestId'};
    void allow(String key) => allowedKeys.add(key);
    bool finiteUnit(dynamic number) =>
        number is num && number.isFinite && number >= 0 && number <= 1;
    switch (action) {
      case 'get_asr_key':
      case 'clear_asr_key':
      case 'list_asr_models':
      case 'history_list':
      case 'history_clear':
      case 'debug_probe':
      case 'get_agent_settings':
      case 'reset_agent_persona':
      case 'clear_agent_history':
        break;
      case 'set_agent_history':
      case 'set_agent_speak':
        allow('on');
        if (value['on'] is! bool) throw const FormatException('Invalid flag');
      case 'set_agent_voice':
        allow('voice');
        if (value['voice'] is! String || (value['voice'] as String).length > 40)
          throw const FormatException('Invalid voice');
      case 'set_agent_persona':
        allow('persona');
        if (value['persona'] is! String ||
            (value['persona'] as String).length > 1200)
          throw const FormatException('Invalid persona');
      case 'agent_trace':
      case 'agent_history':
      case 'agent_history_clear':
        break;
      case 'agent_history_remove':
        allow('index');
        if (value['index'] is! num)
          throw const FormatException('Invalid history index');
      case 'agent_run':
        allow('text');
        if (value['text'] is! String ||
            (value['text'] as String).trim().isEmpty ||
            (value['text'] as String).length > 400)
          throw const FormatException('Invalid command');
      case 'set_asr_model':
        allow('model');
        if (value['model'] is! String || (value['model'] as String).length > 80)
          throw const FormatException('Invalid model');
      case 'set_asr_key':
        allow('key');
        if (value['key'] is! String || (value['key'] as String).length > 200)
          throw const FormatException('Invalid key');
      case 'history_remove':
        allow('url');
        if (value['url'] is! String) throw const FormatException('Invalid URL');
      case 'exit_app':
        allow('confirmed');
        if (value['confirmed'] != true) {
          throw const FormatException('Exit confirmation required');
        }
      case 'back':
      case 'forward':
      case 'reload':
      case 'zoom_in':
      case 'zoom_out':
      case 'scroll_up':
      case 'scroll_down':
      case 'scroll_left':
      case 'scroll_right':
      case 'toggle_hud':
      case 'toggle_passthrough':
      case 'enter':
      case 'backspace':
      case 'cursor_click':
      case 'cursor_dblclick':
      case 'cursor_drag_start':
      case 'cursor_drag_end':
        break;
      case 'navigate':
        allow('url');
        final url = value['url'];
        if (url is! String || url.isEmpty || url.length > 2048) {
          throw const FormatException('Invalid URL');
        }
      case 'type':
        allow('text');
        final text = value['text'];
        if (text is! String || text.isEmpty || text.length > 512) {
          throw const FormatException('Invalid text');
        }
      case 'click':
        allow('x');
        allow('y');
        if (!finiteUnit(value['x']) || !finiteUnit(value['y'])) {
          throw const FormatException('Click coordinates must be normalized');
        }
      case 'swipe':
      case 'cursor_move':
      case 'cursor_drag_move':
        allow('dx');
        allow('dy');
        final dx = value['dx'];
        final dy = value['dy'];
        if (dx is! num ||
            dy is! num ||
            !dx.isFinite ||
            !dy.isFinite ||
            dx.abs() > 1 ||
            dy.abs() > 1 ||
            (dx == 0 && dy == 0)) {
          throw const FormatException('Invalid normalized delta');
        }
      case 'set_visual_mode':
        allow('mode');
        if (!const {
          'normal',
          'transparent',
          'wireframe',
        }.contains(value['mode'])) {
          throw const FormatException('Invalid visual mode');
        }
      case 'set_dim':
        allow('value');
        if (!finiteUnit(value['value']) || (value['value'] as num) > 0.8) {
          throw const FormatException('Invalid dim value');
        }
      default:
        throw const FormatException('Action is not allowed');
    }
    final requestId = value['requestId'];
    if (requestId is! int || requestId < 0 || requestId > 0x7fffffff) {
      throw const FormatException('Invalid request id');
    }
    if (value.keys.any((key) => !allowedKeys.contains(key))) {
      throw const FormatException('Unexpected command field');
    }
    final command = Map<String, dynamic>.from(value)..remove('type');
    if (action == 'click') command['action'] = 'remote_click';
    if (action == 'swipe') command['action'] = 'remote_swipe';
    if (action == 'cursor_move') command['action'] = 'remote_cursor_move';
    if (action == 'cursor_drag_move') command['action'] = 'remote_drag_move';
    return command;
  }

  void _scheduleFrame(Duration delay) {
    _frameTimer?.cancel();
    if (!_authenticated || _paused || _awaitingAck || _captureBusy) return;
    _frameTimer = Timer(delay, _captureFrame);
  }

  Future<void> _captureFrame() async {
    if (!_authenticated || _paused || _awaitingAck || _captureBusy) return;
    _captureBusy = true;
    final generation = _generation;
    final socket = _controller!;
    try {
      final bytes = await onCapture(_captureWidth, _captureHeight);
      if (generation != _generation ||
          !identical(socket, _controller) ||
          !_authenticated ||
          _paused) {
        return;
      }
      if (bytes == null || bytes.isEmpty) {
        _scheduleFrame(const Duration(milliseconds: 500));
        return;
      }
      final details = state();
      _frameId++;
      _awaitingAck = true;
      _send({
        'type': 'frame',
        'frameId': _frameId,
        'byteLength': bytes.length,
        'sourceWidth': details['viewportWidth'],
        'sourceHeight': details['viewportHeight'],
        'density': details['density'],
        'hudHeight': details['hudHeight'],
      });
      try {
        socket.add(bytes);
      } catch (_) {
        _releaseController(socket);
        return;
      }
      _armAckTimeout(socket);
    } catch (error) {
      if (generation != _generation || !identical(socket, _controller)) return;
      _sendError('capture_failed', error.toString());
      _scheduleFrame(const Duration(seconds: 1));
    } finally {
      _captureBusy = false;
      if (_frameTimer?.isActive != true) {
        _scheduleFrame(const Duration(milliseconds: 500));
      }
    }
  }

  void _armAckTimeout(WebSocket socket) {
    _ackTimer?.cancel();
    final generation = _generation;
    _ackTimer = Timer(const Duration(seconds: 3), () {
      if (generation != _generation ||
          !identical(socket, _controller) ||
          _paused ||
          !_awaitingAck) {
        return;
      }
      _sendError('frame_timeout', 'Frame decode ACK timed out');
      _releaseController(socket);
      unawaited(socket.close(WebSocketStatus.goingAway));
    });
  }

  void _send(Map<String, dynamic> value) {
    if (_controller == null) return;
    try {
      _controller!.add(jsonEncode(value));
    } catch (_) {}
  }

  void _sendError(String code, String message, [dynamic requestId]) {
    _send({
      'type': 'error',
      'code': code,
      'message': message,
      'requestId': ?requestId,
    });
  }

  void publishDebug(String payload) {
    if (_authenticated) _send({'type': 'debug', 'payload': payload});
  }

  void publishAgentTrace(List<Map<String, dynamic>> trace) {
    if (_authenticated)
      _send({
        'type': 'agent_trace',
        'trace': trace.length > 120 ? trace.sublist(trace.length - 120) : trace,
      });
  }

  void publishAgentHistory(List<Map<String, dynamic>> items) {
    if (_authenticated)
      _send({'type': 'agent_history', 'items': items.take(100).toList()});
  }

  void publishAgent(String message) {
    if (_authenticated) _send({'type': 'agent', 'message': message});
  }

  void publishAsrModel(String model, List<String>? models) {
    if (_authenticated)
      _send({
        'type': 'asr_model',
        'model': model,
        if (models != null) 'models': models,
      });
  }

  void publishAgentSettings() {
    if (!_authenticated) return;
    _send({
      'type': 'agent_settings',
      'history': BrowserAgent.historyEnabled,
      'speak': AgentSettings.speakEnabled,
      'voice': AgentSettings.voice,
      'voices': AgentSettings.voices,
      'persona': AgentSettings.persona,
      'defaultPersona': BrowserAgent.defaultPersona,
    });
  }

  void publishAsrKeyState(String key) {
    if (_authenticated) {
      _send({
        'type': 'asr_key',
        'hasKey': key.isNotEmpty,
        'tail': key.length > 4 ? key.substring(key.length - 4) : '',
      });
    }
  }

  void publishHistory(List<String> items) {
    if (_authenticated)
      _send({'type': 'history', 'items': items.take(200).toList()});
  }

  void publishState() {
    if (_authenticated) _send({'type': 'state', ...state()});
  }

  void _startGrace() {
    // Do not extend an existing deadline for unauthenticated attempts.
    if (_graceTimer?.isActive == true) return;
    _graceTimer = Timer(reconnectGrace, () {
      _graceTimer = null;
      if (!_authenticated) unawaited(revoke());
    });
  }

  void _releaseController(WebSocket? socket, {bool hard = false}) {
    if (socket != null && !identical(socket, _controller)) return;
    final wasAuthenticated = _authenticated;
    _generation++;
    _authTimer?.cancel();
    _frameTimer?.cancel();
    _ackTimer?.cancel();
    _controller = null;
    _controllerReserved = false;
    _authenticated = false;
    // Capture remains busy until its actual Future completes.
    _awaitingAck = false;
    _paused = false;
    if (hard) {
      _rotateCredentials();
    } else if (wasAuthenticated && _sessionToken != null) {
      _startGrace();
    }
    if (running) onStatusChanged?.call(WebRemoteStatus.waiting);
  }

  Future<void> revoke() async {
    final socket = _controller;
    _releaseController(socket, hard: true);
    try {
      await socket?.close(WebSocketStatus.goingAway, 'Revoked by owner');
    } catch (_) {}
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    final socket = _controller;
    _releaseController(socket, hard: true);
    _sessionToken = null;
    try {
      await socket?.close(WebSocketStatus.goingAway, 'Server stopped');
    } catch (_) {}
    await _requests?.cancel();
    _requests = null;
    await server?.close(force: true);
    onStatusChanged?.call(WebRemoteStatus.stopped);
  }
}
