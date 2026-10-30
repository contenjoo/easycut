# EasyCut for Windows

The Windows edition of EasyCut: a Tauri 2 app (Rust backend + HTML/JS UI) that shares the editing rules and the `.easycut` project format with the Mac app.

- `crates/easycut-core` — editing core (model, timeline ops, transcript cuts, silence detection, Whisper output parsing). JSON-compatible with the Mac app; unknown fields are preserved.
- `app/src-tauri` — Tauri backend: commands, ffmpeg/ffprobe probing, Whisper (whisper-cli) transcription, ffmpeg filter-graph export, `--selftest`.
- `app/ui` — the interface (no bundler): timeline canvas, preview player, transcript/captions panels and prompt video creation.

## Create a video (0.7.0)

Open **Create a Video** in the toolbar, **File › Create a Video…**, or the AI tab. Describe an animation, explainer or promotional video in your own style, then choose the canvas size, 2–60 second length and 24/30/60 fps. Four examples are available as starting points; they only replace the description.

- **Claude:** sign in with your own Claude subscription through Claude Code, or save your Claude API key.
- **GPT:** sign in with your own ChatGPT subscription through Codex, or save your OpenAI API key.
- **Gemini:** save your Gemini API key. Subscription sign-in is not supported.

Subscription connections use the signed-in account's limits. API usage is billed separately from subscriptions. API keys are saved in **Windows Credential Manager** and cleared from the input after saving. EasyCut currently recommends **Claude Opus 5.5** for video creation quality. The default API models are `claude-opus-5-5`, `gpt-6.1-sol` and `gemini-3.8-flash`; you can enter another supported model name.

**Automatically Apply Production Skills** is on by default. The selected AI chooses up to three relevant sets of guidance from five reviewed skills: product/brand motion, visual explanation, kinetic typography, data stories and generative particles/patterns. Your requested style and exclusions come first. The preview shows the selected skills, reasons and source links. You can turn automatic selection off. This uses a bundled catalog, without searching X or installing arbitrary external scripts during generation. [Sources and licenses](../docs/VIDEO-SKILLS-2026-10-30.md).

Click **Create Previews from Description**, review all **four sample frames**, then choose **Approve & Render Full Video**. Rendering uses the same code and settings as the approved samples; changes require new previews. Play the MP4, show its folder or choose **Add to Timeline** to edit it. Adding it can be undone with Ctrl+Z. Closing the window leaves generation running; **Stop** cancels it.

Prepare **Node.js LTS, npm, and Chrome or Edge**. Rendering packages are installed in the app's support folder on first use. Under **Advanced Settings**, choose **Canvas** for frame-by-frame animation with optional synthesized music/effects, or **Remotion** for React motion graphics with silent output. Narration is not generated; add recorded audio or music on the timeline.

Your description is sent to the selected AI provider; generated code runs on this PC. Code, settings, samples and output are kept in `%APPDATA%\com.contenjoo.easycut.windows\generated-videos`. Use **Show Generated Code** to inspect the job folder.

## Gemini API key setup for editing existing videos

In the AI tab, choose **Gemini (free tier)** and expand **처음이신가요? API 키 발급 방법** for the step-by-step guide. [Full Korean instructions](../README.md#기존-영상-편집을-gemini-무료-한도로-시작하기) · [English instructions](../README.en.md#edit-existing-videos-with-geminis-free-tier).

## Develop (works on macOS too)

```bash
cargo test -p easycut-core
cd app && npm install && npx tauri dev          # needs ffmpeg/ffprobe/whisper-cli on PATH
../target/debug/easycut-windows --selftest /tmp/ecw-test
```

## Release

The `Windows build` GitHub Actions workflow downloads ffmpeg (gyan.dev essentials) and whisper.cpp (CPU build), builds the NSIS installer, runs `--selftest` and generation checks on Windows and, for `win-v*` tags, publishes a regular release. The Mac release remains the repository's “latest” release; Windows updates use the Windows release channel.
