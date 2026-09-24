# Kindle-style Home for KOReader

A lightweight KOReader plugin that puts a deliberately simple, Kindle-like
shell on top of KOReader:

```
Home
 ├── Continue Reading   (cover · title · author · progress → opens the book)
 ├── My Library         (simple list: title, author, progress, sort, refresh)
 ├── + Send Book        (phone → Kindle over the phone's hotspot, via QR code)
 ├── Installed Plugins  (every KOReader plugin, with its own menu)
 └── Settings           (Reading · Library · Device · Connectivity · Advanced · About)
```

KOReader is not replaced, forked or patched. It still does all the reading,
rendering, metadata, settings and plugin work; this plugin only adds a
simpler front door and delegates to KOReader's existing APIs. Everything
KOReader offers stays one or two taps away (**Settings → Advanced → Open
KOReader Settings**, and **Installed Plugins**). The shell never locks you in.

**Send Book** works with no internet at all: the phone shares a Wi-Fi hotspot,
the Kindle joins it, the Kindle shows a QR code, the phone's browser opens it
and uploads the file straight to the Kindle over the local link. No cloud, no
account and no phone app are involved.

> **Status: MVP, not yet tested on Kindle hardware.** The transfer layer is
> covered by automated tests (real sockets and HTTP uploads, see
> [docs/TESTING.md](docs/TESTING.md)). The UI was written against the
> KOReader source and checked statically, but it has not been run inside
> KOReader or on a device yet. See [Compatibility](#compatibility).

## Installation

1. Copy the `kindleui.koplugin` folder into KOReader's `plugins` folder:
   - Kindle: `/mnt/us/koreader/plugins/kindleui.koplugin`
   - Kobo: `/mnt/onboard/.adds/koreader/plugins/kindleui.koplugin`
   - Any platform: KOReader's user plugin folder, `<koreader data dir>/plugins/`
2. Restart KOReader.
3. The Home screen appears when KOReader's file browser opens. It can also be
   opened from the KOReader main menu (**☰ → Kindle-style Home**), or bound to
   a gesture/key via **Taps and gestures → Gesture manager → General →
   Kindle-style Home**.

To turn the shell off without uninstalling it: **Settings → Library → Show
Home screen at startup**, or disable the plugin in KOReader's **Plugin
management**. To uninstall, delete the folder.

## Using Send Book (phone hotspot)

1. On the phone, turn on **Personal Hotspot / Mobile Hotspot**. Mobile data
   can be on or off; it is not used.
2. On the Kindle, connect KOReader to the hotspot (KOReader menu → Network →
   Wi-Fi), or tap **+ Send Book** and then **Turn on Wi-Fi**.
3. Tap **+ Send Book**. A QR code and the Kindle's local address appear.
4. Scan the QR code with the same phone. The browser opens *Send to Kindle*.
5. Tap **Choose File**, pick an EPUB/PDF/..., tap **Upload**.
6. The Kindle shows **✓ Book received** with **Read Now** / **Done**. The book
   is already in the library, and the transfer service has shut down.

Books are saved to KOReader's home folder, or to `<home>/documents` on
Kindle when that folder exists (normally `/mnt/us/documents`). A file with the
same name is never overwritten ("Book (2).epub").

The phone and Kindle can also simply be on the same home/office Wi-Fi.

### How the transfer is protected

- The server exists only while the Send Book screen is open. Cancel, Done,
  the Home key, sleep, and KOReader exiting all stop it and close its
  sockets.
- Every session uses a new 128-bit token from `/dev/urandom` in the URL. It
  expires after 15 minutes, or earlier when the session ends. Requests without
  the right token get a 404 and nothing else.
- The browser-supplied filename is never used as a path. Separators, `..`,
  absolute paths, NUL bytes and invalid UTF-8 are rejected. VFAT-invalid
  characters are replaced.
- Uploads stream into a hidden `.part` file in the destination folder. The
  size is checked, the file type is sniffed (EPUB/PDF/MOBI/DJVU headers), and
  only then is the file renamed into place. Interrupted or rejected uploads
  are deleted. Free space is checked before any byte is written.
- The phone page loads nothing from the network and runs under a strict CSP.
- On Kindle, an `iptables` rule for the port is added while the server runs
  and removed afterwards. KOReader's own SSH and HTTP-inspector plugins do the
  same thing.

Plain HTTP on a local link is used (there is no way to get a trusted TLS
certificate for a hotspot IP). Anyone on the same hotspot who can see the QR
code/URL could upload a book during the session; keep the hotspot private.

## Troubleshooting (phone hotspot)

| Symptom | What to check |
| --- | --- |
| *"Wi-Fi connection required"* | The Kindle is not connected to any network. Tap **Turn on Wi-Fi** or connect via KOReader's Network menu, then **Try Again**. |
| *"Unable to determine local network address"* | Wi-Fi is on but no IPv4 lease was obtained yet. Wait a few seconds and tap **Try Again**; if it persists, toggle Wi-Fi off/on. |
| The phone says "cannot open page" / times out | 1) The phone must be the hotspot the Kindle joined, or be on the same Wi-Fi. 2) On iPhone, keep the *Personal Hotspot* settings screen open while the Kindle joins, and turn on **Maximize Compatibility** if the Kindle can't see the network. 3) Some phones switch the browser to mobile data when the hotspot "has no internet". Turn mobile data off briefly, or type the address shown under the QR code. 4) Guest/"AP isolation" Wi-Fi networks block device-to-device traffic. Use the hotspot instead. |
| The browser warns "Not secure" | Expected: it is plain HTTP on your local link. Nothing is sent to the internet. |
| The page opened but the upload fails immediately | The Send Book screen was closed or the session expired (the page says so). Start **Send Book** again for a new QR code. |
| *"Unsupported file type"* | KOReader cannot open that format. Convert it (e.g. with Calibre) to EPUB or PDF. |
| *"Not enough storage space"* | Free space on the Kindle. |
| Port busy | The server tries ports 8080–8089 automatically; the chosen one is shown under the QR code. |
| The Kindle went to sleep | Sleep stops the transfer on purpose. Wake the device and start Send Book again. |

The logs (`crash.log` in the KOReader folder) include the session lifecycle,
the chosen address/interface, the port, upload size/type, validation results
and errors, each prefixed with `KindleUI`. Tokens, URLs and file contents are
never logged.

## Compatibility

Written against KOReader at commit `d9cd278` (master, 2026-09-23;
koreader-base `9a87297`), the latest source available when this was built.
Every KOReader API it uses is listed, with its source location, in
[docs/KOREADER_APIS.md](docs/KOREADER_APIS.md).

**What has been tested:**
- The transfer layer (HTTP server, sessions, tokens, upload validation,
  filename sanitising, IP selection): automated tests under LuaJIT 2.1 +
  LuaSocket, with curl acting as the phone, on Linux x86-64.
- The QR payload, encoded with KOReader's own `ffi/qrencode.lua`.
- All modules: syntax check and luacheck (using KOReader's lint settings).

**What has not been tested:**
- Running inside KOReader (emulator or device), including all UI screens.
- Any Kindle, Kobo or other e-reader.
- Real phone browsers (iOS Safari, Android Chrome) over a real hotspot.

**Assumptions / known limitations:**
- Needs a KOReader recent enough to have `ui/message/simpletcpserver`-style
  ZMQ polling (`UIManager:insertZMQ`), `ffi/netinfo`, `ui/widget/qrwidget` and
  `ui/widget/booklist`. Older KOReader releases may lack some of these; that
  has not been checked.
- The phone page needs JavaScript (for the progress bar and a streaming
  upload). There is no no-JS fallback.
- One upload at a time and one book per session. Use **Send Another** for the
  next book.
- Maximum upload size is 500 MB (setting `transfer_max_mb`).
- The Kindle firewall rule uses `iptables` exactly like KOReader's SSH
  plugin. Jailbreak setups without `iptables` simply skip it.
- Covers on the Home screen come only from the Cover browser plugin's cache.
  With that plugin disabled, or for books it hasn't processed, no cover is
  shown (the plugin never renders a cover itself).
- The Library view scans the home folder when opened (up to 2000 books,
  6 folder levels deep). Very large libraries will open slowly.
- Reading settings (font, size, margins) open KOReader's own in-book menu,
  which means opening the current/last book.
- Upload throughput is bounded by KOReader's 50 ms main-loop poll while the
  Send Book screen is open. This is expected to be fine for books, but has not
  been measured on hardware.
- IPv4 only.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): design, module map, the
  KOReader investigation (phase 1 report) and the transfer flow.
- [docs/KOREADER_APIS.md](docs/KOREADER_APIS.md): every KOReader API used,
  with its source location.
- [docs/TESTING.md](docs/TESTING.md): automated tests and the manual test
  procedure for devices.

## Development

```sh
sudo apt-get install luajit lua-socket curl lua-check   # Debian/Ubuntu
./tests/run.sh
# optional: also encode with KOReader's QR encoder
KOREADER_BASE=/path/to/koreader/base ./tests/run.sh
```
