# KOReader APIs used

Every KOReader API the plugin relies on, where it lives, and what it is used for.
Line numbers refer to `koreader/koreader` master **`d9cd278`** (2026-09-23) and
`koreader/koreader-base` **`9a87297`**. The plugin was run against the
**KOReader v2026.07.1** Linux build (see [TESTING.md](TESTING.md)). Line
numbers drift between versions; the names are what matters.

Nothing below is patched, wrapped or replaced. The plugin only *calls* these
APIs.

## How the Home screen comes back when you leave a book

No KOReader or plugin function is overridden, and Home is not tied to the Home
key. It relies on one KOReader behaviour: **leaving a book always creates a new
FileManager, and KOReader creates a new instance of every plugin for each
FileManager.**

1. Every way out of a book ends in `ReaderUI:showFileManager()`
   (`frontend/apps/reader/readerui.lua:581`). Since no FileManager exists while
   reading, that calls `FileManager:showFiles()` (`filemanager.lua:1312`),
   which builds a new FileManager:
   - the **file-browser icon** in the reader's top menu
     (`readermenu.lua:65-73`: `self.ui:onClose(); self.ui:showFileManager(file)`),
     which is the usual route on a touch Kindle such as the Paperwhite 12;
   - the **Home key** or the **"File browser" gesture/action**, which sends the
     `Home` event (`dispatcher.lua:61`) to `ReaderUI:onHome()`
     (`readerui.lua:931`), which does the same;
   - end-of-book actions and other plugins that return to the file browser.
2. `FileManager:init()` instantiates all enabled plugins
   (`filemanager.lua:418-430`, `PluginLoader:createPluginInstance`), including
   this one. `setupLayout()` only runs *after* that, so at that moment the
   plugin can tell it is in a FileManager only because `self.ui.document` is nil.
   A ReaderUI always has its document.
3. `KindleUI:init()` (`main.lua`) then shows Home with `UIManager:nextTick()`,
   after the file browser itself is up, if *Show Home screen at startup* is on
   (the default), or if "Kindle-style Home" was chosen from the reader menu.

Consequences worth knowing:
- Home appears **every** time a FileManager is created, whichever way the book
  was closed. That is how a stock Kindle behaves.
- If *Show Home screen at startup* is off, closing a book shows KOReader's file
  browser. Home is still in the main menu (☰ → Kindle-style Home).
- *Open KOReader file browser* chosen from inside a book sets a one-shot flag
  so that the FileManager it creates does *not* show Home. From Home, it just
  closes Home.
- Confirmed in the emulator (KOReader v2026.07.1): opening the quickstart guide
  and tapping the reader menu's file-browser icon brings up Home.

## Plugin framework

| API | Location | Used for |
| --- | --- | --- |
| `WidgetContainer:extend{ name, is_doc_only = false }` | `frontend/ui/widget/container/widgetcontainer.lua` | Plugin class (`main.lua`) |
| `_meta.lua` `fullname`, `description` | merged in `frontend/pluginloader.lua:_load` | Name in Plugin management |
| `self.ui` (FileManager or ReaderUI) passed at instantiation | `pluginloader.lua` `createPluginInstance` | Host UI access |
| `self.ui.menu:registerToMainMenu(self)` + `addToMainMenu(menu_items)`, `sorting_hint = "main"` | `filemanagermenu.lua:1114`, `readermenu.lua:532` | "Kindle-style Home" in KOReader's main menu |
| `Dispatcher:registerAction(id, {...})` | `frontend/dispatcher.lua:656` | Gesture/key actions *Kindle-style Home*, *Send Book* |
| `PluginLoader:loadPlugins()` | `pluginloader.lua:273` | Installed Plugins list (module tables already loaded by KOReader: name, fullname, description) |
| `PluginLoader:getPluginInstance(name)` | `pluginloader.lua:573` | The live instance; the list only checks `type(instance.addToMainMenu) == "function"` |
| plugin `instance:addToMainMenu(scratch_table)` | the same call `FileManagerMenu:setUpdateItemTable` makes (`filemanagermenu.lua:854`, and its `dbg:guard` mock at `:866`) | Only when a plugin is **tapped** in Installed Plugins, for that plugin only |
| `PluginShare.pause_auto_suspend` | read by `plugins/autosuspend.koplugin/main.lua:68`; also set by Keep alive and Autoturn | No auto-suspend while Send Book is open (previous value restored) |
| `PluginShare.keepalive` | `plugins/keepalive.koplugin` | Don't release the Kindle screensaver hold if the user enabled Keep alive |
| User patches `<data>/patches/2-*.lua` | `frontend/userpatch.lua` | Emulator-only benchmark and test hooks (`tests/bench/`), never shipped |

## Menus and widgets

| API | Location | Used for |
| --- | --- | --- |
| `menu:setUpdateItemTable()`, `menu.tab_item_table`, `MenuSorter:findById(tbl, id)` | `filemanagermenu.lua:129`, `readermenu.lua:179`, `ui/menusorter.lua:194` | Reuse KOReader's own entries by id in Settings: `frontlight`, `screensaver`, `screen_rotation`, `night_mode`, `document_end_action`, `network`, `plugin_management` |
| `menu:onShowMenu(tab_index)` | `filemanagermenu.lua:1009`, `readermenu.lua:393` | Settings → Advanced → Open KOReader Settings / tools menu |
| `TouchMenu`, `Menu`, `TitleBar`, `ButtonDialog`, `Button`, `FocusManager`, `InputContainer`, `GestureRange` (function ranges), `CenterContainer`, `FrameContainer`, `VerticalGroup`, `HorizontalGroup`, `TextWidget`, `TextBoxWidget`, `ImageWidget`, `ProgressWidget`, `LineWidget`, `InfoMessage` | `frontend/ui/widget/…` | All screens |
| `InputContainer:onHome` daisy-chain | `container/inputcontainer.lua:405` | Home key closes our screens one by one; the Home widget handles it and stops the chain |
| `FrameContainer:getSize()` ignores `width` | `container/framecontainer.lua:54` | Why the grid is centred with a `CenterContainer` (found in the emulator) |
| `UIManager:show/close/setDirty/nextTick/scheduleIn/unschedule/isWidgetShown/setSuspendRepaints` | `frontend/ui/uimanager.lua` | Widget lifecycle |
| `UIManager.event_hook:execute("InputEvent")` | `uimanager.lua:1529` (what the main loop does on input) | After Send Book, restart AutoSuspend's idle countdown from "now" |
| Broadcast events `Suspend`, `Exit`, `ShowingReader` | `device/generic/device.lua:1101`, `ui/elements/common_exit_menu_table.lua`, `readerui.lua` | Stop the transfer server; close our screens when a book opens |

## Library, books, covers, the reader

| API | Location | Used for |
| --- | --- | --- |
| `filemanagerutil.getHomeFolder()`, `splitFileNameType()` | `filemanagerutil.lua:25`, `:45` | Library root / received books; title fallback |
| `DocumentRegistry:getExtensions()` | `document/documentregistry.lua:197` | Supported formats (scan, upload acceptance, phone page text) |
| `DocSettings:findSidecarFile(path)` | `frontend/docsettings.lua:159` | Sidecar location → its mtime is the cache validity check |
| `FileManagerBookInfo:getDocProps(file, nil, true)` (via `ui.bookinfo`) | `filemanagerbookinfo.lua:320` | Title/author from sidecar, only when the sidecar changed |
| `BookList.getBookInfo`, `BookList.resetBookInfoCache` | `ui/widget/booklist.lua:337`, `:328` | Progress/status, only when the sidecar changed |
| `DocumentRegistry:getProvider/openDocument`, `ReaderUI:extendProvider`, `document:loadDocument(false)`, `document:getProps()`, `document:close()` | `documentregistry.lua`, `readerui.lua` | Metadata-only open in the extraction **child process** (same sequence as Cover browser, `bookinfomanager.lua:496-557`) |
| `FileManagerBookInfo:getCoverImage(document)`, `FileManagerBookInfo.extendProps` | `filemanagerbookinfo.lua:461`, `:302` | Cover (honours custom covers) and custom metadata |
| `RenderImage:scaleBlitBuffer` | `ui/renderimage.lua:303` | Thumbnail scaling |
| `Blitbuffer.new/blitFrom/getPixel/free/setAllocated`, `ffi/zstd` | koreader-base | Grayscale thumbnails, stored zstd-compressed (same format idea as Cover browser) |
| `ffiUtil.runInSubProcess`, `isSubProcessDone`, `terminateSubProcess`, `getNonBlockingReadSize`, `readAllFromFD`, `writeToFD` | koreader-base `ffi/util.lua:350-590` | Extraction child process + result pipe (why: see ARCHITECTURE.md → Memory) |
| `LuaSettings:open/readSetting/saveSetting/flush`, `DataStorage:getSettingsDir()` | `frontend/luasettings.lua`, `datastorage.lua:60` | `kindleui_library.lua` cache file, `kindleui_covers/` |
| `ffi/sha2`.md5 | koreader-base | Thumbnail file names |
| `G_reader_settings:readSetting("lastfile")`, `ReadHistory.hist` | `frontend/readhistory.lua` | Continue Reading; "Recent" sort |
| `FileManager.instance:openFile(file, nil, nil, nil, after_open_callback)` / `ReaderUI:showReader(…)` | `filemanager.lua:1616`, `readerui.lua:616` | Open a book |
| `ReaderUI:onHome()` | `readerui.lua:931` | "Kindle-style Home" from inside a book |
| `ReaderConfig:onShowConfigMenu()` | `readerconfig.lua:134` | Settings → Reading → Font, size and margins |
| `FileManager.instance:onRefresh()` | `filemanager.lua:857` | Refresh the file browser after a transfer |
| `ui.bookinfo:show(file)` | `filemanagerbookinfo.lua:71` | Hold a cover → KOReader's book details |

## Network, HTTP, QR, sleep

| API | Location | Used for |
| --- | --- | --- |
| `NetworkMgr:isConnected()`, `runWhenConnected(cb)`, `getNetworkInterfaceName()` | `ui/network/manager.lua:187`, `:713`, `:192` | Wi-Fi pre-flight (no internet check), "Turn on Wi-Fi", preferred interface |
| `NetInfo:new():retrieve()` | koreader-base `ffi/netinfo.lua:79` | Interfaces and IPv4 addresses |
| `Device:getDefaultRoute()` | `device/generic/device.lua:854` | Route-lookup fallback |
| `Device:isKindle()` + `iptables -A/-D INPUT/OUTPUT … --dport/--sport <port>` | pattern from `plugins/SSH.koplugin/main.lua:67`, `httpinspector.koplugin/main.lua:87` | Open/close the port in the Kindle firewall; exit status logged |
| `lipc-set-prop com.lab126.powerd preventScreenSaver 1/0` | pattern from `plugins/keepalive.koplugin/main.lua:38-41` | Kindle system sleep timer held while Send Book is open |
| `UIManager:preventStandby()/allowStandby()` | `uimanager.lua:1732/1721` | No standby while Send Book is open (reference counted) |
| LuaSocket `bind/accept/receive/send/select/udp/gettime` | bundled (as used by `ui/message/simpletcpserver.lua`) | The HTTP server |
| `UIManager:insertZMQ(obj)/removeZMQ(obj)` (`waitEvent()`, `stop()`) | `uimanager.lua:774/779`, polled in `processZMQs` `:1524` every `ZMQ_TIMEOUT` (50 ms, `:32`) | Server polled only while Send Book is open; `UIManager:quit` also calls `stop()` |
| `ffi/qrencode.qrcode`, `QRWidget` | koreader-base `ffi/qrencode.lua:1132`, `ui/widget/qrwidget.lua` | QR code |
| `ffi/util.df(path)` | koreader-base `ffi/util.lua:114` | Free space before accepting an upload |
| `libs/libkoreader-lfs`, `util.getFileNameSuffix`, `logger` | koreader-base, `frontend/util.lua`, `frontend/logger.lua` | Files, logging |
| `ui/time` (`monotonic`, `to_ms`) | `frontend/ui/time.lua` | "KindleUI perf:" timings |

## Self-update

| API | Location | Used for |
| --- | --- | --- |
| `self.path` of the plugin instance (set by PluginLoader) | `pluginloader.lua:_load` (`plugin_module.path = plugin_root`) | Where the plugin is installed (what gets replaced) |
| `socket.http.request{ url, sink, headers, redirect = false, create = … }` | bundled LuaSocket (`common/socket/http.lua`: a custom `create` replaces the https scheme's default) | Requests over our verified TLS connection |
| `ssl.wrap`, `conn:sni`, `conn:dohandshake`, `conn:getpeercertificate`, `cert:extensions()`, `cert:subject()` | bundled LuaSec 1.3.2 | Chain check (`verify = "peer"`) + host-name check |
| `data/ca-bundle.crt` | KOReader data folder (certifi bundle, `base/thirdparty/certifi`) | Trusted CAs |
| `require("json").decode` | bundled | GitHub API answer |
| `ffi/archiver` `Reader:new/open/iterate/extractToPath/close` | koreader-base `ffi/archiver.lua` (libarchive, `ARCHIVE_EXTRACT_SECURE_NODOTDOT`) | Extract the downloaded zip |
| `ffiUtil.purgeDir` | koreader-base `ffi/util.lua:259` | Remove staging/backup folders |
| `NetworkMgr:runWhenOnline(cb)` | `ui/network/manager.lua:698` | Make sure the Kindle is online first |
| `UIManager:forceRePaint()` | `uimanager.lua:1404` | Show "Checking…" before the blocking request |
| `UIManager:askForRestart(text)` | `uimanager.lua:1706` | "Restart KOReader now?" after installing |

## Uncertain / version-sensitive points

- `MenuSorter:findById` returns, for sub-menus, the placeholder entry
  `{ id, text, sub_item_table }`. That relies on an internal detail. If an id is
  missing (user menu customisation, another platform), that Settings entry is
  simply left out. In the emulator, *Device* shows only Rotation, because the
  SDL build has no frontlight or screensaver.
- Calling a plugin's `addToMainMenu` on a scratch table assumes it only fills
  that table. KOReader's own debug guard relies on the same thing. It now
  happens only for the plugin you tap. Errors are caught and logged, and the
  plugin is shown as "No menu".
- The Kindle-only parts (`iptables`, `lipc-set-prop`) could not be exercised
  in the emulator. They mirror KOReader's own SSH and Keep alive plugins, and
  failures are logged.
