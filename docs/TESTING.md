# Testing

## 1. Automated tests (no device needed)

```sh
sudo apt-get install luajit lua-socket curl lua-check
./tests/run.sh
KOREADER_BASE=/path/to/koreader/base ./tests/run.sh   # also encodes the QR with KOReader's encoder
```

`tests/run.sh` runs:

| Check | What it covers |
| --- | --- |
| syntax | every plugin file compiles under LuaJIT |
| gettext shadowing | no `for _, …` / `local _,` in files that use `_()` for translations (such a loop would crash any translated string inside it) |
| luacheck | undefined globals, unused variables, typos |
| `test_security.lua` | token randomness/format/uniqueness and fail-closed RNG, constant-time compare, filename sanitizer (spaces, Unicode, traversal, absolute paths, NUL, invalid UTF-8, overlong, surrogates, VFAT characters, hidden names, length cap), safe joins, duplicate-name suffixes, format sniffing, IP selection (hotspot ranges, loopback, link-local, USB) |
| `test_transfer.lua` | a real LuaSocket server driven by a fake UIManager loop, with curl as the phone: upload page served, invalid/truncated/missing token rejected, traversal/absolute/NUL names rejected, unsupported type (415), chunked without length (411), oversize (413), wrong method (405), fake EPUB rejected after upload (422) with nothing left behind, interrupted upload (temp file exists during, removed after, UI told "cancelled", session survives), Unicode+spaces EPUB stored byte-identical, progress events, auto-stop after success (server unregistered, token cleared, port closed), repeat session on the same port with a new token (old token rejected), duplicate name → "(2)", PDF with `Expect: 100-continue`, cancel (port closed, timer removed, idempotent), expiry, disk full (507), no `.part` leftovers |
| `test_qr.lua` | URL format and length, QR encodes with KOReader's `ffi/qrencode` (≤ version 5), upload page escaping, no external resources, CSP |

These tests do **not** cover the UI modules (`kindleui/ui/*`, `main.lua`,
`util/books.lua`, `transfer/localhttp.lua`). Those need a KOReader runtime;
use the manual procedure below.

## 2. Manual test procedure (KOReader emulator or device)

Setup: install the plugin, restart KOReader, keep `crash.log` open (or run
the emulator from a terminal). Put at least one EPUB and one PDF in the home
folder, and open one of them once so there is a "current" book.

### UI

| # | Step | Expected |
| --- | --- | --- |
| U1 | Start KOReader | Home appears over the file browser: *Home*, Continue Reading card, My Library, + Send Book, Installed Plugins, Settings. Nothing else. |
| U2 | Tap the Continue Reading card | The book opens in KOReader's normal reader at the saved position |
| U3 | In the reader, press Home (or ☰ → Kindle-style Home) | The book closes and Home is shown; progress % is updated |
| U4 | Fresh profile (no `lastfile`) | Card replaced by "No book currently being read." + [Open Library] |
| U5 | My Library | Full-screen list: title, author (2nd line) and "NN%" / "New" / "Finished" |
| U6 | Library ☰ → each Sort by option | Order changes; the choice persists after restart |
| U7 | Library ☰ → Refresh / Browse all files (KOReader) | List reloads / Home closes and the stock file browser is shown |
| U8 | Installed Plugins | All enabled and disabled plugins alphabetically, including user plugins, with Open / No menu / While reading / Disabled |
| U9 | Open e.g. SSH, Calibre, Statistics | That plugin's own KOReader menu appears and works (start/stop SSH etc.) |
| U10 | Tap a disabled plugin; tap *Manage plugins (KOReader)…* | Explanation / KOReader's Plugin management |
| U11 | Settings → every section | Reading, Library, Device (frontlight, sleep screen, rotation where supported), Connectivity (Send Book, Transfer method with Cloud greyed out, Network), Advanced, About |
| U12 | Settings → Advanced → Open KOReader Settings | KOReader's complete main menu opens on its Settings tab |
| U13 | Settings → Reading → Font, size and margins (from Home) | Last book opens and KOReader's bottom config menu appears |
| U14 | Back key on Home (non-touch / keyboard Kindles) | Home closes and the file browser is shown; ☰ → Kindle-style Home brings it back |
| U15 | Settings → Library → uncheck *Show Home screen at startup*, restart | KOReader starts in its file browser; Home still reachable from ☰ |

### Network (phone hotspot)

| # | Step | Expected |
| --- | --- | --- |
| N1 | Wi-Fi off → + Send Book | "Wi-Fi connection required…" with Turn on Wi-Fi / Try Again / Close. No crash. |
| N2 | Phone hotspot on (mobile data **off**), Kindle joined → + Send Book | QR code, "Waiting for upload…", `Local address: <ip>:<port>` |
| N3 | From the phone, open `http://<ip>:<port>/` (no token) | "This transfer link has expired…" (404) |
| N4 | Scan QR | "SEND TO KINDLE" page loads without internet |
| N5 | Choose an EPUB → Upload | Phone shows percentage, then "✓ Book sent successfully"; Kindle shows progress, then "✓ Book received", title, author |
| N6 | Read Now | Book opens |
| N7 | After N5, reload the phone page / rescan the old QR | Fails (server gone) |
| N8 | Start Send Book, then Cancel; from a computer on the same network: `nc -vz <ip> <port>` | Connection refused |
| N9 | Start Send Book and wait 15 min | "This transfer session has expired." Server stopped |
| N10 | During an upload, press the power button | Transfer stops. On wake: "The transfer was stopped because the device went to sleep." No `.part` file remains |
| N11 | Kindle: `iptables -L -n` during and after a session | Rule for the port present during, absent after |

### Files

| # | Step | Expected |
| --- | --- | --- |
| F1 | EPUB | Added and opens |
| F2 | PDF | Added and opens |
| F3 | `.exe` / `.zip` of photos | Phone and Kindle: "Unsupported file type. This file was not added to your library." |
| F4 | `My Great Book.epub` | Stored with spaces intact |
| F5 | `Ünïcödé 日本語.epub` | Stored with the Unicode name (VFAT permitting) |
| F6 | `curl -X POST --data-binary @a.epub 'http://<ip>:<port>/<token>/upload?name=..%2F..%2Fevil.epub'` | 400, nothing written outside the documents folder |
| F7 | Start an upload of a big PDF and turn off the phone's Wi-Fi mid-way | Kindle: "Upload cancelled." after ≤ 45 s. No partial file. Session still waiting |
| F8 | Fill storage (or upload a file larger than free space) | "Not enough storage space to save this book." |
| F9 | Rename a text file to `.epub` and upload | "The uploaded file could not be added." Nothing added |
| F10 | Upload the same book twice | Second copy saved as `Name (2).epub` |

### Lifecycle and leaks

Repeat 10 times: Send Book → Cancel → Send Book → transfer → Read Now → Home.

Expected:
- Each session gets a new token and uses the same port (8080 unless busy).
- `ls -la /proc/$(pidof luajit)/fd | grep -c socket` returns to the idle count
  after each session (no leaked sockets).
- `ls -a /mnt/us/documents | grep kindleui` finds nothing (no temp files).
- `crash.log` shows paired `session started` / `session stopped` lines and
  `stopped` for the server, and never shows a token.
- Memory (`top`/`ps`) does not grow from one round to the next.
