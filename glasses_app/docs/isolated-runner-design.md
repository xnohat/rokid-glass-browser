# Isolated Node / Media Runner — design gate

## Why `libnode.so` cannot live inside the browser process

The latest official JaneaSystems Node.js Mobile Android release is v0.3.3 (2021) and embeds Node **12.19.0**, which is end-of-life. More importantly, a Node runtime loaded into the browser process runs under the browser UID. It can read the Gemini key, cookies, preferences and all private app files; constraining cwd to `agent_workspace` does not provide security. `npm --ignore-scripts` only disables install hooks—imported packages still execute arbitrary JavaScript.

## Required architecture before `run_node`

Use a **separate runner APK / Android UID** (preferred) rather than an `android:process` service, since a normal secondary process shares the browser UID.

### Browser app → runner contract

- Explicit Binder/AIDL interface with only:
  - `runNode(scriptFd, workspaceDirFd, timeoutMs, outputLimit, networkPolicy)`
  - `runMedia(tool, argv, inputFd[], outputFd, timeoutMs)`
  - `cancel(runId)`
- Files cross the boundary only as brokered file descriptors rooted in `agent_workspace`; never expose browser private paths.
- Runner receives no Gemini key, cookies, WebView data or SharedPreferences.
- One disposable execution process per run. Start Node exactly once per process; kill the process tree on timeout/cancel.
- Limits: wall clock ≤30s by default, stdout+stderr ≤64KiB, temp output ≤25MiB, package install ≤100MiB, dependency count/depth caps.
- Network off by default. Per-run allowlisted HTTP(S) only when the user asks; no LAN/private IPs.

### Runtime provenance

- Do **not** ship JaneaSystems v0.3.3 / Node 12.19.0.
- Build a maintained Node LTS for Android arm64 from a pinned source commit using a pinned Android NDK in CI.
- Publish SHA-256 + SBOM + build logs. Reproducibility or signed provenance is required.
- Pin npm compatible with that Node. Package install defaults to `--ignore-scripts --no-audit --no-fund`; native addons unsupported unless separately audited/built for Android arm64.

### Shell / media binaries

- Current `run_shell` is an allowlisted Android **toybox dispatcher**, not Bash or GNU coreutils.
- BusyBox, FFmpeg/FFprobe and ImageMagick must be built from pinned sources as minimal Android arm64 variants and live in the separate runner APK.
- FFmpeg: include only needed codecs/demuxers/filters; document LGPL/GPL configuration.
- ImageMagick: minimal delegates; disable risky coders by policy.xml; resource limits mandatory.
- No arbitrary downloaded executable is ever marked executable or loaded.

## Proof gate

Before exposing `run_node` to the LLM:

1. Runner app has a different UID from the browser.
2. A test script cannot open browser SharedPreferences, WebView cookies or Gemini key.
3. Script can create/read files only through brokered workspace descriptors.
4. Timeout/cancel kills an infinite loop and all descendants.
5. Output and disk caps are enforced.
6. Network-off and allowlisted-network tests pass.
7. A pure-JS npm package installs and runs; lifecycle scripts are proven disabled.
8. FFmpeg and ImageMagick smoke tests pass in the same isolated runner.

Until this gate passes, `run_node`, npm installation and bundled media binaries remain intentionally unavailable. Shipping the old 2021 Node runtime inside the browser would be a security regression, not a feature.
