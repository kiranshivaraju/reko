# Reko — a notch teleprompter for macOS

Your script sits in a black panel that grows out of the MacBook notch, right under the camera, so you look at the lens while you read.

## Build & run

```sh
make test   # unit tests for script parsing + speech tracking
make run    # builds build/Reko.app (release, ad-hoc signed) and launches it
```

Requires macOS 14+ and Xcode / Swift 5.10+. No third-party dependencies. The app bundle is universal and runs on both Apple Silicon and Intel Macs.
Set `REKO_SIGN_IDENTITY` to a code-signing certificate to stop macOS from asking for mic and speech permission again after every rebuild (see `scripts/build-app.sh`).
Reko lives in the menu bar (speech-bubble icon). Macs without a notch get a floating window.

## Features

| | |
|---|---|
| **Notch panel** | Above the menu bar, on every Space including full-screen apps. Click it to play or pause, scroll over it to move the text, hover to pause. |
| **Hidden from screen sharing** | The panel is excluded from screen capture (`NSWindow.sharingType = .none`). Some macOS 15+ capture tools built on ScreenCaptureKit may still record it, so share a single window rather than the whole screen when it matters. Set `REKO_CAPTURABLE=1` to make the panel capturable on purpose, e.g. for demos. |
| **Countdown** | Optional 3, 5 or 10 second countdown before scrolling starts. |
| **Voice beam** | A glow along the bottom edge that follows your voice level (green while you're talking) in the mic modes. |
| **3 scroll modes** | **Constant** speed · **While talking**: scrolls only while the mic hears you (adjustable sensitivity) · **Follow my words**: on-device speech recognition keeps the line you're reading on the marker and dims what you've already said. Ad-libs, skips and re-reads are handled. |
| **Cues** | Every `# Heading` line becomes a cue you can jump to. `[text in brackets]` is a stage direction: shown, but never expected to be read aloud. |
| **Global hotkeys** | ⌃⌥Space play/pause · ⌃⌥P show/hide · ⌃⌥↑/↓ speed · ⌃⌥←/→ previous/next cue · ⌃⌥R back to top |
| **Phone remote** | Off by default; switch it on under Settings › Phone remote, then scan the QR code. Any phone browser on the same Wi-Fi gets play/pause, speed, cues and scrolling. No app install needed; access is protected by a secret token in the link. |
| **Editor** | Script plus settings in one window, auto-saved to `~/Library/Application Support/Reko/script.md`. You can also open or save `.md` files. |
| **Look** | Text size, text colour, width and height. **Mirror mode** flips the text for beam-splitter teleprompter glass. |
| **Drag it anywhere** | Starts attached to the notch. Drag it to pull it out and drop it anywhere, on any screen; it remembers the spot. Drop it back under the notch to re-attach it. Without a saved spot, the free window opens on the screen your pointer is on. A spot saved on a monitor that's no longer connected is ignored. |

## Layout

```
Sources/RekoCore/     pure logic, unit-tested
  Script.swift          markdown → display text, spoken words, cues, directions
  ScriptTracker.swift   aligns recognized speech with the script (fuzzy, windowed)
  SpeechPacer.swift     smooths and extrapolates the tracked position to hide recognizer lag
  RemoteRouter.swift    HTTP request parsing + token check for the phone remote
Sources/Reko/         the app
  PrompterController    hub: playback state, scroll offset, frame tick, commands
  PrompterPanel         notch geometry, NSPanel, text layout ↔ offset mapping
  MicListener           AVAudioEngine level meter + SFSpeechRecognizer stream
  HotKeys               Carbon RegisterEventHotKey (no Accessibility permission)
  RemoteServer          Network.framework HTTP server + embedded phone page
  EditorView            SwiftUI editor & settings
  AppDelegate           menu bar item, windows, wiring
```

Every action is a `Command`, and hotkeys, the menu, the editor and the phone remote all call `PrompterController.perform(_:)`.

## Permissions

The first time you use the mic-based modes, macOS asks for **Microphone** access, and **Speech Recognition** access for "Follow my words". The remote triggers a **Local Network** prompt. The app is ad-hoc signed, so macOS may ask again after each rebuild.
