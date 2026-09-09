import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'voice_asr.dart';

/// Result of one tool call, handed back to the model.
typedef AgentToolRunner =
    Future<Map<String, dynamic>> Function(
      String name,
      Map<String, dynamic> args,
    );

/// Voice/text driven browser agent: Gemini decides which browser tool to run
/// next until it calls `done`. The tools themselves live in browser_screen.
class BrowserAgent {
  BrowserAgent({required this.runTool, required this.onStatus});

  final AgentToolRunner runTool;
  final void Function(String status) onStatus;

  static const _maxSteps = 12;
  static const _maxToolMs = 20000;
  bool _busy = false;
  bool get busy => _busy;
  int _generation = 0;

  /// Cancels the in-flight run (e.g. user pressed cancel or started a new one).
  void cancel() => _generation++;

  /// Conversation memory across runs within one app session (user command +
  /// the agent's spoken reply only — NOT the intermediate tool calls, to keep
  /// context lean). Toggled by [historyEnabled]; cleared when the app closes.
  static final List<Map<String, dynamic>> conversation = [];
  static bool historyEnabled = true;
  static void clearConversation() => conversation.clear();

  /// Optional persona prepended to the (unchanged) browser-control prompt.
  static String persona = defaultPersona;
  static const defaultPersona =
      'You are Ani, a 20-year-old female AI assistant — smart, witty and sweet. '
      'You help the user browse and get things done on their smart glasses. '
      'Keep spoken replies short, warm and natural.';

  /// Trace of the last runs (kept on the glasses, readable from the web remote).
  static final List<Map<String, dynamic>> trace = [];
  static List<Map<String, dynamic>> get sessionHistory =>
      List.unmodifiable(conversation);
  static void removeHistoryTurn(int index) {
    if (index >= 0 && index + 1 < conversation.length)
      conversation.removeRange(index, index + 2);
  }

  static const _maxTraceRuns = 20;
  static void _log(Map<String, dynamic> entry) {
    trace.add({'t': DateTime.now().toIso8601String(), ...entry});
    if (trace.length > 400) trace.removeRange(0, trace.length - 400);
  }

  static const _toolNames = {
    'navigate',
    'back',
    'forward',
    'reload',
    'scroll',
    'read_page',
    'click',
    'type',
    'press_enter',
    'app_action',
    'see_page',
    'watch_video',
    'listen_audio',
    'see_camera',
    'watch_camera',
    'list_files',
    'read_file',
    'write_file',
    'delete_file',
    'download_file',
    'run_shell',
    'done',
  };

  static const _systemPrompt = '''
You control a web browser running on Rokid smart glasses (480x640 screen, one page at a time).
The user speaks a command in Vietnamese or English. Carry it out with the tools, then call done.

Rules:
- Prefer the fewest steps. Simple commands (reload, scroll, go back) are ONE tool call, then done.
- To interact with a page, first call read_page to see the interactive elements and their indexes.
- click takes either index (from read_page) or text. After a click that navigates, call read_page again.
- To search a site: navigate to it, click its search box, type the query, press_enter.
- You may go straight to a search URL when you know it (e.g. https://m.youtube.com/results?search_query=...).
- You can SEE and HEAR: use see_page to look at images / what is on screen, watch_video to understand the video that is playing, and listen_audio to hear (glasses microphone / ambient). Use these when the user asks about a picture, a video's content, or a sound — read_page only gives text.
- You have a private FILE workspace (sandboxed folder on the glasses): list_files, read_file, write_file, delete_file, download_file. Use it to save/read notes, transcripts, or downloaded media.
- COMBINE tools to reach a goal, e.g.:
  * "what is in this image URL" → download_file the URL, then read_file it (media understanding).
  * "save a summary of this video" → watch_video to summarise, then write_file the summary.
  * "search X and tell me about the first result's video" → navigate/search, read_page, click the result, then watch_video.
  Prefer the fewest tools that get the job done; after acting, call done with a short spoken-friendly answer.
- Never ask the user questions; make a reasonable choice and continue.
- Always answer in the SAME language the user spoke (Vietnamese command → Vietnamese reply). The reply may be read aloud, so keep it short and natural.
- For app-level requests (close/exit the browser, close a dialog, dark/transparent mode, zoom, brightness, volume, Wi-Fi) use app_action.
- Finish with done(message) — a SHORT sentence in the user's language describing what you did.
''';

  static final List<Map<String, dynamic>> _tools = [
    {
      'name': 'navigate',
      'description':
          'Open a URL (adds https:// if missing) or search the web if the text is not a URL.',
      'parameters': {
        'type': 'object',
        'properties': {
          'url': {'type': 'string'},
        },
        'required': ['url'],
      },
    },
    {
      'name': 'back',
      'description': 'Go back in history',
      'parameters': {'type': 'object', 'properties': {}},
    },
    {
      'name': 'forward',
      'description': 'Go forward in history',
      'parameters': {'type': 'object', 'properties': {}},
    },
    {
      'name': 'reload',
      'description': 'Reload the current page',
      'parameters': {'type': 'object', 'properties': {}},
    },
    {
      'name': 'scroll',
      'description':
          'Scroll the page. direction: up|down|top|bottom. amount: small|page (default page).',
      'parameters': {
        'type': 'object',
        'properties': {
          'direction': {'type': 'string'},
          'amount': {'type': 'string'},
        },
        'required': ['direction'],
      },
    },
    {
      'name': 'read_page',
      'description':
          'Return the page title, URL, visible text (truncated) and a numbered list of interactive elements.',
      'parameters': {'type': 'object', 'properties': {}},
    },
    {
      'name': 'click',
      'description':
          'Click an element by index (from read_page) or by its visible text.',
      'parameters': {
        'type': 'object',
        'properties': {
          'index': {'type': 'integer'},
          'text': {'type': 'string'},
        },
      },
    },
    {
      'name': 'type',
      'description': 'Type text into the focused field (click it first).',
      'parameters': {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
        'required': ['text'],
      },
    },
    {
      'name': 'press_enter',
      'description': 'Press Enter in the focused field (submits search forms)',
      'parameters': {'type': 'object', 'properties': {}},
    },
    {
      'name': 'app_action',
      'description':
          'Browser-app (not page) actions. action must be one of: '
          'exit_app (close the browser on the glasses), close_overlay (dismiss any open dialog/keyboard/panel), '
          'open_web_remote, transparent_on, transparent_off, dark_on, dark_off, passthrough_toggle, theater_toggle, '
          'hud_toggle (show/hide the address bar), zoom_in, zoom_out, brighter, dimmer, volume_up, volume_down, '
          'clear_history. (Clearing the login session and changing Wi-Fi are NOT available to the agent for safety — tell the user to do those in the web remote settings.)',
      'parameters': {
        'type': 'object',
        'properties': {
          'action': {'type': 'string'},
        },
        'required': ['action'],
      },
    },
    {
      'name': 'see_page',
      'description':
          'Look at what is currently on the screen (image understanding). '
          'Use for pictures, charts, or reading visible content. Optional question focuses the look.',
      'parameters': {
        'type': 'object',
        'properties': {
          'question': {'type': 'string'},
        },
      },
    },
    {
      'name': 'watch_video',
      'description':
          'Understand the video that is playing. On YouTube it uses the full video (visuals + audio); '
          'on other sites it uses sampled frames only (no audio). Optional question; optional seconds (3-20, default 8).',
      'parameters': {
        'type': 'object',
        'properties': {
          'question': {'type': 'string'},
          'seconds': {'type': 'integer'},
        },
      },
    },
    {
      'name': 'listen_audio',
      'description':
          'Record the glasses microphone (ambient/room sound) and transcribe/describe it — NOT the page playback audio. Optional question; optional seconds (3-30, default 8).',
      'parameters': {
        'type': 'object',
        'properties': {
          'question': {'type': 'string'},
          'seconds': {'type': 'integer'},
        },
      },
    },
    {
      'name': 'see_camera',
      'description':
          'Take a photo with the glasses world-facing camera and ask Gemini what the wearer is looking at. Use for objects, signs, documents, scenes or "what is in front of me?". Optional question focuses the analysis.',
      'parameters': {
        'type': 'object',
        'properties': {
          'question': {'type': 'string'},
        },
      },
    },
    {
      'name': 'watch_camera',
      'description':
          'Observe the world-facing camera over a few seconds (chronological frames) and describe movement/change/action. Use for "what is happening?" rather than a still object. Optional seconds 3-15 and question.',
      'parameters': {
        'type': 'object',
        'properties': {
          'question': {'type': 'string'},
          'seconds': {'type': 'integer'},
        },
      },
    },
    {
      'name': 'run_shell',
      'description': 'Run ONE allowlisted Android toybox command inside the private agent workspace. Use for local file inspection/processing when list_files/read_file/write_file are insufficient. Allowed examples: pwd, ls, cat, cp, mv, mkdir, touch, head, tail, grep, sed, wc, sort, uniq, find, ps, date, sha256sum. No pipes, redirects, shell operators, absolute paths, .. traversal or access outside the workspace. For multi-step work call run_shell repeatedly, or write a file and inspect the result. Do not use this for network access; use download_file.',
      'parameters': {
        'type': 'object',
        'properties': {
          'command': {'type': 'string'},
          'timeout_ms': {'type': 'integer'},
        },
        'required': ['command']
      }
    },
    {
      'name': 'list_files',
      'description':
          'List files/folders in the private workspace (a sandboxed folder on the glasses). '
          'Use to see what has been saved before reading/writing. path is a folder relative to the workspace root (empty = root).',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
      },
    },
    {
      'name': 'read_file',
      'description':
          'Read a file from the workspace. Text files return their content; '
          'images/audio/video are understood via Gemini and a description is returned (optional question focuses it). '
          'Combine with download_file (fetch something first) or write_file (read back what you saved).',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'question': {'type': 'string'},
        },
        'required': ['path'],
      },
    },
    {
      'name': 'write_file',
      'description':
          'Create or overwrite a text file in the workspace (set append=true to add to the end). '
          'Use to save notes, transcripts, or results the user asked to keep. path is relative to the workspace root.',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'content': {'type': 'string'},
          'append': {'type': 'boolean'},
        },
        'required': ['path', 'content'],
      },
    },
    {
      'name': 'delete_file',
      'description': 'Delete a file (or folder) from the workspace.',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      },
    },
    {
      'name': 'download_file',
      'description':
          'Download an http/https URL into the workspace (size-capped). '
          'Use to fetch an image/audio/video/document, THEN read_file it to understand its contents, '
          'or to save something for the user. path is the destination filename (empty = derive from URL).',
      'parameters': {
        'type': 'object',
        'properties': {
          'url': {'type': 'string'},
          'path': {'type': 'string'},
        },
        'required': ['url'],
      },
    },
    {
      'name': 'done',
      'description': 'Finish and report to the user.',
      'parameters': {
        'type': 'object',
        'properties': {
          'message': {'type': 'string'},
        },
        'required': ['message'],
      },
    },
  ];

  /// Runs [command] to completion. Returns the final message shown to the user.
  Future<String> run(String command) async {
    if (_busy) return 'Agent is busy';
    _busy = true;
    final key = await VoiceAsr.loadKey();
    final model = await VoiceAsr.loadModel();
    if (key.isEmpty) {
      _busy = false;
      throw StateError('No Gemini API key (set it in the web remote)');
    }
    final gen = ++_generation;
    final runId = DateTime.now().millisecondsSinceEpoch.toString();
    var lastCall = '';
    _log({'run': runId, 'command': command, 'model': model});
    // Persona is prepended; the browser-control prompt is unchanged below it.
    final preamble = persona.trim().isEmpty
        ? _systemPrompt
        : '${persona.trim()}\n\n$_systemPrompt';
    final contents = <Map<String, dynamic>>[
      {
        'role': 'user',
        'parts': [
          {'text': preamble},
        ],
      },
      // Prior turns of this session (spoken replies only) for continuity.
      if (historyEnabled) ...conversation,
      {
        'role': 'user',
        'parts': [
          {'text': 'User command: $command'},
        ],
      },
    ];
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      for (var step = 0; step < _maxSteps; step++) {
        final body = jsonEncode({
          'contents': contents,
          'tools': [
            {'function_declarations': _tools},
          ],
          'generationConfig': {'temperature': 0, 'maxOutputTokens': 800},
        });
        final req = await client.postUrl(
          Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$key',
          ),
        );
        req.headers.contentType = ContentType.json;
        req.write(body);
        final res = await req.close().timeout(const Duration(seconds: 60));
        final text = await res.transform(utf8.decoder).join();
        if (res.statusCode != 200) {
          final msg =
              (jsonDecode(text)['error']?['message'] ??
                      'HTTP ${res.statusCode}')
                  .toString();
          throw StateError(
            'Gemini: ${msg.length > 90 ? msg.substring(0, 90) : msg}',
          );
        }
        final j = jsonDecode(text);
        final parts =
            (j['candidates']?[0]?['content']?['parts'] as List?) ?? const [];
        if (parts.isEmpty) return 'No answer from the model';
        // Keep the model turn (function calls included) in the transcript.
        contents.add({'role': 'model', 'parts': parts});

        if (gen != _generation) return 'Cancelled';
        // Any text the model emits alongside tool calls is its "thinking".
        for (final p in parts) {
          final t = (p['text'] ?? '').toString().trim();
          if (t.isNotEmpty) onStatus('💭 $t');
        }
        final calls = parts.where((p) => p['functionCall'] != null).toList();
        if (calls.isEmpty) {
          final t = parts
              .map((p) => (p['text'] ?? '').toString())
              .firstWhere((t) => t.trim().isNotEmpty, orElse: () => '');
          return _remember(command, t.isEmpty ? 'Done' : t.trim());
        }

        final responses = <Map<String, dynamic>>[];
        for (final c in calls) {
          final name = (c['functionCall']['name'] ?? '').toString();
          final args = Map<String, dynamic>.from(
            (c['functionCall']['args'] as Map?) ?? const {},
          );
          if (name == 'done') {
            final msg = (args['message'] ?? 'Done').toString();
            _log({'run': runId, 'step': step, 'tool': 'done', 'result': msg});
            return _remember(command, msg);
          }
          onStatus('⚙︎ $name${args.isEmpty ? '' : ' ${_short(args)}'}');
          Map<String, dynamic> out;
          final started = DateTime.now();
          final signature = '$name${jsonEncode(args)}';
          // Guard rails live in CODE, not in the prompt: unknown tools, missing
          // arguments, repeats and hangs are rejected here and reported back to
          // the model as a normal tool result so it can correct itself.
          if (!_toolNames.contains(name)) {
            out = {
              'error':
                  'unknown tool $name; use one of ${_toolNames.join(', ')}',
            };
          } else if (name == 'click' &&
              args['index'] == null &&
              (args['text'] ?? '').toString().trim().isEmpty) {
            out = {'error': 'click needs index or text; call read_page first'};
          } else if (name == 'type' &&
              (args['text'] ?? '').toString().isEmpty) {
            out = {'error': 'type needs text'};
          } else if (name == 'navigate' &&
              (args['url'] ?? '').toString().trim().isEmpty) {
            out = {'error': 'navigate needs url'};
          } else if (signature == lastCall && name != 'read_page') {
            out = {
              'error':
                  'same call repeated with no effect; try another step or call done',
            };
          } else if (gen != _generation) {
            return 'Cancelled';
          } else {
            // Multimodal tools record audio + call Gemini vision — allow longer.
            final toolMs =
                (name == 'watch_video' ||
                    name == 'watch_camera' ||
                    name == 'listen_audio' ||
                    name == 'download_file' ||
                    name == 'read_file')
                ? 90000
                : ((name == 'see_page' || name == 'see_camera')
                      ? 40000
                      : _maxToolMs);
            try {
              out = await runTool(
                name,
                args,
              ).timeout(Duration(milliseconds: toolMs));
            } on TimeoutException {
              out = {'error': 'tool timed out'};
            } catch (e) {
              out = {'error': e.toString()};
            }
            // A tool that finished after a newer run started must not feed back.
            if (gen != _generation) return 'Cancelled';
          }
          lastCall = signature;
          _log({
            'run': runId,
            'step': step,
            'tool': name,
            'args': args,
            'ms': DateTime.now().difference(started).inMilliseconds,
            'result': _clip(out),
          });
          responses.add({
            'functionResponse': {'name': name, 'response': out},
          });
        }
        contents.add({'role': 'user', 'parts': responses});
      }
      return 'Stopped after $_maxSteps steps';
    } finally {
      client.close(force: true);
      _busy = false;
    }
  }

  /// Record a completed exchange (user command + spoken reply) for session
  /// continuity, then return the reply unchanged. Only real answers are kept.
  static String _remember(String command, String reply) {
    if (historyEnabled) {
      conversation.add({
        'role': 'user',
        'parts': [
          {'text': command},
        ],
      });
      conversation.add({
        'role': 'model',
        'parts': [
          {'text': reply},
        ],
      });
      // Keep memory bounded (last ~12 turns).
      if (conversation.length > 24) {
        conversation.removeRange(0, conversation.length - 24);
      }
    }
    return reply;
  }

  static Map<String, dynamic> _clip(Map<String, dynamic> out) {
    final m = <String, dynamic>{};
    out.forEach((k, v) {
      final s = v.toString();
      m[k] = s.length > 160 ? '\${s.substring(0, 160)}…' : v;
    });
    return m;
  }

  static String _short(Map<String, dynamic> args) {
    final s = args.values.map((v) => v.toString()).join(' ');
    return s.length > 30 ? '${s.substring(0, 30)}…' : s;
  }
}
