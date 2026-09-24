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

Rules the code follows:

- **Nothing is re-implemented.** Books open through `FileManager:openFile` /
  `ReaderUI:showReader`. Metadata comes from KOReader's sidecars through
  `FileManagerBookInfo:getDocProps` and `BookList`. Settings entries are
  KOReader's own menu entries, and plugin menus are the plugins' own.
- **Nothing is monkey-patched.** No KOReader or third-party function is
  replaced or wrapped.
- **No dead ends.** The Back key on Home reveals KOReader's file browser.
  Settings → Advanced opens KOReader's full menu. Installed Plugins lists
  every plugin and links to KOReader's Plugin management.
- **Nothing runs in the background.** Home is a static widget with no timers.
  The HTTP server exists only while the Send Book screen is open.

## Phase 1 report: what KOReader already provides

Inspected: `koreader/koreader` master `d9cd278` (2026-09-23) and
`koreader/koreader-base` `9a87297`.

| Need | Existing KOReader facility | Decision |
| --- | --- | --- |
| Plugin lifecycle | `frontend/pluginloader.lua`: discovers `*.koplugin` in `plugins/` and `<data>/plugins/`, `dofile`s `main.lua`, merges `_meta.lua`, and instantiates per FileManager/ReaderUI with `{ ui = … }` | Standard `WidgetContainer` plugin, `is_doc_only = false` |
| Plugin discovery | `PluginLoader:loadPlugins()` → enabled/disabled module lists; `PluginLoader:getPluginInstance(name)` | Used as-is for Installed Plugins |
| Plugin menus | Plugins implement `addToMainMenu(menu_items)`; FileManagerMenu/ReaderMenu call it for each registered widget (and `dbg:guard` calls it on a mock table) | Call it on a scratch table and show the result in `TouchMenu` |
| Menus | `ui/widget/touchmenu` (tabbed), `ui/widget/menu` (full-screen lists), `ui/menusorter` (`findById`) | Reused; KOReader's own items fetched by id |
| Library data | `FileChooser` (browsing), `util.findFiles`, `DocumentRegistry` (supported formats), `BookList.getBookInfo` (progress/status from sidecar), `FileManagerBookInfo:getDocProps(file, nil, true)` (metadata without opening), `ReadHistory` | Reused. The simple library is a scan-on-open view, not an index |
| Covers | Cover browser plugin's `BookInfoManager` SQLite cache | Read-only, and only when that plugin is enabled |
| Open/return to reader | `FileManager:openFile`, `ReaderUI:showReader(…, after_open_callback)`, `ReaderUI:onHome` → `showFileManager` | Reused. Home reappears whenever the file browser is created |
| Network state | `NetworkMgr:isConnected()` (link + IP, no internet check), `NetworkMgr:runWhenConnected()` | Reused for the Wi-Fi pre-flight |
| Local IP | `ffi/netinfo` (`getifaddrs`), `Device:getDefaultRoute()`, `NetworkMgr:getNetworkInterfaceName()` | Reused, plus a UDP route lookup and `ip`/`ifconfig` fallbacks |
| QR codes | `ffi/qrencode` (pure Lua) + `ui/widget/qrwidget` | Reused |
| HTTP server | `ui/message/simpletcpserver.lua` (LuaSocket) polled by `UIManager:insertZMQ` (used by the HTTP-inspector plugin). It reads headers only and would buffer everything in RAM | Same integration pattern, but our own small server so bodies stream to disk without blocking the UI |
| Kindle firewall | SSH / HTTP-inspector plugins add and remove `iptables` rules around their port | Same approach |
| Existing upload plugins | None in core: Calibre wireless is a *client* of Calibre, SSH/FTP need extra tools | Not reusable for browser uploads |
| Settings storage | `G_reader_settings` | One key: `kindleui` |

APIs are listed with file references in [KOREADER_APIS.md](KOREADER_APIS.md).

## Module map

```
kindleui.koplugin/
├── _meta.lua                 fullname/description for Plugin management
├── main.lua                  plugin class: init, menu entry, dispatcher actions,
│                             navigation between screens, KOReader delegation
└── kindleui/                 (namespaced so requires never collide with KOReader's)
    ├── config.lua            defaults + G_reader_settings["kindleui"]
    ├── ui/
    │   ├── common.lua        fonts, lines, Tappable, single-tab TouchMenu helper
    │   ├── home.lua          Home screen (FocusManager: works with keys too)
    │   ├── library.lua       My Library (Menu subclass)
    │   ├── plugins.lua       Installed Plugins (Menu subclass)
    │   ├── settings.lua      Settings item tree (TouchMenu)
    │   └── transfer.lua      Send Book screen (state machine)
    ├── transfer/
    │   ├── provider.lua      provider registry (local_http | cloud placeholder)
    │   ├── localhttp.lua     "Local Wi-Fi" provider (pre-flight + session wiring)
    │   ├── session.lua       token, expiry, routing, validation, lifecycle
    │   ├── server.lua        non-blocking HTTP/1.1 server (LuaSocket)
    │   ├── upload.lua        temp file → validate → atomic rename
    │   ├── uploadpage.lua    the phone page (HTML + tiny vanilla JS)
    │   └── qr.lua            URL + QRWidget
    └── util/
        ├── books.lua         adapter to KOReader library/metadata/open APIs
        ├── network.lua       IPv4 discovery, Kindle firewall
        ├── filesystem.lua    paths, free space, unique names, format sniffing
        └── security.lua      CSPRNG tokens, constant-time compare, filename sanitizer
```

`transfer/{session,server,upload,uploadpage}` and `util/{security,filesystem,network}`
depend on nothing KOReader-specific at load time (services are injected or
`pcall`-required), so they run under plain LuaJIT in the tests.

## Screen flow

```
KOReader starts → FileManager created → plugin init → nextTick: show Home
Home ─ Continue Reading ─→ FileManager:openFile ─→ reader
     ─ My Library ───────→ Library (Menu) ─ tap book ─→ reader
                                          ─ ☰ → sort / refresh / "Browse all files (KOReader)"
     ─ + Send Book ──────→ TransferScreen
     ─ Installed Plugins ─→ Plugins (Menu) ─ Open ─→ plugin's own menu (TouchMenu)
                                           ─ Manage plugins (KOReader)
     ─ Settings ─────────→ TouchMenu: Reading/Library/Device/Connectivity/Advanced/About
                                                     └ Advanced → Open KOReader Settings
reader ─ Home key / "Kindle-style Home" menu entry ─→ ReaderUI:onHome → FileManager → Home
Home ─ Back key ─→ KOReader file browser (Home closes; reopen from ☰ menu)
```

## Transfer flow

```
Send Book tapped
  provider:prepare()
    NetworkMgr:isConnected()?           no → "Wi-Fi connection required" [Turn on Wi-Fi][Try Again]
    Network.getLocalAddress()           none → "Unable to determine local network address"
  provider:start()
    token = 16 bytes /dev/urandom (hex)  failure → "Unable to start transfer service"
    Server:start() on 8080..8089         failure → "Unable to start transfer service"
    iptables hole (Kindle only)
    UIManager:insertZMQ(server)          ← polled only while registered
    UIManager:scheduleIn(15 min, expire)
    UIManager:preventStandby()
  QR.newWidget("http://<ip>:<port>/<token>")  failure → "Unable to create transfer QR code"

Phone: GET /<token>                    → upload page (404 for any other path/token)
Phone: POST /<token>/upload?name=…     (raw file body, Content-Length)
  sanitize name → supported extension? → length present? → ≤ max? → free space?
  → open <dest>/.kindleui-upload-<rand>.part
  → stream chunks (≤ 40 ms per main-loop tick) → progress in 10 % steps
  → size == Content-Length? → magic bytes ok? → rename to unique final name
  → 200 "Book sent successfully"
  nextTick: session:stop("done")
    removeZMQ, close listener + clients, remove iptables rule,
    unschedule expiry, allowStandby, clear token
  → FileManager:onRefresh(), "✓ Book received" [Read Now][Send Another][Done]

Any failure mid-upload: temp file deleted, phone gets a message, Kindle shows
it, and the session keeps waiting (same QR) until Cancel/expiry.
Cancel / Done / Home / Back / Suspend / Exit / reader opening:
TransferScreen:onCloseWidget (or the handler) → session:stop().
```

### Why the temp file is not in /tmp

On Kindle, `/tmp` is a small RAM-backed tmpfs and `/mnt/us` is a separate
VFAT filesystem. Renaming across them becomes a copy, which is slow, uses RAM
and can fail half-way. A hidden `.part` file in the destination folder gives an
atomic `rename()` and never appears in KOReader's browser, which hides dot-files.

### Why a raw-body upload instead of multipart

`XMLHttpRequest.send(file)` streams the file as the request body with a
`Content-Length`, so the Kindle writes bytes straight to disk. There is no
multipart boundary parsing and no buffering. The filename travels
URL-encoded in the query string and is sanitised like any other untrusted
input.

### Resource usage

- Home, Library, Plugins, Settings: static widgets with no timers, polling or
  background work.
- Send Book: one listening socket and up to 6 client sockets. KOReader's loop
  wakes every 50 ms (its `ZMQ_TIMEOUT`) only while the server is registered.
  Each tick spends at most 40 ms reading. Memory per upload is one 64 KiB
  chunk.
- Screen updates during upload happen in 10 % steps (at most ~10 e-ink
  refreshes).

## Future: cloud transfer

`transfer/provider.lua` is the seam. A future `cloudr2` provider would
implement the same `prepare()` / `start(info, callbacks)` interface (for
example a pairing code instead of a LAN URL). The UI already lists
**Transfer method: Local Wi-Fi / Cloud (not available yet)**. The Cloud entry
cannot be selected, and nothing in the local provider depends on it.
