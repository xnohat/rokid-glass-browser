import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'voice_asr.dart';

/// Multimodal tools for the agent, powered by Gemini: look at what's on screen
/// (image), watch the playing video (a few frames + its audio), or listen to
/// the audio. Each returns a short text description the agent loop can use.
class AgentVision {
  AgentVision(this._channel, this._capture);
  final MethodChannel _channel;

  /// Grabs one on-screen frame as JPEG bytes (captures the video surface too).
  final Future<Uint8List?> Function(int maxW, int maxH) _capture;

  static const _visionModel = 'gemini-2.5-flash';

  Future<Uint8List> _cameraPhoto({int maxDim = 1280}) async {
    final bytes = await _channel.invokeMethod<Uint8List>(
      'capturePhoto',
      {'maxDim': maxDim},
    );
    if (bytes == null || bytes.isEmpty) {
      throw StateError('Camera capture failed');
    }
    return bytes;
  }

  /// Take a world-facing camera photo and understand it with Gemini.
  Future<String> seeCamera(String question) async {
    final key = await VoiceAsr.loadKey();
    if (key.isEmpty) {
      throw StateError('No Gemini API key (set it in the web remote)');
    }
    final jpeg = await _cameraPhoto();
    final prompt = question.trim().isEmpty
        ? 'This photo is from the glasses world-facing camera. Describe what '
            "the wearer is looking at, including readable text. Answer in the user's language."
        : question.trim();
    return _generate(key, [
      {'text': prompt},
      {
        'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(jpeg)}
      },
    ]);
  }

  /// Sample camera photos over time and describe changes/actions as a short clip.
  Future<String> watchCamera(String question, {int seconds = 6}) async {
    final key = await VoiceAsr.loadKey();
    if (key.isEmpty) {
      throw StateError('No Gemini API key (set it in the web remote)');
    }
    final duration = seconds.clamp(3, 15);
    final count = duration <= 6 ? 3 : (duration <= 10 ? 4 : 6);
    final gap = (duration * 1000 / count).round();
    final frames = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      frames.add(await _cameraPhoto(maxDim: 960));
      if (i < count - 1) {
        await Future<void>.delayed(Duration(milliseconds: gap));
      }
    }
    final parts = <Map<String, dynamic>>[
      {
        'text': question.trim().isEmpty
            ? 'These are chronological photos from the glasses world-facing '
                'camera over about $duration seconds. Describe what the wearer '
                "saw and what changed/happened. Answer in the user's language."
            : '${question.trim()} (Chronological world-camera frames.)',
      },
      for (final f in frames)
        {
          'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(f)}
        },
    ];
    return _generate(key, parts);
  }

  /// Describe what is currently visible on the glasses (image understanding).
  Future<String> seePage(String question) async {
    final key = await VoiceAsr.loadKey();
    if (key.isEmpty) {
      throw StateError('No Gemini API key (set it in the web remote)');
    }
    final frame = await _capture(720, 960);
    if (frame == null || frame.isEmpty) {
      throw StateError('Could not capture the screen');
    }
    final prompt = question.trim().isEmpty
        ? 'Describe what is shown on this screen concisely: main content, any '
            'readable text, and notable UI. Answer in the user\'s language.'
        : question.trim();
    return _generate(key, [
      {'text': prompt},
      {
        'inline_data': {
          'mime_type': 'image/jpeg',
          'data': base64Encode(frame),
        }
      },
    ]);
  }

  /// Watch the playing video. On YouTube, sends the URL straight to Gemini
  /// (native video understanding). Elsewhere, samples frames + audio.
  Future<String> watchVideo(String question,
      {int seconds = 8, String? currentUrl}) async {
    final key = await VoiceAsr.loadKey();
    if (key.isEmpty) {
      throw StateError('No Gemini API key (set it in the web remote)');
    }
    // Fast path: hand YouTube URLs directly to Gemini (no capture needed).
    final ytUrl = _youtubeWatchUrl(currentUrl);
    if (ytUrl != null) {
      return _generate(key, [
        {
          'text': question.trim().isEmpty
              ? 'Summarise what happens in this video (visuals + spoken '
                  "content) in a few sentences. Answer in the user's language."
              : question.trim(),
        },
        {
          'file_data': {'file_uri': ytUrl}
        },
      ]);
    }
    // Fallback for non-YouTube video: sample a few frames only. We deliberately
    // do NOT record the microphone here — the mic captures the room, not the
    // page's playback audio, so calling it "the video's audio" would be wrong.
    final clamped = seconds.clamp(3, 20);
    final frames = <Uint8List>[];
    final frameCount = clamped <= 6 ? 3 : (clamped <= 12 ? 4 : 6);
    final gap = (clamped * 1000 / frameCount).round();
    for (var i = 0; i < frameCount; i++) {
      final f = await _capture(640, 854);
      if (f != null && f.isNotEmpty) frames.add(f);
      if (i < frameCount - 1) {
        await Future<void>.delayed(Duration(milliseconds: gap));
      }
    }
    if (frames.isEmpty) throw StateError('Could not capture the video');

    final parts = <Map<String, dynamic>>[
      {
        'text': question.trim().isEmpty
            ? 'These are $frameCount frames sampled over ~$clamped seconds of a '
                'video playing on screen (no audio track available here). '
                'Describe what is happening visually in a few sentences. '
                "Answer in the user's language."
            : '${question.trim()} '
                '(Only sampled video frames are provided, no audio.)',
      },
    ];
    for (final f in frames) {
      parts.add({
        'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(f)}
      });
    }
    return _generate(key, parts);
  }

  /// Listen to the audio for [seconds] and transcribe/summarise it.
  Future<String> listenAudio(String question, {int seconds = 8}) async {
    final key = await VoiceAsr.loadKey();
    if (key.isEmpty) {
      throw StateError('No Gemini API key (set it in the web remote)');
    }
    final clamped = seconds.clamp(3, 30);
    final wavPath = await _recordAudio(clamped * 1000);
    if (wavPath == null) throw StateError('Could not record audio');
    final bytes = await File(wavPath).readAsBytes();
    if (bytes.length < 4000) throw StateError('No audio captured');
    return _generate(key, [
      {
        'text': question.trim().isEmpty
            ? 'This is audio recorded from the glasses microphone (ambient / '
                'room sound). Describe or transcribe what is heard concisely. '
                "Answer in the user's language."
            : '${question.trim()} '
                '(Audio is from the microphone / ambient sound.)',
      },
      {
        'inline_data': {'mime_type': 'audio/wav', 'data': base64Encode(bytes)}
      },
    ]);
  }

  /// Records mic audio for [ms] into a WAV file via the native recorder,
  /// returning its path (or null on failure). Reuses the ASR capture path.
  Future<String?> _recordAudio(int ms) async {
    try {
      await _channel.invokeMethod('asrStart');
      await Future<void>.delayed(Duration(milliseconds: ms));
      final path = await _channel.invokeMethod<String>('asrStop');
      return path;
    } catch (_) {
      return null;
    }
  }

  /// Describe arbitrary media bytes (image/audio/video) with Gemini. Used by
  /// the file reader for pictures/sound/clips on disk.
  Future<String> describeBytes(
      List<int> bytes, String mime, String question,
      {required String kind}) async {
    final key = await VoiceAsr.loadKey();
    if (key.isEmpty) {
      throw StateError('No Gemini API key (set it in the web remote)');
    }
    if (bytes.isEmpty) throw StateError('Empty file');
    final def = kind == 'image'
        ? 'Describe this image concisely: main content and any readable text.'
        : kind == 'audio'
            ? 'Transcribe or describe this audio concisely.'
            : 'Summarise what happens in this video in a few sentences.';
    final prompt =
        question.trim().isEmpty ? "$def Answer in the user's language." : question.trim();
    return _generate(key, [
      {'text': prompt},
      {
        'inline_data': {'mime_type': mime, 'data': base64Encode(Uint8List.fromList(bytes))}
      },
    ]);
  }

  /// Returns a canonical youtube.com/watch?v=ID url if [url] is a YouTube video.
  static String? _youtubeWatchUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    final u = Uri.tryParse(url);
    if (u == null) return null;
    final host = u.host.toLowerCase();
    const ytHosts = {
      'youtu.be',
      'youtube.com',
      'www.youtube.com',
      'm.youtube.com',
      'music.youtube.com',
    };
    if (!ytHosts.contains(host)) return null;
    if (host == 'youtu.be') {
      final id = u.pathSegments.isNotEmpty ? u.pathSegments.first : '';
      return id.isEmpty ? null : 'https://www.youtube.com/watch?v=$id';
    }
    {
      final id = u.queryParameters['v'];
      if (id != null && id.isNotEmpty) {
        return 'https://www.youtube.com/watch?v=$id';
      }
      if (u.path.startsWith('/shorts/') && u.pathSegments.length >= 2) {
        return 'https://www.youtube.com/watch?v=${u.pathSegments[1]}';
      }
    }
    return null;
  }

  Future<String> _generate(String key, List<Map<String, dynamic>> parts) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.postUrl(Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$_visionModel:generateContent?key=$key'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'contents': [
          {'parts': parts}
        ],
        'generationConfig': {'temperature': 0.2, 'maxOutputTokens': 600},
      }));
      final res = await req.close().timeout(const Duration(seconds: 60));
      final txt = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw StateError('Gemini HTTP ${res.statusCode}');
      }
      final j = jsonDecode(txt);
      final outParts =
          (j['candidates']?[0]?['content']?['parts'] as List?) ?? const [];
      final buf = StringBuffer();
      for (final p in outParts) {
        final t = (p['text'] ?? '').toString();
        if (t.isNotEmpty) buf.write(t);
      }
      final out = buf.toString().trim();
      if (out.isEmpty) throw StateError('Gemini returned no text');
      return out;
    } finally {
      client.close(force: true);
    }
  }
}
