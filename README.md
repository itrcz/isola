<p align="center">
  <img src="Assets/IsolaIcon.png" width="128" alt="Isola icon">
</p>
<h1 align="center">Isola</h1>
<p align="center"><strong>A lightweight Swift app for a fast, comfortable macOS virtual machine.</strong></p>
<p align="center">Native controls. A quiet interface. Another Mac, a click away.</p>
<p align="center">
  <a href="https://github.com/itrcz/isola/releases/latest">Download</a> ·
  <a href="#getting-started">Getting started</a> ·
  <a href="#build-from-source">Build from source</a> ·
  <a href="docs/README.ru.md">Русский</a>
</p>
<p align="center">
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-24292f?style=flat-square">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple-Silicon-24292f?style=flat-square">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-477b85?style=flat-square"></a>
</p>

<p align="center"><img src="docs/screenshots/machine-dark.png" width="1100" alt="Isola in dark mode, with a macOS virtual machine and compact resource settings"></p>

Isola gives a macOS virtual machine a small, native home on your Mac. It is built
with **Swift, SwiftUI and Apple's Virtualization framework**, with a small Go
helper for SOCKS networking. No Electron shell or web interface.

## Made for everyday use

| Feature | What it does |
| --- | --- |
| **A minimal workspace** | Machine tabs, one-click startup, a collapsible settings panel, and light/dark appearance. Open settings with **⌘,**. |
| **Your choice of network** | Use the host connection through NAT or route through SOCKS5. Add IP, CIDR and domain rules for direct access. |
| **Copy across systems** | Share text, images and regular files between host and guest. |
| **One keyboard layout** | Bidirectional input-source sync. **⌘Space** switches both systems together while working in the guest. |
| **Your familiar folders** | Share Desktop and Downloads in both directions, or add folders individually with optional read-only access. |
| **Less visual overhead** | Reduce guest motion, transparency, blur and some animations. Turning optimization off restores the previous preferences. |
| **Room to grow** | Adjust CPU and RAM. Expand the disk and main APFS volume with an automatic backup and Recovery relocation. |
| **Recovery when needed** | Start the guest directly in macOS Recovery from its startup menu. |

<p align="center"><img src="docs/screenshots/integration-light.png" width="1100" alt="Isola in light mode, with guest performance, keyboard, clipboard and shared folder controls"></p>

## Getting started

**Requires an Apple Silicon Mac and macOS 14 or later.** Intel hosts and non-macOS
guests are not supported. Allow at least 45 GB of free space for downloading and
installing macOS; actual usage depends on the guest version and your files.

1. Download the **macOS arm64 ZIP** from [Releases](https://github.com/itrcz/isola/releases/latest).
2. Unzip it and move **Isola.app** to Applications.
3. Choose CPU, memory and disk capacity, then select **Direct** or **Proxy** networking.
4. Select an Apple Silicon `.ipsw` restore image, or let Isola download one from Apple.
5. Install macOS, start the VM and complete Apple's setup assistant.
6. Inside the guest, open **Isola Tools** and run **Install Clipboard.command** once.
   This enables clipboard, keyboard, folder and performance integration for that guest user.

Release builds are **ad-hoc signed and not notarized**. If Gatekeeper blocks the
first launch, use Apple's [Open Anyway instructions](https://support.apple.com/en-us/102445)
in **System Settings → Privacy & Security**. The release includes `SHA256SUMS.txt`
for checking the downloaded ZIP.

To update, shut down guest macOS and quit the previous Isola app before replacing it.
Your VM stays in its existing folder. Run the guest Tools installer again when an
update includes a new helper.

## A few useful details

### Networking

**Direct** uses Apple's NAT networking. **Proxy** uses SOCKS5 for guest IPv4 TCP
and DNS, with no automatic direct fallback. Enter a numeric proxy IP address;
username/password are optional. The password is stored in macOS Keychain.

Bypass rules go one per line:

```text
*company.com
10.0.0.0/8
203.0.113.5
```

`*company.com` matches the domain and its subdomains, not `evilcompany.com`.
Domain rules depend on the guest's DNS queries: encrypted DNS bypasses that
matching, and shared CDN IPs may affect other sites. SOCKS mode does not provide
general UDP/QUIC or IPv6 networking. Restart the guest after network changes.

### Shared folders and clipboard

Desktop and Downloads sharing is enabled by default. These are the **same files
in both systems**, including edits and deletions. macOS may ask for folder access.
Original guest folders are preserved under
`~/Library/Application Support/Isola Integration/` and restored when sharing is
disabled and the guest restarts. Existing unrelated symlinks are not replaced.
Additional shared folders appear in **Finder → My Shared Files**.

Clipboard limits: **10 MiB** for text/images, **64 MiB total and 128 files** for
regular files. Folders, symlinks and file promises are not transferred. The same
keyboard input source must be available in the guest for layout sync.

### Storage and performance

The default VM lives in `~/Library/Application Support/Isola/VM`. Each machine
keeps its disk, identity and settings in its own folder. Disk images are sparse:
the configured capacity is not all allocated immediately.

Disk growth requires an **APFS host volume** and a supported guest GPT/APFS layout.
Isola works on a copy and retains a **Before expansion …** backup. To restore it,
shut down the VM and add that backup folder as an existing machine. Growing the
disk does not require disabling SIP or deleting Recovery.

**Optimize performance** adjusts the guest's visual preferences, not its CPU/GPU
allocation. Some changes require reopening apps or logging out and back in. One
guest can run at a time. UI language follows the host's preferred language
(Russian or English).

## Build from source

On an Apple Silicon Mac, install Xcode command line tools with a macOS 14+ SDK,
[Go 1.27.1 or later](https://go.dev/dl/) and Python 3 for tests.

```sh
git clone https://github.com/itrcz/isola.git
cd isola
bash scripts/build.sh
open dist/Isola-0.5.0.app
```

No Xcode project or third-party Swift package setup is required. The build
compiles the host app, network helper and guest Tools, creates the Tools disk
and app icon, includes license notices and signs the app locally.

```sh
bash scripts/test.sh          # Network, clipboard, layout, folders and settings
bash scripts/test.sh --ui     # Also check window close/reopen behavior
bash scripts/test.sh --disk   # Also exercise APFS growth on temporary images
bash scripts/release.sh      # Fresh ZIP + SHA-256, verified after extraction
```

The disk test requires APFS and Python 3.11+. Tests use temporary fixtures;
the core suite does not start a VM. See [CONTRIBUTING.md](CONTRIBUTING.md) for UI
previews and release packaging. GitHub Actions builds and tests pull requests.

## License

[MIT](LICENSE). Third-party dependencies retain their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Isola is an independent project
and is not affiliated with Apple. macOS restore images are downloaded from Apple
and are not distributed with Isola.
