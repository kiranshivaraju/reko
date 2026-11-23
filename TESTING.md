# Manual test checklist

Automated coverage: `make test` checks script parsing, speech tracking, speech pacing and the remote's request handling (28 tests).
Everything below needs a real Mac, a real voice or a real phone, so it can only be tested by hand.

**Setup:** run `make run` (it rebuilds and relaunches `build/Reko.app`). Open settings from the menu-bar icon › **Script & Settings…**.
Items marked ★ have **not** been tested by hand yet. Do those first.
Sections 1, 2, 3, 5, 6 and 7 were verified by hand on 2026-11-23 (notched MacBook Pro, macOS 15.7). Only the Intel check (section 9) is still open.

## 1. Follow my words (voice tracking) ✓

Settings: Scrolling › Mode = **Follow my words**. Use the sample script.

| # | Do | Expect |
|---|---|---|
| 1.1 | Press ⌃⌥Space, wait for the countdown, read the first paragraph aloud at a normal pace | Text glides smoothly with no visible lag behind your voice; words you've said turn dim |
| 1.2 | Stop talking mid-sentence for 5 s | Scrolling stops within about one word and doesn't drift ahead |
| 1.3 | Skip a sentence and read the next one | It jumps ahead to where you are within a second or two |
| 1.4 | Ad-lib ("um, so, basically…") then carry on reading | It ignores the ad-lib and keeps tracking |
| 1.5 | Re-read the previous sentence | It moves back to it |
| 1.6 | Put "really really" or "no, no" in the script and read it | It doesn't skip ahead of you |
| 1.7 | Switch Mode to **Constant**, play until halfway, pause, switch back to **Follow my words**, play and read from the marker | It follows from the middle and doesn't jump back to the top |
| 1.8 | While following, scroll the prompter with the trackpad to another paragraph and read from there | It picks up from the new spot |
| 1.9 | While following, edit the script in the editor above the line you're reading (e.g. paste a paragraph) | The line on the marker stays the same; tracking continues |
| 1.10 | Change **Language** while playing (e.g. English (UK) → English (US)) | Status line shows "Listening…" again; tracking still works |
| 1.11 | In a noisy room or with music on | Expect worse accuracy; raise or lower **Sensitivity** and see if it helps |

## 2. While talking (voice-activated) ✓

Settings: Mode = **While talking**.

| # | Do | Expect |
|---|---|---|
| 2.1 | Play, then talk | Scrolls at your speed setting only while you talk; stops about 0.6 s after you stop |
| 2.2 | Watch the bottom edge of the prompter while talking | **Voice beam** grows with your volume; green while you're talking, grey when silent |
| 2.3 | Move **Sensitivity** to each end | Low = needs a loud voice; high = background noise starts it |
| 2.4 | Connect or disconnect AirPods while playing | Listening continues on the new mic (may blip briefly) |

## 3. Permissions ✓

Test these on a fresh machine, or reset first with `tccutil reset Microphone app.reko.teleprompter; tccutil reset SpeechRecognition app.reko.teleprompter`.

| # | Do | Expect |
|---|---|---|
| 3.1 | First play in Follow my words | macOS asks for Microphone, then Speech Recognition |
| 3.2 | Deny Microphone, then play | Settings shows "Microphone access denied…" |
| 3.3 | With 3.2 still playing, allow Reko in System Settings › Privacy › Microphone | Within about 3 s it starts listening without you pausing |
| 3.4 | Rebuild with `make run` | macOS may ask again (expected with ad-hoc signing; set `REKO_SIGN_IDENTITY` to avoid it) |

## 4. Countdown, playback, shortcuts

| # | Do | Expect |
|---|---|---|
| 4.1 | Countdown = 3 s, press ⌃⌥Space | Big 3-2-1 with a green timer icon, then scrolling starts |
| 4.2 | Press ⌃⌥Space during the countdown | Countdown cancels and the text comes back |
| 4.3 | Scroll the trackpad during the countdown | Nothing moves |
| 4.4 | Countdown = Off | Starts immediately |
| 4.5 | ⌃⌥↑ / ⌃⌥↓ | Speed label (e.g. 1.2×) changes |
| 4.6 | ⌃⌥→ / ⌃⌥← | Jumps to the next or previous cue |
| 4.7 | ⌃⌥R, ⌃⌥P | Back to top; show/hide |
| 4.8 | Constant mode: hover over the prompter | Pauses (hand icon); resumes when you move away |
| 4.9 | Hide with ⌃⌥P while the cursor is over it, show again, play | Scrolls normally (not stuck paused) |
| 4.10 | Settings › Shortcuts | Any shortcut another app already owns shows in orange "used by another app" |

## 5. Display ✓ (except 5.1a–d, added later) ★

| # | Do | Expect |
|---|---|---|
| 5.1 | Position = Notch | Panel grows out of the notch; status icons beside the camera |
| 5.1a | Drag the prompter out of the notch and drop it mid-screen | It detaches and follows the cursor without jumping; stays where dropped |
| 5.1b | Drag it back up under the notch and let go | Snaps back into the notch |
| 5.1c | Drag it onto another monitor, quit and relaunch | Reopens on that monitor at the same spot |
| 5.1d | Click (don't drag) anywhere on the text | Play/pause toggles |
| 5.2 | Drag Text size / Width / Height | The same line stays on the marker |
| 5.3 | Pick a **Text colour**, dragging around the colour wheel | Text recolours live without stutter; cues stay yellow |
| 5.4 | Position = Floating, drag the window to an external monitor, quit, relaunch | Reopens where you left it |
| 5.5 | Unplug that monitor, show the prompter | Comes back on a connected screen, not off-screen |
| 5.6 | Floating, **Reset window position**, move the pointer to the other screen, hide and show | Opens on the screen the pointer is on |
| 5.7 | Close the lid with an external monitor (clamshell) | Floating window shows on the external screen; no crash |
| 5.8 | Plug or unplug a monitor while reading in notch mode | Same line stays on the marker |
| 5.9 | Mirror text on | Text is flipped left-to-right, marker on the right |
| 5.10 | Open a full-screen app (e.g. Keynote) and switch Spaces | Prompter stays visible |

## 6. Hidden from screen sharing ✓

| # | Do | Expect |
|---|---|---|
| 6.1 | Share **entire screen** in Zoom / Google Meet / Teams; check from another device | Prompter shouldn't appear. Some apps on macOS 15+ may still capture it, so note which ones |
| 6.2 | ⌘⇧5 screen recording / screenshot | Prompter not in the capture |
| 6.3 | QuickTime screen recording | Same |

## 7. Phone remote ✓

Settings › Phone remote › **Enable on local network**. Phone on the same Wi-Fi.

| # | Do | Expect |
|---|---|---|
| 7.1 | Turn it on | macOS asks about Local Network → Allow; QR code appears |
| 7.2 | Scan the QR code with the phone camera | Remote page opens and shows the mode and progress bar |
| 7.3 | Tap Play | Remote shows "Starting in 3…", then Pause; Mac plays |
| 7.4 | Tap cues, Faster/Slower, ▲/▼, Show/Hide, Top | Each works on the Mac within about a second |
| 7.5 | Switch the Mac to another Wi-Fi (or a phone hotspot) with settings open | QR code updates to the new address |
| 7.6 | Turn the remote off and on again | Same link still works (same port) |
| 7.7 | Open the link without `?t=…` | "Scan the QR code…" error page |
| 7.8 | iPhone: Share › Add to Home Screen | Opens full-screen like an app |

## 8. Script & editor

| # | Do | Expect |
|---|---|---|
| 8.1 | Type in the editor | Prompter updates after a brief pause; no lag even with a long script (paste ~5,000 words) |
| 8.2 | Type, then immediately quit Reko (⌘Q from the menu) and relaunch | The last edit was kept |
| 8.3 | `# Heading` lines and `[directions]` | Headings become yellow cues listed in settings, the menu and the phone; directions show in teal and are skipped by Follow my words |
| 8.4 | Open… / Save As… a `.md` file | Works |
| 8.5 | Chinese or Japanese script with that language picked | Follow my words tracks it |

## 9. Intel Mac ★

| # | Do | Expect |
|---|---|---|
| 9.1 | Copy `build/Reko.app` to an Intel Mac running macOS 14+ and open it (right-click › Open the first time) | Launches; panel shows as a floating window (no notch); all modes work |

## Reporting a problem

Note the test number, what you did and what happened. For speech issues, also give the language, the mic (built-in, AirPods…) and the status line text under **Mic** in settings.
