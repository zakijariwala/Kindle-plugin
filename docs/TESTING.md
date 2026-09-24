# Testing

Three layers:

1. **Automated tests** (LuaJIT, no KOReader): transfer layer, security, QR.
2. **Emulator**: the plugin running inside a real KOReader build (v2026.07.1,
   Linux/SDL at Paperwhite 12 geometry), driven by scripts. It covers the UI,
   the end-to-end phone upload, timings and memory.
3. **Device** (manual): what an emulator cannot show. That means the Kindle
   firewall, the Kindle sleep timer, a real phone hotspot, e-ink refresh, and
   real device timings.

## 1. Automated tests

```sh
sudo apt-get install luajit lua-socket lua-filesystem curl lua-check
./tests/run.sh
KOREADER_BASE=/path/to/koreader/base ./tests/run.sh   # also encodes the QR with KOReader's encoder
```

| Check | What it covers |
| --- | --- |
| syntax | every plugin file compiles under LuaJIT |
| gettext shadowing | no `for _, …` / `local _,` in files that use `_()` (such a loop would crash any translated string inside it) |
| luacheck | undefined globals, unused variables, typos |
| `test_security.lua` | Tokens: randomness, format, uniqueness, and the RNG fails closed. Constant-time compare. Filename sanitizer: spaces, Unicode, traversal, absolute paths, NUL, invalid UTF-8, overlong, surrogates, VFAT characters, hidden names, length cap. Safe joins. Duplicate-name suffixes. **Stale temp cleanup** removes exactly our pattern and leaves everything else (including a directory with that name). Format sniffing. IP selection. |
| `test_transfer.lua` | A real LuaSocket server with curl as the phone. Upload page served. Invalid, truncated or missing token rejected. Traversal, absolute and NUL names rejected. Unsupported type → 415. Chunked upload without a length → 411. Oversize → 413. Wrong method → 405. Fake EPUB rejected after upload (422) with nothing left behind. Interrupted upload: temp file exists during, is removed after, and the UI is told "cancelled". Unicode + spaces EPUB stored byte-identical. Progress events carry book *i of N*. Session stays open until `/finish`, then stops (server unregistered, token cleared, port closed). **Several books in one session**, with one rejected in the middle. Old token rejected by a new session. Duplicate name → "(2)". PDF with `Expect: 100-continue`. Cancel: port closed, timer removed, idempotent. Idle expiry. **No expiry while a slow upload is arriving**, then expiry once idle. Disk full → 507. Read-only folder (skipped when run as root). No `.part` leftovers. |
| `test_qr.lua` | URL format and length, QR encodes with KOReader's `ffi/qrencode` (≤ version 5), multi-file picker, page escaping, no external resources, CSP |

## 2. Emulator (real KOReader, scripted)

Requirements: Docker, `xwd` + `convert` (imagemagick), `xdotool`, `zbarimg`
(zbar-tools), and Node + Playwright for the phone simulation. The image
`wardwouts/koreader-novnc` (KOReader's Linux .deb + Xvfb) is pulled through
`mirror.gcr.io`.

```sh
tools/emulator.sh start            # KOReader 1264x1680 @300 dpi with the plugin mounted
tools/emulator.sh shot home.png    # screenshot
tools/emulator.sh tap 300 675      # tap (My Library on Home)
tools/emulator.sh log              # KOReader log
tools/emulator.sh vnc              # URL to use it interactively in a browser
tests/bench/run.sh 150 50          # timing run, 150 books (50 with progress); add 0.1 for a throttled CPU
node tests/e2e/phone.js "$(zbarimg -q --raw shot.png)" phone.png a.epub b.pdf   # the phone
```

What was checked this way (KOReader v2026.07.1):

| Area | Result |
| --- | --- |
| Plugin loads, no errors in the log | ✓ |
| Leaving a book (reader menu → file-browser icon) shows Home | ✓ (mechanism: [KOREADER_APIS.md](KOREADER_APIS.md#how-the-home-screen-comes-back-when-you-leave-a-book)) |
| Continue Reading card opens the book | ✓ |
| My Library cover grid: 3×3, text covers first, real covers swapped in, blank PDF first pages → text cover, paging by swipe | ✓ |
| Library options: Covers/List, sort (Title shows progress %), refresh | ✓ |
| Installed Plugins: list, tap → that plugin's own menu (Auto night mode) | ✓ |
| Settings: Connectivity = Send Book + Network (no Cloud); Advanced → Open KOReader Settings opens KOReader's full menu on its Settings tab | ✓ |
| Send Book → QR decoded from the screen → headless Chromium (phone viewport) uploads 3 files (EPUB, .exe, PDF) | ✓ phone: "2 sent, 1 not sent"; Kindle: "✓ 2 books received" with titles; server stopped; old QR → connection refused |
| Send Book with a read-only library folder | ✓ "Books cannot be saved in the library folder (it is read-only)" before any QR is shown |
| Expiry (timeout shortened to 15 s by a test-only user patch) | ✓ "This code has expired" + New Code; server stopped; sleep released |
| Sleep guard held while Send Book is open, released on finish/expiry | ✓ (log). The effect on an actual Kindle is a device test. |
| Stale `.kindleui-upload-*.part` removed at startup | ✓ "removed 2 stale upload temp file(s)" |
| Port 8080 busy (noVNC in the container) → falls back to 8081 | ✓ |
| No leftover or zombie processes after extraction jobs | ✓ |

Not covered by the emulator: Kindle `iptables`, `lipc` sleep timer, real Wi-Fi
hotspot, e-ink refresh behaviour, non-touch Kindles, real device speed.

## 3. Manual test procedure (device)

Setup: install the plugin, restart KOReader, keep `crash.log` open (all plugin
lines start with `KindleUI`). Put 100+ books in the documents folder and open
one of them once.

### UI

| # | Step | Expected |
| --- | --- | --- |
| U1 | Start KOReader | Home: *Home*, Continue Reading card (cover, title, author, %), My Library, + Send Book, Installed Plugins, Settings |
| U2 | Tap the card | The book opens at the saved position |
| U3 | Leave the book (top menu → file-browser icon, or Home key/gesture) | Home, with updated % |
| U4 | Fresh profile (no `lastfile`) | "No book currently being read." + [Open Library] |
| U5 | My Library (first time) | 3×3 covers; text covers first, real covers appear within a few seconds. The page can be turned while that happens. |
| U6 | My Library (second time) | All covers of visited pages appear immediately |
| U7 | ☰ → List; each Sort by; Refresh; Browse all files | Works; choices persist after restart |
| U8 | Hold a cover | KOReader's book details |
| U9 | Installed Plugins → open SSH, Calibre, Statistics | That plugin's own menu works |
| U10 | Settings → every section; Advanced → Open KOReader Settings | KOReader's full menu, Settings tab |
| U11 | Back key on Home (keyboard Kindles) | File browser; ☰ → Kindle-style Home brings Home back |
| U12 | Settings → Library → uncheck *Show Home screen at startup*, restart | KOReader starts in its file browser |

### Network (phone hotspot)

| # | Step | Expected |
| --- | --- | --- |
| N1 | Wi-Fi off → + Send Book | "Wi-Fi connection required…" with Turn on Wi-Fi / Try Again / Close |
| N2 | Phone hotspot on (mobile data **off**), Kindle joined → + Send Book | QR, "Waiting for upload…", `Local address: <ip>:<port>` |
| N3 | Check the log | `firewall opened for port <port>` (an `iptables … failed` error here explains phone timeouts) |
| N4 | Scan QR, choose 3 books (one unsupported), Upload | Phone: per-book ✓/✗ and a summary. Kindle: "Receiving book i of 3…", then "✓ 2 books received" |
| N5 | After N4: `iptables -L -n` | Rule gone; log shows `firewall closed` |
| N6 | Set the Kindle sleep timeout to its minimum; send a large PDF over a slow hotspot so it takes longer than that | The Kindle does not sleep during the transfer; after Done, normal sleep timing resumes |
| N7 | Leave Send Book open without scanning for 15 min | "This code has expired" + New Code |
| N8 | Start a slow upload at ~minute 14 | It completes (no expiry mid-upload) |
| N9 | During an upload, press the power button | Transfer stops. On wake: "The transfer was stopped because the device went to sleep." No `.part` file |
| N10 | Pull the power (or force-reboot) mid-upload, then start KOReader | Log: `removed 1 stale upload temp file(s)` |

### Files

| # | Step | Expected |
| --- | --- | --- |
| F1 | EPUB, PDF | Added, with a cover in the grid, and open |
| F2 | `.exe` | "Unsupported file type…" on phone and Kindle |
| F3 | `My Great Book.epub`, `Ünïcödé 日本語.epub` | Names kept |
| F4 | `curl -X POST --data-binary @a.epub 'http://<ip>:<port>/<token>/upload?name=..%2F..%2Fevil.epub'` | 400, nothing written |
| F5 | Turn off the phone's Wi-Fi mid-upload | Kindle: "Upload cancelled." within ≤ 45 s. No partial file. Session keeps waiting |
| F6 | File larger than free space | "Not enough storage space to save this book." |
| F7 | Upload the same book twice | Second copy is `Name (2).epub` |

### Performance (compare with a stock Kindle side by side)

Read the `KindleUI perf:` lines in `crash.log`:

| Measure | Log line |
| --- | --- |
| Home open | `home open (to first paint)` |
| Library open, 100+ books, first and second time | `library data` (scan, sidecar reads) + `library open (covers, to first paint)` |
| Page turn | `library page turn (to first paint)` |
| Cover extraction, 9 books | `covers extracted (child process)` |
| Installed Plugins open | `plugins open (to first paint)` |
| Memory | `lua_heap=` / `rss=` on each line; check `rss` after browsing every Library page |

### Lifecycle and leaks

Repeat 10 times: Send Book → Cancel → Send Book → send 2 books → Read Now → Home.

- Each session has a new token and uses the same port.
- The number of sockets in `ls -la /proc/$(pidof luajit)/fd | grep -c socket` returns to its idle value.
- `ls -a /mnt/us/documents | grep kindleui` finds nothing.
- `crash.log` shows paired `session started` / `session stopped` and `sleep held` / `sleep released`, and never a token.
- `rss` does not grow from one round to the next.
