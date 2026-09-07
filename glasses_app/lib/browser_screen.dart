import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'url_keyboard.dart';
import 'voice_asr.dart';
import 'web_remote_server.dart';

const _kGreen = Color(0xFF00FF00);
const _kBlack = Color(0xFF000000);
const _kSoftGreen = Color(0xFF88FF88);
// Fixed height of the top HUD/address strip. Content is laid out below this so
// the address bar never overlaps the web page.
const double _kHudHeight = 44;
// Layout (CSS) viewport width presented to pages, in CSS px. 320 is the
// glasses' native width; 400 gives phone-class layouts.
const int _kLayoutWidth = 400;
// Phone touchpad → glasses cursor gain (1.0 = full pad width == full screen).
const double _kRemotePadGain = 0.45;
// Glasses touchpad swipe → cursor step = screen / divisor.
const double _kPadSwipeDivisor = 30;

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen>
    with WidgetsBindingObserver {
  static const _eventChannel = EventChannel(
    'com.snorlytics.browser_glasses/events',
  );
  static const _methodChannel = MethodChannel(
    'com.snorlytics.browser_glasses/methods',
  );

  late final WebViewController _webController;
  bool _webViewReady = false;
  String _url = '';
  String _title = 'ROKID BROWSER';
  bool _loading = false;
  bool _connected = false;
  String _btStatus = 'scanning';
  bool _canGoBack = false;
  bool _canGoForward = false;
  late final WebRemoteServer _webRemote;
  WebRemoteStatus _webRemoteStatus = WebRemoteStatus.stopped;
  String? _webRemoteError;
  bool _showWebRemotePanel = false;
  bool _showUrlKeyboard = false;
  bool _showTextKeyboard = false;
  late final VoiceAsr _asr = VoiceAsr(_methodChannel);
  bool _micActive = false;
  String? _micStatus;
  Timer? _micStatusTimer;
  final GlobalKey<UrlKeyboardState> _textKbKey = GlobalKey<UrlKeyboardState>();
  final GlobalKey _castKey = GlobalKey();
  final UrlKeyboardController _urlHistory = UrlKeyboardController();
  final GlobalKey<UrlKeyboardState> _urlKbKey = GlobalKey<UrlKeyboardState>();
  // Exit confirmation armed by a two-finger double-tap (F13) or the Exit button.
  bool _confirmExit = false;
  Timer? _confirmExitTimer;
  // Touchpad swipe mode: false = jump between elements, true = scroll page.
  bool _swipeScrollsPage = false;
  // In mouse mode, whether a pad swipe moves the cursor vertically (true) or
  // horizontally (false).
  bool _mouseAxisVertical = false;
  // Smooth cursor glide: each pad swipe adds velocity; a ticker eases the
  // cursor toward the target so motion looks continuous instead of stepped.
  Timer? _glideTimer;
  double _glideTargetX = 0, _glideTargetY = 0;
  int _lastSwipeMs = 0;
  int _swipeStreak = 0;
  String? _modeToast;
  Timer? _modeToastTimer;
  int _hwPressCount = 0;
  int _hwLastPressMs = 0;
  Timer? _hwPressTimer;

  double _cursorX = 0;
  double _cursorY = 0;
  bool _cursorVisible = false;
  bool _cursorDragging = false;
  Timer? _cursorHideTimer;

  // 1.0 = fill the viewport. CSS body.zoom<1 shrinks the page toward the top-left
  // and leaves black gaps on the right/bottom, so we default to full size.
  double _pageZoom = 1.0;
  bool _webViewConfigured = false;
  bool _isDark = true;
  // Visual render mode (separate from dark mode). 'normal' = untouched;
  // 'transparent' = strip backgrounds/fills so the page reads as floating text
  // (great on the AR waveguide — less emitted light); 'wireframe' = transparent
  // fills + outline on structural elements. Images/video stay visible in all.
  String _visualMode = 'normal';
  Timer? _configRetryTimer;
  bool _passthrough = false;
  bool _theaterMode = false;
  // Address bar hidden state has two independent sources (advisor): the user's
  // manual toggle and real HTML5-video fullscreen. Effective = either is true.
  bool _manualHudHidden = false;
  bool _editingText = false;
  bool _autoVideoFullscreen = false;
  bool get _videoFullscreen => _manualHudHidden || _autoVideoFullscreen || _editingText;
  int _lastGestureMs = 0; // debounce for touchpad swipes
  static const _gestureDebounceMs = 700;
  // Touchpad focus-navigation: the Rokid pad emits PAIRED keys for one swipe —
  // forward = ArrowRight THEN ArrowDown, backward = ArrowLeft THEN ArrowUp. We
  // coalesce the companion key within this window so one physical swipe = one
  // focus move (separate from the 700ms gesture debounce, which is too slow here).
  int _lastNavMs = 0;
  // Wider window so one physical swipe = exactly one focus move: a firm/long
  // swipe on the Rokid pad can emit several key pairs in quick succession, which
  // would otherwise skip multiple links. 380ms collapses those into one step
  // while still allowing deliberate repeated swipes (~3/sec).
  static const _navCoalesceMs = 380;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _webRemote = WebRemoteServer(
      onCommand: _handleCommand,
      onCapture: _captureRemoteFrame,
      pageHtml: '',
      onStatusChanged: (status) {
        if (mounted) {
          setState(() {
            _webRemoteStatus = status;
            if (status == WebRemoteStatus.paired) {
              _showWebRemotePanel = false;
            }
          });
        }
      },
      state: () => {
        'url': _url,
        'title': _title,
        'loading': _loading,
        'canGoBack': _canGoBack,
        'canGoForward': _canGoForward,
        'visualMode': _visualMode,
        'viewportWidth': mounted ? MediaQuery.sizeOf(context).width : 0,
        'viewportHeight': mounted ? MediaQuery.sizeOf(context).height : 0,
        'density': mounted ? MediaQuery.devicePixelRatioOf(context) : 1,
        'hudHeight': _videoFullscreen || _theaterMode ? 0 : _kHudHeight,
      },
    );
    _loadVisualMode();
    _urlHistory.load();
    _initWebView();
    _setupEventStream();
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final size = MediaQuery.of(context).size;
        setState(() {
          _cursorX = size.width / 2;
          _cursorY = size.height / 2;
        });
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _cursorHideTimer?.cancel();
    _configRetryTimer?.cancel();
    _navRefreshTimer?.cancel();
    _confirmExitTimer?.cancel();
    _modeToastTimer?.cancel();
    _hwPressTimer?.cancel();
    _micStatusTimer?.cancel();
    _glideTimer?.cancel();
    unawaited(_webRemote.stop());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(_stopWebRemote());
    }
  }

  Future<Uint8List?> _captureRemoteFrame(int maxWidth, int maxHeight) async {
    if (!mounted || _webRemoteStatus != WebRemoteStatus.paired) return null;
    return _methodChannel.invokeMethod<Uint8List>('captureFrame', {
      'maxWidth': maxWidth,
      'maxHeight': maxHeight,
    });
  }

  Future<void> _startWebRemote() async {
    if (_webRemote.running) return;
    setState(() => _webRemoteError = null);
    try {
      _webRemote.pageHtml = await rootBundle.loadString(
        'assets/web_remote.html',
      );
      await _webRemote.start();
      if (mounted) setState(() {});
    } catch (error) {
      await _webRemote.stop();
      if (mounted) {
        setState(() => _webRemoteError = error.toString());
      }
    }
  }

  Future<void> _stopWebRemote() async {
    await _webRemote.stop();
    if (mounted) setState(() {});
  }

  Future<void> _revokeWebRemote() async {
    await _webRemote.revoke();
    if (mounted) setState(() {});
  }

  void _initWebView() {
    // onPermissionRequest: grant in-page getUserMedia (mic) so voice search works.
    _webController = WebViewController(
      onPermissionRequest: (request) => request.grant(),
    )
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'RokidInput',
        onMessageReceived: (msg) {
          if (!mounted) return;
          final editing = msg.message == '1';
          if (_editingText != editing) {
            setState(() {
              _editingText = editing;
              // Field focused by the glasses cursor -> compact text keyboard.
              if (editing && !_showUrlKeyboard) _showTextKeyboard = true;
              if (!editing) _showTextKeyboard = false;
            });
            _applyHudInset(fullscreen: _videoFullscreen);
          }
        },
      )
      ..addJavaScriptChannel(
        'RokidFS',
        onMessageReceived: (msg) {
          // The page reports a video going (near-)fullscreen; hide the HUD AND drop
          // the in-page HUD inset so the video reaches the very top edge.
          final fs = msg.message == '1';
          if (mounted && fs != _autoVideoFullscreen) {
            final before = _videoFullscreen;
            setState(() => _autoVideoFullscreen = fs);
            // Only touch the inset when the EFFECTIVE hidden state actually changed
            // (so a delayed auto '0' can't restore the inset while manually hidden).
            if (_videoFullscreen != before) {
              _applyHudInset(fullscreen: _videoFullscreen);
            }
          }
        },
      )
      ..setBackgroundColor(_kBlack)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 12; Pixel 6) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/120.0.0.0 Mobile Safari/537.36',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final scheme = Uri.tryParse(request.url)?.scheme ?? '';
            if (scheme == 'http' || scheme == 'https' || scheme == 'about') {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
          // SPA sites (YouTube, Facebook…) navigate via History pushState without
          // firing onPageFinished, so canGoBack/Forward would never refresh and the
          // phone's Back/Forward buttons stayed greyed out. onUrlChange fires on
          // those in-app route changes too — re-sync the nav state here.
          onUrlChange: (change) {
            final u = change.url;
            if (u != null && u.isNotEmpty) _refreshNavState(url: u);
          },
          onPageStarted: (url) {
            setState(() {
              _url = url;
              _loading = true;
              _theaterMode = false;
              _autoVideoFullscreen =
                  false; // reset auto; keep the manual choice
            });
            _lastNavMs = 0; // reset touchpad focus-nav coalescing on navigation
            // Paint the page dark IMMEDIATELY (before content renders) so a bright
            // white background never flashes onto the waveguide — the white flash is
            // what causes both the flashing and the heat on these glasses.
            // Dark mode is handled by the native WebView forceDark (algorithmic
            // USER_AGENT darkening) — no CSS invert needed, which avoids the extra
            // repaint/flashing. Just paint the base dark so there's no white flash
            // before the first frame.
            if (_isDark) {
              _webController
                  .runJavaScript(
                    "document.documentElement&&document.documentElement.style"
                    ".setProperty('background','#000','important');",
                  )
                  .catchError((_) {});
            }
            _sendState(url: url, loading: true);
            if (!_webViewConfigured) {
              _startConfigureRetry();
            }
          },
          onPageFinished: (url) async {
            unawaited(_urlHistory.record(url));
            // Patch matchMedia + setForceDark BEFORE the viewport change below,
            // so Google's layout-triggered re-check of prefers-color-scheme
            // already sees our override and doesn't switch to light mode.
            await _applyTheme(_isDark);

            // Reset viewport and apply persistent zoom for the AR display
            await _webController.runJavaScript('''
(function(){
  var m=document.querySelector('meta[name="viewport"]');
  if(!m){m=document.createElement('meta');m.name='viewport';document.head.appendChild(m);}
  // Glasses CSS viewport is only 320px wide (480px @1.5x). Most responsive
  // sites are designed for >=360px and cramp/overlap below that (Google top
  // bar, YouTube). Present a phone-class 400px layout viewport and scale it
  // to fit: everything is ~20% smaller but laid out as intended.
  var W=${_kLayoutWidth};var s=(window.screen.width/W).toFixed(3);
  m.content='width='+W+',initial-scale='+s+',minimum-scale='+s+',maximum-scale=5.0';
  document.querySelectorAll('video').forEach(function(v){v.muted=false;if(v.volume>0.5)v.volume=0.5;});
  // Kill the green tap-highlight / focus outline that appears as a border around
  // focused links & the page frame on this WebView.
  var g=document.getElementById('__rokidNoOutline');
  if(!g){g=document.createElement('style');g.id='__rokidNoOutline';(document.head||document.documentElement).appendChild(g);}
  g.textContent='*{ -webkit-tap-highlight-color:transparent !important; }'+
    '*:focus,*:focus-visible,a:focus,button:focus,input:focus{outline:none !important;'+
      'box-shadow:none !important;}'+
    'html,body{outline:none !important;border:0 !important;}';
  // Report "video takes (almost) the whole screen" to Flutter so the address bar
  // hides and the video is edge-to-edge. We do NOT rely only on the HTML5
  // fullscreen API because sites like Facebook enlarge a <video> with CSS instead
  // of calling requestFullscreen — so we also poll the biggest playing video's
  // size vs the viewport.
  if(!window.__rokidFSHooked){
    window.__rokidFSHooked=true;
    function _bigVideo(){
      // Auto-hide ONLY for real HTML5 fullscreen (reliable, no false positives on
      // large feed/autoplay videos). Reels / CSS-enlarged players are handled by
      // the manual "Ẩn thanh URL" button. (advisor: size heuristic was too eager.)
      return !!document.fullscreenElement;
    }
    var _last=-1;
    function _rfs(){ var f=_bigVideo()?1:0; if(f!==_last){_last=f; try{RokidFS.postMessage(''+f);}catch(e){}} }
    // Recheck ~300ms after an event too (Facebook animates the resize).
    function _rfsSoon(){ _rfs(); setTimeout(_rfs,320); }
    // EVENT-DRIVEN (no permanent polling → no CPU/heat): fullscreen API + play/
    // pause/ended + a ResizeObserver on videos as they appear.
    document.addEventListener('fullscreenchange',_rfsSoon,true);
    document.addEventListener('webkitfullscreenchange',_rfsSoon,true);
    document.addEventListener('play',_rfsSoon,true);
    document.addEventListener('pause',_rfsSoon,true);
    document.addEventListener('ended',_rfsSoon,true);
    window.addEventListener('pagehide',function(){ try{RokidFS.postMessage('0');}catch(e){} });
    var _ro=window.ResizeObserver?new ResizeObserver(_rfs):null;
    function _watch(v){ if(_ro && !v.__rokidRO){v.__rokidRO=1; try{_ro.observe(v);}catch(e){}} }
    document.querySelectorAll('video').forEach(_watch);
    if(window.MutationObserver){
      new MutationObserver(function(muts){
        for(var i=0;i<muts.length;i++){var a=muts[i].addedNodes;
          for(var j=0;j<a.length;j++){var n=a[j];
            if(n.tagName==='VIDEO')_watch(n);
            else if(n.querySelectorAll){n.querySelectorAll('video').forEach(_watch);}}}
      }).observe(document.documentElement,{childList:true,subtree:true});
    }
  }
})();''');
            // Re-apply the user's zoom level to the freshly loaded page (no-op at 100%).
            if (_pageZoom != 1.0) _applyZoom();
            // Reserve the HUD strip INSIDE the page (the WebView itself is full-screen
            // and sits UNDER the address bar). A persistent scroll-padding + a spacer
            // push the page content below the address bar so it is never overlapped,
            // and because the WebView surface stays full-size there is no black band.
            await _applyHudInset();
            // Re-apply after zoom/viewport change triggers Google's layout re-check
            await _applyTheme(_isDark);
            // Re-apply the visual render mode (transparent/wireframe) on the new
            // document — pure CSS, so SPA nodes inherit without re-injection.
            if (_visualMode != 'normal') {
              await _applyVisualMode();
              // SPAs (Facebook) keep injecting styled nodes/stylesheets for a
              // few seconds after "finished"; re-apply so our sheet stays last.
              for (final ms in [600, 1500, 3000, 6000]) {
                Future.delayed(Duration(milliseconds: ms), () {
                  if (mounted && _visualMode != 'normal') _applyVisualMode();
                });
              }
            }
            // Dark mode: only sites that ship their OWN dark theme switch (WebView
            // WEB_THEME_DARKENING_ONLY / prefers-color-scheme). Sites without a dark
            // theme keep their original colors — no simulated/forced recoloring. The
            // brightness slider handles glare/heat for bright pages.

            final title = await _webController.getTitle() ?? '';
            final canGoBack = await _webController.canGoBack();
            final canGoForward = await _webController.canGoForward();
            if (mounted) {
              setState(() {
                _url = url;
                _title = title.isNotEmpty ? title : 'ROKID BROWSER';
                _loading = false;
                _canGoBack = canGoBack;
                _canGoForward = canGoForward;
              });
            }
            _sendState(
              url: url,
              title: title,
              loading: false,
              canGoBack: canGoBack,
              canGoForward: canGoForward,
            );
          },
          onWebResourceError: (_) {
            if (mounted) setState(() => _loading = false);
          },
        ),
      );

    // Enable mixed content and configure Android-specific settings
    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = _webController.platform as AndroidWebViewController;
      android.setMixedContentMode(MixedContentMode.compatibilityMode);
      // Prevent OS accessibility font scaling from inflating page text
      android.setTextZoom(100);
      // Allow media (e.g. YouTube) to play without requiring a tap gesture
      android.setMediaPlaybackRequiresUserGesture(false);
    }


    setState(() => _webViewReady = true);
  }

  void _startConfigureRetry() {
    _configRetryTimer?.cancel();
    _configRetryTimer = Timer.periodic(const Duration(milliseconds: 150), (
      t,
    ) async {
      if (!mounted) {
        t.cancel();
        return;
      }
      try {
        final ok = await _methodChannel.invokeMethod<bool>(
          'configureWebViewZoom',
        );
        if (ok == true) {
          t.cancel();
          _webViewConfigured = true;
          await _applyTheme(_isDark);
        }
      } catch (_) {}
    });
  }

  void _setupEventStream() {
    _eventChannel.receiveBroadcastStream().listen((dynamic event) {
      try {
        final json = jsonDecode(event as String) as Map<String, dynamic>;
        final type = json['type'] as String?;
        if (type == 'bt_status') {
          final status = json['status'] as String? ?? 'unknown';
          if (mounted) {
            setState(() {
              _btStatus = status;
              _connected = status.startsWith('connected');
            });
          }
        } else if (type == 'browser_cmd') {
          _handleCommand(json);
        }
      } catch (e) {
        debugPrint('Event parse error: $e');
      }
    });
  }

  /// Push the page content below the top HUD/address strip by injecting a fixed
  /// spacer + top padding, so a full-screen WebView never has the address bar
  /// overlapping its content. Idempotent (safe to call on every page load).
  /// Zoom the page like a real browser: use the WebView's native text zoom
  /// (settings.textZoom, in %) which reflows content to the viewport width —
  /// unlike CSS `body.zoom` which scaled the box and left black gaps / overflow.
  void _applyZoom() {
    // Reader-style TEXT zoom via native WebView textZoom (%). This is the one
    // approach that is STABLE on this WebView 95: text scales cleanly on every
    // site, always fills the width, never shifts left/right, never breaks layout,
    // never leaves a black margin. (Whole-page CSS zoom/transform that also scales
    // images was tried many ways but was unreliable here — off-screen shifting,
    // side margins, Facebook overriding it.)
    // Whole-page zoom (text + images + everything scales together) via CSS
    // transform:scale on <html>, with transform-origin TOP CENTER so when the page
    // is zoomed out and becomes narrower than the frame, the leftover space splits
    // evenly on both sides — i.e. the page is CENTERED (no all-black on the right).
    // No width hack, no wrapper (which broke SPAs). textZoom stays at 100 so it
    // doesn't double-scale.
    _methodChannel.invokeMethod('setTextZoom', 100).catchError((_) {});
    final z = _pageZoom;
    final zStr = z.toStringAsFixed(3);
    _webController
        .runJavaScript('''
(function(){
  var de=document.documentElement;
  // Remove leftovers from earlier experiments.
  de.style.removeProperty('width');
  de.style.removeProperty('min-height');
  ['__rokidMediaZoom','__rokidZoomFit','__rokidZoomStyle'].forEach(function(id){var e=document.getElementById(id);if(e)e.remove();});
  if($z===1){
    de.style.removeProperty('transform');
    de.style.removeProperty('transform-origin');
    de.style.removeProperty('width');
    return;
  }
  de.style.setProperty('transform','scale($zStr)','important');
  // Scale about the horizontal center but from the TOP of the CONTENT area (just
  // below the address bar = _kHudHeight), not y=0 — otherwise the top of the page
  // scales up under the bar and its first row gets clipped. Uses the shared HUD
  // height constant so the bar and the zoom pivot never drift apart.
  de.style.setProperty('transform-origin','center ${_kHudHeight.round()}px','important');
  de.style.setProperty('background','#000','important');
})();''')
        .catchError((_) {});
  }

  /// Robust scroll: many sites (incl. m.facebook.com) put the scrollable content
  /// in an inner element with its own overflow, not the window. Scroll the window
  /// AND walk up from the cursor position to the nearest actually-scrollable
  /// ancestor and scroll that too.
  void _scrollPage(int dx, int dy) {
    _webController.runJavaScript('''
(function(){
  var DX=$dx, DY=$dy;
  // Scroll exactly ONE target: the nearest scrollable ancestor under the cursor
  // if it can still move in that direction, otherwise the window. (Previously
  // both were scrolled -> double distance.)
  var cx=${_cursorPageX}||Math.floor(window.innerWidth/2);
  var cy=${_cursorPageY}||Math.floor(window.innerHeight/2);
  var el=document.elementFromPoint(cx,cy), guard=0, done=false;
  while(el&&guard++<20&&!done){
    var st=getComputedStyle(el), oy=st.overflowY, ox=st.overflowX;
    var canY=(oy==='auto'||oy==='scroll')&&el.scrollHeight>el.clientHeight+2;
    var canX=(ox==='auto'||ox==='scroll')&&el.scrollWidth>el.clientWidth+2;
    if((canY&&DY)||(canX&&DX)){
      var before=el.scrollTop+el.scrollLeft;
      el.scrollBy({top:DY,left:DX,behavior:'smooth'});
      // If it cannot move further, fall through to the window.
      done=(el.scrollTop+el.scrollLeft)!==before||(DY>0?el.scrollTop<el.scrollHeight-el.clientHeight-1:el.scrollTop>0);
    }
    el=el.parentElement;
  }
  if(!done)window.scrollBy({top:DY,left:DX,behavior:'smooth'});
})()''');
  }

  Future<void> _applyHudInset({bool fullscreen = false}) async {
    // The WebView itself is laid out below the HUD (see build), so pages keep
    // their own layout untouched — fixed headers land right under the bar.
    // Only the editable-focus reporter is installed here.
    try {
      await _webController.runJavaScript(r'''
(function(){
  var s=document.getElementById('__rokidHudInset');if(s)s.remove();
  var sp=document.getElementById('__rokidHdrPad');if(sp)sp.remove();
  if(window.__rokidFixMO){window.__rokidFixMO.disconnect();window.__rokidFixMO=null;}
  if(!window.__rokidInputHooked){
    window.__rokidInputHooked=true;
    function active(root){var e=root.activeElement;return e&&e.shadowRoot?active(e.shadowRoot):e;}
    function report(){var e=active(document);var yes=!!(e&&(e.tagName==='INPUT'||e.tagName==='TEXTAREA'||e.isContentEditable));try{RokidInput.postMessage(yes?'1':'0');}catch(_){} }
    document.addEventListener('focusin',report,true);
    document.addEventListener('focusout',function(){setTimeout(report,0);},true);
    report();
  }
})();''');
    } catch (_) {}
  }

  Future<void> _applyTheme(bool dark) async {
    try {
      await _methodChannel.invokeMethod('setForceDark', dark);
    } catch (_) {}
    if (dark) {
      // Only HINT dark mode: set prefers-color-scheme:dark + neutralize any light
      // color-scheme meta, so sites THAT SUPPORT dark switch to it. We do NOT
      // force-recolor arbitrary elements anymore (that made Facebook washed-out
      // and ran a heavy 400ms loop). Native WebView force-dark already ran above.
      await _webController.runJavaScript(r'''
(function(){
  if(window.__rokidThemeInterval){clearInterval(window.__rokidThemeInterval);window.__rokidThemeInterval=null;}
  try{
    var _o=window.__rokidOrigMM||(window.__rokidOrigMM=window.matchMedia);
    window.matchMedia=function(q){
      if(typeof q==='string'&&q.indexOf('prefers-color-scheme')>=0)
        return{matches:q.replace(/\s/g,'').indexOf('dark')>=0,media:q,onchange:null,
          addListener:function(){},removeListener:function(){},
          addEventListener:function(){},removeEventListener:function(){},
          dispatchEvent:function(){return false;}};
      return _o.call(this,q);
    };
    var meta=document.querySelector('meta[name="color-scheme"]');
    if(!meta&&document.head){meta=document.createElement('meta');meta.name='color-scheme';document.head.appendChild(meta);}
    if(meta)meta.content='dark';
    document.documentElement.style.colorScheme='dark';
  }catch(e){}
})();''');
      return;
    }
    // Light mode: undo every dark hint we set above so the site renders in its
    // own default (light) colors. No forced recoloring in either direction.
    await _webController.runJavaScript(r'''
(function(){
  if(window.__rokidThemeInterval){clearInterval(window.__rokidThemeInterval);window.__rokidThemeInterval=null;}
  if(window.__rokidOrigMM){window.matchMedia=window.__rokidOrigMM;window.__rokidOrigMM=null;}
  var meta=document.querySelector('meta[name="color-scheme"]');
  if(meta)meta.content='light';
  document.documentElement.style.colorScheme='';
  var s=document.getElementById('__rk');if(s)s.remove();
  var ov=document.getElementById('__rk_ov');if(ov)ov.remove();
  document.documentElement.removeAttribute('dark');
  document.documentElement.removeAttribute('data-theme');
  document.documentElement.removeAttribute('data-color-mode');
  document.documentElement.classList.remove('dark');
  // Remove all inline color/fill we forced in dark mode (including shadow DOM).
  function _clean(root){
    var all=root.querySelectorAll('*');
    for(var i=0;i<all.length;i++){
      all[i].style.removeProperty('color');
      all[i].style.removeProperty('fill');
      if(all[i].shadowRoot)_clean(all[i].shadowRoot);
    }
  }
  _clean(document);
})();''');
  }

  /// Apply the current visual render mode by injecting (or removing) a single
  /// reversible stylesheet <style id="__rokidVisualMode">. Pure CSS — no DOM walk,
  /// no MutationObserver — so newly added SPA nodes inherit automatically and
  /// removing the <style> restores the page exactly. Images/video/canvas/svg are
  /// preserved in every mode. Reapplied on onPageFinished (new document).
  static const _kVisualModePref = 'rokid_visual_mode';

  /// Restore the persisted visual mode so it survives an app restart.
  Future<void> _loadVisualMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String saved = prefs.getString(_kVisualModePref) ?? 'normal';
      if (saved == 'transparent' || saved == 'wireframe') {
        if (mounted) setState(() => _visualMode = saved);
        // Apply now regardless of load timing: if a page is already up it takes
        // effect immediately; if not, onPageFinished re-applies. This closes the
        // race where prefs resolve AFTER the first onPageFinished (advisor).
        await _applyVisualMode();
      }
    } catch (_) {}
  }

  Future<void> _saveVisualMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kVisualModePref, _visualMode);
    } catch (_) {}
  }

  // Escape a Dart string into a safe single-quoted JS literal.
  String _jsStr(String s) =>
      "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  Future<void> _applyVisualMode() async {
    final mode = _visualMode;
    await _webController
        .runJavaScript('''
(function(){
  var ID='__rokidVisualMode';
  var old=document.getElementById(ID);
  if(old)old.remove();
  var mode=${_jsStr(mode)};
  if(mode==='normal'){if(window.__rokidVisualMO){window.__rokidVisualMO.disconnect();window.__rokidVisualMO=null;}return;}
  var css='';
  if(mode==='transparent'||mode==='wireframe'){
    // Strip backgrounds + fills so the page reads as floating content. Keep media
    // (img/video/canvas/picture/iframe/svg) and their backgrounds intact. Bright
    // text + a subtle shadow for legibility on the transparent waveguide.
    css+=
      '*:not(img):not(video):not(canvas):not(picture):not(iframe):not(svg):not(svg *){'+
        'background:transparent !important;'+          // shorthand: beats FB bg-sN classes
        'background-color:transparent !important;'+
        'background-image:none !important;'+
        'box-shadow:none !important;'+
        'backdrop-filter:none !important;-webkit-backdrop-filter:none !important;'+
        'border-color:rgba(255,255,255,.18) !important;'+
      '}'+
      // Semi-transparent scrims / dimmers (FB uses rgba overlays and CSS vars).
      '[style*="background"]{background:transparent !important;background-image:none !important;}'+
      ':root{--card-background:transparent !important;--surface-background:transparent !important;'+
        '--nav-bar-background:transparent !important;--web-wash:transparent !important;'+
        '--secondary-button-background:transparent !important;--wash:transparent !important;}'+
      // Facebook (and many sites) paint solid panels via ::before/::after overlays
      // with a white background — neutralize the FILL color, but KEEP their
      // background-image so pseudo-drawn icons/badges/toggles/arrows survive.
      '*::before,*::after{'+
        'background-color:transparent !important;'+
        'background-image:none !important;'+
        'box-shadow:none !important;'+
        'backdrop-filter:none !important;'+
      '}'+
      'html,body{background:#000 !important;}'+  // base so unlit areas are true-black (transparent on AR)
      'body,p,span,a,li,td,th,h1,h2,h3,h4,h5,h6,div,label,strong,em,small,button{'+
        'color:#EDEDED !important;'+
        'text-shadow:0 0 2px rgba(0,0,0,.9) !important;'+
      '}'+
      'a,a *{color:#8ab4f8 !important;}'+
      // Keep form fields usable: visible border + caret even if the site had none.
      'input,textarea,select{'+
        'border:1px solid rgba(160,190,255,.6) !important;'+
        'color:#EDEDED !important;caret-color:#EDEDED !important;'+
      '}';
  }
  if(mode==='wireframe'){
    // Outline only STRUCTURAL / interactive elements (not every div/span — that
    // makes an unreadable nested grid). Subtle 1px so it reads as a blueprint.
    css+=
      'main,section,article,nav,header,footer,aside,form,table,figure,'+
      'button,input,textarea,select,[role="button"],[role="link"],'+
      '.card,[class*="card"],[class*="Card"]{'+
        'outline:1px solid rgba(120,180,255,.45) !important;'+
        'outline-offset:-1px !important;'+
      '}';
  }
  var s=document.createElement('style');
  s.id=ID;
  s.textContent=css;
  (document.body||document.head||document.documentElement).appendChild(s);
  // Keep our sheet LAST so later site stylesheets cannot out-cascade it.
  if(!window.__rokidVisualMO){
    window.__rokidVisualMO=new MutationObserver(function(muts){
      var el=document.getElementById(ID);
      if(!el)return;
      var parent=document.body||document.head;
      if(parent&&parent.lastElementChild!==el){parent.appendChild(el);}
    });
    window.__rokidVisualMO.observe(document.documentElement,{childList:true,subtree:true});
  }
})();''')
        .catchError((_) {});
  }

  Future<void> _handleCommand(Map<String, dynamic> cmd) async {
    final action = cmd['action'] as String?;
    switch (action) {
      case 'remote_click':
        if (!mounted) throw StateError('Screen is not active');
        final x = (cmd['x'] as num).toDouble();
        final y = (cmd['y'] as num).toDouble();
        final size = MediaQuery.sizeOf(context);
        final logicalY = y * size.height;
        if (!_videoFullscreen && !_theaterMode && logicalY < _kHudHeight) {
          throw StateError('The glasses HUD is not a clickable web-page area');
        }
        _cursorX = x * size.width;
        _cursorY = logicalY;
        await _handleCommand({'action': 'cursor_click'});
      case 'remote_swipe':
        if (!mounted) throw StateError('Screen is not active');
        final size = MediaQuery.sizeOf(context);
        final dx = (cmd['dx'] as num).toDouble();
        final dy = (cmd['dy'] as num).toDouble();
        _scrollPage((-dx * size.width).round(), (-dy * size.height).round());
      case 'remote_drag_move':
        if (!mounted) throw StateError('Screen is not active');
        final size = MediaQuery.sizeOf(context);
        await _handleCommand({
          'action': 'cursor_drag_move',
          'dx': (cmd['dx'] as num).toDouble() * size.width * _kRemotePadGain / 2.5,
          'dy': (cmd['dy'] as num).toDouble() * size.height * _kRemotePadGain / 2.5,
        });
      case 'remote_cursor_move':
        if (!mounted) throw StateError('Screen is not active');
        final size = MediaQuery.sizeOf(context);
        await _handleCommand({
          'action': 'cursor_move',
          'dx': (cmd['dx'] as num).toDouble() * size.width * _kRemotePadGain / 2.5,
          'dy': (cmd['dy'] as num).toDouble() * size.height * _kRemotePadGain / 2.5,
        });
      case 'click':
        final x = (cmd['x'] as num?)?.toDouble();
        final y = (cmd['y'] as num?)?.toDouble();
        if (x != null && y != null) {
          _cursorX = x.clamp(0, 480);
          _cursorY = y.clamp(0, 640);
          _cursorVisible = true;
          _syncCursor();
          // Let the native overlay settle so cursorScreenPos reflects the new spot.
          await Future<void>.delayed(const Duration(milliseconds: 40));
          await _handleCommand({'action': 'cursor_click'});
        }
      case 'type':
        await _handleCommand({'action': 'keyboard_type', 'text': cmd['text']});
      case 'enter':
        await _handleCommand({'action': 'keyboard_enter'});
      case 'backspace':
        await _handleCommand({'action': 'keyboard_backspace'});
      case 'navigate':
        final input = (cmd['url'] as String? ?? '').trim();
        if (input.isEmpty) throw const FormatException('Address is empty');
        final explicit = Uri.tryParse(input);
        late final Uri destination;
        if (explicit != null &&
            (explicit.scheme == 'http' || explicit.scheme == 'https') &&
            explicit.host.isNotEmpty) {
          destination = explicit;
        } else if (!input.contains(RegExp(r'\s')) && input.contains('.')) {
          destination = Uri.parse('https://$input');
        } else {
          destination = Uri.https('www.google.com', '/search', {'q': input});
        }
        _webController.loadRequest(destination);
      case 'hw_button_up':
        // Temple button. The system often delivers the same press twice within
        // ~20ms -> ignore duplicates < 80ms. Two presses within 500ms toggle
        // MOUSE <-> SCROLL mode; a single press flips the mouse axis.
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - _hwLastPressMs < 80) return;
        _hwLastPressMs = nowMs;
        _hwPressCount++;
        _hwPressTimer?.cancel();
        if (_hwPressCount >= 2) {
          _hwPressCount = 0;
          setState(() {
            _swipeScrollsPage = !_swipeScrollsPage;
            _cursorVisible = !_swipeScrollsPage;
          });
          _syncCursor();
          _resetCursorHideTimer();
          _showModeToast(_modeLabel());
        } else {
          _hwPressTimer = Timer(const Duration(milliseconds: 500), () {
            if (!mounted) return;
            _hwPressCount = 0;
            if (_swipeScrollsPage) {
              _showModeToast(_modeLabel());
            } else {
              setState(() => _mouseAxisVertical = !_mouseAxisVertical);
              _showModeToast(_modeLabel());
            }
          });
        }
      case 'hw_button_long':
        _hwPressTimer?.cancel();
        _hwPressCount = 0;
        if (_confirmExit) {
          await _handleCommand({'action': 'exit_app'});
        } else {
          _armExitConfirm();
        }
      case 'cursor_dblclick':
        // Two native taps within the double-tap window; the WebView itself
        // synthesises the dblclick event (verified), so do not add another.
        await _handleCommand({'action': 'cursor_click'});
        await Future<void>.delayed(const Duration(milliseconds: 90));
        await _handleCommand({'action': 'cursor_click'});
      case 'touchpad_back':
        // One-finger double-tap: mouse mode = double-click at the cursor;
        // scroll mode = Back.
        if (!_swipeScrollsPage) {
          await _handleCommand({'action': 'cursor_dblclick'});
          return;
        }
        await _handleCenterDoubleTap();
      case 'back':
        // Phone / web remote Back: exit video fullscreen first, otherwise go
        // back in history; never exit the app when history is empty.
        await _handleCenterDoubleTap();
      case 'forward':
        _webController.goForward();
      case 'reload':
        _webController.reload();
      case 'scroll_down':
        _scrollPage(0, 120);
      case 'scroll_up':
        _scrollPage(0, -120);
      case 'scroll_left':
        _scrollPage(-80, 0);
      case 'scroll_right':
        _scrollPage(80, 0);
      case 'zoom_in':
        _pageZoom = (_pageZoom + 0.1).clamp(0.5, 3.0);
        _applyZoom();
      case 'zoom_out':
        _pageZoom = (_pageZoom - 0.1).clamp(0.5, 3.0);
        _applyZoom();
      case 'set_theme':
        final dark = cmd['dark'] as bool? ?? true;
        if (mounted) setState(() => _isDark = dark);
        if (_url.isNotEmpty) await _applyTheme(dark);
      case 'set_visual_mode':
        // normal | transparent | wireframe — strip page backgrounds/fills for the
        // AR waveguide. Echo state back so the phone's selector stays in sync.
        final m = cmd['mode'] as String? ?? 'normal';
        _visualMode = (m == 'transparent' || m == 'wireframe') ? m : 'normal';
        await _applyVisualMode();
        _saveVisualMode(); // persist so it survives glasses-app restart
        _sendState(); // echo new mode back so phone selector stays in sync
      case 'toggle_hud':
        // Manual show/hide of the address bar (independent of auto video-detect).
        if (mounted) {
          final before = _videoFullscreen;
          setState(() => _manualHudHidden = !_manualHudHidden);
          if (_videoFullscreen != before) {
            await _applyHudInset(fullscreen: _videoFullscreen);
          }
        }
      case 'toggle_passthrough':
        // Passthrough (dim overlay) is now triggered from the phone app instead
        // of a touchpad gesture (the touchpad drives focus-navigation).
        _togglePassthrough();
      case 'minimize':
        if (_theaterMode) {
          _exitTheaterMode();
        } else {
          _exitFullscreen();
        }
      case 'video_theater':
        if (_theaterMode) {
          _exitTheaterMode();
        } else {
          setState(() => _theaterMode = true);
          _webController.runJavaScript('''
(function(){
  var v=document.querySelector('video');
  if(!v)return;
  window.__rokidTheaterOriginals=window.__rokidTheaterOriginals||{};
  window.__rokidTheaterOriginals.htmlStyle=document.documentElement.getAttribute('style')||'';
  window.__rokidTheaterOriginals.bodyStyle=document.body.getAttribute('style')||'';
  window.__rokidTheaterOriginals.videoStyle=v.getAttribute('style')||'';
  window.__rokidTheaterOriginals.hiddenEls=[];
  document.documentElement.style.cssText='background:#000!important;overflow:hidden!important';
  document.body.style.cssText='background:#000!important;overflow:hidden!important;margin:0!important;padding:0!important';
  v.style.cssText='position:fixed!important;top:0!important;left:0!important;width:100vw!important;height:100vh!important;z-index:2147483647!important;background:#000!important;object-fit:contain!important';
  v.muted=false; v.volume=1;
  Array.from(document.body.children).forEach(function(el){
    if(!el.contains(v)&&el!==v){
      window.__rokidTheaterOriginals.hiddenEls.push({el:el,display:el.style.display});
      el.style.setProperty('display','none','important');
    }
  });
})()''');
        }
      case 'cursor_move':
        final dx = (cmd['dx'] as num?)?.toDouble() ?? 0;
        final dy = (cmd['dy'] as num?)?.toDouble() ?? 0;
        if (mounted) {
          final size = MediaQuery.of(context).size;
          // IMPORTANT: do NOT call setState() here. The cursor is drawn by a native
          // Android overlay View (see updateCursor in MainActivity.kt), NOT by the
          // Flutter tree — so rebuilding the widget tree (which includes the
          // VirtualDisplay WebView) ~20x/sec on every trackpad move is what caused
          // the flashing + overheating. Just update the coordinates and push them
          // straight to the native cursor.
          _cursorX = (_cursorX + dx * 2.5).clamp(0, size.width);
          _cursorY = (_cursorY + dy * 2.5).clamp(0, size.height);
          _cursorVisible = true;
          _resetCursorHideTimer();
          _syncCursor();
        }
      case 'cursor_click':
        final cx = _cursorX;
        final cy = _cursorY;
        // Overlays are hit-tested against where the dot is REALLY drawn.
        double ox = cx, oy = cy;
        try {
          final pos = await _methodChannel.invokeMethod<List<dynamic>>('cursorScreenPos');
          if (pos != null && pos.length == 2) {
            ox = (pos[0] as num).toDouble();
            oy = (pos[1] as num).toDouble();
          }
        } catch (_) {}
        // Flutter overlay coordinates: the Scaffold body starts at the window
        // origin (no system bars on this device), so window == Flutter global.
        if (_showUrlKeyboard) {
          _urlKbKey.currentState?.hitTest(Offset(ox, oy));
          return;
        }
        if (_showTextKeyboard) {
          final consumed = _textKbKey.currentState?.hitTest(Offset(ox, oy)) ?? false;
          if (consumed) return;
          // fell through: keyboard closed itself, continue as a page click
        }
        if (_showWebRemotePanel) {
          final panelActions = <String, VoidCallback?>{
            'start': _webRemote.running ? null : _startWebRemote,
            'revoke': _webRemoteStatus == WebRemoteStatus.paired ? _revokeWebRemote : null,
            'stop': _webRemote.running ? _stopWebRemote : null,
            'exit': () {
              if (_confirmExit) {
                _handleCommand({'action': 'exit_app'});
              } else {
                _armExitConfirm();
              }
            },
            'close': () => setState(() {
                  _showWebRemotePanel = false;
                  _confirmExit = false;
                }),
          };
          for (final entry in _panelKeys.entries) {
            final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
            if (box == null || !box.hasSize) continue;
            final origin = box.localToGlobal(Offset.zero);
            if ((origin & box.size).inflate(10).contains(Offset(ox, oy))) {
              panelActions[entry.key]?.call();
              return;
            }
          }
          return; // click on dim backdrop: ignore
        }
        // Cursor over the HUD strip: activate the toolbar button under it.
        {
          final box = _castKey.currentContext?.findRenderObject() as RenderBox?;
          if (box != null && box.hasSize) {
            final o = box.localToGlobal(Offset.zero);
            if ((o & box.size).inflate(6).contains(Offset(ox, oy))) {
              setState(() => _showWebRemotePanel = true);
              return;
            }
          }
        }
        if (!_theaterMode && !_videoFullscreen && oy < _kHudHeight + 2) {
          final actions = <String, VoidCallback?>{
            'address': () => setState(() => _showUrlKeyboard = true),
            'back': _canGoBack ? _goBack : null,
            'forward': _canGoForward ? () => _webController.goForward() : null,
            'up': _url.isNotEmpty ? () => _handleCommand({'action': 'keyboard_key', 'key': 'ArrowUp'}) : null,
            'down': _url.isNotEmpty ? () => _handleCommand({'action': 'keyboard_key', 'key': 'ArrowDown'}) : null,
            'left': _url.isNotEmpty ? () => _handleCommand({'action': 'keyboard_key', 'key': 'ArrowLeft'}) : null,
            'right': _url.isNotEmpty ? () => _handleCommand({'action': 'keyboard_key', 'key': 'ArrowRight'}) : null,
            'stop': _loading ? () => _webController.runJavaScript('window.stop()') : null,
            'reload': _url.isNotEmpty ? () => _webController.reload() : null,
            'exit': () {
              if (_confirmExit) {
                _handleCommand({'action': 'exit_app'});
              } else {
                _armExitConfirm();
              }
            },
          };
          for (final entry in _HudBar.toolKeys.entries) {
            final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
            if (box == null || !box.hasSize) continue;
            final origin = box.localToGlobal(Offset.zero);
            if ((origin & box.size).inflate(6).contains(Offset(ox, oy))) {
              actions[entry.key]?.call();
              return;
            }
          }
          return;
        }
        // Use the same fullscreen detection as the double-tap exit handler:
        // document.fullscreenElement covers HTML5 fullscreen; the YouTube
        // aria-label check covers its custom player fullscreen mode.
        bool isFullscreen = false;
        try {
          final fsResult = await _webController.runJavaScriptReturningResult(
            r'''
(function(){
  if(document.fullscreenElement)return true;
  var fb=document.querySelector('.ytp-fullscreen-button');
  if(fb){var l=(fb.getAttribute('aria-label')||'').toLowerCase();if(l.includes('exit')||l.includes('minimize'))return true;}
  return false;
})()''',
          );
          isFullscreen = fsResult == true || fsResult.toString() == 'true';
        } catch (_) {}
        bool nativeOk = false;
        try {
          nativeOk =
              await _methodChannel.invokeMethod<bool>('clickAt', {
                'x': cx,
                'y': cy,
                'fullscreen': isFullscreen,
              }) ??
              false;
        } catch (_) {}
        if (!nativeOk) {
          // JS fallback for when the WebView isn't found yet
          _webController.runJavaScript('''
(function(x,y){
  var el=document.elementFromPoint(x,y);
  if(!el)return;
  try{var id=Date.now();var tc=new Touch({identifier:id,target:el,clientX:x,clientY:y,pageX:x,pageY:y,screenX:x,screenY:y,radiusX:1,radiusY:1,rotationAngle:0,force:1});el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[tc],changedTouches:[tc]}));el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],changedTouches:[tc]}));}catch(e){}
  ['mouseover','mousedown','mouseup','click'].forEach(function(t){el.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,view:window,clientX:x,clientY:y}));});
  if(el.tagName==='INPUT'||el.tagName==='TEXTAREA'||el.isContentEditable)el.focus();
  if(el.tagName==='IFRAME'){try{var r=el.getBoundingClientRect();var fx=x-r.left,fy=y-r.top;var fi=el.contentDocument&&el.contentDocument.elementFromPoint(fx,fy);if(fi){['mouseover','mousedown','mouseup','click'].forEach(function(t){fi.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,view:el.contentWindow,clientX:fx,clientY:fy}));});if(fi.tagName==='INPUT'||fi.tagName==='TEXTAREA'||fi.isContentEditable)fi.focus();}}catch(e){}}
})($_cursorPageX,$_cursorPageY)''');
        }
      case 'cursor_long_press':
        final cx = _cursorX.toInt();
        final cy = _cursorPageY;
        _webController.runJavaScript('''
(function(x,y){
  var el=document.elementFromPoint(x,y);
  if(!el)return;
  el.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true,view:window,clientX:x,clientY:y}));
})($_cursorPageX,$_cursorPageY)''');
      case 'clear_session':
        _webController.clearCache();
        _webController.clearLocalStorage();
        WebViewCookieManager().clearCookies();
        _webController.runJavaScript(
          'try{localStorage.clear();sessionStorage.clear();}catch(e){}',
        );
        if (mounted) {
          setState(() {
            _url = '';
            _title = 'ROKID BROWSER';
            _canGoBack = false;
            _canGoForward = false;
            _cursorVisible = false;
            _cursorDragging = false;
          });
        }
        _webController.loadRequest(Uri.parse('about:blank'));
      case 'set_third_party_cookies':
        final block = cmd['block'] as bool? ?? false;
        try {
          await _methodChannel.invokeMethod('setThirdPartyCookies', {
            'block': block,
          });
        } catch (_) {}
      case 'cursor_drag_start':
        if (mounted) {
          setState(() => _cursorDragging = true);
          _syncCursor();
        }
        _webController.runJavaScript('''
(function(x,y){
  window.__rokidDragId=Date.now()&0xFFFF;
  window.__rokidDragEl=document.elementFromPoint(x,y)||document.body;
  try{
    var tc=new Touch({identifier:window.__rokidDragId,target:window.__rokidDragEl,
      clientX:x,clientY:y,pageX:x+window.pageXOffset,pageY:y+window.pageYOffset,
      screenX:x,screenY:y,radiusX:1,radiusY:1,rotationAngle:0,force:1});
    window.__rokidDragEl.dispatchEvent(new TouchEvent('touchstart',
      {bubbles:true,cancelable:true,touches:[tc],targetTouches:[tc],changedTouches:[tc]}));
  }catch(e){}
})(${_cursorPageX},${_cursorPageY})''');
      case 'cursor_drag_move':
        final ddx = (cmd['dx'] as num?)?.toDouble() ?? 0;
        final ddy = (cmd['dy'] as num?)?.toDouble() ?? 0;
        if (mounted) {
          final size = MediaQuery.of(context).size;
          // No setState() — same reason as cursor_move: the native overlay draws
          // the cursor; rebuilding the WebView subtree per drag frame overheats.
          _cursorX = (_cursorX + ddx * 2.5).clamp(0, size.width);
          _cursorY = (_cursorY + ddy * 2.5).clamp(0, size.height);
          _cursorVisible = true;
          _resetCursorHideTimer();
          _syncCursor();
          // Scroll the page like a phone swipe (negate delta: drag up = scroll down)
          _webController.runJavaScript(
            '''
(function(x,y,dx,dy){
  window.scrollBy(-dx*3,-dy*3);
  var el=window.__rokidDragEl||document.body;
  var id=window.__rokidDragId||1;
  try{
    var tc=new Touch({identifier:id,target:el,
      clientX:x,clientY:y,pageX:x+window.pageXOffset,pageY:y+window.pageYOffset,
      screenX:x,screenY:y,radiusX:1,radiusY:1,rotationAngle:0,force:1});
    document.dispatchEvent(new TouchEvent('touchmove',
      {bubbles:true,cancelable:true,touches:[tc],targetTouches:[tc],changedTouches:[tc]}));
  }catch(e){}
})(${_cursorPageX},${_cursorPageY},${ddx.toStringAsFixed(2)},${ddy.toStringAsFixed(2)})''',
          );
        }
      case 'cursor_drag_end':
        if (mounted) {
          setState(() => _cursorDragging = false);
          _syncCursor();
        }
        _webController.runJavaScript('''
(function(x,y){
  var el=window.__rokidDragEl||document.body;
  var id=window.__rokidDragId||1;
  try{
    var tc=new Touch({identifier:id,target:el,
      clientX:x,clientY:y,pageX:x+window.pageXOffset,pageY:y+window.pageYOffset,
      screenX:x,screenY:y,radiusX:1,radiusY:1,rotationAngle:0,force:0});
    document.dispatchEvent(new TouchEvent('touchend',
      {bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[tc]}));
  }catch(e){}
  window.__rokidDragEl=null;window.__rokidDragId=null;
})(${_cursorPageX},${_cursorPageY})''');
      case 'keyboard_type':
        final text = cmd['text'] as String? ?? '';
        if (text.isNotEmpty) {
          final encoded = jsonEncode(text);
          _webController.runJavaScript('''
(function(t){
  // Resolve the truly focused element, piercing shadow roots and iframes.
  // document.activeElement returns the shadow HOST when focus is inside a shadow root,
  // and the <iframe> element when focus is inside a frame — we must drill through both.
  function _deepActive(doc){
    var el=doc.activeElement;
    if(!el)return null;
    if(el.shadowRoot&&el.shadowRoot.activeElement)return _deepActive(el.shadowRoot);
    if(el.tagName==='IFRAME'){
      try{var id=el.contentDocument&&_deepActive(el.contentDocument);if(id)return id;}catch(e){}
    }
    return el;
  }
  var el=_deepActive(document);
  if(!el||(el.tagName!=='INPUT'&&el.tagName!=='TEXTAREA'&&!el.isContentEditable))return;
  el.focus();
  // execCommand('insertText') is the correct way to type into framework-controlled inputs
  // (React, Angular, Polymer) — it triggers their synthetic input events and works on
  // ALL input types including password fields (unlike setRangeText which throws for password).
  if(document.execCommand('insertText',false,t))return;
  // Fallback for browsers where execCommand is disabled: native value setter + input event.
  // The native setter bypasses React's overridden setter, then firing 'input' notifies React.
  try{
    if(el.isContentEditable){el.textContent+=t;}
    else{
      var proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
      var setter=Object.getOwnPropertyDescriptor(proto,'value').set;
      setter.call(el,el.value+t);
    }
    el.dispatchEvent(new InputEvent('input',{bubbles:true,data:t,inputType:'insertText'}));
    el.dispatchEvent(new Event('change',{bubbles:true}));
  }catch(e){}
})($encoded)''');
        }
      case 'keyboard_clear_field':
        _webController.runJavaScript(r'''
(function(){
  function _deepActive(doc){var el=doc.activeElement;if(!el)return null;if(el.shadowRoot&&el.shadowRoot.activeElement)return _deepActive(el.shadowRoot);if(el.tagName==='IFRAME'){try{var id=el.contentDocument&&_deepActive(el.contentDocument);if(id)return id;}catch(e){}}return el;}
  var el=_deepActive(document);if(!el)return;
  if(el.isContentEditable){el.textContent='';el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'deleteContentBackward'}));return;}
  if(el.tagName!=='INPUT'&&el.tagName!=='TEXTAREA')return;
  var proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
  var setter=Object.getOwnPropertyDescriptor(proto,'value').set;setter.call(el,'');
  el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'deleteContentBackward'}));
  el.dispatchEvent(new Event('change',{bubbles:true}));
})()''');
      case 'keyboard_backspace':
        _webController.runJavaScript('''
(function(){
  function _deepActive(doc){
    var el=doc.activeElement;
    if(!el)return null;
    if(el.shadowRoot&&el.shadowRoot.activeElement)return _deepActive(el.shadowRoot);
    if(el.tagName==='IFRAME'){try{var id=el.contentDocument&&_deepActive(el.contentDocument);if(id)return id;}catch(e){}}
    return el;
  }
  var el=_deepActive(document);
  if(!el||(el.tagName!=='INPUT'&&el.tagName!=='TEXTAREA'&&!el.isContentEditable))return;
  el.focus();
  if(document.execCommand('delete',false,null))return;
  try{
    if(el.isContentEditable){document.execCommand('delete',false,null);}
    else{var s=el.selectionStart;if(s>0){el.setRangeText('',s-1,s,'end');el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'deleteContentBackward'}));}}
  }catch(e){}
})()''');
      case 'keyboard_enter':
        _webController.runJavaScript(r'''
(function(){
  function _deepActive(doc){
    var el=doc.activeElement;
    if(!el)return null;
    if(el.shadowRoot&&el.shadowRoot.activeElement)return _deepActive(el.shadowRoot);
    if(el.tagName==='IFRAME'){try{var id=el.contentDocument&&_deepActive(el.contentDocument);if(id)return id;}catch(e){}}
    return el;
  }
  var el=_deepActive(document)||document.body;
  el.focus&&el.focus();
  var proceed=el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
  if(proceed)proceed=el.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
  el.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
  // Respect a site's Enter handler. Never click an arbitrary button in the form:
  // modern search forms also contain AI, microphone and camera buttons.
  if(proceed&&el.form){
    try{if(typeof el.form.requestSubmit==='function')el.form.requestSubmit();
    else el.form.submit();}catch(e){}
  }
})()''');
      case 'keyboard_key':
        // Generic key press (Tab, ArrowLeft/Right/Up/Down, etc.) dispatched to the
        // focused element on the page.
        final key = cmd['key'] as String? ?? '';
        if (key.isNotEmpty) {
          final keyMap = <String, int>{
            'Tab': 9,
            'ArrowLeft': 37,
            'ArrowUp': 38,
            'ArrowRight': 39,
            'ArrowDown': 40,
          };
          final code = keyMap[key] ?? 0;
          _webController.runJavaScript('''
(function(){
  function _deepActive(doc){
    var el=doc.activeElement;
    if(!el)return null;
    if(el.shadowRoot&&el.shadowRoot.activeElement)return _deepActive(el.shadowRoot);
    if(el.tagName==='IFRAME'){try{var id=el.contentDocument&&_deepActive(el.contentDocument);if(id)return id;}catch(e){}}
    return el;
  }
  var el=_deepActive(document)||document.body;
  var K='$key', C=$code;
  function fire(t){el.dispatchEvent(new KeyboardEvent(t,{key:K,code:K,keyCode:C,which:C,bubbles:true,cancelable:true}));}
  el.focus&&el.focus();
  fire('keydown'); fire('keyup');
  // Tab moves focus; emulate it since synthetic KeyboardEvent doesn't change focus.
  if(K==='Tab'){
    var f=Array.prototype.slice.call(document.querySelectorAll(
      'a[href],button,input,select,textarea,[tabindex]:not([tabindex="-1"])'))
      .filter(function(e){return e.offsetParent!==null&&!e.disabled;});
    var i=f.indexOf(el);
    var next=f[(i+1)%f.length]; if(next)next.focus();
  }
  // Arrow keys: also scroll the page a little so navigation feels responsive.
  if(K==='ArrowDown')window.scrollBy(0,60);
  else if(K==='ArrowUp')window.scrollBy(0,-60);
  else if(K==='ArrowRight')window.scrollBy(40,0);
  else if(K==='ArrowLeft')window.scrollBy(-40,0);
})()''');
        }
      case 'set_dim':
        // Manual brightness/dim control from the phone (0.0=normal .. 0.8=dimmest).
        final v = (cmd['value'] as num?)?.toDouble() ?? 0.0;
        _methodChannel.invokeMethod('setDim', v).catchError((_) {});
      case 'volume_up':
        _adjustMediaVolume(0.05);
      case 'volume_down':
        _adjustMediaVolume(-0.05);
      case 'wifi_enable':
        _methodChannel.invokeMethod('wifiEnable');
      case 'wifi_disable':
        _methodChannel.invokeMethod('wifiDisable');
      case 'debug_probe':
        final r = await _webController.runJavaScriptReturningResult(r'''
(function(){
  var out=[];var seen=0;
  var all=document.querySelectorAll('*');
  for(var i=0;i<all.length&&out.length<40;i++){
    var el=all[i];var cs=getComputedStyle(el);
    var bg=cs.backgroundColor, bi=cs.backgroundImage, bf=cs.backdropFilter||cs.webkitBackdropFilter;
    var r=el.getBoundingClientRect();
    if(r.width<20||r.height<20)continue;
    var opaque=(bg&&bg!=='rgba(0, 0, 0, 0)'&&bg!=='transparent')||(bi&&bi!=='none')||(bf&&bf!=='none');
    if(opaque){out.push({t:el.tagName,c:(el.className||'').toString().slice(0,60),bg:bg,bi:bi.slice(0,60),bf:bf,w:Math.round(r.width),h:Math.round(r.height),y:Math.round(r.top)});}
  }
  return JSON.stringify(out);
})()''');
        _webRemote.publishDebug(r.toString());
      case 'set_asr_key':
        await VoiceAsr.saveKey((cmd['key'] as String?) ?? '');
        _webRemote.publishAsrKeyState(await VoiceAsr.loadKey());
      case 'clear_asr_key':
        await VoiceAsr.saveKey('');
        _webRemote.publishAsrKeyState('');
      case 'get_asr_key':
        _webRemote.publishAsrKeyState(await VoiceAsr.loadKey());
        _webRemote.publishAsrModel(await VoiceAsr.loadModel(), null);
      case 'set_asr_model':
        await VoiceAsr.saveModel((cmd['model'] as String?) ?? '');
        _webRemote.publishAsrModel(await VoiceAsr.loadModel(), null);
      case 'list_asr_models':
        final key = await VoiceAsr.loadKey();
        if (key.isEmpty) throw StateError('No Gemini API key saved');
        final models = await VoiceAsr.listModels(key);
        _webRemote.publishAsrModel(await VoiceAsr.loadModel(), models);
      case 'history_list':
        _webRemote.publishHistory(_urlHistory.history);
      case 'history_remove':
        await _urlHistory.remove(cmd['url'] as String);
        _webRemote.publishHistory(_urlHistory.history);
      case 'history_clear':
        for (final u in List<String>.from(_urlHistory.history)) {
          await _urlHistory.remove(u);
        }
        _webRemote.publishHistory(_urlHistory.history);
      case 'exit_app':
        _confirmExitTimer?.cancel();
        await _webRemote.stop();
        await _methodChannel.invokeMethod('exitApp');
      case 'wifi_connect':
        _methodChannel.invokeMethod('wifiConnect', {
          'ssid': cmd['ssid'] as String? ?? '',
          'password': cmd['password'] as String? ?? '',
        });
    }
  }

  void _resetCursorHideTimer() {
    _cursorHideTimer?.cancel();
    // Mouse mode on the glasses: the cursor is the primary pointer, keep it.
    if (!_swipeScrollsPage) return;
    _cursorHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _cursorVisible = false);
        _syncCursor();
      }
    });
  }

  // Push cursor state to the native Android layer so it remains visible above
  // SurfaceView fullscreen video, which renders above Flutter's widget tree.
  /// The native cursor dot is drawn at y + (WebView top offset). Overlay
  /// widgets (HUD, panels, keyboard) are hit-tested in window space, so add
  /// the same offset to compare like with like.
  double _cursorOverlayY() => _cursorY;
  /// Cursor Y in WebView/page coordinates (WebView sits below the HUD).
  double get _pageTop => (!_theaterMode && !_videoFullscreen && _url.isNotEmpty) ? _kHudHeight : 0;
  int get _cursorPageY => ((_cursorY - _pageTop) * _pageScaleInv).round();
  int get _cursorPageX => (_cursorX * _pageScaleInv).round();
  /// CSS px per logical px: layout width / screen width (e.g. 400/320 = 1.25).
  double get _pageScaleInv => mounted ? _kLayoutWidth / MediaQuery.sizeOf(context).width : 1.0;
  double _cursorNativeOffsetY = 0;

  Future<void> _refreshCursorOffset() async {
    try {
      final v = await _methodChannel.invokeMethod<double>('cursorOffsetY');
      if (v != null && mounted) _cursorNativeOffsetY = v;
    } catch (_) {}
  }

  void _syncCursor() {
    _methodChannel
        .invokeMethod('updateCursor', {
          'x': _cursorX,
          'y': _cursorY,
          'visible': _cursorVisible,
          'dragging': _cursorDragging,
        })
        .catchError((_) {});
  }

  // ── Passthrough / glasses gesture controls ───────────────────────────────

  /// Hardware key handler for Rokid touchpad gestures (focus-navigation mode).
  /// Swipe forward (ArrowRight+ArrowDown, coalesced) → focus NEXT clickable element.
  /// Swipe back    (ArrowLeft+ArrowUp,   coalesced) → focus PREVIOUS clickable element.
  /// Single tap (ENTER/centre)  → activate (click) the focused element.
  /// Double tap                 → minimize / back.
  /// Volume keys are intercepted natively in MainActivity and arrive here
  /// as browser_cmd events (volume_up / volume_down), not as hardware keys.
  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final k = event.logicalKey;

    // F13 (two-finger double-tap) is unreliable and the system also uses the
    // gesture; keep it only as a panel toggle, never as exit.
    if (k == LogicalKeyboardKey.f13) {
      setState(() => _showWebRemotePanel = !_showWebRemotePanel);
      return true;
    }
    if (_showWebRemotePanel && _swipeScrollsPage) {
      // Scroll/focus mode: arrows traverse the panel's buttons.
      if (k == LogicalKeyboardKey.arrowRight ||
          k == LogicalKeyboardKey.arrowDown) {
        FocusScope.of(context).nextFocus();
        return true;
      }
      if (k == LogicalKeyboardKey.arrowLeft ||
          k == LogicalKeyboardKey.arrowUp) {
        FocusScope.of(context).previousFocus();
        return true;
      }
      return false;
    }
    // In mouse mode the panel is driven by the cursor (fall through).
    if (_url.isEmpty && !_showUrlKeyboard && !_showWebRemotePanel &&
        (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select)) {
      setState(() => _showUrlKeyboard = true);
      return true;
    }

    // Forward swipe = ArrowRight, with ArrowDown as its paired companion.
    // Backward swipe = ArrowLeft, with ArrowUp as its paired companion.
    final isForward =
        k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.arrowDown;
    final isBackward =
        k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowUp;

    if (isForward || isBackward) {
      // Coalesce the paired companion key: one physical swipe emits two keys
      // (e.g. Right then Down) — only the first advances focus.
      if (now - _lastNavMs < _navCoalesceMs) return true;
      _lastNavMs = now;
      if (_swipeScrollsPage) {
        final step = (MediaQuery.sizeOf(context).height / 3).round();
        _scrollPage(0, isForward ? step : -step);
      } else {
        // Mouse mode: each swipe glides the cursor along the chosen axis
        // (forward = right/down). Consecutive quick swipes accelerate.
        final size = MediaQuery.sizeOf(context);
        // Fine base step (~1/24 of the screen); consecutive quick swipes
        // accelerate up to ~3x so long travel stays fast.
        if (now - _lastSwipeMs < 550) {
          _swipeStreak = (_swipeStreak + 1).clamp(0, 6);
        } else {
          _swipeStreak = 0;
        }
        _lastSwipeMs = now;
        final base = (_mouseAxisVertical ? size.height : size.width) / _kPadSwipeDivisor;
        final stepPx = base * (1 + _swipeStreak * 0.65); // up to ~4.9x
        _glideCursor(
          _mouseAxisVertical ? 0 : (isForward ? stepPx : -stepPx),
          _mouseAxisVertical ? (isForward ? stepPx : -stepPx) : 0,
        );
      }
      return true;
    }

    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.space) {
      // Single tap: in mouse mode click under the cursor; in scroll mode
      // activate the focused element (legacy behaviour).
      if (!_swipeScrollsPage) {
        _handleCommand({'action': 'cursor_click'});
      } else {
        _focusNavActivate();
      }
      return true;
    }
    return false;
  }

  /// Move sequential focus by [dir] (+1 next, -1 previous) through the page's
  /// clickable elements, drawing a highlight outline and scrolling into view.
  /// Candidates are recomputed on every move so SPA DOM changes never use a
  /// stale index (advisor). Cross-origin iframe contents can't be reached.
  void _focusNavMove(int dir) {
    _webController
        .runJavaScript('''
(function(dir){
  var SEL='a[href],button,input:not([type=hidden]),select,textarea,'+
    '[tabindex]:not([tabindex="-1"]),[role="button"],[role="link"],'+
    '[contenteditable="true"],[onclick]';
  function visible(el){
    if(!el.isConnected)return false;
    var s=getComputedStyle(el);
    if(s.display==='none'||s.visibility==='hidden'||s.opacity==='0')return false;
    if(el.getAttribute('aria-hidden')==='true')return false;
    if(el.disabled)return false;
    var r=el.getBoundingClientRect();
    if(r.width<=1||r.height<=1)return false;
    return true;
  }
  var els=Array.prototype.filter.call(document.querySelectorAll(SEL),visible);
  // Drop nested clickables: if an ancestor is also a candidate, keep only the
  // outermost (avoids focusing both a link and an inner span/icon).
  els=els.filter(function(el){
    var p=el.parentElement;
    while(p){ if(p.matches&&p.matches(SEL))return false; p=p.parentElement; }
    return true;
  });
  if(!els.length)return;
  var cur=window.__rokidFocusEl;
  var idx=cur?els.indexOf(cur):-1;
  // If the current element vanished (SPA) or is scrolled far out of view (user
  // scrolled with the phone/pad), restart from what is on screen now.
  var H=window.innerHeight, TOP=46;
  function inView(el){var r=el.getBoundingClientRect();return r.bottom>TOP&&r.top<H;}
  if(idx>=0&&!inView(cur)){idx=-1;cur=null;}
  if(idx<0&&cur){cur=null;}
  var next;
  if(idx<0){
    // First/last element currently inside the viewport (below the HUD strip).
    var vis=els.filter(inView);
    if(vis.length){ next = dir>0 ? vis[0] : vis[vis.length-1]; }
    else { next = dir>0 ? els[0] : els[els.length-1]; }
  }
  else { next = els[(idx+dir+els.length)%els.length]; }
  // Clear previous highlight
  var PROPS=['outline','outline-offset','box-shadow'];
  function restorePrev(){
    var el=window.__rokidFocusEl, snap=window.__rokidFocusPrevStyles;
    if(!el||!snap)return;
    if(el.isConnected){
      PROPS.forEach(function(p){
        if(snap[p] && snap[p].v) el.style.setProperty(p,snap[p].v,snap[p].pri);
        else el.style.removeProperty(p);
      });
    }
  }
  if(window.__rokidFocusEl&&window.__rokidFocusEl!==next){
    restorePrev(); // put back the site's ORIGINAL inline values (not blanket remove)
  }
  window.__rokidFocusEl=next;
  // Snapshot the element's original inline value+priority for each prop so we can
  // restore it exactly when focus moves (blindly removing would delete a site's
  // own inline outline/shadow permanently — advisor).
  window.__rokidFocusPrevStyles={};
  PROPS.forEach(function(p){
    window.__rokidFocusPrevStyles[p]={
      v:next.style.getPropertyValue(p),
      pri:next.style.getPropertyPriority(p)
    };
  });
  // Use !important so the highlight beats wireframe-mode's outline rule and any
  // site :focus{outline:none}. Add a glow so it's visible on the transparent AR
  // waveguide where a thin line can wash out.
  next.style.setProperty('outline','3px solid #4da3ff','important');
  next.style.setProperty('outline-offset','2px','important');
  next.style.setProperty('box-shadow','0 0 8px 2px rgba(77,163,255,.9)','important');
  try{ next.focus({preventScroll:true}); }catch(e){ try{next.focus();}catch(e2){} }
  next.scrollIntoView({behavior:'smooth',block:'center',inline:'nearest'});
})($dir);''')
        .catchError((_) {});
  }

  /// Activate (click) the currently focused element. If none is focused yet,
  /// fall back to toggling media playback so a plain video page still responds.
  void _focusNavActivate() {
    _webController
        .runJavaScript('''
(function(){
  var el=window.__rokidFocusEl;
  if(el&&el.isConnected){
    var t=(el.tagName||'').toLowerCase();
    // Inputs / textareas / contenteditable: just focus so the keyboard flow
    // takes over — don't synthesize a click that would dismiss them.
    if(t==='input'||t==='textarea'||el.isContentEditable){
      try{el.focus();}catch(e){}
      return 'focus';
    }
    try{ el.click(); return 'click'; }catch(e){}
  }
  // Nothing focused → media fallback
  var v=document.querySelector('video');
  if(v){ if(v.paused)v.play(); else v.pause(); return 'media'; }
  return 'none';
})();''')
        .then((r) {
          // If there was nothing to click and no focused element, mirror the old
          // behavior of toggling playback (handled inside the JS above already).
        })
        .catchError((_) {});
  }

  void _bookmarkCurrent() {
    if (_url.isEmpty) return;
    _methodChannel
        .invokeMethod('bookmarkCurrent', {'url': _url, 'title': _title})
        .catchError((_) {});
  }

  void _togglePassthrough() {
    if (!mounted) return;
    setState(() => _passthrough = !_passthrough);
    // A Flutter overlay and a DOM div both fail when YouTube fullscreens a video —
    // Chrome renders the video on a hardware SurfaceView layer above both.
    // The only reliable fix is a native Android View added to the Activity's
    // DecorView (window root), which composites above the hardware video layer.
    _methodChannel
        .invokeMethod('setPassthrough', _passthrough)
        .catchError((_) {});
  }

  /// Double-tap on the touchpad = browser Back.
  /// If a video is in fullscreen we exit that first (so Back doesn't skip the
  /// page); otherwise go back in history, and if there's no history left,
  /// minimize the app.
  Future<bool> _exitFullscreenIfAny() async {
    final result = await _webController.runJavaScriptReturningResult(r'''
(function(){
  if(document.fullscreenElement){document.exitFullscreen();return true;}
  var fb=document.querySelector('.ytp-fullscreen-button');
  if(fb){var l=(fb.getAttribute('aria-label')||'').toLowerCase();if(l.includes('exit')||l.includes('minimize')){fb.click();return true;}}
  return false;
})()''');
    return result == true || result.toString() == 'true';
  }

  Future<void> _handleCenterDoubleTap() async {
    final result = await _webController.runJavaScriptReturningResult(r'''
(function(){
  if(document.fullscreenElement){document.exitFullscreen();return true;}
  var fb=document.querySelector('.ytp-fullscreen-button');
  if(fb){var l=(fb.getAttribute('aria-label')||'').toLowerCase();if(l.includes('exit')||l.includes('minimize')){fb.click();return true;}}
  return false;
})()''');
    final inFullscreen = result == true || result.toString() == 'true';
    if (inFullscreen) return;
    // Re-check history at tap time (more reliable than the cached _canGoBack).
    if (await _webController.canGoBack()) {
      _webController.goBack();
    }
  }

  void _exitTheaterMode() {
    setState(() => _theaterMode = false);
    _webController.runJavaScript(r'''
(function(){
  var o=window.__rokidTheaterOriginals;
  if(!o)return;
  var v=document.querySelector('video');
  if(o.htmlStyle!==null)document.documentElement.setAttribute('style',o.htmlStyle);
  else document.documentElement.removeAttribute('style');
  if(o.bodyStyle!==null)document.body.setAttribute('style',o.bodyStyle);
  else document.body.removeAttribute('style');
  if(v){
    if(o.videoStyle)v.setAttribute('style',o.videoStyle);
    else v.removeAttribute('style');
  }
  (o.hiddenEls||[]).forEach(function(item){item.el.style.display=item.display;});
  delete window.__rokidTheaterOriginals;
})()''');
  }

  void _exitFullscreen() {
    _webController.runJavaScript(r'''
(function(){
  if(document.fullscreenElement){document.exitFullscreen();return;}
  var fb=document.querySelector('.ytp-fullscreen-button');
  if(fb){var l=(fb.getAttribute('aria-label')||'').toLowerCase();if(l.includes('exit')||l.includes('minimize')){fb.click();return;}}
  document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',keyCode:27,code:'Escape',bubbles:true,cancelable:true}));
})()''');
  }

  /// Fine-grained media volume control.
  /// Step size shrinks at low volumes so the user can reach near-silent
  /// levels without jumping straight to muted.
  void _adjustMediaVolume(double delta) {
    final dir = delta > 0 ? 1 : -1;
    _webController.runJavaScript('''
(function(dir){
  var changed=false;
  document.querySelectorAll('video,audio').forEach(function(m){
    // Adaptive step: 0.01 below 0.10, 0.03 below 0.30, 0.05 otherwise
    var step = m.volume < 0.10 ? 0.01 : m.volume < 0.30 ? 0.03 : 0.05;
    m.volume=Math.max(0,Math.min(1,m.volume+dir*step));
    changed=true;
  });
  if(!changed){
    var key=dir>0?'ArrowUp':'ArrowDown';
    ['keydown','keyup'].forEach(function(t){
      document.dispatchEvent(new KeyboardEvent(t,{key:key,code:key,bubbles:true,cancelable:true}));
    });
  }
})($dir)
''');
  }

  Timer? _navRefreshTimer;
  int _navRefreshSeq =
      0; // guards against an older async query overwriting newer state

  /// Query current history state and push it to the phone. Used for SPA route
  /// changes (onUrlChange) that don't trigger onPageFinished, so the phone's
  /// Back/Forward buttons reflect reality on sites like YouTube/Facebook.
  /// Debounced ~90ms: onUrlChange can fire in bursts and slightly before the
  /// WebView history settles, so we coalesce and query once it's quiet.
  void _refreshNavState({String? url}) {
    _navRefreshTimer?.cancel();
    _navRefreshTimer = Timer(const Duration(milliseconds: 90), () {
      _doRefreshNavState(url: url);
    });
  }

  Future<void> _doRefreshNavState({String? url}) async {
    final seq = ++_navRefreshSeq;
    try {
      final cgb = await _webController.canGoBack();
      final cgf = await _webController.canGoForward();
      // Discard if a newer refresh started while we awaited (SPA route spam).
      if (seq != _navRefreshSeq || !mounted) return;
      setState(() {
        _canGoBack = cgb;
        _canGoForward = cgf;
      });
      await _sendState(url: url ?? _url, canGoBack: cgb, canGoForward: cgf);
    } catch (_) {}
  }

  Future<void> _sendState({
    String? url,
    String? title,
    bool? loading,
    bool? canGoBack,
    bool? canGoForward,
  }) async {
    try {
      _webRemote.publishState();
      await _methodChannel.invokeMethod('sendBrowserState', {
        'url': url ?? _url,
        'title': title ?? _title,
        'loading': loading ?? _loading,
        // Fall back to the last known value (not false) so a page-load-start
        // event doesn't wrongly grey out the phone's Back/Forward buttons
        // mid-navigation.
        'canGoBack': canGoBack ?? _canGoBack,
        'canGoForward': canGoForward ?? _canGoForward,
        // Echo the visual render mode so the phone's selector stays in sync after
        // reconnect / glasses restart (advisor).
        'visualMode': _visualMode,
      });
    } on PlatformException catch (e) {
      debugPrint('sendState failed: ${e.message}');
    }
  }

  Widget _buildWebView() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidWebViewWidget(
        AndroidWebViewWidgetCreationParams(
          controller: _webController.platform,
          displayWithHybridComposition: false,
        ),
      ).build(context);
    }
    return WebViewWidget(controller: _webController);
  }

  void _goBack() {
    if (_canGoBack) _webController.goBack();
  }

  /// Ease the native cursor toward (current + dx, current + dy) over ~160ms.
  void _glideCursor(double dx, double dy) {
    _cursorVisible = true;
    final size = MediaQuery.sizeOf(context);
    if (_glideTimer == null) {
      _glideTargetX = _cursorX;
      _glideTargetY = _cursorY;
    }
    _glideTargetX = (_glideTargetX + dx).clamp(0, size.width);
    _glideTargetY = (_glideTargetY + dy).clamp(0, size.height);
    _cursorVisible = true;
    _resetCursorHideTimer();
    _glideTimer ??= Timer.periodic(const Duration(milliseconds: 16), (t) {
      final rx = _glideTargetX - _cursorX;
      final ry = _glideTargetY - _cursorY;
      if (rx.abs() < 0.6 && ry.abs() < 0.6) {
        _cursorX = _glideTargetX;
        _cursorY = _glideTargetY;
        _syncCursor();
        t.cancel();
        _glideTimer = null;
        return;
      }
      _cursorX += rx * 0.28;
      _cursorY += ry * 0.28;
      _syncCursor();
    });
  }

  String _modeLabel() => _swipeScrollsPage
      ? 'SCROLL PAGE'
      : (_mouseAxisVertical ? 'MOUSE ↕ VERTICAL' : 'MOUSE ↔ HORIZONTAL');

  /// Push-to-talk shared by both keyboards: first press starts recording,
  /// second press stops and transcribes. Returns text on the second press.
  int _micLastPressMs = 0;
  Future<String?> _micPress() async {
    // One physical tap can reach us twice (overlay hit-test + gesture); ignore
    // repeats inside 500 ms so a single tap never starts AND stops recording.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _micLastPressMs < 500) return null;
    _micLastPressMs = nowMs;
    void status(String? t, {int clearAfterMs = 0}) {
      _micStatusTimer?.cancel();
      setState(() => _micStatus = t);
      if (t != null && clearAfterMs > 0) {
        _micStatusTimer = Timer(Duration(milliseconds: clearAfterMs), () {
          if (mounted) setState(() => _micStatus = null);
        });
      }
    }
    if (!_micActive) {
      try {
        await _asr.start();
        _methodChannel.invokeMethod('beep', {'kind': 'start'}).catchError((_) {});
        setState(() => _micActive = true);
        status('🎤 LISTENING… speak, then tap ⏹ to stop');
      } catch (e) {
        status('Could not open microphone', clearAfterMs: 2500);
      }
      return null;
    }
    setState(() => _micActive = false);
    _methodChannel.invokeMethod('beep', {'kind': 'stop'}).catchError((_) {});
    status('⏳ Recognising (Gemini)…');
    try {
      final t = await _asr.stopAndTranscribe();
      status(t.isEmpty ? 'Did not catch that, try again' : null, clearAfterMs: 2500);
      return t;
    } catch (e) {
      status(e is StateError ? e.message : 'Recognition error', clearAfterMs: 4000);
      return null;
    }
  }

  void _showModeToast(String text) {
    _modeToastTimer?.cancel();
    setState(() => _modeToast = text);
    _modeToastTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _modeToast = null);
    });
  }

  void _armExitConfirm() {
    _confirmExitTimer?.cancel();
    setState(() {
      _confirmExit = true;
      _showWebRemotePanel = true;
    });
    _confirmExitTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _confirmExit = false);
    });
  }

  // Panel buttons reachable by the glasses cursor (mouse mode).
  final Map<String, GlobalKey> _panelKeys = {
    for (final n in ['start', 'revoke', 'stop', 'exit', 'close']) n: GlobalKey(),
  };

  Widget _buildWebRemoteOwnerPanel() {
    final running = _webRemote.running;
    final paired = _webRemoteStatus == WebRemoteStatus.paired;
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xE6000000),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Container(
              width: 400,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF0D160D),
                border: Border.all(color: const Color(0xFF477047)),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'WEB REMOTE · SAME WI-FI',
                    style: TextStyle(
                      color: _kGreen,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (!running) ...[
                    const Text(
                      'The server only runs after you press Start. Use a trusted Wi-Fi network.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _kSoftGreen, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      key: _panelKeys['start'],
                      autofocus: true,
                      onPressed: _startWebRemote,
                      child: const Text('START WEB REMOTE'),
                    ),
                  ] else ...[
                    Text(
                      paired ? 'CONNECTED' : 'WAITING FOR PHONE',
                      style: TextStyle(
                        color: paired ? _kGreen : const Color(0xFFFFCC66),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Open this address on your phone:',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    SelectableText(
                      _webRemote.address,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    if (!paired)
                      const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: Text(
                          'Open the address on a phone on the same Wi-Fi to connect. Fixed port 8765 — bookmark it.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white60, fontSize: 11),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        if (paired)
                          OutlinedButton(
                            key: _panelKeys['revoke'],
                            onPressed: _revokeWebRemote,
                            child: const Text('REVOKE'),
                          ),
                        FilledButton.tonal(
                          key: _panelKeys['stop'],
                          onPressed: _stopWebRemote,
                          child: const Text('STOP'),
                        ),
                      ],
                    ),
                  ],
                  if (_webRemoteError != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _webRemoteError!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFFF7777),
                        fontSize: 11,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  if (_confirmExit)
                    const Text(
                      'Hold the button again or choose CONFIRM to exit',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFFFFCC66), fontSize: 11),
                    ),
                  TextButton(
                    key: _panelKeys['exit'],
                    onPressed: () {
                      if (_confirmExit) {
                        _handleCommand({'action': 'exit_app'});
                      } else {
                        _armExitConfirm();
                      }
                    },
                    child: Text(_confirmExit ? 'CONFIRM EXIT' : 'EXIT BROWSER'),
                  ),
                  TextButton(
                    key: _panelKeys['close'],
                    onPressed: () => setState(() {
                      _showWebRemotePanel = false;
                      _confirmExit = false;
                    }),
                    child: const Text('CLOSE'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _canGoBack) _webController.goBack();
      },
      // GestureDetector wraps the whole screen as a fallback swipe input.
      // translucent behaviour lets the WebView underneath still receive taps.
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: (details) {
          // Screen-drag fallback (rarely used — the AR glasses have no touch
          // screen; the physical touchpad arrives via _onHardwareKey instead).
          // Kept as focus-nav to match the touchpad, but scoped to fast flings
          // only so it doesn't swallow ordinary in-page horizontal gestures.
          final v = details.primaryVelocity ?? 0;
          if (v.abs() < 600) return; // only deliberate flings
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastGestureMs < _gestureDebounceMs) return;
          _lastGestureMs = now;
          _focusNavMove(v > 0 ? 1 : -1);
        },
        child: Scaffold(
          backgroundColor: _kBlack,
          // Fill the ENTIRE display, including the area under the system
          // status/navigation bars (immersive). Without this the Scaffold shrinks
          // the body by the nav-bar inset, leaving an un-painted strip at the
          // bottom that shows as a black/white band on the waveguide.
          resizeToAvoidBottomInset: false,
          extendBody: true,
          extendBodyBehindAppBar: true,
          // The WebView is kept FULL-SCREEN from first creation (a stable size the
          // Android VirtualDisplay/TextureView is happy with — resizing it after
          // creation produced a black band at the bottom). The HUD/address bar is
          // an overlay pinned to the top; page content is pushed below it by CSS
          // padding injected into the page (_applyHudInset) so nothing overlaps or
          // is cut off.
          body: Stack(
            children: [
              Positioned(
                top: (!_theaterMode && !_videoFullscreen && _url.isNotEmpty) ? _kHudHeight : 0,
                left: 0,
                right: 0,
                bottom: 0,
                child: (_webViewReady && _url.isNotEmpty)
                    ? _buildWebView()
                    : _WaitingOverlay(
                        btStatus: _btStatus,
                        connected: _connected,
                      ),
              ),
              // Hide the address bar while a video is fullscreen / in theater mode
              // so the video is truly edge-to-edge (the HUD was covering its top).
              if (!_theaterMode && !_videoFullscreen)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: _kHudHeight,
                  child: _HudBar(
                    title: _title,
                    url: _url,
                    loading: _loading,
                    connected: _connected,
                    canGoBack: _canGoBack,
                    passthrough: _passthrough,
                    onBack: _goBack,
                    onBookmark: _url.isNotEmpty ? _bookmarkCurrent : null,
                    onForward: _canGoForward ? () => _webController.goForward() : null,
                    onScrollUp: _url.isNotEmpty ? () => _handleCommand({'action': 'keyboard_key', 'key': 'ArrowUp'}) : null,
                    onScrollDown: _url.isNotEmpty ? () => _handleCommand({'action': 'keyboard_key', 'key': 'ArrowDown'}) : null,
                    onKeyLeft: _url.isNotEmpty ? () => _handleCommand({'action': 'keyboard_key', 'key': 'ArrowLeft'}) : null,
                    onKeyRight: _url.isNotEmpty ? () => _handleCommand({'action': 'keyboard_key', 'key': 'ArrowRight'}) : null,
                    onStop: () => _webController.runJavaScript('window.stop()'),
                    onReload: _url.isNotEmpty ? () => _webController.reload() : null,
                    onExit: _armExitConfirm,
                  ),
                ),
              Positioned(
                right: 4,
                bottom: 4,
                child: IconButton.filledTonal(
                  key: _castKey,
                  tooltip: 'Web Remote',
                  onPressed: () => setState(() => _showWebRemotePanel = true),
                  icon: Icon(
                    _webRemoteStatus == WebRemoteStatus.paired
                        ? Icons.cast_connected
                        : Icons.cast,
                    color: _webRemote.running ? _kGreen : Colors.white70,
                  ),
                ),
              ),
              if (_modeToast != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 70,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xCC000000),
                          border: Border.all(color: _kGreen),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(_modeToast!, style: const TextStyle(color: _kGreen, fontSize: 14, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                ),
              if (_showWebRemotePanel) _buildWebRemoteOwnerPanel(),
              if (_showTextKeyboard && !_showUrlKeyboard)
                UrlKeyboard(
                  key: _textKbKey,
                  mode: 'text',
                  initialText: '',
                  controller: _urlHistory,
                  onGo: (_) {},
                  onType: (t) => _handleCommand({'action': 'keyboard_type', 'text': t}),
                  onBackspace: () => _handleCommand({'action': 'keyboard_backspace'}),
                  onEnter: () {
                    setState(() => _showTextKeyboard = false);
                    _handleCommand({'action': 'keyboard_enter'});
                  },
                  onClearField: () => _handleCommand({'action': 'keyboard_clear_field'}),
                  onMic: _micPress,
                  micActive: _micActive,
                  micStatus: _micStatus,
                  onClose: () => setState(() => _showTextKeyboard = false),
                ),
              if (_showUrlKeyboard)
                UrlKeyboard(
                  key: _urlKbKey,
                  initialText: _url,
                  controller: _urlHistory,
                  onGo: (u) {
                    setState(() => _showUrlKeyboard = false);
                    _handleCommand({'action': 'navigate', 'url': u});
                  },
                  onMic: _micPress,
                  micActive: _micActive,
                  micStatus: _micStatus,
                  onClose: () => setState(() => _showUrlKeyboard = false),
                ),
              // Cursor is rendered as a native Android View in the DecorView
              // (see updateCursor in MainActivity.kt) so it stays visible above
              // YouTube's SurfaceView fullscreen video layer.
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Waiting overlay ──────────────────────────────────────────────────────────

class _WaitingOverlay extends StatefulWidget {
  final String btStatus;
  final bool connected;
  const _WaitingOverlay({required this.btStatus, required this.connected});

  @override
  State<_WaitingOverlay> createState() => _WaitingOverlayState();
}

class _WaitingOverlayState extends State<_WaitingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _anim = Tween<double>(
      begin: 0.3,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: _anim,
            child: const Icon(Icons.language, color: _kGreen, size: 48),
          ),
          const SizedBox(height: 16),
          const Text(
            'ROKID BROWSER',
            style: TextStyle(
              color: _kGreen,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.connected
                ? 'CONNECTED — WAITING FOR URL'
                : widget.btStatus.toUpperCase(),
            style: TextStyle(
              color: widget.connected ? _kSoftGreen : const Color(0xFFFF4444),
              fontSize: 9,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── AR HUD bar ───────────────────────────────────────────────────────────────

class _HudBar extends StatelessWidget {
  final String title;
  final String url;
  final bool loading;
  final bool connected;
  final bool canGoBack;
  final bool passthrough;
  final VoidCallback onBack;
  final VoidCallback? onBookmark;
  final VoidCallback? onForward;
  final VoidCallback? onScrollUp;
  final VoidCallback? onScrollDown;
  final VoidCallback? onKeyLeft;
  final VoidCallback? onKeyRight;
  final VoidCallback? onStop;
  final VoidCallback? onReload;
  final VoidCallback? onExit;

  const _HudBar({
    required this.title,
    required this.url,
    required this.loading,
    required this.connected,
    required this.canGoBack,
    required this.passthrough,
    required this.onBack,
    this.onBookmark,
    this.onForward,
    this.onScrollUp,
    this.onScrollDown,
    this.onKeyLeft,
    this.onKeyRight,
    this.onStop,
    this.onReload,
    this.onExit,
  });

  static final Map<String, GlobalKey> toolKeys = {
    for (final n in ['address', 'back', 'forward', 'left', 'right', 'up', 'down', 'stop', 'reload', 'exit']) n: GlobalKey(),
  };

  Widget _tool(String name, IconData icon, VoidCallback? cb, {Color? color}) => GestureDetector(
        key: toolKeys[name],
        behavior: HitTestBehavior.opaque,
        onTap: cb,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: Icon(
            icon,
            color: color ?? (cb == null ? _kGreen.withValues(alpha: 0.3) : _kGreen),
            size: 14,
            weight: 800,
            shadows: cb == null ? null : const [Shadow(color: _kGreen, blurRadius: 4)],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _kHudHeight,
      color: _kBlack, // opaque so page content never bleeds through the bar
      padding: const EdgeInsets.fromLTRB(4, 18, 8, 4),
      child: Row(
        children: [
          const SizedBox(width: 4),
          if (loading)
            const SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: _kGreen,
              ),
            )
          else
            const Icon(Icons.language, color: _kGreen, size: 10),
          const SizedBox(width: 6),
          Expanded(
            child: Container(
              key: toolKeys['address'],
              alignment: Alignment.centerLeft,
              child: Text(
              url.isNotEmpty ? url : title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _kSoftGreen,
                fontSize: 9,
                letterSpacing: 0.3,
              ),
            ),
            ),
          ),
          if (url.isNotEmpty && onBookmark != null) ...[
            const SizedBox(width: 3),
            GestureDetector(
              onTap: onBookmark,
              child: Icon(
                Icons.bookmark_add_outlined,
                color: _kGreen.withValues(alpha: 0.75),
                size: 9,
              ),
            ),
          ],
          const SizedBox(width: 4),
          // One tight cluster on the right so the cursor travels a short path.
          _tool('back', Icons.arrow_back, canGoBack ? onBack : null),
          _tool('forward', Icons.arrow_forward, onForward),
          _tool('left', Icons.keyboard_arrow_left, onKeyLeft),
          _tool('right', Icons.keyboard_arrow_right, onKeyRight),
          _tool('up', Icons.keyboard_arrow_up, onScrollUp),
          _tool('down', Icons.keyboard_arrow_down, onScrollDown),
          _tool('stop', Icons.stop_circle, loading ? onStop : null),
          _tool('reload', Icons.refresh, onReload),
          _tool('exit', Icons.power_settings_new, onExit, color: const Color(0xFFFF6666)),
          // Passthrough mode indicator
          if (passthrough) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Text(
                'PASS',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 7,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ],
          const SizedBox(width: 6),
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? _kGreen : const Color(0xFFFF4444),
            ),
          ),
        ],
      ),
    );
  }
}
