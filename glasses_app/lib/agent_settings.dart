import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'browser_agent.dart';
import 'voice_asr.dart';

/// Persisted settings for the conversational AI-agent features:
/// conversation history on/off, speak-reply on/off + voice, and persona prompt.
/// All stored on the glasses only (SharedPreferences).
class AgentSettings {
  static const _kHistory = 'agent_history_enabled';
  static const _kSpeak = 'agent_speak_enabled';
  static const _kVoice = 'agent_tts_voice';
  static const _kPersona = 'agent_persona';

  // Gemini prebuilt TTS voices (a useful subset for the dropdown).
  static const voices = <String>[
    'Zephyr', 'Puck', 'Charon', 'Kore', 'Fenrir', 'Aoede',
    'Leda', 'Orus', 'Callirrhoe', 'Autonoe', 'Enceladus', 'Umbriel',
  ];
  static const defaultVoice = 'Aoede';

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    BrowserAgent.historyEnabled = p.getBool(_kHistory) ?? true;
    speakEnabled = p.getBool(_kSpeak) ?? true;
    voice = p.getString(_kVoice) ?? defaultVoice;
    final persona = p.getString(_kPersona);
    if (persona != null && persona.trim().isNotEmpty) {
      BrowserAgent.persona = persona;
    }
  }

  static bool speakEnabled = true;
  static String voice = defaultVoice;

  static Future<void> setHistory(bool on) async {
    BrowserAgent.historyEnabled = on;
    if (!on) BrowserAgent.clearConversation();
    (await SharedPreferences.getInstance()).setBool(_kHistory, on);
  }

  static Future<void> setSpeak(bool on) async {
    speakEnabled = on;
    (await SharedPreferences.getInstance()).setBool(_kSpeak, on);
  }

  static Future<void> setVoice(String v) async {
    voice = v.trim().isEmpty ? defaultVoice : v.trim();
    (await SharedPreferences.getInstance()).setString(_kVoice, voice);
  }

  static Future<void> setPersona(String prompt) async {
    final p = prompt.trim();
    BrowserAgent.persona = p.isEmpty ? BrowserAgent.defaultPersona : p;
    (await SharedPreferences.getInstance())
        .setString(_kPersona, BrowserAgent.persona);
  }

  static String get persona => BrowserAgent.persona;
}

/// Speaks text using Gemini's TTS model, playing the returned PCM through a
/// native AudioTrack (the glasses have no on-device TTS engine).
class AgentSpeaker {
  AgentSpeaker(this._channel);
  final MethodChannel _channel;
  int _generation = 0;

  void stop() {
    _generation++;
    _channel.invokeMethod('ttsStop').catchError((_) => null);
  }

  /// Best-effort: never throws (a failed speak must not break the agent).
  Future<void> speak(String text) async {
    if (!AgentSettings.speakEnabled) return;
    final clean = text.trim();
    if (clean.isEmpty) return;
    final key = await VoiceAsr.loadKey();
    if (key.isEmpty) return;
    final gen = ++_generation;
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
      try {
        final body = jsonEncode({
          'contents': [
            {'parts': [{'text': clean}]}
          ],
          'generationConfig': {
            'responseModalities': ['AUDIO'],
            'speechConfig': {
              'voiceConfig': {
                'prebuiltVoiceConfig': {'voiceName': AgentSettings.voice}
              }
            }
          },
        });
        final req = await client.postUrl(Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent?key=$key'));
        req.headers.contentType = ContentType.json;
        req.write(body);
        final res = await req.close().timeout(const Duration(seconds: 45));
        final txt = await res.transform(utf8.decoder).join();
        if (res.statusCode != 200 || gen != _generation) return;
        final j = jsonDecode(txt);
        final parts =
            (j['candidates']?[0]?['content']?['parts'] as List?) ?? const [];
        String? b64;
        int rate = 24000;
        for (final p in parts) {
          final data = p['inlineData'] ?? p['inline_data'];
          if (data != null && data['data'] != null) {
            b64 = data['data'].toString();
            final mime = (data['mimeType'] ?? data['mime_type'] ?? '').toString();
            final m = RegExp(r'rate=(\d+)').firstMatch(mime);
            if (m != null) rate = int.tryParse(m.group(1)!) ?? rate;
            break;
          }
        }
        if (b64 == null || gen != _generation) return;
        final pcm = base64Decode(b64);
        await _channel.invokeMethod('ttsPlay', {
          'pcm': Uint8List.fromList(pcm),
          'rate': rate,
        });
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      // swallow: speaking is a nice-to-have
    }
  }
}
