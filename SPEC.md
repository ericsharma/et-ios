# E.T. — a tmux client for iPhone and iPad

"ET phone home": one tap opens your tmux session on a server you own. Each tmux window is a full-screen page; swipe between them. A compose bar with on-device dictation sends text to the terminal.

Bundle ID `xyz.ericsharma.et` · repo `github.com/ericsharma/et-ios` (private) · status: spec v2, 2026-10-15.

## 1. Scope

**The app replaces:** `ssh server` → `tmux attach` → `prefix n` / `prefix p`, on a phone keyboard.

**It must work for any tmux user.** Nothing in the app assumes a host name, session name, window naming scheme, or install path. Eric's setup (below) is the first real test case, not the design.

**v1 includes:** saved servers, session picker, one page per window, history restore, typing, key-row presets, compose bar with dictation, new-window templates, reconnect, iPad layout with keyboard shortcuts, Secure Enclave key.

**Not in v1:** a general SSH client (SFTP, port forwards), Mosh, split-pane layouts (the app shows each window's active pane), push notifications, AI features, Android, macOS.

### 1.1 Example setup: Eric

- Server `trigkey` (NixOS, tmux 3.6a), reached over Tailscale. One session, `0`.
- Windows follow `<machine>` / `<machine>-claude`: `trigkey`, `trigkey-claude`, `gmktec`, `gmktec-claude`, `mac-mini`, `mac-mini-claude`. Windows for other machines run `ssh <machine>` from trigkey, then a shell or `claude` there.
- tmux-resurrect and tmux-continuum keep windows across reboots.

The app should make this setup pleasant through general features: templates (§6.4), key-row presets (§5.4), and optional name grouping (§5.3).

## 2. How it works: tmux control mode

The app does **not** draw tmux's own screen (status bar, borders) in one terminal. It uses **control mode** (`tmux -C`), like iTerm2's tmux integration:

- Each pane's output arrives as its own stream (`%output %<pane> …`).
- Window changes arrive as notifications (`%window-add`, `%window-renamed`, …).
- The app sends ordinary tmux commands; each reply comes in a `%begin` … `%end` / `%error` block.

So each tmux window becomes a native page with its own terminal emulator, and the window list becomes native UI.

### 2.1 Connecting

1. SSH to the server with the app's key (§9).
2. **Find tmux:** run one exec that tries `command -v tmux` in a login shell (`$SHELL -lc`), then common paths: `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/run/current-system/sw/bin`, `/etc/profiles/per-user/$USER/bin`, `~/.nix-profile/bin`. Cache the result per server. Users can override it in server settings.
3. **Pick a session:** run `tmux list-sessions -F '#{session_id} #{session_name} #{session_windows} #{session_attached}'`.
   - One session: attach it.
   - Several: attach the session used last on this server, or show a picker the first time.
   - None, or "no server running": offer to create one (name defaults to `main`).
4. **Attach:** open an exec channel **without a PTY** and run `exec <tmux> -C attach-session -t <session>`. Create a session with `exec <tmux> -C new-session -A -s <name>`.

Verified on tmux 3.5a: `-C` works without a PTY. **Still to check on 3.6a (trigkey).** If it fails, request a PTY, use `-CC`, and strip the DCS wrapper (`ESC P 1000 p` … `ESC \`). The parser already accepts `\r\n` line endings for that case.

### 2.2 Protocol notes (verified, tmux 3.5a)

- Lines end in `\n`. In `%output` data, bytes < 0x20 and `\` arrive as octal `\ooo`. Everything else is raw, so **a UTF-8 character can be split across two `%output` lines**. Treat output as bytes, never as strings.
- Reply bodies (`capture-pane` etc.) are raw and not escaped. Body lines can start with `%`, so a block ends only at the `%end`/`%error` line whose time and number match its `%begin`.
- Reply flags: `1` means a command sent by this client. `0` means a command tmux ran itself (the initial attach). Match only flag-1 replies, in order, against the queue of sent commands.
- tmux prints tabs in `-F` output as `_`. Use space-separated fields with the free-text field (the window name) last.
- `new-window -n` and `rename-window` expand `#{…}` in names, so double `#` in names typed by the user.
- Closing stdin ends the control client with `%exit`. The session keeps running.
- Unknown `%` lines are logged and ignored, never fatal.

### 2.3 Commands

| Purpose | Command |
|---|---|
| Window list | `list-windows -F '#{window_id} #{window_index} #{window_active} #{pane_id} #{window_panes} #{window_width} #{window_height} #{s/ /_/:pane_current_command} #{window_name}'` |
| Type input | `send-keys -t %<pane> -H <hex bytes>`, sent without waiting for replies, in chunks of up to 256 bytes |
| History | `capture-pane -p -e -J -t %<pane> -S -<N>` (N = scrollback setting, default 2000) |
| Cursor and screen mode | `display-message -p -t %<pane> '#{cursor_x} #{cursor_y} #{alternate_on} #{pane_width} #{pane_height}'` |
| Alternate screen | `capture-pane -p -e -a -t %<pane>`, only when `alternate_on` is 1 (fails otherwise) |
| Client size | `refresh-client -C <cols>x<rows>` |
| New window | `new-window -d -n <name> -P -F '#{window_id} #{pane_id}'`. `-d` leaves the server's current window alone. |
| Rename / close / select | `rename-window`, `kill-window` (after confirm), `select-window` |

### 2.4 Restoring a window

For each window, before showing live output:

1. Create the terminal emulator at the pane's size.
2. Feed it `capture-pane` output: history plus visible screen, with colors.
3. If `alternate_on`, also feed the alternate-screen capture.
4. Move the cursor (`ESC [ row ; col H`) from `display-message`.
5. Hold `%output` for this pane that arrives during steps 2–4, and apply it afterwards.

Order: the visible window first, then its neighbors, then the rest in the background.

### 2.5 Window size

With tmux's default `window-size latest`, windows take the size of whichever client was used last. Typing on the phone resizes windows to fit the phone; typing on a laptop resizes them back. The app never changes the server's `window-size` option.

Send `refresh-client -C` on attach, rotation, font-size change, and iPad window resize, debounced by 150 ms.

## 3. Stack

| Part | Choice |
|---|---|
| Language / UI | Swift 6 (strict concurrency), SwiftUI, UIKit where SwiftTerm needs it |
| Minimum OS | iOS / iPadOS 18 |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) `TerminalView` in a `UIViewRepresentable` |
| SSH | [Citadel](https://github.com/orlandos-nl/Citadel) (SwiftNIO SSH). Must support a long-running exec channel with streamed stdin and stdout; fall back to `swift-nio-ssh` directly if not. |
| Keys | Secure Enclave P-256 (CryptoKit). Fallback: Ed25519 in the Keychain, `WhenUnlockedThisDeviceOnly`. |
| Speech | `SFSpeechRecognizer` with `requiresOnDeviceRecognition`, plus `contextualStrings`. Later, `SpeechAnalyzer` (iOS 26) if quality isn't good enough; only `VoiceInput` changes. |
| Storage | JSON in Application Support for servers, templates, and settings. Keychain for keys and pinned host keys. |
| Network | `NWPathMonitor` for reconnect |

No other third-party packages unless one proves necessary.

## 4. Architecture

```
ETCore (Swift package, no UI, tested on macOS)
  ControlParser    bytes → [ControlEvent]; pure                           ✅ done
  TmuxCommand      command builders + reply parsing; pure                 ✅ done
  TmuxClient       actor: command queue, reply matching, event stream     ✅ done
  ControlChannel   protocol: bytes in/out (SSH in the app, a pipe in tests) ✅ done
App
  SSHTransport     Citadel connection, tmux discovery, exec channel → ControlChannel
  SessionStore     @Observable, MainActor: windows, connection state, restore progress
  PaneTerminal     one TerminalView per window, fed by %output; keys → send-keys -H
  UI               ServerList, SessionPicker, WindowPager, TabBar, Overview, KeyRow, ComposeBar, Settings
  VoiceInput       SFSpeechRecognizer wrapper: partial + final text
  KeyStore         key generation, public key export, host-key pinning
```

- Keep a `TerminalView` alive for every window, even off screen, so no output is lost and swipes are instant. Plan for up to about 30 windows.
- All tmux traffic goes through `TmuxClient`. UI code never writes to SSH.

## 5. UI

The style borrows from the Claude app's Remote Control screen: dark and calm, one main surface, the compose bar at the bottom, connection status at the top.

### 5.1 iPhone

```
┌─────────────────────────────────┐
│ ● trigkey · 0          ⊞   ⚙   │  status dot, server · session, overview, settings
│ trigkey │ trigkey-claude │ gmk… │  window tabs (§5.3), scrolls
├─────────────────────────────────┤
│                                 │
│        terminal (window)        │  ← swipe = previous / next window
│                                 │
├─────────────────────────────────┤
│ esc tab ctrl ↑ ↓ ← → | ~ / -    │  key row (§5.4)
│ [ type or dictate…     ] 🎤  ➤ │  compose bar (§6.2)
└─────────────────────────────────┘
```

**First run:** "Add server" (host, port, user) → show the app's public key with Copy and Share, plus a one-line hint ("add to `~/.ssh/authorized_keys` on the server") → connect → trust the host key (§9) → session picker if needed → terminal.

**Server list:** reached from the status row. Tap a server to switch to it; long-press to edit or delete. One connection at a time in v1.

### 5.2 Window pager

- One page per tmux window, in `window_index` order. Light haptic on page change.
- Vertical pans belong to the terminal (scrollback). The pager only takes clearly horizontal swipes, and never while text is selected.
- Changing page does **not** run `select-window` on the server, so other clients keep their own current window. Setting: "Follow app window on server", off by default.
- Windows added or closed on the server add or remove pages live. When the current window closes, show its neighbor.
- Remember the last window per server and session **by name**, since IDs change when the tmux server restarts.

### 5.3 Window tabs

- **Default:** a scrolling tab row, one tab per window, labeled with the window name. It follows the pager.
- **Optional grouping** (per server, off by default): "Group windows by name prefix" splits names at the first `-`. The top row shows one chip per prefix (`trigkey`, `gmktec`, `mac-mini`); a second row shows the windows in that group (`trigkey`, `claude`). The prefix chip, tab underline, and a 2 pt line above the terminal take that prefix's color, editable in settings, so you can see at a glance which machine is live.

### 5.4 Key row and presets

One row above the compose bar; it scrolls horizontally if it doesn't fit. It's hidden when a hardware keyboard is attached.

| Preset | Keys |
|---|---|
| Shell (default) | `esc` `tab` `ctrl` `↑` `↓` `←` `→` `\|` `~` `/` `-` `^C` `^D` |
| Claude | `esc` `⇧tab` `1` `2` `3` `↑` `↓` `enter` `^C` |

- `ctrl` is sticky: tap once and the next key is sent with Ctrl; long-press to lock it.
- The preset is chosen per window (long-press the key row) and remembered by window name.
- **Suggestion:** when a window's pane runs `claude`, or its name contains `claude`, the app switches it to the Claude preset, unless the user has already chosen a preset for it. (A window that runs claude over ssh shows `ssh` as its command, so the name check matters.)
- A Claude-preset window also changes the compose bar: prose mode (spoken symbols off) and the placeholder "Message Claude…". That makes the phone a good place to answer Claude's questions and approve actions.

### 5.5 Overview

- Tap ⊞, or pinch in on the pager: a grid of all windows (grouped when grouping is on). Each tile shows a live snapshot, the name, and activity or bell badges.
- Tap a tile to open it. Long-press: Rename, Close (confirm), New window from template.
- A **+** tile opens New window (§6.4).

### 5.6 Activity and bells

- A window that gets output while not visible gets a dot on its tab.
- A BEL (`0x07`) in a window that isn't visible gives a red badge and a light haptic.
- Opening the window clears both.

### 5.7 Connection state

| State | Look |
|---|---|
| Connected | Green dot |
| Connecting / restoring | Pulsing amber dot, "Restoring 3/6" |
| Reconnecting | Amber banner "Reconnecting…". Last screen stays visible, dimmed 30%, input disabled. |
| Unreachable | Red banner "Can't reach <host>. Check your network or VPN." + Retry |
| Auth failed | Red banner + "Show my key" (Settings → Key) |
| Host key changed | Red full-screen error, no connect (§9) |
| tmux not found | Prompt for the tmux path |

### 5.8 Font

Pinch in the terminal changes the font size for all windows, then resizes (§2.5). Default: SF Mono 13 pt on iPhone, 14 pt on iPad.

### 5.9 iPad

- `NavigationSplitView`: the sidebar lists windows (grouped if grouping is on); the detail is the terminal. In compact width, use the iPhone layout.
- Hardware keyboard: `⌘[` / `⌘]` previous / next window, `⌘1`…`⌘9` window by position, `⌘T` new window, `⌘K` focus the compose bar, `⌘\` toggle the sidebar. All other keys go to the terminal, including Ctrl and Esc.

## 6. Input

### 6.1 Typing

Tap the terminal for the keyboard. Keys go straight to the pane: SwiftTerm input → `send-keys -H`.

### 6.2 Compose bar

A text field that grows to 5 lines, with mic and send buttons.

- **Send:** sends the text, then Enter. Long-press for "Send without Enter".
- Clears after sending. Keeps a per-window history: ↑ in an empty field, or swipe up, shows recent entries.

### 6.3 Dictation

- Tap the mic to start, tap again to stop. While listening, the mic is red and partial text appears live. Recognition is on-device only.
- Contextual strings: the server's window names and session names, plus a fixed list (`ssh`, `sudo`, `git`, `grep`, `tmux`, `docker`, `systemctl`, `journalctl`, `claude`, `vim`, `cd`, `ls`).
- **Spoken-symbol mode:** a toggle on the compose bar. It defaults to on in Shell-preset windows and off in Claude-preset windows. After transcription it replaces words with symbols, without AI: "dash" `-`, "dash dash" `--`, "pipe" `|`, "slash" `/`, "tilde" `~`, "dot" `.`, "star" `*`, "and and" `&&`, "greater than" `>`, "space" ` `, "all caps X" → uppercase X. It also lowercases the first word and drops a trailing period.
- Permissions: microphone and speech recognition, with plain purpose strings.

### 6.4 New window and templates

**New window** (from the overview **+**, `⌘T`, or a long-press on a tab): enter a name and, optionally, pick a template.

A **template** is stored per server and has:
- a label, such as "Claude on gmktec"
- a default window name, such as `gmktec-claude`
- command lines to type into the new window, one per line, each followed by Enter, such as `ssh gmktec` and `claude`

To create the window, the app runs `new-window -d -n <name> -P -F …`, then sends each command line with `send-keys`, then opens the page.

Commands are typed into the new window's shell, not passed to `new-window` as its command. So when `ssh` exits, the window stays as a shell, and session-restore plugins (tmux-resurrect) save it like any window the user made by hand.

There are no built-in templates. Eric's six windows are six templates he adds once.

## 7. Lifecycle

| Event | Action |
|---|---|
| Launch / foreground | Connect to the last server and session. Goal: first terminal on screen in under 2 s on a good network. Visible window restores first. |
| Background | `beginBackgroundTask`, then close the control client. The session keeps running on the server. |
| Network path change | Reconnect. |
| Disconnect | Reconnect after 0.5, 1, 2, 4 s, then every 8 s; stop after 2 min and show Retry. |
| Reconnect | Full restore (§2.4) into the existing `TerminalView`s, so pages don't flash. |

## 8. Settings

**Per server:** display name, host, port (22), user, tmux path (auto), last session, scrollback lines to restore (2000), follow app window on server (off), group by name prefix (off), prefix colors, templates.

**App:** font size, theme (default Catppuccin Mocha: bg `#181825`, accent `#89b4fa`, active `#f38ba8`, plus a few built-ins), require Face ID to open (off), Key (view, copy, share).

## 9. Security

- **Client key:** generated on first launch in the Secure Enclave (P-256); it can't leave the device. One key for all servers. Settings → Key shows the public key in OpenSSH format with Copy and Share.
- **Host keys:** trust on first use. Show the fingerprint and ask once, then pin it per server. If it changes, stop and show a clear error; there's no "connect anyway" in v1. To accept a new key, the user deletes and re-adds the server.
- No passwords, no keyboard-interactive.
- Optional Face ID before showing terminal content.
- Blur the content in the app switcher snapshot (when `scenePhase` is inactive).

## 10. Build plan

**Build environment:** Mac mini (m1-mini), headless, macOS 15.5, Xcode 16.3 (iOS 18.4 SDK). The project is generated with `xcodegen`. Signing is headless: an App Store Connect API key passed to `xcodebuild -allowProvisioningUpdates -authenticationKey…`. Testing runs on Eric's iPhone, installed with `xcrun devicectl`.

**TestFlight needs Xcode 26** (Apple requires the iOS 26 SDK for uploads), which needs macOS 15.6+. Upgrade from the terminal (`softwareupdate`, `xcodes`) before phase 6.

| Phase | Work | Done when | Status |
|---|---|---|---|
| 1a. Core | `ControlParser`, `TmuxCommand`, `TmuxClient`, tests | Integration test passes against a local tmux | ✅ |
| 1b. SSH + first page | Citadel transport, tmux discovery, session picker, one `PaneTerminal`, typing, history restore, resize, debug log screen | Use a real window on trigkey from the iPhone like a normal terminal; 3.6a no-PTY question answered | |
| 2. Navigation | Pager, tabs, optional grouping, overview, new/rename/close, templates, activity, bells | Swipe through all windows; create a `gmktec-claude` window from a template | |
| 3. Input | Key row and presets, compose bar, dictation, spoken symbols | Dictate `systemctl status sshd` in a shell window and it runs | |
| 4. Lifecycle | Reconnect, background, network changes, restore last window, banners | Airplane Mode for 10 s, then off: the session comes back without touching anything | |
| 5. iPad | Split view, keyboard shortcuts, compact fallback | `⌘]` moves through windows on a hardware keyboard | |
| 6. Ship | Server list polish, Secure Enclave key, host-key pinning, app icon, Xcode 26, TestFlight | Installed from TestFlight on Eric's iPhone | |

### 10.1 Tests

- **Parser:** recorded control-mode output as fixtures. Covers octal escapes, UTF-8 split across lines, `%`-lines inside reply blocks, unknown notifications, `%exit`, and any chunking.
- **Client integration:** a throwaway tmux server on a private socket (`tmux -L et-test-…`), driven over a pipe. Covers window add/rename/close, `send-keys` round trip, capture, resize, errors, disconnect.
- **SSH:** against this Mac's own sshd, using a throwaway key.
- **Manual on device:** the "Done when" column.
- Never run destructive commands (`kill-window`, `kill-session`) against a real session. Use a separate one (`tmux new -d -s ettest`).

## 11. Later

1. Push notifications when a window rings a bell or Claude waits for input (needs a small hook service on the server → APNs).
2. Live Activity for a long-running command.
3. Snippets: saved commands per server, one tap to send.
4. Shortcuts / Siri: "Open gmktec in E.T.".
5. Several servers connected at once.
6. Split-pane layouts.
7. `SpeechAnalyzer` dictation (iOS 26).
