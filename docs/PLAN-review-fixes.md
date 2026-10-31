# Plan: et-ios review fixes (package R1, track B)

Status: R1: DONE 544543e, TestFlight 202610312032, Mac release mac-202610312036 (mac-mini; "Result" at the end). Owner: the **mac-mini** agent (track B, PLAN-logbook-v2 §6 rule 4). Claim it the same way: change this Status line to "R1: IN PROGRESS (mac-mini)", commit, push.

Source: `review-etd-and-et-ios.md` (2026-10-31, reviewed at et-ios `e5b70fe`). Each finding below was re-checked on et-ios `eba7b3a`; line numbers are from that commit. The etd side of the review is handled separately (etd 0.0.18: issues 2–7 and 10; issues 1 and 9 next). Nothing here needs an etd change.

Do it **after** the Logbook v2 B package you are on, not inside it. Issues 1 and 2 touch `App/LogbookUI/Logbook.swift`, which Logbook v2 also uses: do them in one commit and pull first.

Time: about 1 day for all 8. Order = priority.

## Must

### 1. Logbook cursor comes from the device clock — `App/LogbookUI/Logbook.swift:111`

After a successful `logbookSessions`, `lastList = UInt64(Date().timeIntervalSince1970)`; the next poll sends it as `since`. etd filters `changed.max(last) >= since` on **the archive's** clock (`crates/etd/src/logbook/store.rs` `list`). A device clock ahead of the archive freezes the list on the first snapshot. Even with synced clocks, a change that lands between the archive building the list and this assignment is never fetched.

Fix: take the cursor from the answer, not the device: the max of `changed` / `last` over the returned sessions (or keep the previous cursor if the answer is empty), and rely on `>=` so the boundary row comes back (merging it is idempotent). The overview and signals polls (lines 90 and 138) also take `since` from `Date()` (before the call, so no gap, but still the device clock): give them the same treatment.

Test: set `lastList` from a list whose newest `changed` is T; the next call sends `since == T`, not now.

### 2. Cursor survives a change of archive host — `SessionController.swift:1589` (`archiveHost()`), `Logbook.swift:108`

`archiveHost()` returns the first connected archive, else the hub. The cursor is not tied to the host it came from. If the hub answers first and the preferred archive connects later, the polls to the archive are incremental against the hub's cursor and miss sessions only the archive has. The Mac has the same fallback (`App/Mac/Sources/Fleet.swift`, `archiveHost`).

Fix: store the endpoint id the cursor was read from. When `archiveHost()` returns a different host, set the cursor to 0 and **replace** `sessions` instead of merging.

### 3. Share extension sends multi-GB folders itself — `App/ShareExtension/ShareModel.swift:68`

`totalBytes += fileSizeKey` of each copied item. For a folder or package that is the directory entry, not the tree, so a large folder counts as a few hundred bytes, `isLarge` (line 53, `> ShareStore.extensionLimit` = 25 MB) is false, and the extension sends it itself — the path iOS kills mid-send.

Fix: for a directory, walk it (`FileManager.enumerator`) and sum `totalFileAllocatedSize` (or `fileSize`) of every regular file. Decide on that sum.

Test: share a folder with one 30 MB file → it is parked (`ShareStore.addJob`), not sent from the extension.

### 4. Cancel deletes files under a running send — `ShareModel.swift:177`

Cancel calls `task?.cancel()`, closes the host on a detached task, deletes the temp copies at once and completes the request. `sendFiles` may still be importing them by reference (`ImportMode::TryReference`; et-link `send_files` says keep the files until it returns). The send can still be delivered after the sheet is gone, or fail with nobody to show it.

Fix: on Cancel, cancel the task and close the host, then **await** the send task (success, failure or cancellation) before deleting the temp folder and calling `completeRequest`. Show "Cancelling…" meanwhile.

### 5. Push suppression stays armed after backgrounding — `SessionController.swift:468`, `:1647`, `:1652`; `AppModel.swift` `scenePhaseChanged`

The app re-arms `foreground(seconds: 60)` every 20 s. On background, `disconnect()` sends `foreground(seconds: 0)` from an unstructured `Task` with no `beginBackgroundTask`, so iOS can suspend before it is sent: pushes stay muted up to 60 s. Also, the per-member `Task { try? await member.foreground(seconds: 60) }` (line 1652) is not a child of `heartbeatTask`, is not cancelled by `disconnect()`, and can land **after** the `foreground(0)`.

Fix: wrap the shutdown in `beginBackgroundTask`; await `foreground(0)` (and the heartbeat-file `rm`) on the hub and every `mmHosts` entry before closing. Make the per-member calls children of `heartbeatTask` (a `withTaskGroup` inside the loop). Do not start a `foreground(60)` once disconnect has begun (a flag checked before each call).

Test (owner): open E.T., background it, trigger an agent notification within 10 s → it arrives.

## Should

### 6. Notification opens the hub for a member named like the hub's hostname — `SessionController.swift:1603`

`mmMachineName(for:)` maps `name == hubHostName` to the hub **before** checking whether `name` is already a member name. `ETD_MACHINE` in a push is the member name. If another machine's member name equals the hub's current `gethostname()`, the tap opens the hub.

Fix: swap the order: `if mmHostNames[name] != nil { return name }` first (also accept `hubName` and `networkMachines` names), then the `hubHostName → hubName` alias.

### 7. Older etd on a non-hub machine never gets the heartbeat fallback — `SessionController.swift:1648–1652`

Only the hub's `foreground` call falls back to `heartbeatTouchScript` on error; other members use `try?` and do nothing. Shows only on a mixed fleet.

Fix: on a member's `foreground` error, run the same heartbeat script on that member via `mmRun`, and clear it in the shutdown path of item 5.

### 8. Quick Look cache path uses the raw machine name — `App/FilesUI/SharedFiles.swift:95`

`cacheFolder.appendingPathComponent(item.machine)`. etd allows `.` and `..` as machine names (`[A-Za-z0-9._-]`), so `..` writes the preview outside the cache.

Fix: reject empty, `.`, `..` and names with `/` (or use a hash of the name as the folder). After `fetchFile` returns, refuse a URL that is not under `cacheFolder` (`standardizedFileURL.path.hasPrefix`).

## Added 2026-10-31: the follow-up review (Logbook v2 UI)

From `review-etd-et-ios-followup-2026-10-31.md`. The etd side is done in **etd 0.0.24** (gmktec deployed): `fresh` no longer applies a change twice, `@` imports of settings / keys are never listed or writable, `ConfigWrite`s of one file no longer interleave. 0.0.24 also adds two JSON fields the app can use (read with `decodeIfPresent`): `targets[].route` (`write` / `agent` per machine; the proposal's `route` is `agent` only when every target is) and `proposals[].undo` (`machine`, `path`, `base`, `content`: Undo = `configWrite(path, base, content)` for a machine already in `applied`). Line numbers below are from et-ios `9e9d7de` (after B7).

Do 9 and 10 before more auto-apply: with etd's `fresh` fix they close the path where a finding becomes a wrong file and then looks finished.

### 9. Auto-apply marks a proposal done before the write succeeds, and writes proposals for one file at once — `App/LogbookUI/LogbookFindings.swift:120–128`, `apply` at `:143`

`applyAll` inserts `run.id|proposal.key` into the UserDefaults `done` set, then `apply` sends `configWrite` for every target in parallel. Two `write` proposals for one path carry the same base: one wins, the other is refused, and `done` keeps it from being retried. An offline machine, a stale base or a failed `metaDecision` ends the same way; after a restart the Retry state is gone. `decide` stamps `self.run.id` when it sends, so an apply still running when the next run arrives is recorded against the new run.

Fix: add to `done` only after `configWrite` **and** `metaDecision` succeed. On each load, write what the response still lists in `targets` (etd 0.0.24 rebuilds them against the files as they are). Apply proposals that share a `path` one at a time, reloading between them. Pass the run id that was loaded into `decide`. Skip targets whose `route` is `agent`.

### 10. A finished apply shows "Not applied" — `LogbookFindings.swift:468`

The status counts machines still in `targets`; etd moves a machine that has the change to `applied` and drops its target. After a successful apply (or when another device wrote it) `targets` is empty and the card says "Not applied". Fix: show "Applied on …" from `proposal.applied`; "Not applied" only when a target is outstanding.

### 11. Closing one Logbook window stops polling for all — `App/LogbookUI/Logbook.swift:70` (`watch()`)

`watch()` returns at once if another caller runs it, and the owner's `defer` clears `watching` when its task ends. The Mac starts it from every main window and from the Logbook window; closing the window that won stops the 5 s poll, the report reload and auto-apply for the others. Fix: one loop owned by `Logbook`, refcounted; cancel at zero.

### 12. A failed grouping accept is never retried — `Logbook.swift:234–235`

`accepting.insert(proposal)` happens before `logbookGrouping` returns; on failure it stays, so `loadReport` skips the proposal until the app restarts. Fix: insert after success, or remove it in the `catch`.

### 13. The sidebar "needs you" count is always 0 — `App/Mac/Sources/LogbookSidebar.swift:34`

It counts `session.status == "needs-you"`; status is `busy` / `idle` / `gone`. Count from `Logbook.state` (`LogbookPlaces.swift`), which the cards use.

### 14. Comments that retell the plan — `LogbookFindings.swift`, `Logbook.swift`

Drop the dates and the allow-list tour; keep one line where behavior surprises (etd drops finished targets).

Also: the reviewer found the worktree's `Vendor/etd` checked out at `5192f1c`, older than the committed pin. `git submodule update` before building.

## When done

Change the Status line to "R1: DONE <commit>, TestFlight <build>" with one line per item (fixed / skipped and why), and push.

## Result (2026-10-31, mac-mini)

1. Fixed: the list cursor is the newest `last` in the answer (the archive's clock, `>=` repeats the boundary row); overview and signals take the list's cursor read before their call.
2. Fixed: the cursors belong to one archive host object; another host (or a reconnect) starts from 0 and replaces the list. Shared by iOS and Mac.
3. Fixed: a folder or package counts the size of every regular file in it.
4. Fixed: Cancel shows "Cancelling…", closes the host, waits for the send task, then deletes the copies and closes the sheet.
5. Fixed: the shutdown runs in a background task, waits for the heartbeat task (whose per-machine calls are now its children), then sends `foreground(0)` + clears the heartbeat file on every machine.
6. Fixed: a member name wins over the hub's host-name alias.
7. Fixed: every machine falls back to the heartbeat file on a `foreground` error; the shutdown clears it on every machine.
8. Fixed: `""`, `.`, `..` and names with `/` are refused, and a fetched file outside the cache is refused.
9. Fixed: one write per file per read, targets with `route: agent` skipped, `done` only after `configWrite` and `meta_decision` both succeed (a failed target waits 10 min), decisions carry the loaded run's id. Undo uses `proposals[].undo` (etd 0.0.24).
10. Fixed in 88f2f12: "Applied on" from `applied` ∪ follow-up ∪ this device's writes.
11. Fixed: one poll loop owned by `Logbook`, counted by watchers, cancelled at zero.
12. Fixed: a failed accept is removed from `accepting`; every report load (each minute) sends it again.
13. Fixed: counted from `Logbook.state`.
14. Fixed: plan tags and dates dropped from the Logbook comments.

Checked: iOS and Mac build; Mac headless on the real archive (25 sessions, live card updating). Not checked: 3, 4, 5, 7 need the phone (share sheet, backgrounding).
