# Plan: file sharing between every member of the network

Status: 2026-10-23. D1 ACCEPTED: iroh-blobs (the building blocks of [sendme](https://github.com/n0-computer/sendme), not the sendme binary). D3 ACCEPTED with a change: files land in a top-level folder in the home directory (`~/etd-downloads/`). Owner priority: the main use is to **send files to machines and point a Claude session there at them**. A file view on the phone or iPad is nice to have (phase 2). D2 and D4 apply only to phase 2.

F0 DONE on Linux (etd branch `spike/f0-blobs`, c135142): the receiver pulls over the **sender's own connection** (§4.1); a 200 MB folder, cut at 50 %, finished with only the missing 50 % (second pull 104.8 MB, 0.4 s on localhost); a hash the sender did not offer is refused; the tree comes out whole. The new crates with OS code (redb, reflink-copy, positioned-io, iroh-io) compile for `aarch64-apple-ios` and `-ios-sim`; blake3 and ring were already in the app. F0 DONE on the Mac too (2026-10-23): `build-ios.sh` passes; `blobs_spike` passes on macOS (second pull 104.8 MB in 0.54 s); ET and ET-mac Debug both link; EtLinkFFI.xcframework +0.4 MB (224,548 KB → 224,972 KB). F1 + F2 DONE and DEPLOYED (F5 DONE: et-ios cbe00eb, Mac app on the real `sendFiles`, stub removed, tested to trigkey; Vendor/etd at d28ace0, bump to 159d559 for F4) (F3 DONE: etd d28ace0, et-link `sendFiles`, Swift signature checked against the stub) (F4 DONE: etd v0.0.4 159d559, `etd send … machine:session` and `Deliver { session }` type the paths; attach at the current size, so no resize; DEPLOYED trigkey + gmktec, nixos-config ed9e461; owner test PASSED: `etd send … gmktec:claude` typed the path into the real Claude prompt) (etd v0.0.3 eda781c on trigkey + gmktec, nixos-config 2559164; a 50 MB folder trigkey → gmktec in 0.5 s, checksum equal; mac-mini and m1-air not updated yet): `etd send <path>… <machine>`, tests pass, Nix package builds.

Follows [PLAN-network.md](PLAN-network.md) and [PLAN-macos.md](PLAN-macos.md). Work split as in those plans: **A** = the trigkey Claude session (etd, et-link), **B** = the Mac agent (apps, extensions, builds), **C** = the owner (tests).

## 1. Goal

Move a file to the machine where a Claude session needs it, and put its path in that session, in two taps or one command. No scp, no ssh keys.

**Phase 1 (the main use): files to machines, into sessions.**

| From | To | How the owner does it | Result |
|---|---|---|---|
| iPhone / iPad, in a session | that session | Paperclip in the key row (or "Open in E.T." / share sheet → E.T. → pick a session) | File in `~/etd-downloads/` on the session's machine; its path typed into the session (no Enter), so you add the question |
| Mac app | a session | Drag the file onto the terminal, or onto a session in the sidebar | Same |
| Mac app | a machine | Drag the file onto a machine in the sidebar | File in `~/etd-downloads/` there; path shown, copy button |
| A terminal or a Claude session on a machine | another machine, or a session there | `etd send report.pdf gmktec` / `etd send ./out gmktec:claude` | Same; folders keep their tree; `etd send` prints the path(s) on the target |

The last row lets one Claude session hand files to another: Claude on trigkey runs `etd send diff.patch mac-mini:claude`, and the path appears in the mac-mini Claude prompt.

**Phase 2 (nice to have): files to the phone and iPad.** `etd send shot.png iphone` → a push to that device only → a tap opens it in Quick Look. A Files screen lists what was received.

## 2. Facts that decide the design (checked 2026-10-23)

| Fact | Where | Effect |
|---|---|---|
| sendme is a CLI only (one `src/main.rs`), built on iroh-blobs 0.103.1 + `iroh ^1.0`. The sender serves until the receiver pulls with a ticket; each send uses a new random key; anyone with the ticket can fetch. | github.com/n0-computer/sendme v0.37.1 | Use its parts (iroh-blobs `Collection`, `BlobTicket`, `FsStore`, import/export), not its binary or its access model. |
| iroh-blobs 0.103.1 builds with etd's iroh 1.4.1. `PushRequest` is marked experimental, and the pusher does not learn when the receiver refuses. `provider::handle_connection` serves on **any** connection, also one this side opened; `remote().fetch(conn, …)` asks only for what the local store does not have. | crates.io, iroh-blobs source, F0 test | The sender serves on its own et/1 connection; the target pulls. No push, no new ALPN, no access hook on the machine: et/1's member check covers it. |
| Devices (iPhone, iPad, Mac app) only dial out; et-link has no accept loop. Machines run etd all the time. | `et-link/src/lib.rs` | Phase 1 works because the device serves on the connection it opened. Phase 2 needs files for a device to wait on a machine (D2). |
| `Upload { path, len }`: max 32 MiB, the whole file in memory, writes to `~/.cache/et-uploads`. | `et-proto`, `etd/src/ops.rs` | Replaced for files by iroh-blobs. Kept for now; removed when phase 1 is done (no users, no compatibility work). |
| A manymux session in the iOS app accepts **images only** (`attachment.paste`): "Only images can go to a manymux session". On the Mac, other files go to `~/.cache/et-uploads` with `Upload`. | `SessionController.swift:2255`, `SessionTerminal.swift:300` | Phase 1 removes this limit: any file, any size, any session. Images keep the paste path (Claude Code shows them inline). |
| manymux has no CLI command to type into a session. The app types with its `MmAttachment` (et-link `mm.rs`). | `mm --help`, et-link | The app types the path itself. For `etd send … machine:session`, etd must type through manymux's agent protocol without resizing the session: F4 checks it first. |
| A new request at the end of the `Request` enum keeps `et/1`. | `PROTOCOL.md` | Add requests; no ALPN change. iroh-blobs streams run inside the et/1 connection (F0). |

## 3. Decisions

| # | Question | Decision |
|---|---|---|
| D1 | Transfer protocol | **ACCEPTED: iroh-blobs**, inside the et/1 connection (F0), so members only. The control messages (what, where, which session) stay on et/1. Folders are a `Collection`, so the old D5 (zip) is gone. Resume and BLAKE3 checks come with it. |
| D2 | (Phase 2) How does a file reach a phone or tablet? | Recommended: the file waits in a machine's blob store, tagged for the device; a push goes to that device only; the app fetches when it opens. |
| D3 | Where do files land on a machine? | **ACCEPTED: `~/etd-downloads/`**, a top-level folder in the home directory, lower case so it is easy to type in a shell (`ETD_DOWNLOADS` changes it). A folder keeps its name and tree: `~/etd-downloads/out/…`. A name clash gets ` (2)`, ` (3)`. Short paths, so a Claude prompt stays readable. |
| D4 | (Phase 2) How long does a machine keep a device's file? | Recommended: until the device has it, at most 7 days. |

## 4. Design

### 4.1 One send, step by step

```
sender (app or etd)                          target machine's etd
1. import file/folder into own FsStore
   by reference (no copy) as a Collection
2. serve that one root hash on its own
   et/1 connection (provider, intercept)
3. ── et/1 Deliver { hash, name, session } ─▶ (the et/1 member check, as always)
4.                        ◀── iroh-blobs GET ─ fetch(conn, root): asks only for
   ── the missing chunks ───────────────────▶   the chunks it does not have
5.                                            export to ~/etd-downloads/, drop the blob
6. ◀── Delivered { paths, typed } ──────────
7. type "<paths> " into the session (app), or print them (etd send); clean own store
```

- If the connection breaks, the sender sends `Deliver` again; step 4 fetches only the rest (F0: cut at 50 %, the second pull read 50 %).
- The sender serves only the hash it is delivering; other requests get `Permission` (F0).
- The target refuses a `Deliver` that leaves less than 2 GB free on its disk (the Collection's sizes are known before the pull).

### 4.2 Protocol (et/1, appended)

```
Request::Deliver  { hash: [u8;32], name: String, session: Option<String> }   // 17
Response::Delivered { paths: Vec<String>, typed: bool }
```

- `session: None`: export only. `session: Some(name)`: export, then type the paths into that manymux session on this machine (F4). `typed` says whether that worked.
- Members only, as every other request.

### 4.3 etd

- `crates/etd/src/files.rs`: `FsStore` under the state directory (`blobs/`), the fetch on the `Deliver` connection, the provider side for `etd send` (on etd's outgoing connection), export to `~/etd-downloads/` (D3), clean-up of blobs with no tag at start and each hour.
- CLI (sends through the local etd over its socket, as `etd-ssh` does):
  - `etd send <path>… <machine>[:<session>]`. A path can be a file or a folder. Progress on stderr. Prints the paths on the target, one per line, so Claude can read them.
  - Names: machine names from `etd members`; `<session>` is the manymux session name on that machine.

### 4.4 et-link (Rust, shared by both apps)

- `Link.send(paths: [String], machine endpoint, name, session: Option<String>, progress) -> Delivered`: import into a temporary FsStore in the app's caches folder, push, `Deliver`, clean up.
- `progress`: a uniffi callback (`on_progress(done, total)`), at most 10 times a second.
- Cancel = drop the Swift `Task`; the next send of the same file resumes.

### 4.5 Apps (phase 1)

- **iOS session**: the key row's file/photo action and "Open in E.T." use `Link.send` with the window's machine and session. Any file type, any size. Images to a Claude session can still use `attachment.paste` (inline image); everything else is a send + typed path. The `~/.cache/et-uploads` code goes.
- **iOS share sheet** (share extension, App Group): pick a machine, then optionally a session. Short files are sent by the extension. A large file is handed to the app through the App Group, and the app sends it.
- **Mac**: a drop on a terminal = send to that session; a drop on a sidebar machine = send to the machine, show the path with a **Copy** button. File → **Send File…** (⇧⌘S).

### 4.6 Phase 2: phone and iPad as receivers

- `etd send <path> <device>`: the local etd keeps the Collection in its own store with a tag for that device (D2, D4).
- New et/1 requests: `Inbox` (items for the caller's endpoint id, never someone else's) and `Done { hash }`. The app fetches with iroh-blobs `GetRequest` from that machine.
- Targeted pushes: the app writes its endpoint id into its device record (`~/.config/et/devices/*.json`); `NotifyFile { to, item }` (machines only) runs the push command with `ETD_KIND=file` and `ETD_TARGET`; `et-notify` sends only to that device.
- Files screen on iOS (Received list, Quick Look, Share, Save to Files).

### 4.7 Shared Files screen (owner choice A, 2026-10-23)

Owner: "see all the files that are shared amongst the individual screens instead of having it just be injected directly into the terminal". Sending to a session still types the path; this screen adds a place to see every file and use it again.

**What the owner sees** (Mac app and iPhone/iPad): one list, newest first, of everything sent to any machine. Each row: name, `from → to` (member names), when, size, a folder icon for a folder. Actions on a row:

| Action | What happens |
|---|---|
| Tap | Preview (Quick Look): the device fetches the file from the machine into its caches folder |
| Type into a session… | Pick a session on any machine. Same machine: etd types the path. Other machine: the file's machine sends it there first (no bytes through the phone), and the path is typed there |
| Send to… | Pick a machine: sent machine to machine |
| Copy path | The path on its machine |
| Delete | Removed from that machine's `~/etd-downloads/` and from the list |

**How it works**

- Each etd writes a line to `deliveries.jsonl` (state directory) for each delivery: top-level path, size, folder or file, sender's member id and name, session, typed, time. No replication: the app asks every machine and merges the lists.
- A row whose path is gone from disk (the owner deleted it) is not shown.
- Bytes from a machine to a device: et/1 request `Blobs` makes the rest of its stream an iroh-blobs request, served by etd's provider with the same "offered hashes only" rule. So a device can fetch over the connection it opened, and nothing new listens.

**Protocol (et/1, appended)**

| # | Request | Answer |
|---|---|---|
| 19 | `Shared` | `SharedList([SharedItem { path, name, size, is_dir, from, from_id, received, session }])` |
| 20 | `Offer { path }` (inside `~/etd-downloads/`) | `Offered { hash, total }`; the offer lasts while this stream is open |
| 21 | `Blobs` | then an iroh-blobs request on the same stream |
| 22 | `Share { path, to, session }` | `to` = this machine: type into `session`. Else send to `to` (as `etd send`), typed there. `Delivered` |
| 23 | `Unshare { path }` | `Pong`; the file or folder and its log line are removed |

**et-link**: `sharedFiles()`, `fetchFile(path, into, progress) -> local path`, `shareFile(path, to, session) -> Delivered`, `unshareFile(path)`.

**CLI**: `etd files`: the list of every machine, as the app shows it.

## 5. Work

### Phase 1: files to machines and sessions

| Step | Owner | What | Done when |
|---|---|---|---|
| F0 | A | Spike: iroh-blobs 0.103.1 + `FsStore` in et-link builds for iOS (device + simulator) with the netdev patch; push from a test endpoint into a test etd store | `scripts/build-ios.sh` passes; a 200 MB push arrives. If iOS fails: stop and ask the owner (fallback = the et/1 `Put` design, git history of this file) |
| F1 | A | etd: `files.rs`, blobs handler with member check, `Deliver` with `session: None`, names in `~/etd-downloads/`, clean-up, PROTOCOL.md. Tests: file and folder delivered; resume after a cut at 50 %; a non-member is refused | `cargo test` passes |
| F2 | A | `etd send <path>… <machine>` | From trigkey, a folder lands in gmktec's `~/etd-downloads/`; deployed to trigkey + gmktec; etd tagged `v0.0.3` |
| F3 | A | et-link `Link.send` with progress and cancel | et-link test: send from disk, resume after cancel |
| F4 | A | `Deliver { session: Some }` and `etd send … machine:session`: type the paths into a manymux session through the agent protocol, without resizing it. Check manymux's protocol first; if typing needs an attach that resizes, report to the owner before building | `etd send x.png mac-mini:claude` from trigkey puts the path in the mac-mini Claude prompt |
| F5 | B | Mac app §4.5 (drop on terminal, drop on machine, ⇧⌘S); remove `~/.cache/et-uploads` | Drag a 1 GB file onto a gmktec session in the Mac app: path typed, progress shown |
| F6 | B | iOS session send (§4.5 first point), remove the images-only limit | A PDF from Files into a trigkey Claude session from the iPhone: path typed |
| F7 | B | iOS share extension (§4.5 second point); TestFlight | Share sheet → E.T. → gmktec → claude works from Photos and Files |

Time: F0 half a day, F1 1 day, F2 half a day, F3 half a day, F4 half a day (more if manymux needs a change). F5 about 1 day, F6 half a day, F7 about 1 day. **First useful point: F0–F2**, about 2 days: `etd send` between machines, from any terminal or Claude session. Phase 1 in total: about 5 days.

### Shared Files screen (§4.7)

| Step | Owner | What | Done when |
|---|---|---|---|
| S1 | A | etd: delivery log, `Shared`, `Offer`, `Blobs`, `Share`, `Unshare`, `etd files`; et-link API; tests; deploy | `etd files` on trigkey lists files on trigkey and gmktec; et-link test fetches one |
| S2 | B | Mac app: a Files section in the sidebar with the list and actions | Owner sends from the phone, sees it on the Mac, types it into another session |
| S3 | B | iOS app: a Files screen (same list, Quick Look, actions) | Owner previews a PDF sent from the Mac |

Time: S1 about 1 day, S2 about 1 day, S3 about 1 day.

### Phase 2: phone and iPad as receivers (nice to have)

| Step | Owner | What |
|---|---|---|
| G1 | A | Device tags, `Inbox`, `Done`, 7-day sweep, `NotifyFile` + `ETD_TARGET`, et-notify filter |
| G2 | B | iOS Files screen, fetch on open and on push tap, Quick Look |

Time: about 2 days.

## 6. Tests (owner, C)

1. From a trigkey terminal: `etd send ~/some-folder gmktec`; check `~/etd-downloads/some-folder` on gmktec.
2. From the iPhone in a gmktec Claude session: send a PDF; the path is in the prompt; ask Claude to read it.
3. iPhone on cellular only (relay path): the same as test 2 with a 100 MB file.
4. Mac app: drag a 1 GB file onto a session; turn Wi-Fi off and on halfway; the send resumes.
5. From the trigkey Claude session: `etd send notes.md mac-mini:claude`; the path appears in the mac-mini Claude prompt.

## 7. Risks

- **iOS build of iroh-blobs** (redb, more crates next to the netdev patch). F0 finds out before other work.
- **Disk use**: a send uses the disk twice for a moment (the sender's store and the file). The app's store is in the caches folder and is cleaned after each send.
- **Relay speed**: away from home with no direct path, files go through the n0 relays (rate-limited). The progress view shows direct / relay.
- **Typing into a session** (F4) can collide with what the user types at that moment. The path ends with a space and no Enter, so nothing runs by itself.
- **Version skew**: a machine with an etd older than v0.0.3 does not speak the blobs ALPN. The app shows "etd too old" for that machine (the version comes from `Hello`).
