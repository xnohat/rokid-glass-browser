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
  static const _modelKey = 'gemini_asr_model';
  static const defaultModel = 'gemini-3.5-transcribe';

  static Future<String> loadModel() async =>
      (await SharedPreferences.getInstance()).getString(_modelKey) ?? defaultModel;

  static Future<void> saveModel(String m) async =>
      (await SharedPreferences.getInstance()).setString(_modelKey, m.trim().isEmpty ? defaultModel : m.trim());

  /// Lists Gemini models that support generateContent (audio-capable families).
  static Future<List<String>> listModels(String key) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?key=$key&pageSize=200'));
      final res = await req.close().timeout(const Duration(seconds: 20));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
      final j = jsonDecode(text);
      final out = <String>[];
      for (final m in (j['models'] as List? ?? const [])) {
        final name = (m['name'] ?? '').toString().replaceFirst('models/', '');
        final methods = (m['supportedGenerationMethods'] as List? ?? const []).cast<String>();
        if (!methods.contains('generateContent')) continue;
        if (!name.startsWith('gemini')) continue;
        if (RegExp(r'image|tts|embedding|robotics|computer-use').hasMatch(name)) continue;
        out.add(name);
      }
      out.sort();
      return out;
    } finally {
      client.close(force: true);
    }
  }

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
    if (path == null) throw StateError('Could not record audio');
    final key = await loadKey();
    if (key.isEmpty) throw StateError('No Gemini API key (set it in the web remote)');
    final model = await loadModel();
    final bytes = await File(path).readAsBytes();
    if (bytes.length < 4000) throw StateError('Microphone returned no audio');
    // Silence guard: peak below ~1% of full scale -> the mic is not picking up.
    int peak = 0;
    for (var i = 44; i + 1 < bytes.length; i += 2) {
      final v = (bytes[i] | (bytes[i + 1] << 8));
      final sv = v > 32767 ? v - 65536 : v;
      if (sv.abs() > peak) peak = sv.abs();
    }
    if (peak < 300) throw StateError('Microphone is silent (peak $peak)');
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
      'generationConfig': {'temperature': 0, 'maxOutputTokens': 400}
    });
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$key'));
      req.headers.contentType = ContentType.json;
      req.write(body);
      final res = await req.close().timeout(const Duration(seconds: 30));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        final msg = (jsonDecode(text)['error']?['message'] ?? 'HTTP ${res.statusCode}').toString();
        throw StateError('Gemini: ${msg.length > 80 ? msg.substring(0, 80) : msg}');
      }
      final j = jsonDecode(text);
      // Chat models answer in `text`; transcribe models in `audioTranscription.text`.
      final parts = (j['candidates']?[0]?['content']?['parts'] as List?) ?? const [];
      var out = '';
      for (final part in parts) {
        final t = (part['audioTranscription']?['text'] ?? part['text'] ?? '').toString().trim();
        if (t.isNotEmpty) { out = t; break; }
      }
      // Keep the last WAV for debugging (overwritten each time).
      try { File(path).copySync('${File(path).parent.path}/asr-last.wav'); } catch (_) {}
      return out.replaceAll(RegExp(r'^["“]|["”]$'), '');
    } finally {
      client.close(force: true);
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  }
}
