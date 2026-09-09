# Media toolchain result on Rokid RV101

## Working

- Python 3.13.5 embedded with Chaquopy 17 in disposable `:python` process.
- Runtime installation of universal pure-Python wheels: Dart/Android TLS downloads the wheel; pip installs locally with `--no-index --no-deps --only-binary=:all:`. Verified `six==1.17.0`.
- Runtime installation/import of universal pure-Python wheels (verified with `six==1.17.0`).
- Existing Gemini tools understand workspace images/audio/video via `read_file`.

## FFmpeg / FFprobe blocker

FFmpeg n7.1.1 was successfully cross-compiled from the official source with Android NDK 27 for arm64 as static PIE executables (`ffmpeg` 7.5 MB, `ffprobe` 1.1 MB). SHA/source provenance was controlled. When packaged as native-lib-shaped files and invoked via `ProcessBuilder` from `applicationInfo.nativeLibraryDir`, YodaOS returned `Permission denied`. The firmware does not allow executing these packaged PIE binaries in this context. They were removed from the release; no broken `run_ffmpeg`/`run_ffprobe` tools are advertised.

A future implementation must integrate FFmpeg as JNI libraries/API (or use a maintained Android AAR). Official FFmpegKit artifacts are retired/removed from Maven, so no unverified third-party binary was substituted.

## ImageMagick blocker

No maintained official Android arm64 ImageMagick artifact was selected. Pillow 11.1.0 from Chaquopy's Android repository was also tested, but its native `_imaging.so` could not load on YodaOS (`not a regular file`) from the Chaquopy extraction path. Pillow was removed from the release rather than advertising a broken image tool. Building ImageMagick/Pillow native code into a direct JNI library remains future work.
