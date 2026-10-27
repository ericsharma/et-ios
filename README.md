# E.T.

Your terminal sessions on iPhone, iPad and Mac. Every machine you own, one tap away. No VPN, no open port, no ssh keys.

| Part | What it is |
|---|---|
| **E.T. for iPhone and iPad** | The client. Each tmux window or manymux session is a full-screen terminal, with voice input, push when a command or Claude is done, and file sharing. [TestFlight](https://testflight.apple.com/join/TODO) <!-- TODO: public TestFlight link --> |
| **E.T. for Mac** | A client too, and it runs etd for you. One app makes the Mac a machine of your network. [Download](https://github.com/ericsharma/et-ios/releases/latest) |
| **[etd](https://github.com/ericsharma/etd)** | The daemon on each machine (Linux or macOS). It connects your devices over [iroh](https://iroh.computer). |

## Try it in 2 minutes

**On a Mac:**

1. Download [E.T. for Mac](https://github.com/ericsharma/et-ios/releases/latest), move it to Applications, and open it.
2. Click **Make this Mac a machine**, then **Start a new network**.
3. Scan the QR code with the iPhone camera.

**On Linux (or a Mac without the app):**

```sh
curl -fsSL https://raw.githubusercontent.com/ericsharma/etd/main/install.sh | sh
~/.local/bin/etd invite    # scan this QR code with the iPhone camera
```

Then run `mm new -n hello` on the machine. The session shows on the phone.

More machines: run `etd invite --machine` on one machine of the network, then the printed `etd join <link>` on the new one. In E.T. for Mac, click **Join a network** and paste the link.

## Requirements

iOS 18, macOS 15, or Linux (aarch64 or x86_64).

## Docs

- [Field guide](docs/GUIDE.md): every button, gesture and shortcut in the app
- [etd](https://github.com/ericsharma/etd): commands, security, Nix install

## Build

Needs Xcode and rustup (`stable-aarch64-apple-darwin`).

```sh
git clone --recursive git@github.com:ericsharma/et-ios.git && cd et-ios
scripts/build-link.sh       # builds EtLink from Vendor/etd
open App/ET.xcodeproj       # targets: ET (iOS), ET-mac
```
