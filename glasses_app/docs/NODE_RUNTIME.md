# Node.js Runtime — Implementation Notes

## Bundled Runtime

| Property | Value |
|---|---|
| Runtime | Node.js 12.19.0 "Erbium" |
| Package | JaneaSystems/nodejs-mobile v0.3.3 |
| Binary | `libnode.so` (arm64-v8a) |
| Source zip | `../nodejs-mobile/nodejs-mobile-v0.3.3-android.zip` |
| APK location | `android/app/src/main/jniLibs/arm64-v8a/libnode.so` |
| npm version (built-in) | 6.14.8 (JS files NOT included — see below) |
| NAPI version | 7 |
| NODE_MODULE_VERSION | 72 |

### **EOL WARNING**

Node.js 12 reached **End-of-Life on 2022-04-30** and receives **no security patches**.
Do not use `run_node` to evaluate untrusted remote data (no `eval()`, no `new Function(remote_code)`).
All scripts must be written by the agent or the user and stored inside the sandboxed workspace.

A future upgrade to a newer Node version requires a newer nodejs-mobile release or an alternative
official Android arm64 binary (see "Why nodejs-mobile v0.3.3?" below).

---

## Architecture — Disposable-Process Pattern

`node::Start()` initialises V8 and libuv globally in the calling process and **cannot be called
a second time** in the same process lifetime.  To allow repeated `run_node` calls:

1. `NodeService.kt` is declared with `android:process=":node"` — it runs in a **separate OS
   process** from the Flutter/browser process.
2. After `node::Start()` returns, the service calls `System.exit(0)`, fully terminating the `:node`
   process and releasing all V8/libuv state.
3. The next `run_node` call starts a fresh `:node` process; Android allocates a clean address
   space with no stale V8 heap.
4. The Flutter/browser process **never** loads `libnode.so` or calls `node::Start()`.

This satisfies the requirement: "prefer disposable process; never repeatedly call node::Start
in browser process."

### Same-UID Risk

`NodeService` runs under the same Linux UID as the browser APK (same signing key = same UID).
It therefore has read/write access to the app's private files directory, including cookies and
WebView session data.  The owner has accepted this risk (same APK = same trust boundary).

Mitigations in place:
- `android:exported="false"` — no other app can start the service.
- The Dart agent layer enforces a 100 MB workspace disk quota and rejects paths that escape
  the workspace before passing the script path to `runNode()`.
- Scripts are written by the AI agent (not by remote web content).

---

## npm / npx Support

### Current Status: Partial — npm JS files not bundled

`libnode.so` contains the Node engine only.  The npm package (its JavaScript source) is **not**
included in the nodejs-mobile binary zip.  A full npm installation (npm 6.14.8 for Node 12)
consists of ~6 MB of JavaScript files that would need to be shipped separately.

#### What IS supported today

- `run_node` with any pure-JavaScript `.js` file.
- `require()` for Node built-in modules (`fs`, `path`, `crypto`, `http`, `stream`, etc.).
- `require()` for modules the agent has installed manually in the workspace
  (e.g. by unpacking a downloaded tarball into `workspace/node_modules/`).

#### How to use npm-equivalent functionality (workaround)

The agent can download an npm package tarball, unpack it in the workspace, and `require()` it:

```javascript
// In a run_node script:
const myLib = require('./node_modules/my-lib');
```

#### Lifecycle scripts disabled (design intent)

When `is_npm=true` is passed to `run_node`, the Dart layer appends `--ignore-scripts` to
the effective npm command arguments.  This prevents `preinstall`, `postinstall`, `prepare`,
and other lifecycle hooks from executing — even if npm JS is later bundled.

The `NPM_CONFIG_IGNORE_SCRIPTS=1` environment variable can also be set in the script itself
as a belt-and-suspenders guard.

#### Blocker for full npm bundling

Bundling npm 6's JS (~6 MB) would require:
1. Extracting `node_modules/npm/` from a Node 12 installation.
2. Shipping it as a Flutter asset or as files in the APK's `assets/`.
3. Extracting it to the app's files directory on first run.

This is feasible but was deferred pending a Node version upgrade decision.

---

## Tool Assessment — Other Binaries

### BusyBox

**Status: Not bundled.**

Android ships `toybox` (a BusyBox-compatible applet set) at `/system/bin/toybox`.
The agent's `run_shell` tool already exposes a curated allow-list of toybox applets.
Bundling the full BusyBox static binary would:
- Add ~1 MB (static arm64).
- Require GPL compliance (BusyBox is GPL-2.0).
- Duplicate applets already available via toybox.

**Decision: Use toybox via `run_shell`.  Not bundling BusyBox.**

---

### git

**Status: Not bundled — blocker.**

There is no official standalone static git binary for Android arm64 maintained by the
git project.  Available sources:
- **Termux** packages git for Android arm64, but extracting a single static binary from
  Termux's `.deb` / `.pkg` package (which has many shared-library dependencies) is not
  straightforward.
- **libgit2** is an embeddable C library but requires significant JNI integration work
  and does not expose the full git CLI.

**Decision: Not bundled.  If git is needed, the agent can use the GitHub API or download
pre-built tarballs.**

---

### Python

**Status: Not bundled — blocker.**

CPython for Android arm64 is available via:
- **Chaquopy** (commercial SDK, Gradle plugin).
- **BeeWare/Briefcase** (open-source, targets their own project structure).
- **Termux APK** packages (shared-library chain, not self-contained).

None of these provide a simple single-file static binary suitable for bundling.
A standalone arm64 CPython `.so` would be ~5–15 MB plus stdlib.

**Decision: Not bundled.  For data science / scripting needs, use `run_node` (JS) or
call Python APIs over HTTP from the agent.**

---

### FFmpeg / ffprobe

**Status: Not bundled — feasible, deferred.**

Official static arm64 Android builds of FFmpeg exist (e.g. from `johnvansickle.com` static
builds adapted for Android, or the `ffmpeg-kit` project).  The binaries are large (~30–60 MB
for a full build) and would significantly increase APK size.

`ffmpeg-kit` provides an Android AAR that can be added as a Gradle dependency.  This is the
cleanest integration path.

**Decision: Not bundled in this iteration.  Can be added via `ffmpeg-kit` AAR dependency if
video processing is needed.**

---

### ImageMagick

**Status: Not bundled — blocker.**

ImageMagick has deep system-library dependencies (libpng, libjpeg, libwebp, libtiff, libxml2,
libfontconfig, …) and no official static Android arm64 binary.  Building it statically for
Android requires a substantial cross-compilation toolchain setup.

**Decision: Not bundled.  Image processing can be done via Canvas/Bitmap APIs in Kotlin,
or via Gemini vision APIs.**

---

## Security Checklist

- [ ] Node 12 EOL — upgrade when a modern official Android arm64 binary is available.
- [x] Scripts sandboxed to agent_workspace before the native call.
- [x] Disk quota enforced (100 MB) before each `run_node`.
- [x] Wall-clock timeout enforced (30 s default, 120 s max).
- [x] stdout/stderr capped at 64 KB each.
- [x] `android:exported="false"` on NodeService.
- [x] `System.exit(0)` after each run — no V8 state reuse.
- [x] `--ignore-scripts` injected for npm mode.
