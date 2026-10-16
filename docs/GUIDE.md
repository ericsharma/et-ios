# E.T. Field Guide

Oct 15, 2026 · [living version](https://claude.ai/code/artifact/c37eb59e-e071-412f-9695-b5aa07ba5200)

E.T. puts your tmux session on iPhone and iPad: every tmux window is its own full-screen terminal, and nearly everything is one tap, one swipe, or one word away.

## The bottom bar

The big mic sits in the middle; everything else is one tap on either side.

| Button | What it does |
| --- | --- |
| ✎ Editor | Write or edit a whole message, then send it in one go |
| ⌶ Select | Freeze the window and select text precisely (see Select mode) |
| ⋯ Keys | Open the key wheel: esc, tab, ctrl, arrows, ^C and friends |
| Mic | Tap to dictate, tap to stop; on-device only |
| Speaker (top bar) | Tap: reads the window's last "Next:" line. Hold: summarizes Claude's whole last reply on your summary model (⋯ → Read aloud), then reads it. Tap again to stop or cancel |
| Paste | Appears when the clipboard has text; pastes in one tap, no prompt |
| Image | Send a screenshot or photo; its path is typed into the window |
| ⏎ | Press Enter |

## Gestures

Two fingers move you around; one finger is for the text.

| Gesture | Result |
| --- | --- |
| Two fingers up / down | Scroll back through history; the keyboard tucks away |
| Two fingers left / right | Next / previous window |
| Tap the terminal | Bring up the keyboard |
| Long-press text | Select it, with a Copy menu |
| Tap a tab | Jump to that window |
| Long-press a tab | Rename, close, or create a window |

In full-screen programs like vim or htop, two-finger scrolling scrolls inside the program instead.

## Talking and typing

Speak, type, paste, or send a picture; it all lands in the window you're looking at.

- **Mic:** tap, talk as long as you like (pauses don't lose anything), tap to stop. Your words appear live in a bubble, then go into the terminal without pressing Enter.
- **Edit after dictating:** when dictation ends, an **Edit** button appears. Tap it to move the text into the editor; ignore it and the text stays put.
- **Keyboard mic:** the iPhone keyboard's own dictation works too, with the same Edit button.
- **Names (repos, files, tools):** E.T.'s mic learns the names on your servers: git repos and their files on the tmux host and on hosts your windows ssh into, window names, and odd words on screen. Say "key row dot swift" and you get `KeyRow.swift`; in a Claude window, "at source slash auth dot ts" becomes `@src/auth.ts`. Add your own under **⋯ → Dictation words** (with "sounds like" for names it keeps mishearing); the same screen has a box to try a transcript. Two quicker ways to add names: on that screen, tap the mic next to "sounds like" and say the name the way you normally do; or after tapping **Edit**, fix a misheard name in the editor and tap the **Learn** chip that appears above the text. The keyboard's mic can't be taught names; only E.T.'s mic.
- **Editor (✎):** a roomy box for longer messages. Send, or long-press Send for *Send without Enter*. Multi-line text reaches Claude as one message.
- **Key wheel (⋯):** spin it, tap a key, and it stays open for repeats. Long-press **ctrl** to lock it on. Long-press ⋯ to swap between the Shell and Claude key sets (Claude windows get esc, ⇧tab, 1 2 3 automatically).
- **Paste:** one tap, no permission prompt; multi-line pastes arrive as one block.
- **Images:** pick a screenshot and E.T. uploads it to the machine the window is running on, then types its path. Add a question and send it to Claude.

## Select mode (⌶)

Select mode freezes the window as text, so output can't scroll away while you pick exactly what you want; whatever you select is copied automatically.

| Do this | Get this |
| --- | --- |
| Tap | A whole word, path, URL, or flag |
| Double-tap | The line |
| Triple-tap | The block: a full Claude reply or a command's output |
| Long-press and drag | Any range, with iOS handles and magnifier |
| Volume up / down | Move the chosen end one letter; hold to keep going |
| Volume up and down together | Swap between moving the Start and the End |

The toolbar adds **One line** (joins wrapped lines, handy for long commands), **Editor** (quote the selection back to Claude), and **Screen** (select everything visible). Tap a tab or swipe two fingers to leave select mode and paste in another window.

## Windows

Every tmux window is a tab, and you can manage them all without touching a prefix key.

- **Overview (⊞):** every window as a live thumbnail. Tap to jump; long-press to rename, close, or start a new one.
- **New window (+):** give it a name and, optionally, commands to run, such as `ssh gmktec` then `claude`. Save it as a **template** to recreate it in one tap.
- **Sizing:** the window you're viewing fits the device you're holding, and your laptop gets its size back when you leave.
- **Dots on tabs:** blue means new output, red means a bell.

## Notifications

E.T. pings your phone when something needs you, even when the app is closed.

- **A long command finishes:** any shell command that ran 15 seconds or more.
- **Claude is done or waiting:** the notification quotes the start of Claude's last message.
- **Tap the notification:** E.T. opens on exactly that window, even from the lock screen.
- **While E.T. is open:** no push; you get a buzz and a banner instead, and tapping the banner jumps to the window.
- **No pile-ups:** a newer alert from the same window replaces the older one.

## iPad and keyboard shortcuts

On a full-width iPad, your windows live in a sidebar; the ▤ button hides it, and E.T. remembers your choice. With a hardware keyboard:

| Keys | Action |
| --- | --- |
| ⌘[ / ⌘] | Previous / next window |
| ⌘1 … ⌘9 | Window by position |
| ⌘T | New window |
| ⌘K | Open the editor |
| ⌘O | Overview |
| ⌘\\ | Show or hide the sidebar |

Hold ⌘ anywhere to see the list. Every other key, including Ctrl and Esc, goes straight to the terminal.

## Behind the scenes

E.T. keeps the connection alive for you, so there's rarely anything to manage.

- **Opens where you left off:** launches straight into your last server, session, and window.
- **Reconnects itself:** after switching networks or coming back to the app, the last screen stays dimmed until it's live again.
- **Tailscale approval:** when Tailscale asks you to confirm it's you, tap **Approve in browser**; E.T. waits and finishes the login.
- **Which build am I on?** The small grey label in the header, such as `b 10-15 21:45`.
- **Something off?** ⋯ → Debug log → Share.
