# Performance

**None of these numbers were measured on a Kindle.** They come from KOReader
v2026.07.1 (Linux/SDL build) running this plugin at Paperwhite 12 geometry
(1264×1680, 300 dpi) in Docker, driven by `tests/bench/run.sh 150 50`. The
library was 150 books (120 EPUB, 30 PDF, spread over 4 folders), 50 of them
with KOReader reading-progress files.

Two runs:
- **Desktop**: a modern x86-64 core. Much faster than any Kindle.
- **Throttled**: the same container limited to 10 % of one core
  (`--cpus 0.1`). This is a crude pessimistic proxy, *not* a model of a
  Paperwhite. CFS throttling works in 100 ms slices, so its timings are coarse
  (steps of ~100 ms).

"To first paint" means from the tap handler until the screen has been drawn
into KOReader's framebuffer, not including the e-ink refresh itself.

The comparison with a stock Kindle still has to be done on the device, side by
side, using the `KindleUI perf:` log lines (see [TESTING.md](TESTING.md)).

## Screen open times

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

## Cover extraction (first time a book is shown)

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

## Memory

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

## Installed Plugins: before and after

Building every plugin's menu on open (the previous design) was measured with
an emulator-only user patch (`tests/bench/2-kindleui-eager-plugins-bench.lua`):
**≈1 ms for 30 built-in plugins, even throttled**. So that was not a speed
problem with the built-in plugins. The change to building a menu only when
tapped is about **not running third-party code** every time the screen opens,
and about not scaling with plugin count. The screen's open time is dominated by
drawing the list.

## Send Book

| | Desktop (emulator, headless Chromium as the phone) |
| --- | --- |
| Phone page load | 85–217 ms |
| 3 files (0.8 MB EPUB, rejected .exe, 3.6 MB PDF), whole batch | 0.77 s |

Hotspot throughput on a real Kindle is not known yet. The server reads for at
most 40 ms per 50 ms main-loop tick, in 64 KiB chunks.

## Reproduce

```sh
tests/bench/run.sh 150 50         # desktop
tests/bench/run.sh 150 50 0.1     # throttled
```
