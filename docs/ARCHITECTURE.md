# Architecture

## Principle

KOReader stays the platform. The plugin is a thin presentation layer:

```
┌───────────────────────────────────┐
│   kindleui.koplugin (this shell)  │   Home · Library · Send Book ·
│                                   │   Installed Plugins · Settings
└────────────────┬──────────────────┘
                 │ existing KOReader APIs only (no patches, no forks)
┌────────────────▼──────────────────┐
│             KOReader              │   reader, rendering, metadata,
│                                   │   file browser, menus, plugins
└───────────────────────────────────┘
```

- **Nothing is re-implemented.** Books open through `FileManager:openFile` /
  `ReaderUI:showReader`. Metadata comes from KOReader's sidecars and document
  engines. Settings entries are KOReader's own menu entries, and plugin menus
  are the plugins' own.
- **Nothing is monkey-patched.** Home reappears after reading because KOReader
  creates a new plugin instance whenever it builds a file browser (exact
  mechanism in [KOREADER_APIS.md](KOREADER_APIS.md#how-the-home-screen-comes-back-when-you-leave-a-book)).
- **No dead ends.** Back on Home shows KOReader's file browser. Settings →
  Advanced opens KOReader's full menu. Installed Plugins lists every plugin.
- **Nothing runs in the background.** Work happens only while the screen that
  needs it is open: Send Book's server, and cover extraction for the Library
  page on screen.

## Phase 1 report: what KOReader already provides

Inspected: `koreader/koreader` master `d9cd278` (2026-09-23) and
`koreader/koreader-base` `9a87297`. The plugin was then run against the
KOReader v2026.07.1 Linux build.

| Need | Existing KOReader facility | Decision |
| --- | --- | --- |
| Plugin lifecycle | `frontend/pluginloader.lua`: discovers `*.koplugin` in `plugins/` and `<data>/plugins/`, merges `_meta.lua`, creates an instance per FileManager/ReaderUI with `{ ui = … }` | Standard `WidgetContainer` plugin, `is_doc_only = false` |
| Plugin discovery | `PluginLoader:loadPlugins()` → enabled/disabled module lists; `getPluginInstance(name)` | Used as-is for Installed Plugins |
| Plugin menus | Plugins implement `addToMainMenu(menu_items)`, called by FileManagerMenu/ReaderMenu | Called on a scratch table, only for the plugin tapped, and shown in `TouchMenu` |
| Menus | `TouchMenu`, `Menu`, `MenuSorter:findById` | Reused; KOReader's own entries fetched by id |
| Library data | `DocumentRegistry` (formats), `BookList`/`FileManagerBookInfo` (sidecar metadata, progress), `ReadHistory` | Reused, behind a small mtime-validated cache |
| Covers | Document engines via `FileManagerBookInfo:getCoverImage`; Cover browser shows how to run extraction in a child process | Same approach, without depending on Cover browser |
| Open/return to reader | `FileManager:openFile`, `ReaderUI:showReader`, `ReaderUI:onHome`/`showFileManager` | Reused; Home reappears whenever a FileManager is created |
| Network state | `NetworkMgr:isConnected()` (link + IP, no internet check), `runWhenConnected()` | Wi-Fi pre-flight |
| Local IP | `ffi/netinfo` (getifaddrs), `Device:getDefaultRoute()`, `NetworkMgr:getNetworkInterfaceName()` | Reused, plus a UDP route lookup and `ip`/`ifconfig` fallbacks |
| QR codes | `ffi/qrencode` + `ui/widget/qrwidget` | Reused |
| HTTP server | `ui/message/simpletcpserver.lua` (LuaSocket) polled via `UIManager:insertZMQ` (HTTP-inspector plugin). It reads headers only and would buffer in RAM | Same integration, own small server that streams bodies to disk |
| Kindle firewall / sleep | SSH & HTTP-inspector plugins (`iptables`), Keep alive plugin (`lipc … preventScreenSaver`), AutoSuspend (`PluginShare.pause_auto_suspend`) | Same switches, restored afterwards |
| Existing upload plugins | None in core (Calibre wireless is a *client*; SSH/FTP need extra tools) | Not reusable for browser uploads |
| Settings storage | `G_reader_settings`, `LuaSettings` | One key `kindleui`; one cache file |

## Module map

```
kindleui.koplugin/
├── _meta.lua                 fullname/description for Plugin management
├── main.lua                  plugin class: init (Home on FileManager creation,
│                             stale temp cleanup), menu entry, dispatcher actions,
│                             navigation, KOReader delegation
└── kindleui/                 (namespaced so requires never collide with KOReader's)
    ├── config.lua            defaults + G_reader_settings["kindleui"]
    ├── ui/
    │   ├── common.lua        fonts, lines, Tappable, single-tab TouchMenu helper
    │   ├── home.lua          Home (FocusManager: works with keys too)
    │   ├── library.lua       data loading + sort + options dialog + list view
    │   ├── librarygrid.lua   cover grid view (default)
    │   ├── plugins.lua       Installed Plugins (menus built only on tap)
    │   ├── plugininstall.lua Install plugin from phone: pick, confirm, install, undo
    │   ├── settings.lua      Settings item tree (TouchMenu)
    │   └── transfer.lua      Send Book screen (state machine; also "Send plugin")
    ├── transfer/
    │   ├── provider.lua      provider registry (only local_http today)
    │   ├── localhttp.lua     "Local Wi-Fi" provider (pre-flight, session, sleep guard)
    │   ├── session.lua       token, idle expiry, routing, validation, lifecycle
    │   ├── server.lua        non-blocking HTTP/1.1 server (LuaSocket)
    │   ├── upload.lua        temp file → validate → atomic rename
    │   ├── uploadpage.lua    the phone page (HTML + small vanilla JS, multi-file)
    │   └── qr.lua            URL + QRWidget
    └── util/
        ├── books.lua         adapter to KOReader library/open APIs, folder scan
        ├── librarycache.lua  metadata + thumbnail cache (one file + small .bbz files)
        ├── extractor.lua     cover/metadata extraction in a child process
        ├── sleepguard.lua    hold/restore AutoSuspend + Kindle screensaver timer
        ├── perf.lua          "KindleUI perf:" timing/memory log lines
        ├── https.lua         HTTPS GET with CA-chain *and* host-name checks
        ├── updater.lua       Check for updates: latest commit → zip → stage → swap
        ├── pluginzip.lua     plugin .zip analysis (pure: find folder, plan, _meta as text)
        ├── plugininstaller.lua  install from a zip: stage → compile check → swap, Undo
        ├── network.lua       IPv4 discovery, Kindle firewall (logged)
        ├── filesystem.lua    paths, free space, writability, unique names,
        │                     format sniffing, stale temp cleanup
        └── security.lua      CSPRNG tokens, constant-time compare, filename sanitizer
```

`transfer/{session,server,upload,uploadpage,qr}`,
`util/{security,filesystem,network,pluginzip}` and (with small stubs)
`util/plugininstaller` load under plain LuaJIT, so the automated
tests run them without KOReader.

## Screen flow

```
KOReader starts / a book is closed → new FileManager → plugin init → nextTick: Home
Home ─ Continue Reading ─→ FileManager:openFile ─→ reader
     ─ My Library ───────→ cover grid (or list) ─ tap ─→ reader
                                                 ─ hold ─→ KOReader book details
                                                 ─ ☰ ─→ view, sort, refresh, "Browse all files (KOReader)"
     ─ + Send Book ──────→ TransferScreen
     ─ Installed Plugins ─→ list ─ tap ─→ that plugin's own menu (TouchMenu)
     ─ Settings ─────────→ Reading / Library / Device / Connectivity / Advanced / About
                                                         └ Advanced → Open KOReader Settings,
                                                           Install plugin from phone, Undo last plugin install
reader ─ top menu file-browser icon, Home key, "File browser" gesture ─→ FileManager → Home
Home ─ Back key ─→ KOReader file browser (☰ → Kindle-style Home brings it back)
```

## Library: cache, covers, memory

**Data on open.** `Library.loadBooks` does:
1. Scan the home folder: `lfs.dir` + `lfs.attributes` per entry. Hidden
   folders and `.sdr` folders are skipped.
2. For each book, stat its KOReader sidecar (`DocSettings:findSidecarFile`).
3. Re-read a sidecar (title, author, progress) **only if its mtime changed**
   since the last time. Otherwise the values come from `kindleui_library.lua`,
   which is loaded once per KOReader process.
4. Sort in memory.

For 150 books: 50 sidecar reads the first time, then **0** on every later open
until a book is read again.

**Covers.** Stored per book as a zstd-compressed grayscale blitbuffer
(`kindleui_covers/<md5>.bbz`, typically a few KB). Showing a page loads at most
9 of them, and needs no image decoding.

- **Extraction:** a book without a thumbnail is extracted once, only when it is
  on the visible page, and only while the Library is open. The first page
  appears straight away with text covers (title + author), and real covers
  replace them tile by tile.
- **Books from Send Book:** extracted as soon as they arrive, so they already
  have a cover in the grid.
- **Blank first pages:** a cover that is (almost) a blank page, which is common
  for PDFs, is dropped so the text cover is used instead.

**Memory: why extraction runs in a child process.** Opening documents inside
KOReader's own process makes its document engines keep memory after
`document:close()`. Measured in the emulator:

| Extraction of N distinct books, in-process | RSS growth |
| --- | --- |
| 25 | +57 MB |
| 75 | +132 MB |
| 150 | +245 MB (no plateau) |
| same 30 books again | +0 MB (per-document cache) |

A Paperwhite has far too little RAM for that. So extraction runs in a forked
child (`ffiUtil.runInSubProcess`), the same approach as KOReader's Cover
browser. The child writes thumbnails to disk and streams one result line per
book over a pipe. The parent polls the pipe every 0.25 s, but only while a job
runs. Result: RSS stayed within +6 MB across 81 extractions, and the UI no
longer blocks while covers are extracted. Page change or closing the Library
kills the child (and reaps it). Thumbnails are written to a `.tmp` file and
renamed, so a killed child never leaves a half-written file.

## Transfer flow

```
Send Book tapped
  provider:prepare()
    NetworkMgr:isConnected()?             no → "Wi-Fi connection required" [Turn on Wi-Fi][Try Again]
    Network.getLocalAddress()             none → "Unable to determine local network address"
  provider:start()
    library folder exists / writable?     no → "…could not be found" / "…is read-only"
    token = 16 bytes /dev/urandom (hex)   failure → "Unable to start transfer service"
    Server:start() on 8080..8089          failure → "Unable to start transfer service"
    iptables hole (Kindle; exit status logged)
    UIManager:insertZMQ(server)           ← polled only while registered
    idle expiry timer (15 min)
    SleepGuard.hold(): PluginShare.pause_auto_suspend = true,
                       lipc preventScreenSaver 1 (Kindle), preventStandby()
  QR "http://<ip>:<port>/<token>"         failure → "Unable to create transfer QR code"

Phone: GET /<token>                        → upload page (404 for anything else)
Phone picks N books, then for each, in turn:
  POST /<token>/upload?name=…&index=i&count=N   (raw file body, Content-Length)
    sanitize name → supported? → length? → ≤ max? → free space?
    → <dest>/.kindleui-upload-<rand>.part → stream (≤ 40 ms per main-loop tick)
    → size == Content-Length? → magic bytes? → rename to a unique final name
    → 200; the Kindle adds the book, refreshes the file browser, and starts
      cover extraction for it in a child process
    (a rejected book does not end the session: the phone moves on to the next)
Phone: POST /<token>/finish
  nextTick: session:stop("done")
    removeZMQ, close listener + clients, remove iptables rule,
    unschedule expiry, SleepGuard.release() (restores previous values,
    restarts AutoSuspend's idle countdown), clear token
  → "✓ N books received" [Read Now | Open Library] [Send More] [Done]
```

- **Expiry is idle-based.** Every upload pushes it back, and it never fires
  while a file is arriving: the check re-arms itself while receiving. When it
  fires, the QR code is removed and the screen shows "This code has expired"
  with **New Code**.
- **Everything stops the server:** Cancel, Done, Back or Home key, sleep,
  KOReader exit, or a book opening. They all go through
  `TransferScreen:onCloseWidget` or its event handlers, and `session:stop()`.
- **Crash or power loss mid-upload:** the next KOReader start deletes files
  matching exactly `.kindleui-upload-<hex>.part` in the destination and home
  folders, before any session can exist.

### Why the temp file is not in /tmp

On Kindle, `/tmp` is a small RAM-backed tmpfs and `/mnt/us` is a separate VFAT
filesystem. A rename across them is really a copy. A hidden `.part` file in the
destination folder gives an atomic `rename()` and is hidden from KOReader's
browser.

### Why a raw-body upload instead of multipart

`XMLHttpRequest.send(file)` streams each file as the request body with a
`Content-Length`, so the Kindle writes straight to disk with no multipart
parsing and no buffering. Several books are sent as several sequential
requests.

## Performance and resource usage

Measured numbers are in [PERFORMANCE.md](PERFORMANCE.md).

- Home, Library, Installed Plugins and Settings have no timers and no polling.
  The only exceptions: the Library polls its extraction child every 0.25 s while
  it works, and Home runs a one-off extraction for the current book's cover.
- Send Book keeps one listening socket and at most 6 client sockets.
  KOReader's loop wakes every 50 ms (`ZMQ_TIMEOUT`) only while the server is
  registered. Each tick spends at most 40 ms reading, in 64 KiB chunks.
- Installed Plugins runs no plugin code when it opens. A plugin's menu is built
  when you tap it.

## Self-update

Settings → About → **Check for updates** (only when tapped):

```
api.github.com/repos/zakijariwala/kindle-plugin/commits/main   → latest sha
  same as BUILD file next to main.lua?  → "You have the latest version"
codeload.github.com/zakijariwala/kindle-plugin/zip/<sha>        (≤ 20 MB)
  extract only <repo>-<sha>/kindleui.koplugin/** (no "..", nothing else)
  → plugins/.kindleui.koplugin.new     (hidden, not a *.koplugin: never loaded)
  loadfile() main.lua, _meta.lua, config.lua, home.lua  → must compile
  write BUILD
  rename kindleui.koplugin → .kindleui.koplugin.old
  rename .kindleui.koplugin.new → kindleui.koplugin    (rollback if this fails)
  delete .old → "Restart KOReader now?"
```

**Why a custom HTTPS helper.** KOReader's LuaSec default is
`verify = "none"` (`common/ssl/https.lua`), and LuaSec 1.3 does not check
host names at all. For downloading code that gets installed, `util/https.lua`
opens the TLS connection itself: `verify = "peer"` against KOReader's bundled
`data/ca-bundle.crt`, plus a subjectAltName host-name match. In the emulator
it refused a wrong-host certificate, a self-signed one, a CA not in the
bundle, and plain HTTP.

## Install plugin from phone

The Send Book screen with `kind = "plugin"` (Settings → Advanced, or the row
at the end of Installed Plugins). Same session, token, server and expiry as
Send Book; only these differ:

```
session: kind "plugin", max_files 1, only *.zip (zip magic checked), ≤ 20 MB,
         stored in <settings>/kindleui-incoming/ (not the library)
phone page: "SEND PLUGIN", one file, plugin wording
phone POSTs /finish → screen closes → ui/plugininstall.lua:
  Installer.analyze: list entries, find <name>.koplugin folder(s) (any depth,
    also GitHub's "<name>.koplugin-main"), read fullname/description from
    _meta.lua as text (nothing from the zip runs)
  several plugins in the zip → pick one; built-in or this plugin → refused
  confirm: name, description, new / replaces, full-access warning, disabled note
  Installer.install:
    PluginZip.plan: refuse "..", absolute paths, links; ≤ 50 MB, ≤ 5000 files;
      only the plugin folder, minus __MACOSX/._*/.DS_Store/.git/…
    extract → plugins/.<name>.koplugin.new; loadfile main.lua + _meta.lua
    new:     rename .new → <name>.koplugin
    replace: rename <name> → .<name>.old, .new → <name> (rollback on failure),
             .old → .<name>.undo
    Config last_plugin_install = { name, had_previous }; older .undo removed
  → "Restart KOReader now?"
Undo last plugin install: restore .<name>.undo, or remove the new plugin → restart
```

At startup `main.lua` empties the incoming folder and removes `.undo`
folders the record does not point to; `Updater.cleanupLeftovers` already
handles interrupted `.new`/`.old` folders.

## Future: cloud transfer

`transfer/provider.lua` is the seam. A future provider implements the same
`prepare()` / `start(info, callbacks)` interface. Nothing in the UI mentions it
until it exists (the earlier greyed-out "Cloud" entry was removed).
