import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rokid_browser_glasses/web_remote_server.dart';

void main() {
  late WebRemoteServer server;
  final commands = <Map<String, dynamic>>[];
  var captures = 0;

  Future<void> start({
    Duration pairingLifetime = const Duration(minutes: 5),
    Duration reconnectGrace = const Duration(seconds: 60),
    RemoteCapture? capture,
  }) async {
    server = WebRemoteServer(
      bindAddress: InternetAddress.loopbackIPv4,
      allowLoopbackForTesting: true,
      pairingLifetime: pairingLifetime,
      reconnectGrace: reconnectGrace,
      pageHtml: '<!doctype html><title>test</title>',
      onCommand: commands.add,
      state: () => {
        'title': 'Test',
        'viewportWidth': 480,
        'viewportHeight': 640,
        'density': 1,
        'hudHeight': 44,
      },
      onCapture:
          capture ??
          (width, height) async {
            captures++;
            return Uint8List.fromList([0xff, 0xd8, captures, 0xff, 0xd9]);
          },
    );
    await server.start();
  }

  Future<HttpClientResponse> get({String? host}) async {
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse(server.address));
    if (host != null) request.headers.set(HttpHeaders.hostHeader, host);
    final response = await request.close();
    client.close(force: true);
    return response;
  }

  Future<HttpClientResponse> pair(String code, {String? origin}) async {
    final client = HttpClient();
    final request = await client.postUrl(Uri.parse('${server.address}/pair'));
    request.headers.contentType = ContentType.json;
    if (origin != null) request.headers.set('origin', origin);
    request.write(jsonEncode({'code': code}));
    final response = await request.close();
    return response;
  }

  Future<String> pairToken() async {
    final response = await pair(server.pairingCode, origin: server.origin);
    expect(response.statusCode, HttpStatus.ok);
    final body = await utf8.decoder.bind(response).join();
    return (jsonDecode(body) as Map<String, dynamic>)['token'] as String;
  }

  Future<WebSocket> connect(String token) async {
    final socket = await WebSocket.connect(
      '${server.address.replaceFirst('http:', 'ws:')}/ws',
      headers: {'origin': server.origin},
    );
    socket.add(jsonEncode({'type': 'auth', 'token': token}));
    return socket;
  }

  Future<Map<String, dynamic>> nextJson(StreamIterator<dynamic> events) async {
    while (await events.moveNext()) {
      if (events.current is String) {
        return jsonDecode(events.current as String) as Map<String, dynamic>;
      }
    }
    throw StateError('socket closed');
  }

  tearDown(() async {
    commands.clear();
    captures = 0;
    if (server.running) await server.stop();
  });

  test('binds only explicit allowed address and enforces exact Host', () async {
    await start();
    expect(server.address, startsWith('http://127.0.0.1:'));
    final accepted = await get();
    expect(accepted.statusCode, HttpStatus.ok);
    expect(accepted.headers.value('cache-control'), contains('no-store'));
    expect(accepted.headers.value('referrer-policy'), 'no-referrer');
    await accepted.drain<void>();

    final rejected = await get(
      host: '192.168.1.99:${Uri.parse(server.address).port}',
    );
    expect(rejected.statusCode, HttpStatus.forbidden);
    await rejected.drain<void>();
  });

  test('pair writes and websocket require exact non-missing Origin', () async {
    await start();
    final missing = await pair(server.pairingCode);
    expect(missing.statusCode, HttpStatus.forbidden);
    await missing.drain<void>();

    final foreign = await pair(
      server.pairingCode,
      origin: 'http://192.168.1.8:80',
    );
    expect(foreign.statusCode, HttpStatus.forbidden);
    await foreign.drain<void>();

    await expectLater(
      WebSocket.connect('${server.address.replaceFirst('http:', 'ws:')}/ws'),
      throwsA(isA<WebSocketException>()),
    );
  });

  test('pairing expires and failed attempts are rate limited', () async {
    await start();
    for (var i = 0; i < 5; i++) {
      final wrong = await pair('000000', origin: server.origin);
      expect(wrong.statusCode, HttpStatus.unauthorized);
      await wrong.drain<void>();
    }
    final limited = await pair('000000', origin: server.origin);
    expect(limited.statusCode, HttpStatus.tooManyRequests);
    await limited.drain<void>();
  });

  test(
    'authenticates without URL secret and reserves one controller',
    () async {
      await start();
      final token = await pairToken();
      expect(server.address, isNot(contains(token)));
      final socket = await connect(token);
      final events = StreamIterator<dynamic>(socket);
      expect((await nextJson(events))['type'], 'ready');

      await expectLater(
        WebSocket.connect(
          '${server.address.replaceFirst('http:', 'ws:')}/ws',
          headers: {'origin': server.origin},
        ),
        throwsA(isA<WebSocketException>()),
      );
      await events.cancel();
      await socket.close();
    },
  );

  test('allowlist validates schema and reports command failures', () async {
    await start();
    final socket = await connect(await pairToken());
    final events = StreamIterator<dynamic>(socket);
    expect((await nextJson(events))['type'], 'ready');
    expect((await nextJson(events))['type'], 'state');
    // Consume the unsolicited first frame; command responses follow it.
    expect((await nextJson(events))['type'], 'frame');
    expect(await events.moveNext(), isTrue);
    expect(events.current, isA<List<int>>());

    socket.add(
      jsonEncode({
        'type': 'command',
        'action': 'javascript',
        'script': 'alert(1)',
        'requestId': 1,
      }),
    );
    expect((await nextJson(events))['code'], 'invalid_command');

    socket.add(
      jsonEncode({
        'type': 'command',
        'action': 'click',
        'x': 1.1,
        'y': 0.5,
        'requestId': 2,
      }),
    );
    expect((await nextJson(events))['code'], 'invalid_command');

    socket.add(
      jsonEncode({
        'type': 'command',
        'action': 'type',
        'text': 'whole text, not a char field',
        'requestId': 3,
      }),
    );
    expect((await nextJson(events))['type'], 'command_ok');
    expect(commands.single['action'], 'type');
    expect(commands.single['text'], 'whole text, not a char field');
    await events.cancel();
    await socket.close();
  });

  test('binary frames require matching ACK and never queue captures', () async {
    await start();
    final socket = await connect(await pairToken());
    final events = StreamIterator<dynamic>(socket);
    expect((await nextJson(events))['type'], 'ready');
    expect((await nextJson(events))['type'], 'state');
    final metadata = await nextJson(events);
    expect(metadata['type'], 'frame');
    expect(await events.moveNext(), isTrue);
    expect(events.current, isA<List<int>>());
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(captures, 1);

    socket.add(jsonEncode({'type': 'ack', 'frameId': metadata['frameId']}));
    final secondMetadata = await nextJson(events);
    expect(secondMetadata['type'], 'frame');
    expect(captures, 2);
    await events.cancel();
    await socket.close();
  });

  test(
    'transient reconnect retains owner token despite invalid auth',
    () async {
      await start();
      final token = await pairToken();
      var socket = await connect(token);
      var events = StreamIterator<dynamic>(socket);
      expect((await nextJson(events))['type'], 'ready');
      await events.cancel();
      await socket.close();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      socket = await connect('invalid');
      events = StreamIterator<dynamic>(socket);
      expect((await nextJson(events))['code'], 'unauthorized');
      await events.cancel();
      await socket.close();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      socket = await connect(token);
      events = StreamIterator<dynamic>(socket);
      expect((await nextJson(events))['type'], 'ready');
      await events.cancel();
      await socket.close();
    },
  );

  test('grace expires and revoke rejects old credentials', () async {
    await start(reconnectGrace: const Duration(milliseconds: 120));
    final old = await pairToken();
    await Future<void>.delayed(const Duration(milliseconds: 160));
    await expectLater(connect(old), throwsA(isA<WebSocketException>()));
    await pairToken();
    var socket = await connect(old);
    var events = StreamIterator<dynamic>(socket);
    expect((await nextJson(events))['code'], 'unauthorized');
    await events.cancel();
    await socket.close();
    await server.revoke();
    final token = await pairToken();
    socket = await connect(token);
    events = StreamIterator<dynamic>(socket);
    expect((await nextJson(events))['type'], 'ready');
    await server.revoke();
    await events.cancel();
    await socket.close();
    await pairToken();
    socket = await connect(token);
    events = StreamIterator<dynamic>(socket);
    expect((await nextJson(events))['code'], 'unauthorized');
    await events.cancel();
    await socket.close();
  });

  test('pause stops frames; resume waits for outstanding ACK', () async {
    await start();
    final socket = await connect(await pairToken());
    final events = StreamIterator<dynamic>(socket);
    await nextJson(events);
    await nextJson(events);
    final meta = await nextJson(events);
    await events.moveNext();
    socket.add(jsonEncode({'type': 'pause', 'extra': true}));
    expect((await nextJson(events))['code'], 'invalid_command');
    socket.add(jsonEncode({'type': 'pause'}));
    await Future<void>.delayed(const Duration(milliseconds: 3200));
    expect(server.paired, isTrue);
    expect(captures, 1);
    socket.add(jsonEncode({'type': 'resume'}));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(captures, 1);
    socket.add(jsonEncode({'type': 'ack', 'frameId': meta['frameId']}));
    expect((await nextJson(events))['type'], 'frame');
    expect(captures, 2);
    await events.cancel();
    await socket.close();
  });

  test('old capture cannot leak to reconnected controller', () async {
    final pending = Completer<Uint8List?>();
    var calls = 0;
    await start(
      capture: (_, _) {
        calls++;
        return calls == 1
            ? pending.future
            : Future.value(Uint8List.fromList([2]));
      },
    );
    final token = await pairToken();
    var socket = await connect(token);
    var events = StreamIterator<dynamic>(socket);
    await nextJson(events);
    await nextJson(events);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(calls, 1);
    await events.cancel();
    await socket.close();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    socket = await connect(token);
    events = StreamIterator<dynamic>(socket);
    await nextJson(events);
    await nextJson(events);
    expect(calls, 1);
    pending.complete(Uint8List.fromList([9, 9, 9]));
    final meta = await nextJson(events);
    expect(meta['byteLength'], 1);
    expect(calls, 2);
    await events.cancel();
    await socket.close();
  });

  test('stop invalidates token across restart', () async {
    await start();
    final old = await pairToken();
    await server.stop();
    await server.start();
    await pairToken();
    final socket = await connect(old);
    final events = StreamIterator<dynamic>(socket);
    expect((await nextJson(events))['code'], 'unauthorized');
    await events.cancel();
    await socket.close();
  });

  test('ACK timeout closes once and allows bounded reconnect', () async {
    await start();
    final token = await pairToken();
    var socket = await connect(token);
    var events = StreamIterator<dynamic>(socket);
    await nextJson(events);
    await nextJson(events);
    await nextJson(events);
    await events.moveNext();
    expect((await nextJson(events))['code'], 'frame_timeout');
    expect(await events.moveNext(), isFalse);
    expect(captures, 1);
    socket = await connect(token);
    events = StreamIterator<dynamic>(socket);
    expect((await nextJson(events))['type'], 'ready');
    await events.cancel();
    await socket.close();
  });

  test(
    'pause during capture discards it and resumes without overlap',
    () async {
      final pending = Completer<Uint8List?>();
      var calls = 0;
      await start(
        capture: (_, _) {
          calls++;
          return calls == 1
              ? pending.future
              : Future.value(Uint8List.fromList([2]));
        },
      );
      final socket = await connect(await pairToken());
      final events = StreamIterator<dynamic>(socket);
      await nextJson(events);
      await nextJson(events);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      socket.add(jsonEncode({'type': 'pause'}));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      pending.complete(Uint8List.fromList([9, 9, 9]));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, 1);
      socket.add(jsonEncode({'type': 'resume'}));
      expect((await nextJson(events))['byteLength'], 1);
      expect(calls, 2);
      await events.cancel();
      await socket.close();
    },
  );

  test('stop closes controller and capture loop', () async {
    await start();
    final socket = await connect(await pairToken());
    final done = Completer<void>();
    socket.listen((_) {}, onDone: done.complete);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await server.stop();
    await done.future.timeout(const Duration(seconds: 1));
    final before = captures;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(captures, before);
    expect(server.running, isFalse);
  });
}
