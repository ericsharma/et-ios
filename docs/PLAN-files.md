# Plan: file sharing between every member of the network

Status: 2026-10-23, draft. Decisions D1–D5 wait for the owner.

Follows [PLAN-network.md](PLAN-network.md) and [PLAN-macos.md](PLAN-macos.md). Work split as in those plans: **A** = the trigkey Claude session (etd, et-link), **B** = the Mac agent (apps, extensions, builds), **C** = the owner (tests).

## 1. Goal

Send any file from any member to any other member of the network, in two taps or one command. No scp, no ssh keys, no AirDrop limits (Linux machines, away from home).

| From | To | How the owner does it |
|---|---|---|
| iPhone / iPad | a machine | Share sheet → **E.T.** → tap `trigkey`. The file is in `~/Downloads` on trigkey. |
| iPhone | iPad (or back) | Share sheet → **E.T.** → tap `iPad`. A push on the iPad; a tap opens the file. |
| Mac (app) | anything | Drag the file onto a member in the sidebar, or Finder → Share → **E.T.** |
| A machine's terminal | anything | `etd send report.pdf iphone` / `etd send -r ./out gmktec` |
| Any machine | the phone | Same command. A push on the phone; a tap opens the file in Quick Look. |

## 2. Facts that decide the design (checked 2026-10-23)

| Fact | Where | Effect |
|---|---|---|
| Machines run etd all the time. Devices (iPhone, iPad, the Mac app) only dial out; et-link has no accept loop, and iOS stops the app in the background. | `et-link/src/lib.rs` (`Link::start`, `dial`), iOS rules | A device cannot be a receiver that waits. Files for a device wait on a machine (an **inbox**), and the device collects them. |
| The app already connects to every machine of the network directly. | `Fleet.swift`, `SessionController` | A device can check every machine's inbox with no new routing. |
| `Upload { path, len }` exists: max 32 MiB, the whole file in memory on both sides (`Vec<u8>` / `Data`), no resume, no progress, writes only under `$HOME`. | `et-proto`, `etd/src/ops.rs`, `Iroh.swift` | Good for pasted images. Not good for a 2 GB video. New requests stream from and to disk. |
| A new request at the end of the `Request` enum keeps `et/1`. A new field in `Note` is a new ALPN. | `PROTOCOL.md` | Add requests; do not change `Note`. |
| Pushes go to **every** device token in `~/.config/et/devices/` on the machine with the push command. | nixos-config `home/trigkey/et-notify.nix` | "File for the iPad" would also buzz the iPhone. The device record needs its endpoint id, and the push needs a target. |
| iroh-blobs 0.103.1 depends on `iroh ^1.0`, so it builds with etd's iroh 1.4.1. | crates.io | D1 has a real second option. |
| The iOS app already accepts "Open in E.T." for any file (`CFBundleDocumentTypes`), and the Mac app accepts dropped files on a terminal. | `project.yml`, `AppModel.swift:93`, `SessionTerminal.swift:300` | The entry points exist; they only type a path into a terminal today. |
| A share extension is a separate process with a memory limit (about 120 MB on iOS) and a short life. | Apple rules | The extension must stream from disk, and must hand an unfinished send to the app (resume, §4.4). |

## 3. Decisions for the owner

| # | Question | Recommended | Other choice |
|---|---|---|---|
| D1 | Which transfer protocol? | **New et/1 requests** (`Put`, `Fetch`, `Inbox`, `Drop`): streams from disk, resume by offset, BLAKE3 check at the end. The same access check (members only) as every other request. About 1 day. | **iroh-blobs**: verified streaming, resume and dedup for free, but a second ALPN, a blob store (redb) in etd and in the app, its own access control (it serves any hash to any peer unless we add a filter), and a new iOS build risk next to the netdev patch. About 3 days. |
| D2 | How does a file reach a phone or tablet? | **Inbox on a machine + targeted push.** The sender puts the file on a machine it reaches (its own Mac, or the best-path machine). The device lists the inbox of every machine when it opens, and after the push. | Direct device-to-device only when both apps are open. Fast on the same Wi-Fi, but fails for a phone in a pocket. Later as an extra path (F8). |
| D3 | Where do files land on a machine? | **`~/Downloads`**, with ` (2)`, ` (3)` on a name clash. `etd send` prints the path on the receiver. A setting `ETD_DOWNLOADS` changes it. | `~/Downloads/E.T./`: tidier, but one more folder to open. |
| D4 | How long does an inbox keep a file? | **Until the device has it (it sends `Drop`), at most 7 days.** A machine also refuses a `Put` that leaves less than 2 GB free. | Keep until the owner deletes it: the disk fills. |
| D5 | Folders? | **The sender makes one `.zip`** (iOS: `NSFileCoordinator` `.forUploading` does it; `etd send -r` and the Mac app use the zip crate / `ditto`). Machines unzip into `~/Downloads/<name>/`; devices keep the zip. | A tree protocol (one `Put` per file): more requests, partial folders on failure. |

## 4. Design

### 4.1 Protocol (et/1, appended)

```
Request::Put   { id: [u8;16], to: EndpointId, name, size, from_name }   // 17
Request::Fetch { id: [u8;16], offset: u64 }                             // 18
Request::Inbox                                                           // 19
Request::Drop  { id: [u8;16] }                                           // 20

Response::PutFrom   { offset: u64 }           // resume point; 0 for a new id
Response::Stored    { path: Option<String> }  // Some = landed in Downloads here; None = kept for a device
Response::Item      { item: InboxItem }       // Fetch: then size - offset raw bytes, then a trailer
Response::InboxList (Vec<InboxItem>)
InboxItem { id, name, size, from: EndpointId, from_name, sent: u64, blake3: [u8;32] }
```

`Put` on one bi-stream:

1. App → etd: `Put`. etd checks that `to` is a member and that the disk has room.
2. etd → app: `PutFrom { offset }`: the size of `<inbox>/<id>.part`, or 0.
3. App → etd: the bytes from `offset` to `size`, then a trailer frame `Done { blake3 }` (BLAKE3 of the whole file; the sender hashes while it reads, so it reads the file once; on a resume it hashes the first part again).
4. etd checks the hash, then:
   - `to` is this machine: move the file into Downloads (D3); answer `Stored { path: Some }`; run the push command with kind `file` for this machine's own notice (Mac: local notification through the app, D5 of PLAN-macos).
   - `to` is a device: keep it as `<inbox>/<to>/<id>` + `<id>.json`; answer `Stored { path: None }`; send a file push to that device (§4.3).
   - `to` is another machine: refuse. The sender connects to that machine itself (every member can).

The peer id comes from the connection, never from the request: `Inbox`, `Fetch` and `Drop` only see files whose `to` is the caller. `Upload` stays as it is for pasted images.

### 4.2 etd

- `crates/etd/src/files.rs`: the store under the state directory (`inbox/<endpoint>/`), `.part` files, the 7-day sweep (each hour), the free-space check, Downloads names (D3), unzip of folders (D5). When the network document removes a member, etd deletes that member's inbox.
- CLI, through the local socket (as `etd-ssh`):
  - `etd send <file>… <member>`: member = a machine name or a device name from `etd members` (case-insensitive; `iphone` matches `Eric's iPhone` when only one device matches). Progress on stderr. To a machine: the local etd connects to it and sends `Put`. To a device: the local etd keeps the file in its own inbox.
  - `etd send -r <dir> <member>`: zip on the fly (D5).
  - `etd inbox`: what waits on this machine, per device, with age; `etd inbox --clear`.
- The local socket gets a `SendFile { path, to }` request so the CLI does not read the file into the socket: etd reads the path itself (the socket is 0600, same user).

### 4.3 Targeted pushes

- The app adds its endpoint id to the device record it writes to `~/.config/et/devices/<token>.json` (one line in `Push.swift`).
- New append-only request `NotifyFile { to: EndpointId, item: InboxItem }` (21, machines only), sent like `Notify` to every machine; a machine with a push command runs it with `ETD_KIND=file`, `ETD_TARGET=<endpoint id>`, `ETD_TITLE=<from_name>`, `ETD_BODY=<name> (<size>)`, `ETD_MACHINE=<machine that holds it>`, `ETD_SESSION=<id hex>`.
- `et-notify` (nixos-config) sends kind `file` only to the device records with that endpoint id; payload `{"file": {machine, id}}` for tap routing.
- `Foreground` holds a file push back as it holds bells: the open app collects the file itself.

### 4.4 et-link (Rust, shared by both apps)

- `RemoteHost.put_file(path, to, name, from_name, progress) -> Stored` and `fetch_file(id, dest_path, progress)`. Both read and write disk in 1 MiB chunks; nothing in memory. `progress` is a uniffi callback interface (`on_progress(done, total)`), called at most 10 times a second.
- `RemoteHost.inbox()`, `RemoteHost.drop_item(id)`.
- Cancel = drop the Swift `Task` (uniffi async cancel); the `.part` file stays for a resume.
- A small resumable queue in Swift (shared code in `App/Shared/Transfers.swift`): each send is a JSON record (file URL bookmark, target, id, machine) in the App Group container, so the app finishes what an extension started.

### 4.5 iOS app

1. **Share extension "E.T."** (new target `ET-share`, App Group `group.xyz.ericsharma.et`): a sheet with the members (machines first, then devices; offline ones grey). One tap sends. It shows progress, and it leaves the sheet open until the file is stored. If iOS ends the extension early, the queue record (§4.4) lets the app finish the send at its next start.
2. **Open in E.T.** (exists): before "type the path into a window", show the same member sheet. The terminal paste stays as one row: **Paste into <window>**.
3. **Files screen** (a tab next to Machines): **Received** (inbox items of every machine, auto-fetched into the app's Documents when the app opens or a push comes in), **Sending** (progress, retry). A row tap opens Quick Look; a long press: Share, Save to Files, Delete. `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` show the received folder in the Files app.
4. **Push tap** with `{"file": …}`: open the Files screen, fetch, then Quick Look.

### 4.6 Mac app

1. **Drop on a member**: the sidebar lists every member (machines and devices). A drop on a row sends to it, with a progress ring on the row.
2. **Send menu**: File → **Send File…** (⇧⌘S): file picker, then the member list. Also a Dock-icon drop.
3. **Finder share extension** (`ET-mac-share`, sandboxed as Apple requires; it passes the file to the app through the App Group queue and the app sends it, so the extension needs no network code).
4. **Receive**: a file for this Mac goes to its machine (the app's own etd), so it lands in `~/Downloads` even when the app is closed. When the app runs, a local notification; a click shows the file in Finder.
5. In the member list the Mac's own `m1-air app` device does not show: send to `m1-air` (the machine) instead.

## 5. Work

| Step | Owner | What | Done when |
|---|---|---|---|
| F0 | C | Accept or change D1–D5 | This file says so |
| F1 | A | et/1 `Put`/`Fetch`/`Inbox`/`Drop` + `files.rs` store, resume, BLAKE3 trailer, sweep, Downloads names. PROTOCOL.md. Tests: a 200 MB file to a machine and to a device inbox; a resume after the stream is cut at 50 %; a peer cannot fetch another device's item. | `cargo test` passes; etd tagged `v0.0.3` |
| F2 | A | `etd send` / `send -r` / `inbox` over the local socket | `etd send` from trigkey puts a file in gmktec's `~/Downloads`; deployed to trigkey + gmktec |
| F3 | A | et-link `put_file`/`fetch_file`/`inbox`/`drop_item` with progress callback; `NotifyFile` + `ETD_TARGET`; et-notify filter by endpoint id (nixos-config) | et-link test sends and fetches from disk; a test push reaches only one device |
| F4 | B | Mac app §4.6 points 1, 2, 4, 5 | Drag a 1 GB file onto `trigkey`: it lands in `~/Downloads` with progress shown |
| F5 | B | iOS app §4.5 points 2–4 + push device record with endpoint id | "Open in E.T." → iPad: the iPad gets one push, the iPhone none; tap opens Quick Look |
| F6 | B | iOS share extension + App Group queue (§4.5 point 1); TestFlight | Share a 500 MB video from Photos to `trigkey`; lock the phone halfway; the app finishes it at next open |
| F7 | B | Finder share extension (§4.6 point 3); notarized release | Finder → Share → E.T. → iPhone works |
| F8 | — | Later, only if wanted: direct device-to-device when both apps are open; clipboard text/URL send; a File Provider to browse a machine's `~` in the Files app | — |

Time: F1 about 1 day, F2 half a day, F3 half a day. F4 about 1 day, F5 about 1.5 days, F6 about 1 day (App Group and extension provisioning in ASC take the most time), F7 half a day. Total about 6 days. **First useful point: F1 + F2 + F3 + F4**, about 3 days: Mac drag-and-drop and `etd send` between machines, which already replaces scp.

## 6. Tests (owner, C)

1. `etd send` a file from trigkey to gmktec and to mac-mini; check `~/Downloads` there.
2. iPhone share sheet → trigkey, with Wi-Fi on, then on cellular only (relay path).
3. `etd send photo.jpg iphone` from gmktec; only the iPhone buzzes; tap opens it.
4. A 2 GB file Mac → iPad; turn Wi-Fi off and on halfway; the send resumes, not restarts.
5. Revoke the iPad (`etd revoke`): its inbox items are deleted on every machine.

## 7. Risks

- **Disk fill on a machine** from device inboxes: D4 limits it (7 days, 2 GB free minimum, `etd inbox --clear`).
- **Relay speed**: away from home with no direct path, files go through the n0 relays (rate-limited). Large files are slow there; the progress view shows the path (direct / relay) as the terminal header does.
- **Extension limits on iOS**: memory (stream from disk) and life time (queue + resume). The F6 test checks it.
- **Version skew**: a machine with an older etd answers `Error` to `Put`. The member sheet shows "etd too old" for it (the version comes from `Hello`).
