# `run_node` runtime decision

## Status

`run_node` was **not implemented** in this build.

## Findings

- The app is a Flutter Android application; agent tools are implemented in Dart (`lib/agent_files.dart`) and dispatched from `lib/browser_screen.dart`.
- The existing `run_shell` tool deliberately invokes only `/system/bin/toybox`, with an app-private `agent_workspace` working directory, path/symlink checks, a 10-second cap, and a 64 KiB output cap.
- `pubspec.yaml` has no Node runtime dependency, and the Android source tree contains no Node executable, Node shared library, JNI bridge, or arm64 runtime asset.
- Existing build outputs contain Flutter/plugin libraries only; no Node runtime was present to reuse.
- No verified `nodejs-mobile` package or pinned/maintained arm64 Android runtime source is available in this isolated project. Building one would require introducing a substantial native toolchain/dependency and obtaining source/artifacts not present here.

## Why we stopped

Adding a downloaded prebuilt executable or opaque `.so` would violate the requirement not to use unverified random binaries. A fake Dart evaluator or unrestricted shell command would not provide Node semantics and would weaken the current security boundary. Therefore the safe result for this run is to document the blocker and leave existing features unchanged.

## Requirements for a future implementation

A future change should only proceed after adding a reviewed, reproducible arm64 Android runtime (preferably source-built or a pinned maintained dependency) and a JNI/native bridge that:

1. Executes only scripts under the app-private `agent_workspace`.
2. Rejects traversal, absolute paths, symlink escapes, and access to app preferences/credentials.
3. Uses a sanitized environment (no inherited secrets), fixed working directory, and bounded argv/script size.
4. Enforces a hard wall-clock timeout, kills the complete process tree, caps stdout/stderr, and limits concurrent/aggregate resource use.
5. Ships only the `arm64-v8a` runtime needed by the Rokid target and is verified with `flutter analyze` and a release build.

## Verification

- `flutter analyze` ran and reported 39 existing lint/info issues; it exited with code 1 because the repository treats these analyzer findings as failure. No new source changes were made to address unrelated lints.
- `flutter build apk --release` reached Gradle invocation but failed because this host has no Java runtime configured: `Unable to locate a Java Runtime`.
- Dependency resolution completed; no runtime package was added.

No install, device push, or external binary download was performed.
