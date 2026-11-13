# EOS Cue Helper

A small native macOS app (Swift/SwiftUI, no Electron, no Python) for ETC EOS programming:

- **Follows the cue EOS is targeting**: the last cue on the command line, or the pending or active cue.
- **Adds a prefix and/or suffix to that cue's label** (and can remove them, or undo the last change).
- **Turns pages in Cuelist** (app.thecuelist.com in Chrome) when it receives `/cuelist/next`, `/cuelist/last` or `/cuelist/page=12`.
- Talks to EOS over **UDP or TCP** (OSC 1.1 SLIP on 3037, or OSC 1.0 on 3032).
- **Updates itself** from GitHub Releases.

## Build & install

You need Xcode or the Command Line Tools installed. Then:

```bash
./build.sh install
```

That builds `EOS Cue Helper.app`, copies it to `/Applications`, and opens it.

## Releasing an update

```bash
./release.sh 1.1.0 "What changed"
```

This bumps `VERSION`, tags the commit and pushes it. GitHub Actions then builds the app and publishes a Release. The installed app checks for a new release each time it launches and installs it before connecting. You can turn that off in Settings (⌘,) or check by hand with **EOS Cue Helper ▸ Check for Updates…**.

## EOS setup

**Setup ▸ System ▸ Show Control ▸ OSC**

| | UDP | TCP |
|---|---|---|
| OSC RX / OSC TX | On | On |
| OSC UDP RX Port | 8000 (app's "Send to port") | — |
| OSC UDP TX Port | 8001 (app's "Listen on UDP") | — |
| OSC UDP TX IP Address | this Mac's IP | — |
| App setting | Protocol UDP | Protocol TCP, port 3037 (SLIP) or 3032 (OSC 1.0) |

The app always listens on its UDP port, including in TCP mode, so Cuelist and labeler triggers can come from anything: EOS macros, a Stream Deck, QLab and so on.

Labels are written as `/eos/newcmd "Cue {list}/{cue} Label {label}#"`. You can change this template in Settings.

## OSC triggers (send to the app's UDP listen port, or from EOS)

| Address | Does |
|---|---|
| `/cuelist/next` | next page |
| `/cuelist/last` (or `/prev`) | previous page |
| `/cuelist/page=12`, `/cuelist/page/12`, `/cuelist/page 12` | go to page 12 |
| `/labeler/prefix` `[text]` | add prefix (optional text overrides the box) |
| `/labeler/suffix` `[text]` | add suffix |
| `/labeler/both`, `/labeler/remove`, `/labeler/undo` | — |
| `/labeler/cue "2/5"` | target a specific cue |

From an EOS macro or cue, send the OSC string `/cuelist/page=12`. EOS sends that as `/cuelist/page` with the argument `12`, and both forms work.

## Cuelist control

The app runs a little JavaScript in the Cuelist tab through AppleScript, so Chrome doesn't need to be in front. You need:
1. Chrome ▸ View ▸ Developer ▸ **Allow JavaScript from Apple Events** turned on.
2. Click **OK** the first time macOS asks to let EOS Cue Helper control Google Chrome. After an update that asks again, click OK again.

## Keyboard shortcuts

⌘1 prefix · ⌘2 suffix · ⌘3 both · ⌘4 remove · ⇧⌘Z undo · ⌘R refresh label · ⌘[ / ⌘] Cuelist prev/next
