# EasyCut — an easy video editor for Mac

[한국어](README.md) | **English**

EasyCut is a macOS video editor that puts simple cut editing, transcript-based editing with speech recognition (STT), captions, screen & face recording and AI editing in one app.

**[⬇︎ Download the latest version (Releases)](https://github.com/contenjoo/easycut/releases/latest)**

Windows (beta): [download EasyCut for Windows](https://github.com/contenjoo/easycut/releases?q=win-v&expanded=true) · source in [`windows/`](windows)

![Transcript editing — recognized transcript, captions, timeline](docs/screenshots/transcript.jpg)

| One-click silence cut | Caption styles | AI editing |
|---|---|---|
| ![Silence cut](docs/screenshots/silence.jpg) | ![Captions](docs/screenshots/captions.jpg) | ![AI editing](docs/screenshots/ai.jpg) |

The app follows your macOS language: English on English (and any non-Korean) systems, Korean on Korean systems. You can switch it in **EasyCut › Language** (applies after a restart).

## Install

Requires an **Apple Silicon Mac (M1 or later) with macOS 14 or later**.

1. Download `EasyCut-x.y.z.dmg` from [Releases](https://github.com/contenjoo/easycut/releases/latest), open it and drag EasyCut into the Applications folder.
2. The first time only: the app is not notarized, so if macOS warns you, go to System Settings › Privacy & Security and click **Open Anyway**.
3. Download the Whisper model (574 MB) with **Turn On Whisper** in the Transcript tab, and the YouTube tool (yt-dlp) with **Install YouTube Tool** in the link window — once each.

The Whisper speech engine and ffmpeg (for MKV etc.) are bundled, so there is nothing else to install (no Homebrew needed).
AI editing is optional. It works with your Claude Pro/Max plan (via Claude Code login) or your own API key; the API key is stored only in the macOS Keychain.

Updates are automatic from 1.3.0 on: when a new version is released, the app tells you at launch and installs it with one click (**EasyCut › Check for Updates…**).

## Build from source

Needs Xcode Command Line Tools (Swift 5.10+), `cmake` (`brew install cmake`) and `git`.

```bash
./scripts/build_deps.sh      # build Whisper and ffmpeg from source into vendor/bin (once, ~10 minutes)
./scripts/build_app.sh --dmg # app bundle + DMG (dist/)
```

## Features

| Feature | Details |
|---|---|
| Screen & face recording | Record the full screen, a window or a dragged area together with your camera (face), microphone and computer audio. When you stop, the screen goes on Track 1, your face as a small round picture bottom-right on Track 2, computer audio on Track 3, and your voice is transcribed right away. Pause ⌥⌘P, stop ⌥⌘. (work while other apps are in front). Mouse clicks are highlighted. Open with ⌥⌘R; files go to Movies › EasyCut 녹화 |
| Import | Video (MP4 · MOV · M4V, **MKV · WebM · AVI · FLV · WMV · TS · MTS · MPG** …), audio (MP3 · WAV · M4A · AAC · AIFF), photos (PNG · JPG · HEIC · GIF · TIFF). Drag and drop supported |
| Multi-track timeline | Move, trim, split, duplicate, copy/paste clips; mute/hide tracks; snapping; thumbnails and waveforms; adjustable track height; resizable timeline area; groups (⌘G) and join (⌘J) |
| Up to 20× speed | Preview playback 0.25–20×, clip speed 0.1–20× (pitch preserved) |
| Level meter | Shows the loudness of what is playing (if the bar moves but you hear nothing, check your Mac's output device) |
| Speech recognition (STT) | Apple on-device (no install, works offline) or Whisper (optional, high accuracy) |
| Edit by transcript | Select words in the transcript and press ⌫ to cut them from the video. Click a word to jump there, ↩ to fix a word |
| One-click silence cut | Detects silence by loudness (no transcription needed) → red preview on the timeline → delete it all at once |
| Filler removal | Finds filler words such as "um"/"uh" in the transcript and deletes them at once |
| Captions | Generate from the transcript, add/edit by hand, drag on the timeline, style (font, color, background, outline, position), SRT import/export, burn into the video |
| Text (titles) | Text clips on top of the picture with position, size and color |
| Layout & effects | Size, position, opacity, picture-in-picture, fades, shape (circle, rounded rectangle), person background blur/removal |
| Cut by captions | Deleting a caption line also deletes its video; dragging captions in the list reorders the video with them; Track 1 clips can be dragged to insert-reorder (⌥+drag = free move) |
| AI editing | Edit by talking: "cut all the silences", "2× speed from 3:00 to 5:00" (Claude Pro/Max plan login or API key). Choose the model (Fable 5.1 · Opus 5.5 · Opus 5 · Sonnet 5 · Haiku 4.5), reasoning effort and whether to show thinking |
| Claude connection (MCP) | Control the app directly from Claude Code / Claude Desktop |
| Export | MP4 (H.264/HEVC), MOV (ProRes), audio (M4A), 4K/1080p/720p/480p, SRT alongside, save the current frame as PNG |
| Projects | Save/open `.easycut` files, up to 300 undo steps, **live auto-save** (unsaved new projects are kept for recovery at the next launch) |
| Auto update | Tells you at launch when GitHub has a new version and installs it with one click |

## Keyboard shortcuts (also in the app with ⌘/)

| Keys | Action |
|---|---|
| Space | Play / pause |
| L / J / K | Faster (1→2→4→8→16→20×) / slower / stop |
| ] / [ / \ | Speed up / down one step / back to 1× |
| ⌥1…⌥9, ⌥0 | Jump to 1·2·3·4·5·8·10·12·16·20× |
| , / . | Previous / next frame |
| ← / → , ⇧← / ⇧→ | Move 1 s / 5 s |
| ↑ / ↓ | Previous / next edit point |
| S or ⌘T | Split at playhead (⇧⌘T: all tracks) |
| I / O / X | Mark in / out / clear → ⌫ cuts the range |
| ⌫ / ⌘⌫ | Delete / delete and close the gap |
| ⌘C ⌘X ⌘V ⌘D | Copy · cut · paste · duplicate clips |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⇧⌘R | Transcribe |
| ⇧⌘X | One-click silence cut |
| ⇧⌘C | Make captions from the transcript |
| C / T | Add caption / add text |
| ⌘= / ⌘- / ⇧Z | Zoom timeline in / out / fit (⌘+scroll, magnifier buttons) |
| Drag empty space / drag the ruler | Select multiple clips / select a time range → ⌫ to cut |
| ⌘G / ⇧⌘G / ⌘J | Group / ungroup / join (cut pieces become one clip, others are butted together and grouped) |
| ⌘1–⌘4 | Media / Transcript / Captions / AI tab |
| ⌘I / ⌘E / ⌘S / ⌘O | Import / export / save / open |
| ⌥⌘R, ⌥⌘P, ⌥⌘. | Open recording, pause/resume recording, stop recording |

Shortcuts also work while a Korean input source is active (they use key positions).

## Import from a link (YouTube etc.)

Click **Link** in the Media tab or File › Import from Link (⇧⌘I). Paste an address and EasyCut downloads an edit-friendly H.264 MP4 and puts it on the timeline (the first time, click Install YouTube Tool in the link window; if downloads get blocked, click Update YouTube Tool).

- Quality 720p/1080p/best/audio only, **download only part** (e.g. 1:30–5:00), and the uploader's Korean/English captions
- Downloads are saved to `~/Movies/EasyCut 다운로드`
- You can also ask in the AI tab: "import this link and cut the silences"
- Only download and edit your own videos or ones you have permission to use.

## MKV and other formats

Files such as MKV, WebM and AVI are converted to MP4 automatically on import (ffmpeg is bundled).

- H.264/HEVC video is remuxed without re-encoding: done in seconds, no quality loss.
- VP9, AV1 etc. are converted to H.264 with the Mac's hardware encoder.
- If an MKV contains captions (SRT/ASS), they come in as captions when imported into an empty project.
- Converted files are kept in `~/Library/Application Support/EasyCut/converted`; the same file is not converted twice, and if the copy is deleted it is rebuilt from the original when you open the project.

## Speech recognition engines

- **Apple built-in (default)**: runs on this Mac with nothing to install. Long videos are recognized in 25–45 s pieces split at silences.
- **Whisper (default when installed)**: more accurate (especially for Korean) and much faster (a 2-hour recording in about 5 minutes vs. tens of minutes with Apple). Settings that prevent repeated-sentence hallucinations in long recordings are applied.
- With both engines the transcript appears as it is recognized.
  - Click **Turn On Whisper** in the Transcript tab, or Engine settings › Whisper › **Download** a model (Large v3 Turbo recommended, about 574 MB).

## AI editing / connecting Claude

- **Claude connection helper** (AI tab or Tools › Connect Claude…): install Claude Code → log in → connect Claude Desktop/Claude Code, all with buttons.
- **In the app — Claude plan (default, no API key)**: install Claude Code and log in once to your Pro/Max account with `claude` → `/login` in Terminal. Then just type something like "cut all the parts with no talking" in the **AI** tab and it edits using your subscription. (The app runs your logged-in Claude Code internally and lets it use only the editing tools.)
- **In the app — API key**: AI tab ⚙︎ › Connection › API key → enter the key (stored in the Keychain). The model is `claude-opus-5`.
- **From Claude Code**: register once while the app is running

  ```bash
  claude mcp add easycut -- /Applications/EasyCut.app/Contents/MacOS/EasyCut --mcp
  ```

- **From Claude Desktop**: add to `mcpServers` in Settings › Developer › Edit Config

  ```json
  "easycut": { "command": "/Applications/EasyCut.app/Contents/MacOS/EasyCut", "args": ["--mcp"] }
  ```

The connection stays inside this Mac (127.0.0.1) and only accepts requests carrying the secret token in the app's support folder. Every AI edit can be undone with ⌘Z.

## Development

```bash
swift build                                  # debug build
.build/debug/EasyCut --selftest /tmp/ectest  # engine self-test (creates test media → edits → verifies export)
./scripts/build_app.sh --dmg                 # app bundle + DMG
```

Layout:

- `Sources/EasyCut/Model` — project/clip/caption data and edit operations (split, ripple delete, speed, transcript cuts, groups)
- `Sources/EasyCut/Engine` — AVFoundation compositing (custom compositor), export, speech recognition, silence detection, screen recording, updater
- `Sources/EasyCut/App` — editor state, playback (20×), shortcuts, recording flow, localization, self-test
- `Sources/EasyCut/Views` — timeline (AppKit), transcript editor, panels, sheets
- `Sources/EasyCut/AI` — editing tool definitions, Claude API chat, MCP control server

Translations: Korean is the source language. English strings live in `Sources/EasyCut/App/LocTable.swift` (Korean → English); `scripts/gen_strings.py` generates `Resources/en.lproj/Localizable.strings` from it for SwiftUI text (run automatically by `build_app.sh`).

## License

[MIT](LICENSE). Licenses for the bundled FFmpeg (LGPL-2.1) and whisper.cpp (MIT) are in [`vendor/licenses/`](vendor/licenses).
