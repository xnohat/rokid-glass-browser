import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Push-to-talk speech-to-text via Gemini (the glasses have no Google Speech).
/// Native side records 16 kHz mono PCM into a WAV file; we upload it inline.
class VoiceAsr {
  VoiceAsr(this._channel);
  final MethodChannel _channel;
  static const _prefKey = 'gemini_api_key';
  static const _model = 'gemini-2.5-flash';

  static Future<String> loadKey() async =>
      (await SharedPreferences.getInstance()).getString(_prefKey) ?? '';

  static Future<void> saveKey(String key) async =>
      (await SharedPreferences.getInstance()).setString(_prefKey, key.trim());

  bool _recording = false;
  bool get recording => _recording;

  Future<void> start() async {
    if (_recording) return;
    await _channel.invokeMethod('asrStart');
    _recording = true;
  }

  /// Stops recording and returns the recognised text ('' on silence).
  /// Throws [StateError] with a human message when key/network fails.
  Future<String> stopAndTranscribe({String lang = 'vi'}) async {
    if (!_recording) return '';
    _recording = false;
    final path = await _channel.invokeMethod<String>('asrStop');
    if (path == null) throw StateError('Không ghi được âm thanh');
    final key = await loadKey();
    if (key.isEmpty) throw StateError('Chưa có Gemini API key (nhập ở web remote)');
    final bytes = await File(path).readAsBytes();
    if (bytes.length < 4000) return '';
    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {
              'text':
                  'Transcribe this audio verbatim. Reply with ONLY the spoken text, no quotes, no explanation. Language is most likely $lang or English.'
            },
            {
              'inline_data': {'mime_type': 'audio/wav', 'data': base64Encode(bytes)}
            },
          ]
        }
      ],
      'generationConfig': {'temperature': 0, 'maxOutputTokens': 200}
    });
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent?key=$key'));
      req.headers.contentType = ContentType.json;
      req.write(body);
      final res = await req.close().timeout(const Duration(seconds: 30));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        final msg = (jsonDecode(text)['error']?['message'] ?? 'HTTP ${res.statusCode}').toString();
        throw StateError('Gemini: ${msg.length > 80 ? msg.substring(0, 80) : msg}');
      }
      final j = jsonDecode(text);
      final out = (j['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '').toString().trim();
      return out.replaceAll(RegExp(r'^["“]|["”]$'), '');
    } finally {
      client.close(force: true);
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  }
}
