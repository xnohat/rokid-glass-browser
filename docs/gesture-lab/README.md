# RV101 touchpad gesture lab — measured 2026-09-07

Method: temporary app-side KeyEvent log (`RokidGesture`, lab build only, removed in release), kernel `getevent` on `/dev/input/event1` (ROKID,PSOC-TP-R), system `WindowManager interceptKeyTq` log, `AssistServer_Log`, and display-power polling. Owner performed each gesture on request; the app was foreground unless noted. Raw captures: `*.json`, `continuous.log`, `system-keys-timeline.txt`, `screen-state-*.log`.

## Vocabulary
Rokid firmware turns every touchpad gesture into **key events** (no touch coordinates ever reach the app). Every finger-down first emits scancode 204 → `KEYCODE_NOTIFICATION` (83); it is noise for gesture purposes.

## Results

| Gesture | Kernel / system key | App receives? | Samples | Notes |
|---|---|---|---|---|
| Single tap, 1 finger | KEY_ENTER (28) | ENTER ✅ | 2/2 | app: activate focused element |
| Double-tap, 1 finger | KEY_BACK (158) | BACK ✅ | 2/2 | app: browser back (intercepted from touchpad) |
| Double-tap, 2 fingers | KEY_F13 (183 = `SPRITE_SWIPE_FORWARD` in Generic.kl) | F13 ✅ | recognised 3/8 attempts; others only finger-down | app 1.3.0: F13 = arm exit, F13 again ≤4 s = exit. Unreliable at firmware level, not a logging gap (kernel agrees) |
| Hold, 1 finger (~3 s) | KEY_PROG1 (148) DOWN held for hold duration, UP on release | ❌ never reaches app | 2/2 | Consumed by system before app; kernel sees it. Rokid uses it as system "long press" |
| Hold, 2 fingers (~3 s) | — (no key to app) | ❌ | 2/2 | System opens **Rokid AI assistant** (`AIModeManager startNewTalk`), app goes to background. Not usable by app |
| Swipe 1 finger back→front (toward eye) | KEY_RIGHT + KEY_DOWN pair | DPAD_RIGHT, DPAD_DOWN ✅ | 4/4 | app: focus next |
| Swipe 1 finger front→back | KEY_LEFT + KEY_UP pair | DPAD_LEFT, DPAD_UP ✅ | 4/4 | app: focus previous |
| Swipe 1 finger up / down | only finger-down (204) | ❌ nothing | 4/4 | **No vertical swipe gesture exists** on this firmware — pad is effectively 1-D (forward/back) |
| Swipe 2 fingers back→front | `KEYCODE_SPRITE_SWIPE_FORWARD` → system broadcast `ACTION_TWO_FINGER_SWIPE_FORWARD` | ❌ consumed by WindowManager | 2/2 + | System handles as **volume up** (`RokidTouchReceiver handleVolume forward:true`, setting `settings_two_finger_swipe_func=1`) |
| Swipe 2 fingers front→back | `KEYCODE_SPRITE_SWIPE_BACK` → `ACTION_TWO_FINGER_SWIPE_BACK` | ❌ | 2/2 + | System **volume down** |
| Swipe 2 fingers up / down | only finger-down | ❌ | 2/2 | no vertical recognition |
| Tap / swipe / double-tap 3 fingers | recognised as 1- or 2-finger equivalents (ENTER, SPRITE_SWIPE_FORWARD, DPAD pair) | partially | 2 each | Firmware does **not** distinguish 3 fingers; it classifies as 1 or 2 depending on contact |
| Display power during 2-finger double-tap | mWakefulness=Awake, display ON throughout | — | 16 s poll | No screen toggle observed |

## Conclusions for the app
- Usable in-app inputs: **ENTER, BACK, DPAD forward/back pair, F13** (best-effort). Nothing else from the pad reaches the app.
- Vertical scrolling cannot come from the touchpad; it must come from the phone web remote (swipe on preview / trackpad), which is implemented.
- Hold-1-finger (PROG1) and hold-2-fingers (AI assistant) and 2-finger swipes (volume) are **system-owned**. Remapping would require system-level access (not available to a normal app).
- Firmware 2-finger double-tap detection is flaky (≈40 %). Keep the on-glasses "THOÁT TRÌNH DUYỆT" button and web-remote exit as the reliable paths.

## Not measured
Three-finger hold, edge taps, hardware button combos, behaviour while the AI assistant overlay is open.
