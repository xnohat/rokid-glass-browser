import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// On-glasses URL keyboard, operated with the touchpad cursor (2-axis mouse)
/// via [hitTest] + tap. All keys are large, laid on a fixed grid so the cursor
/// travels short, predictable paths.
class UrlKeyboardController {
  static const _kHistoryPref = 'rokid_url_history';
  static const _kMaxHistory = 200;

  /// Popular services shown as suggestions before any history exists.
  static const popular = <String>[
    'google.com', 'youtube.com', 'facebook.com', 'x.com', 'gmail.com',
    'instagram.com', 'tiktok.com', 'reddit.com', 'wikipedia.org',
    'twitter.com', 'threads.net', 'telegram.org', 'messenger.com',
    'chatgpt.com', 'gemini.google.com', 'github.com', 'amazon.com',
    'netflix.com', 'spotify.com', 'maps.google.com', 'zalo.me',
    'shopee.vn', 'vnexpress.net', 'tuoitre.vn', 'lazada.vn',
  ];

  List<String> history = [];

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    history = p.getStringList(_kHistoryPref) ?? [];
  }

  Future<void> record(String url) async {
    final u = url.trim();
    if (u.isEmpty || u == 'about:blank') return;
    history.remove(u);
    history.insert(0, u);
    if (history.length > _kMaxHistory) history = history.sublist(0, _kMaxHistory);
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kHistoryPref, history);
  }

  Future<void> remove(String url) async {
    history.remove(url);
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kHistoryPref, history);
  }

  static String _host(String u) {
    final uri = Uri.tryParse(u.contains('://') ? u : 'https://$u');
    var h = uri?.host ?? u;
    if (h.startsWith('www.')) h = h.substring(4);
    return h;
  }

  static bool _isRoot(String u) {
    final uri = Uri.tryParse(u.contains('://') ? u : 'https://$u');
    if (uri == null) return false;
    return (uri.path.isEmpty || uri.path == '/') && uri.query.isEmpty && uri.fragment.isEmpty;
  }

  /// Ranked suggestions: root domains first (history then popular), then deep
  /// paths from history. Matching is case-insensitive substring on the URL.
  List<String> suggest(String query, {int max = 5}) {
    final q = query.trim().toLowerCase().replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'^www\.'), '');
    bool m(String u) => q.isEmpty || u.toLowerCase().contains(q) || _host(u).toLowerCase().contains(q);

    final roots = <String>[];
    final paths = <String>[];
    final seenHost = <String>{};
    for (final u in history) {
      if (!m(u)) continue;
      if (_isRoot(u)) {
        if (seenHost.add(_host(u))) roots.add(u);
      } else {
        paths.add(u);
      }
    }
    // Hosts seen only via deep paths still deserve a root entry.
    for (final u in paths) {
      final h = _host(u);
      if (seenHost.add(h)) roots.add('https://$h');
    }
    for (final d in popular) {
      if (m(d) && seenHost.add(d)) roots.add('https://$d');
    }
    // Exact-prefix host matches float to the top.
    int score(String u) {
      final h = _host(u).toLowerCase();
      if (q.isNotEmpty && h.startsWith(q)) return 0;
      if (q.isNotEmpty && h.split('.').any((p) => p.startsWith(q))) return 1;
      return 2;
    }
    roots.sort((a, b) => score(a).compareTo(score(b)));
    return [...roots, ...paths].take(max).toList();
  }
}

/// Visual key definition.
class _K {
  final String label;
  final String? insert; // text inserted; null = special
  final String? action; // 'clear','backspace','go','http','https','up','down','close','space'
  final double w;
  const _K(this.label, {this.insert, this.action, this.w = 1});
}

class UrlKeyboard extends StatefulWidget {
  /// 'url' = address bar (suggestions, GO). 'text' = typing into a web field
  /// (no suggestions, keys stream to the page, ENTER submits).
  final String mode;
  final void Function(String text)? onType;
  final VoidCallback? onBackspace;
  final VoidCallback? onEnter;
  final VoidCallback? onClearField;
  /// Push-to-talk: called on mic key press; returns recognised text or null.
  final Future<String?> Function()? onMic;
  final bool micActive;
  /// Status line shown inside the keyboard (listening / recognising / error).
  final String? micStatus;
  final String initialText;
  final UrlKeyboardController controller;
  final void Function(String url) onGo;
  final VoidCallback onClose;
  const UrlKeyboard({
    super.key,
    this.mode = 'url',
    this.onType,
    this.onBackspace,
    this.onEnter,
    this.onClearField,
    this.onMic,
    this.micActive = false,
    this.micStatus,
    required this.initialText,
    required this.controller,
    required this.onGo,
    required this.onClose,
  });

  @override
  State<UrlKeyboard> createState() => UrlKeyboardState();
}

class UrlKeyboardState extends State<UrlKeyboard> {
  late String text = widget.initialText;
  int selected = -1;
  List<String> suggestions = [];
  final Map<String, GlobalKey> _keys = {};
  final List<GlobalKey> _sugKeys = List.generate(5, (_) => GlobalKey());
  final List<GlobalKey> _sugDelKeys = List.generate(5, (_) => GlobalKey());

  static const _green = Color(0xFF00FF00);
  static const _soft = Color(0xFF88FF88);

  static const _rows = <List<_K>>[
    [_K('✕', action: 'clear', w: 1.3), _K('http://', insert: 'http://', w: 2), _K('https://', insert: 'https://', w: 2), _K('www.', insert: 'www.', w: 1.6), _K('.com', insert: '.com', w: 1.5), _K('⌫', action: 'backspace', w: 1.6)],
    [_K('1', insert: '1'), _K('2', insert: '2'), _K('3', insert: '3'), _K('4', insert: '4'), _K('5', insert: '5'), _K('6', insert: '6'), _K('7', insert: '7'), _K('8', insert: '8'), _K('9', insert: '9'), _K('0', insert: '0')],
    [_K('q', insert: 'q'), _K('w', insert: 'w'), _K('e', insert: 'e'), _K('r', insert: 'r'), _K('t', insert: 't'), _K('y', insert: 'y'), _K('u', insert: 'u'), _K('i', insert: 'i'), _K('o', insert: 'o'), _K('p', insert: 'p')],
    [_K('a', insert: 'a'), _K('s', insert: 's'), _K('d', insert: 'd'), _K('f', insert: 'f'), _K('g', insert: 'g'), _K('h', insert: 'h'), _K('j', insert: 'j'), _K('k', insert: 'k'), _K('l', insert: 'l'), _K('-', insert: '-')],
    [_K('z', insert: 'z'), _K('x', insert: 'x'), _K('c', insert: 'c'), _K('v', insert: 'v'), _K('b', insert: 'b'), _K('n', insert: 'n'), _K('m', insert: 'm'), _K('_', insert: '_'), _K('=', insert: '='), _K('&', insert: '&')],
    [_K(':', insert: ':'), _K('/', insert: '/'), _K('?', insert: '?'), _K('.', insert: '.'), _K('#', insert: '#'), _K('%', insert: '%'), _K('@', insert: '@'), _K('▲', action: 'up'), _K('▼', action: 'down'), _K('🎤', action: 'mic', w: 1.2), _K('GO', action: 'go', w: 1.4)],
  ];

  static const _textRows = <List<_K>>[
    [_K('✕ Clear', action: 'clearfield', w: 2.2), _K('🎤', action: 'mic', w: 1.3), _K('␣', insert: ' ', w: 1.8), _K('⌫', action: 'backspace', w: 1.5), _K('ENTER', action: 'enter', w: 1.9)],
    [_K('1', insert: '1'), _K('2', insert: '2'), _K('3', insert: '3'), _K('4', insert: '4'), _K('5', insert: '5'), _K('6', insert: '6'), _K('7', insert: '7'), _K('8', insert: '8'), _K('9', insert: '9'), _K('0', insert: '0')],
    [_K('q', insert: 'q'), _K('w', insert: 'w'), _K('e', insert: 'e'), _K('r', insert: 'r'), _K('t', insert: 't'), _K('y', insert: 'y'), _K('u', insert: 'u'), _K('i', insert: 'i'), _K('o', insert: 'o'), _K('p', insert: 'p')],
    [_K('a', insert: 'a'), _K('s', insert: 's'), _K('d', insert: 'd'), _K('f', insert: 'f'), _K('g', insert: 'g'), _K('h', insert: 'h'), _K('j', insert: 'j'), _K('k', insert: 'k'), _K('l', insert: 'l'), _K('⇧', action: 'shift')],
    [_K('z', insert: 'z'), _K('x', insert: 'x'), _K('c', insert: 'c'), _K('v', insert: 'v'), _K('b', insert: 'b'), _K('n', insert: 'n'), _K('m', insert: 'm'), _K(',', insert: ','), _K('.', insert: '.'), _K('?', insert: '?')],
    [_K('@', insert: '@'), _K('#', insert: '#'), _K('!', insert: '!'), _K('-', insert: '-'), _K('_', insert: '_'), _K(':', insert: ':'), _K('/', insert: '/'), _K("'", insert: "'"), _K('"', insert: '"'), _K('CLOSE', action: 'close', w: 1.4)],
  ];
  bool shift = false;
  List<List<_K>> get rows => widget.mode == 'text' ? _textRows : _rows;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    suggestions = widget.controller.suggest(text);
    if (selected >= suggestions.length) selected = suggestions.length - 1;
    setState(() {});
  }

  void _press(_K k) {
    if (widget.mode == 'text') {
      if (k.insert != null) {
        final ch = shift ? k.insert!.toUpperCase() : k.insert!;
        text += ch;
        widget.onType?.call(ch);
        if (shift) shift = false;
        setState(() {});
        return;
      }
      switch (k.action) {
        case 'mic':
          widget.onMic?.call().then((t) {
            if (t == null || t.isEmpty || !mounted) return;
            text += t;
            widget.onType?.call(t);
            setState(() {});
          });
        case 'clearfield':
          text = '';
          widget.onClearField?.call();
          setState(() {});
        case 'backspace':
          if (text.isNotEmpty) text = text.substring(0, text.length - 1);
          widget.onBackspace?.call();
          setState(() {});
        case 'enter':
          widget.onEnter?.call();
        case 'shift':
          shift = !shift;
          setState(() {});
        case 'close':
          widget.onClose();
      }
      return;
    }
    if (k.insert != null) {
      text += k.insert!;
      selected = -1;
      _refresh();
      return;
    }
    switch (k.action) {
      case 'mic':
        widget.onMic?.call().then((t) {
          if (t == null || t.isEmpty || !mounted) return;
          text += t;
          selected = -1;
          _refresh();
        });
      case 'clear':
        text = '';
        selected = -1;
        _refresh();
      case 'backspace':
        if (text.isNotEmpty) text = text.substring(0, text.length - 1);
        selected = -1;
        _refresh();
      case 'up':
        if (suggestions.isNotEmpty) {
          selected = (selected - 1 + suggestions.length) % suggestions.length;
          setState(() {});
        }
      case 'down':
        if (suggestions.isNotEmpty) {
          selected = (selected + 1) % suggestions.length;
          setState(() {});
        }
      case 'go':
        final target = (selected >= 0 && selected < suggestions.length) ? suggestions[selected] : text;
        if (target.trim().isNotEmpty) widget.onGo(target.trim());
      case 'close':
        widget.onClose();
    }
  }

  /// Called from the cursor click handler. Returns true if consumed.
  bool hitTest(Offset p) {
    for (var i = 0; i < suggestions.length; i++) {
      if (_contains(_sugDelKeys[i], p)) {
        final u = suggestions[i];
        widget.controller.remove(u).then((_) => _refresh());
        return true;
      }
      if (_contains(_sugKeys[i], p)) {
        widget.onGo(suggestions[i]);
        return true;
      }
    }
    for (final entry in _keys.entries) {
      if (_contains(entry.value, p)) {
        final k = rows.expand((r) => r).firstWhere((k) => k.label == entry.key);
        _press(k);
        return true;
      }
    }
    if (_contains(_closeKey, p)) {
      widget.onClose();
      return true;
    }
    // Text mode: clicking outside the keyboard closes it so the user can
    // reach the page underneath.
    if (widget.mode == 'text') {
      final box = _sheetKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final o = box.localToGlobal(Offset.zero);
        if (!(o & box.size).contains(p)) {
          widget.onClose();
          return false; // let the click pass through to the page
        }
      }
    }
    return true; // consume clicks on the backdrop while open
  }
  final GlobalKey _sheetKey = GlobalKey();

  final GlobalKey _closeKey = GlobalKey();

  bool _contains(GlobalKey k, Offset p) {
    final box = k.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final o = box.localToGlobal(Offset.zero);
    return (o & box.size).inflate(1).contains(p);
  }

  Widget _key(_K k) {
    final key = _keys.putIfAbsent(k.label, () => GlobalKey());
    final special = k.action != null;
    return Expanded(
      flex: (k.w * 10).round(),
      child: Padding(
        padding: const EdgeInsets.all(1.5),
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: () => _press(k),
          child: Container(
            height: 29,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: (k.action == 'mic' && widget.micActive) ? const Color(0xFF5A1010) : k.action == 'go' ? const Color(0xFF184818) : const Color(0xFF0B140B),
              border: Border.all(color: (k.action == 'mic' && widget.micActive) ? const Color(0xFFFF4444) : special ? _green : const Color(0xFF2E5A2E), width: (k.action == 'mic' && widget.micActive) ? 2 : 1),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              (k.action == 'mic' && widget.micActive) ? '⏹' : k.label,
              style: TextStyle(
                color: special ? _green : _soft,
                fontSize: k.label.length > 2 ? 10 : 15,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mode == 'text') {
      return Positioned(
        left: 0, right: 0, bottom: 0,
        child: Container(
          key: _sheetKey,
          color: const Color(0xF2000000),
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(children: [
                  Expanded(child: Text(widget.micStatus ?? (text.isEmpty ? 'Typing into the page field…' : '$text▏'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: widget.micStatus != null ? const Color(0xFFFF7777) : text.isEmpty ? const Color(0xFF4A7A4A) : Colors.white, fontSize: 12, fontWeight: widget.micStatus != null ? FontWeight.bold : FontWeight.normal))),
                  if (shift) const Text('SHIFT', style: TextStyle(color: _green, fontSize: 10, fontWeight: FontWeight.bold)),
                ]),
              ),
              for (final row in rows) Row(children: [for (final k in row) _key(k)]),
            ],
          ),
        ),
      );
    }
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xF2000000),
        child: Column(
          children: [
            const SizedBox(height: 14),
            // Address field + close
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 30,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        border: Border.all(color: _green),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        widget.micStatus ?? (text.isEmpty ? 'Enter address or search' : '$text▏'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: widget.micStatus != null ? const Color(0xFFFF7777) : text.isEmpty ? const Color(0xFF4A7A4A) : Colors.white, fontSize: 13),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    key: _closeKey,
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onClose,
                    child: Container(
                      width: 40,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(border: Border.all(color: const Color(0xFFFF6666)), borderRadius: BorderRadius.circular(6)),
                      child: const Text('CLOSE', style: TextStyle(color: Color(0xFFFF6666), fontSize: 9, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // Suggestions (5 rows fixed height so the keyboard never jumps)
            SizedBox(
              height: 5 * 27,
              child: Column(
                children: [
                  for (var i = 0; i < 5; i++)
                    if (i < suggestions.length)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                        child: Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                key: _sugKeys[i],
                                behavior: HitTestBehavior.opaque,
                                onTap: () => widget.onGo(suggestions[i]),
                                child: Container(
                                  height: 25,
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  alignment: Alignment.centerLeft,
                                  decoration: BoxDecoration(
                                    color: i == selected ? const Color(0xFF163A16) : const Color(0xFF070D07),
                                    border: Border.all(color: i == selected ? _green : const Color(0xFF244024)),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: Text(
                                    suggestions[i].replaceFirst(RegExp(r'^https?://'), ''),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: i == selected ? Colors.white : _soft, fontSize: 12),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            if (widget.controller.history.contains(suggestions[i]))
                              GestureDetector(
                                key: _sugDelKeys[i],
                                behavior: HitTestBehavior.opaque,
                                onTap: () => widget.controller.remove(suggestions[i]).then((_) => _refresh()),
                                child: Container(
                                  width: 34,
                                  height: 25,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(border: Border.all(color: const Color(0xFF7A3A3A)), borderRadius: BorderRadius.circular(5)),
                                  child: const Text('✕', style: TextStyle(color: Color(0xFFFF7777), fontSize: 13)),
                                ),
                              )
                            else
                              const SizedBox(width: 34, height: 25),
                          ],
                        ),
                      )
                    else
                      const SizedBox(height: 27),
                ],
              ),
            ),
            const SizedBox(height: 2),
            // Keyboard rows
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                children: [
                  for (final row in rows) Row(children: [for (final k in row) _key(k)]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
