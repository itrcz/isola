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
| **Shared folders** | Add or remove folders without restarting the VM. Native virtiofs access, stable mount names and optional read-only access. |
| **VMs on your network** | Discover and control a VM from another Mac with Isola. Connect without a password by default, or enable password protection. |
| **Suspend and resume** | Save the VM to disk, quit Isola and continue with the same open apps. |
| **Stay awake** | Separate switches keep guest macOS awake or prevent host idle sleep while the VM runs. |
| **Time through SOCKS** | Guest NTP requests are answered locally using the host clock, without proxy UDP support or direct internet traffic. |
| **Less visual overhead** | Reduce guest motion, transparency, blur and some animations. Turning optimization off restores the previous preferences. |
| **Room to grow** | Adjust CPU and RAM. Expand the disk and main APFS volume with an automatic backup and Recovery relocation. |
| **Recovery when needed** | Start the guest directly in macOS Recovery from its startup menu. |

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
   This enables clipboard, keyboard, sleep and performance integration for that guest user.

Release builds are **ad-hoc signed and not notarized**. If Gatekeeper blocks the
first launch, use Apple's [Open Anyway instructions](https://support.apple.com/en-us/102445)
in **System Settings → Privacy & Security**. The release includes `SHA256SUMS.txt`
for checking the downloaded ZIP.

To update, shut down guest macOS and quit the previous Isola app before replacing it.
Your VM stays in its existing folder. Run the guest Tools installer again when an
update includes a new helper.

## A few useful details

### Suspend and resume

Click **⏸ Suspend** in the toolbar to save memory and device state to the VM folder.
You can then quit Isola, reopen it and choose **Resume macOS**. **⌘Q → Save & Quit**
does both steps together. Closing the window alone keeps the VM running.

Allow free host disk space equal to guest RAM plus 2 GB. A suspended VM uses no CPU
or RAM. CPU, RAM, disk and integration settings stay locked until you resume and
shut down macOS, or explicitly **Discard Saved State**. Discarding loses open apps
and unsaved work; it keeps the VM disk. Saved state is not a backup.

Restore on the **same Mac**. Apple ties saved states to the host, and some host macOS
updates can make a state incompatible. Shut down the guest before updating host
macOS or moving the VM to another Mac. Isola checks the disk/configuration before
restoring and never silently replaces a failed restore with a cold boot.
Network sessions and remote viewers reconnect after resume. Installed Isola Tools
restarts its integration channel automatically; no extra installer run is needed.

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
general UDP/QUIC or IPv6 networking. Standard IPv4 NTP requests (UDP 123) are
answered locally from the host clock. Keep the host's own automatic time enabled.
The local server is also available at `10.77.0.1`; check from the guest with
`sntp 10.77.0.1`. This check does not change the clock. Keep automatic date/time
enabled in guest System Settings. Direct/NAT mode uses normal network time.
Restart the guest after network changes.

### Shared folders and clipboard

Add folders under **Settings → Integration → Shared Folders**. They appear in
**Finder → My Shared Files** in the guest, without installing Tools. You can add,
remove or change read-only access while the VM is running. Work on large files
inside these folders directly to avoid transferring them through the clipboard.
With write access, changes and deletions affect the host files too.

Automatic Desktop/Downloads mirroring was removed in 0.6. Updated Isola Tools
restores the guest's saved original folders from
`~/Library/Application Support/Isola Integration/`, including when the old share
is no longer mounted. Host files stay on the host; unrelated local folders and
symlinks are never overwritten. You can explicitly share Desktop or Downloads
as ordinary folders if needed.

Clipboard file I/O and encoding run in the background. Tools 0.6 uses a binary,
readiness-driven transport without Base64 expansion; older Tools remains compatible
with the original JSON protocol. Re-run **Install Clipboard.command** to upgrade.

Clipboard limits: **10 MiB** for text/images, **64 MiB total and 128 files** for
regular files. Folders, symlinks and file promises are not transferred. The same
keyboard input source must be available in the guest for layout sync.

### Sleep and layout

**Keep guest macOS awake** runs `caffeinate -dis` inside the guest. Tools 0.7
restarts it if it exits unexpectedly, and the host periodically reapplies the
preference after Tools reconnects. No screen saver, password or lock preferences
are changed. **Keep this Mac awake while running** separately runs `caffeinate -is`
on the host; its display may still sleep. Both default to off and apply live.
A sleeping host suspends the VM regardless of the guest setting.

The checkbox records the requested state; the status below it confirms whether
Tools applied it. If it says **Update Isola Tools**, run **Install Clipboard.command**
from the current Tools disk once. The guest helper is a separately installed copy:
replacing the host app does not update it. You do not need to rerun the installer
for each checkbox change. Assertions end when the helper exits or the VM stops.
After guest sleep, layout sync first requests the host's current input source.

### Connect from another Mac

1. Start the VM on the host. Open **Settings → Integration → Network Sharing**
   and enable **Share this VM**. Allow Screen Recording and Local Network access
   if macOS asks; Screen Recording changes may require restarting Isola.
2. On another Mac with Isola 0.8, choose **+ → Local Network**, select the VM and
   click **Connect**. Both Macs must be on the same local network.
3. Sharing has **no password by default**: anyone on that network may control the
   shared VM. To require a password, enable **Require a password** on the host and
   save a password. The client then asks for it and can remember it in Keychain.

The host continues running the VM. One client controls it at a time; **Take
Control** returns it to the host. Disabling sharing or stopping the VM disconnects
clients. Sharing must be explicitly enabled each time the VM starts. Password
changes terminate the old session. Keep the host awake for uninterrupted access.

Video uses ScreenCaptureKit (only the VM window) and hardware VideoToolbox encoding
and decoding at up to **60 fps**. The guest display follows the client's window and
Retina scale, within 4096 pixels per side and 8.85 megapixels. The display menu offers:

- **Retina**: sharp text, HEVC with H.264 fallback, 12–80 Mbps target depending on resolution.
- **Balanced**: fewer pixels and lower bandwidth, with the same window proportions.
- **Responsive**: native low-delay H.264 encoding at standard pixel density.

Control, video and clipboard use separate encrypted connections. At most two video
frames await decoder acknowledgement; only the latest raw capture is retained under
load. The encoder reduces its bitrate when acknowledgements slow down. The status
bar shows codec, resolution, actual frame rate, throughput and network RTT. RTT is
**not** total input-to-display latency; static desktops naturally produce fewer frames.

Update **both Macs to 0.8**: the streaming protocol changed. Install the bundled
**Isola Tools 0.8 once inside the guest** for local cursor shapes and hotspots. During
remote control Tools hides the guest cursor, sends its shape separately, and restores
it on disconnect or lease expiry. Without updated Tools, the client uses an arrow and
the guest may still draw another pointer. Tools also enables clipboard text/images/files
and keyboard layout sync with the client; the host's own clipboard and layout stay isolated.

Existing shared folders still belong to the host. Client folders, audio forwarding,
wake-on-LAN and simultaneous local/remote VM sessions are not supported yet. Streaming
is intended for LAN use; performance still depends on Wi-Fi, display size and host load.

Transport uses TLS 1.2 with ECDHE-PSK/ChaCha20-Poly1305. Password mode derives the
key with PBKDF2-SHA256; passwords stay in Keychain. Open mode uses a public key
and provides no peer authentication. Bonjour discovery and incoming subnet checks
limit the feature to the local network. The VM's Direct/Proxy internet setting
is independent of this host-to-host connection.

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
open dist/Isola-0.9.0.app
```

No Xcode project or third-party Swift package setup is required. The build
compiles the host app, network helper and guest Tools, creates the Tools disk
and app icon, includes license notices and signs the app locally.

```sh
bash scripts/test.sh          # Network, clipboard, layout, folders and settings
bash scripts/test.sh --ui     # Also check window close/reopen behavior
bash scripts/test.sh --disk   # Also exercise APFS growth on temporary images
bash scripts/test.sh --stream # Capture → TLS → real client, using a synthetic window
bash scripts/test_suspend.sh /path/to/Hardware.bin # Firmware-only suspend/restart/resume
bash scripts/release.sh      # Fresh ZIP + SHA-256, verified after extraction
```

The disk test requires APFS and Python 3.11+. Tests use temporary fixtures;
the core suite does not start a VM. The stream test needs existing Screen Recording
permission and otherwise skips capture without asking for access. It covers a local
loopback connection; it does not replace testing between two physical Macs. See [CONTRIBUTING.md](CONTRIBUTING.md) for UI
previews and release packaging. GitHub Actions builds and tests pull requests.

## License

[MIT](LICENSE). Third-party dependencies retain their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Isola is an independent project
and is not affiliated with Apple. macOS restore images are downloaded from Apple
and are not distributed with Isola.
