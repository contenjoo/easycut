# EasyCut for Windows (beta)

The Windows edition of EasyCut: a Tauri 2 app (Rust backend + HTML/JS UI) that shares the editing rules and the `.easycut` project format with the Mac app.

- `crates/easycut-core` — editing core (model, timeline ops, transcript cuts, silence detection, Whisper output parsing). JSON-compatible with the Mac app; unknown fields are preserved.
- `app/src-tauri` — Tauri backend: commands, ffmpeg/ffprobe probing, Whisper (whisper-cli) transcription, ffmpeg filter-graph export, `--selftest`.
- `app/ui` — the interface (no bundler): timeline canvas, preview player, transcript/captions panels.

## Develop (works on macOS too)

```bash
cargo test -p easycut-core
cd app && npm install && npx tauri dev          # needs ffmpeg/ffprobe/whisper-cli on PATH
../target/debug/easycut-windows --selftest /tmp/ecw-test
```

## Release

The `Windows build` GitHub Actions workflow downloads ffmpeg (gyan.dev essentials) and whisper.cpp (CPU build), builds the NSIS installer, runs `--selftest` on Windows and, for `win-v*` tags, publishes a prerelease.
