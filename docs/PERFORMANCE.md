# Performance

Measured on a **Kindle Paperwhite** (KOReader reports it as `KindlePaperWhite6`:
1272×1696 screen, 2 × ARMv7 cores, 1 GB RAM, firmware 5.19.5) running
**KOReader v2026.07.2**, in September 2026. Two sources:

- **Device bench** (`tools/kindle.sh bench`): the same sequence as the
  emulator bench below (150 synthetic books, 50 with reading progress, in 4
  folders), run twice in a scratch profile on the Kindle. Directly comparable
  with the emulator tables.
- **Real use**: every `KindleUI perf:` line from three days of normal use on
  the same Kindle (25–28 Sep), with a real library that grew from 163 to 496
  books. Test runs are left out.

"To first paint" means from the tap handler until the screen has been drawn
into KOReader's framebuffer, not including the e-ink refresh itself.

## Kindle Paperwhite: device bench (150 books)

| Screen | Run 1 | Run 2 | Emulator, throttled (0.1 CPU) |
| --- | --- | --- | --- |
| Home (first, new process) | 62 ms | 118 ms | 602 ms |
| Home (after restart, cache on disk) | 137 ms | 171 ms | 290 ms |
| My Library, **first ever open** | 296 ms data + 351 ms to paint | 312 ms + 374 ms | 199 ms + 304 ms |
| … of which: 50 sidecar reads + metadata | 242 ms | 259 ms | |
| … of which: folder scan | 33 ms | 34 ms | 2 ms |
| My Library, **later opens** | 103 ms data + 180 ms to paint | 109 ms + 200 ms | 5 ms + 203 ms |
| My Library after a KOReader restart | 82 ms data + 200 ms to paint | 104 ms + 205 ms | 100 ms + 396 ms |
| Library page turn, covers cached | 84–102 ms | 82 ms | 18 ms |
| Library page turn, cover job starting | 31 ms | 45 ms | 561 ms |
| 9 covers extracted (one page), child process | 2.6–3.0 s | 3.1–3.7 s | 13–15 s |
| Installed Plugins (38 plugins), first / again | 81 / 56 ms | 112 / 61 ms | 104–205 ms |

Memory during the whole bench: **RSS 32–37 MB, Lua heap 10–15 MB**, no growth
after 18 covers were extracted (the extraction runs in a child process).

Against the 0.1-CPU emulator guess: **CPU-bound work is 3–10× faster** on
the Paperwhite (Home, cover extraction, a page turn while a cover job runs).
**File-system-bound work is slower**: sidecar reads, the folder scan, the
`stat()` of every book and its sidecar on a warm Library open (5 → ~105 ms),
and loading 9 thumbnails on a cached page turn (18 → 82–102 ms). The Kindle's
`/mnt/us` is a FUSE file system (`fsp`), so each file access costs more than
on a desktop disk.

## Kindle Paperwhite: real use (3 days, 163–496 books)

| Measure | Median | 90th percentile | Max | Samples |
| --- | --- | --- | --- | --- |
| Home open | 84 ms | 209 ms | 298 ms | 51 |
| My Library data (scan + cache) | 583 ms | 812 ms | 1.59 s | 47 |
| My Library open, cover grid, to first paint | 706 ms | 935 ms | 1.44 s | 33 |
| Library page turn | 62 ms | 106 ms | 177 ms | 151 |
| Cover job (≤ 9 books), child process | 0.83 s | 2.0 s | 3.6 s | 69 |
| A received book indexed (title, author, cover) | 1.06 s | 1.9 s | 3.0 s | 42 |
| Installed Plugins open (36–38 plugins) | 52 ms | 67 ms | 77 ms | 32 |

**The folder scan dominates on a real library.** Scanning `documents` took
221–247 ms for 163 books and 346–577 ms (twice ≈ 950 ms) for ~490 books,
against 25–55 ms for the synthetic 150. The real folder holds Amazon's own
files and folders next to the books. Sidecar reads are almost always 0–2 (the
cache works); the rest of "library data" is metadata (23–265 ms).

**Memory:** 27–35 MB RSS in a fresh KOReader showing Home. After reading
sessions the process reaches 225–284 MB; that is KOReader's document engines
(the Lua heap stays at 8–33 MB), and it drops back after a restart. The
Kindle has 1 GB.

## Kindle Paperwhite: Send Book and Send Plugin

| Transfer | Size | Time | Throughput |
| --- | --- | --- | --- |
| Phone → Kindle over Wi-Fi, 9 PDFs in one session | 66.0 MB | 21 s (first upload to last stored) | ≈ 3.1 MB/s |
| … the largest of them | 25.8 MB | ≈ 5 s | ≈ 5 MB/s |
| Computer → Kindle over an iPhone hotspot, RONkindle GitHub zip (Send Plugin) | 27.6 MB | 7 s | ≈ 3.9 MB/s |

The Kindle firewall rule (`iptables`) and the sleep hold (`lipc-set-prop`)
worked every time: 184 `firewall opened/closed` and `sleep held/released`
lines in the logs, and no failure.

Not measured yet: a stock Kindle side by side (same books, same screens).

## Emulator (before device testing)

These come from KOReader v2026.07.1 (Linux/SDL build) running this plugin at
Paperwhite 12 geometry (1264×1680, 300 dpi) in Docker, driven by
`tests/bench/run.sh 150 50`. The library was 150 books (120 EPUB, 30 PDF,
spread over 4 folders), 50 of them with KOReader reading-progress files.

Two runs:
- **Desktop**: a modern x86-64 core. Much faster than any Kindle.
- **Throttled**: the same container limited to 10 % of one core
  (`--cpus 0.1`). This is a crude pessimistic proxy, *not* a model of a
  Paperwhite. CFS throttling works in 100 ms slices, so its timings are coarse
  (steps of ~100 ms).

### Screen open times

| Screen | Desktop | Throttled (0.1 CPU) | What it does |
| --- | --- | --- | --- |
| Home (first, new process) | 28 ms | 602 ms | builds the card; loads the library cache file once per process |
| Home (after restart, cache on disk) | 19 ms | 290 ms | |
| My Library, **first ever open** (150 books) | 16 ms data + 32 ms to paint | 199 ms data + 304 ms to paint | folder scan (2 ms) + **50 sidecar reads** |
| My Library, **later opens** | 4 ms data + 18 ms to paint | 5 ms data + 203 ms to paint | **0 sidecar reads**; one `stat()` of each book and its sidecar |
| My Library after a KOReader restart | 8 ms data + 31 ms to paint | 100 ms data + 396 ms to paint | cache file read once (≈95 ms throttled for 150 entries) |
| Library page turn (covers cached) | 15 ms | 18 ms | loads ≤ 9 small thumbnails, no image decoding |
| Library page turn (while a cover job runs) | 36 ms | 561 ms | shares the CPU with the extraction child |
| Installed Plugins (29 plugins) | 14–21 ms | 104–205 ms | list only; no plugin code runs |

### Cover extraction (first time a book is shown)

| | Desktop | Throttled |
| --- | --- | --- |
| 9 books (one page), child process | 0.77–1.03 s | 13–15 s |
| per book, in-process (previous design, for reference) | 42–150 ms | 0.45–1.6 s |

The page is usable during extraction: text covers are shown first, then each
real cover replaces its tile. The child runs with `SCHED_BATCH` + `nice 5`
(`ffiUtil.runInSubProcess` defaults), so it yields to the UI. That is also why
it takes longer than in-process extraction when the CPU is scarce. Every cover
is extracted only once. Books received through Send Book are extracted as
soon as they arrive.

### Memory

| | Lua heap | Process RSS |
| --- | --- | --- |
| Home / Library open | 12–16 MB | stable (±2 MB) |
| 81 covers extracted (9 pages), **in-process** (previous design) | stable | **+137 MB** (193 → 330 MB), linear, no plateau |
| 81 covers extracted, **child process** (current) | stable | **+6 MB** (194 → 200 MB) |
| 150 distinct books opened in-process, isolated test | | +245 MB |

The in-process growth comes from KOReader's document engines keeping memory
for every document opened. Repeating the same documents added nothing, and
Lua's garbage collector did not release it. That finding is why extraction
moved to a child process (see [ARCHITECTURE.md](ARCHITECTURE.md#library-cache-covers-memory)).
Absolute RSS here includes the desktop SDL/X11 build and is not comparable to
a Kindle. The deltas are what matter.

### Installed Plugins: before and after

Building every plugin's menu on open (the previous design) was measured with
an emulator-only user patch (`tests/bench/2-kindleui-eager-plugins-bench.lua`):
**≈1 ms for 30 built-in plugins, even throttled**. So that was not a speed
problem with the built-in plugins. The change to building a menu only when
tapped is about **not running third-party code** every time the screen opens,
and about not scaling with plugin count. The screen's open time is dominated by
drawing the list.

### Send Book

| | Desktop (emulator, headless Chromium as the phone) |
| --- | --- |
| Phone page load | 85–217 ms |
| 3 files (0.8 MB EPUB, rejected .exe, 3.6 MB PDF), whole batch | 0.77 s |

The server reads for at most 40 ms per 50 ms main-loop tick, in 64 KiB
chunks. On the Kindle that gave 3–5 MB/s (above).

## Reproduce

```sh
tools/kindle.sh bench 150 50      # on a Kindle (docs/TESTING.md section 3)
tests/bench/run.sh 150 50         # emulator, desktop
tests/bench/run.sh 150 50 0.1     # emulator, throttled
```
