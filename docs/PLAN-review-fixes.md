# Plan: et-ios review fixes (package R1, track B)

Status: 2026-10-31. Not started (mac-mini is on an owner request first: auto-accept Logbook suggestions). Owner: the **mac-mini** agent (track B, PLAN-logbook-v2 §6 rule 4). Claim it the same way: change this Status line to "R1: IN PROGRESS (mac-mini)", commit, push.

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

## When done

Change the Status line to "R1: DONE <commit>, TestFlight <build>" with one line per item (fixed / skipped and why), and push.
