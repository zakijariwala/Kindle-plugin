# Kindle-style Home for KOReader

A lightweight KOReader plugin that puts a deliberately simple, Kindle-like
shell on top of KOReader:

```
Home
 ├── Continue Reading   (cover · title · author · progress → opens the book,
 │                       plus up to two more books you are reading)
 ├── My Library         (cover grid like a Kindle, or a list; sort, refresh;
 │                       hold a book: status, reset, remove, details, delete)
 ├── + Send Book        (phone → Kindle over the phone's hotspot, via QR code;
 │                       several books at once)
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

> **Status: MVP, tested in a KOReader emulator, not yet on Kindle hardware.**
> Every screen and the complete phone → Kindle transfer were run inside a real
> KOReader build (v2026.07.1, Linux, at Paperwhite 12 resolution), with
> headless Chromium playing the phone. The Kindle-only parts (firewall rule,
> Kindle sleep timer) and real device speed still need a device. See
> [Compatibility](#compatibility) and [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

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

### Updating

**Settings → About → Check for updates** (needs internet; the phone hotspot
with mobile data on is fine). It compares your installed build with the
latest commit on this repository's `main` branch. If there is a newer one, it
shows what changed and, after you tap **Update**, downloads it, checks it and
replaces the plugin. Then restart KOReader. Your settings, library cache and
covers are kept. Nothing is ever checked automatically.

The repository must be **public** for this to work (the Kindle downloads
without any GitHub login). An install copied by hand shows its build as
"unknown", and the first check offers the latest version.

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
5. Tap **Choose Books**, pick one or several EPUB/PDF/… files, tap **Upload**.
   The phone shows each book's result.
6. The Kindle shows **✓ Book received** (or *N books received*) with **Read
   Now** / **Open Library**, **Send More** and **Done**. The books are already
   in the library, with their covers, and the transfer service has shut down.

While Send Book is open the Kindle does not go to sleep (both KOReader's
auto-suspend and, on Kindle, the system sleep timer are held and restored
afterwards). The code expires after 15 minutes without an upload, but never
while a book is still arriving. An expired screen offers **New Code**.

Books are saved to KOReader's home folder, or to `<home>/documents` on
Kindle when that folder exists (normally `/mnt/us/documents`). A file with the
same name is never overwritten ("Book (2).epub").

The phone and Kindle can also simply be on the same home/office Wi-Fi.

### How the transfer is protected

- The server exists only while the Send Book screen is open. Cancel, Done,
  the Home key, pressing the power button, and KOReader exiting all stop it
  and close its sockets.
- Every session uses a new 128-bit token from `/dev/urandom` in the URL. It
  expires after 15 idle minutes, or earlier when the session ends. Requests
  without the right token get a 404 and nothing else.
- The browser-supplied filename is never used as a path. Separators, `..`,
  absolute paths, NUL bytes and invalid UTF-8 are rejected. VFAT-invalid
  characters are replaced.
- Uploads stream into a hidden `.part` file in the destination folder. The
  size is checked, the file type is sniffed (EPUB/PDF/MOBI/DJVU headers), and
  only then is the file renamed into place. Interrupted or rejected uploads
  are deleted. Free space, and whether the folder is writable, are checked
  before anything is written. If the Kindle loses power mid-upload, the
  leftover hidden file is deleted the next time KOReader starts.
- The phone page loads nothing from the network and runs under a strict CSP.
- On Kindle, an `iptables` rule for the port is added while the server runs
  and removed afterwards, the same way KOReader's own SSH and HTTP-inspector
  plugins do it. Success or failure is logged (`firewall opened for port …`),
  so a phone timeout caused by the firewall shows up in `crash.log`.

Plain HTTP on a local link is used (there is no way to get a trusted TLS
certificate for a hotspot IP). Anyone on the same hotspot who can see the QR
code/URL could upload a book during the session; keep the hotspot private.

## Installing other plugins from the phone

**Settings → Advanced → Install plugin from phone** (or the row of that name at the end of
**Installed Plugins**) shows the same kind of QR code as Send Book. On the
phone, choose a plugin's `.zip`, for example GitHub → Code → **Download ZIP**,
or a release asset (up to 20 MB). The Kindle finds the `*.koplugin` folder
inside it and shows its name and description, and whether it is new or
replaces an installed version. Nothing is installed until you tap
**Install** / **Replace**; then restart KOReader.

- Only the plugin folder is unpacked: README files, tests, `.git` and macOS
  `__MACOSX` junk around it are never written. Zips with `..` or absolute
  paths, symbolic links, more than 50 MB unpacked or 5 000 files are refused.
- The new files are checked to compile before anything is replaced. If
  anything fails, the installed plugins are unchanged.
- KOReader's built-in plugins cannot be replaced, and this plugin updates
  itself through **Check for updates** instead.
- **Settings → Advanced → Undo last plugin install** puts back the version the
  last install replaced, or removes the plugin if it was new (one level only).
- A plugin runs with full access to KOReader and your files: only install
  plugins you trust.

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
| *"…the library folder (it is read-only)"* | The Kindle's storage is mounted read-only (e.g. while connected over USB). Eject/unplug and try again. |
| Phone times out and `crash.log` shows `iptables … failed` | The Kindle firewall could not be opened (unusual jailbreak setup). Opening the port by hand, or KOReader's SSH plugin, would show the same issue. |
| Port busy | The server tries ports 8080–8089 automatically; the chosen one is shown under the QR code. |
| The Kindle went to sleep | It does not sleep on its own while Send Book is open, but pressing the power button stops the transfer on purpose. Wake it and start Send Book again. |

The logs (`crash.log` in the KOReader folder) include the session lifecycle,
the chosen address/interface, the port, upload size/type, validation results
and errors, each prefixed with `KindleUI`. Tokens, URLs and file contents are
never logged.

## Compatibility

Written against KOReader at commit `d9cd278` (master, 2026-09-23;
koreader-base `9a87297`) and run against the **KOReader v2026.07.1** Linux
build. Every KOReader API it uses is listed, with its source location, in
[docs/KOREADER_APIS.md](docs/KOREADER_APIS.md).

**What has been tested:**
- The transfer layer (HTTP server, sessions, several books per session, idle
  expiry, tokens, upload validation, filename sanitising, stale temp cleanup,
  IP selection): automated tests under LuaJIT 2.1 + LuaSocket, with curl as
  the phone.
- The whole plugin inside KOReader v2026.07.1 (Linux/SDL, 1264×1680 at
  300 dpi), driven by scripts. That covers every screen, leaving a book →
  Home, the cover grid, Installed Plugins, Settings → Advanced, and Send Book
  end to end (QR decoded from the screen, then headless Chromium uploading
  EPUB + PDF + an unsupported file). It also covers the read-only folder,
  expiry and stale-file cases, and installing a plugin from a GitHub-style
  zip, replacing it and undoing that, across restarts. Details: [docs/TESTING.md](docs/TESTING.md).
- Timings and memory in that emulator: [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

**What has not been tested:**
- Any Kindle, Kobo or other e-reader (so, no real device timings yet).
- The Kindle-only commands: `iptables` (firewall) and `lipc-set-prop`
  (sleep timer). They mirror KOReader's own SSH and Keep alive plugins, and
  their result is logged.
- Real phone browsers (iOS Safari, Android Chrome) over a real hotspot.
- Non-touch Kindles (key navigation is implemented but untested).
- Installing a plugin on a real Kindle (the user plugins folder there is
  `koreader/plugins`, next to the built-in ones).

**Assumptions / known limitations:**
- Needs a KOReader recent enough to have `UIManager:insertZMQ`,
  `ffi/netinfo`, `ui/widget/qrwidget`, `ui/widget/booklist` and
  `ffiUtil.runInSubProcess`. Older releases have not been checked.
- The phone page needs JavaScript (progress bar, streaming upload, several
  books). There is no no-JS fallback.
- Books are received one after another (not in parallel). Maximum 500 MB per
  book (setting `transfer_max_mb`).
- Covers are extracted the first time a Library page (or Home, or Send Book)
  shows a book. On a slow device, a page of 9 new books needs a few seconds
  before all real covers appear. Text covers are shown meanwhile and the page
  stays usable. Thumbnails are grayscale.
- Until a book's cover and metadata have been extracted, "Sort by Title" uses
  its file name.
- The Library scans the home folder when opened (up to 2000 books, 6 levels
  deep). The per-book cost is a couple of `stat()` calls.
- Reading settings (font, size, margins) open KOReader's own in-book menu,
  which means opening the current/last book.
- IPv4 only.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): design, module map, the
  KOReader investigation (phase 1 report) and the transfer flow.
- [docs/KOREADER_APIS.md](docs/KOREADER_APIS.md): every KOReader API used,
  with its source location.
- [docs/TESTING.md](docs/TESTING.md): automated tests, the emulator runs and
  the manual test procedure for devices.
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md): measured timings and memory.
- [docs/ROADMAP.md](docs/ROADMAP.md): feature list and ideas, each with its performance cost.

## Development

```sh
sudo apt-get install luajit lua-socket lua-filesystem curl lua-check   # Debian/Ubuntu
./tests/run.sh
# optional: also encode with KOReader's QR encoder
KOREADER_BASE=/path/to/koreader/base ./tests/run.sh

# run the plugin inside a real KOReader (Docker), see docs/TESTING.md
tools/emulator.sh start && tools/emulator.sh vnc
tests/bench/run.sh 150 50        # timing run
```
