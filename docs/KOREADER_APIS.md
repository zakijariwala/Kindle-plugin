# KOReader APIs used

Every KOReader API the plugin relies on, where it lives, and what it is used for.
Line numbers refer to `koreader/koreader` master **`d9cd278`** (2026-09-23) and
`koreader/koreader-base` **`9a87297`**. They will drift in later versions;
the names are what matters.

Nothing below is patched or replaced. The plugin only calls these APIs.

## Plugin framework

| API | Location | Used for |
| --- | --- | --- |
| `WidgetContainer:extend{ name, is_doc_only = false }` | `frontend/ui/widget/container/widgetcontainer.lua` | Plugin class (`main.lua`) |
| `_meta.lua` `fullname`, `description` | merged in `frontend/pluginloader.lua:_load` | Name in Plugin management |
| `self.ui` (FileManager or ReaderUI) passed at instantiation | `frontend/pluginloader.lua` `createPluginInstance` | Host UI access |
| `self.ui.menu:registerToMainMenu(self)` + `addToMainMenu(menu_items)` with `sorting_hint = "main"` | `frontend/apps/filemanager/filemanagermenu.lua:1114`, `frontend/apps/reader/modules/readermenu.lua:532` | "Kindle-style Home" entry in KOReader's main menu |
| `Dispatcher:registerAction(id, { category, event, title, general })` | `frontend/dispatcher.lua:656` | Gesture/key actions *Kindle-style Home* and *Send Book* |
| `PluginLoader:loadPlugins()` | `frontend/pluginloader.lua:273` | Installed Plugins: enabled + disabled plugin modules (fullname, description, name) |
| `PluginLoader:getPluginInstance(name)` | `frontend/pluginloader.lua:573` | The live instance whose `addToMainMenu` we read |
| plugin `instance:addToMainMenu(scratch_table)` | convention; called the same way by `FileManagerMenu:setUpdateItemTable` (`filemanagermenu.lua:854`) and its `dbg:guard` mock (`:866`) | Installed Plugins → Open shows the plugin's own entries |

## Menus and widgets

| API | Location | Used for |
| --- | --- | --- |
| `FileManagerMenu:setUpdateItemTable()` / `ReaderMenu:setUpdateItemTable()` | `filemanagermenu.lua:129`, `readermenu.lua:179` | Build the host menu (if not built yet) so its entries can be reused |
| `menu.tab_item_table` + `MenuSorter:findById(tbl, id)` | `frontend/ui/menusorter.lua:194` | Fetch KOReader's own entries by id: `frontlight`, `screensaver`, `screen_rotation`, `night_mode`, `document_end_action`, `network`, `plugin_management`, `filemanager_display_mode` (Cover browser) |
| `FileManagerMenu:onShowMenu(tab_index)` / `ReaderMenu:onShowMenu(tab_index)` | `filemanagermenu.lua:1009`, `readermenu.lua:393` | Settings → Advanced → Open KOReader Settings / tools menu |
| `TouchMenu:new{ tab_item_table, width, show_parent, close_callback }` | `frontend/ui/widget/touchmenu.lua` | Settings and plugin menus (single tab) |
| `Menu:extend{…}`, `onMenuChoice`, `onLeftButtonTap`, `switchItemTable`, item fields `text`/`mandatory`/`select_enabled` | `frontend/ui/widget/menu.lua` | Library and Installed Plugins lists |
| `FocusManager`, `InputContainer`, `GestureRange` (function ranges) | `frontend/ui/widget/focusmanager.lua`, `container/inputcontainer.lua`, `frontend/ui/gesturerange.lua` | Home / Send Book screens (touch and key navigation) |
| `InputContainer:onHome` daisy-chain | `container/inputcontainer.lua:405` | Home key closes our screens; Home widget stops the chain |
| `Button`, `ButtonDialog`, `TextWidget`, `TextBoxWidget`, `FrameContainer`, `CenterContainer`, `VerticalGroup`, `HorizontalGroup`, `VerticalSpan`, `HorizontalSpan`, `LineWidget`, `ImageWidget`, `ProgressWidget`, `InfoMessage` | `frontend/ui/widget/…` | Layout |
| `Font:getFace`, `Size`, `Screen:scaleBySize`, `Blitbuffer.COLOR_*` | `frontend/ui/font.lua`, `frontend/ui/size.lua`, `frontend/device/…` | Typography and spacing |
| `UIManager:show/close/setDirty/nextTick/scheduleIn/unschedule/isWidgetShown/setSuspendRepaints` | `frontend/ui/uimanager.lua` | Widget lifecycle |
| Broadcast events `Suspend`, `Exit`, `ShowingReader` | `device/generic/device.lua:1101`, `ui/elements/common_exit_menu_table.lua`, `readerui.lua` | Stop the transfer server; close our screens when a book opens |

## Library, books and the reader

| API | Location | Used for |
| --- | --- | --- |
| `filemanagerutil.getHomeFolder()` | `frontend/apps/filemanager/filemanagerutil.lua:25` | Library root; destination of received books |
| `filemanagerutil.splitFileNameType()` | same file, `:45` | Title fallback from file name |
| `DocumentRegistry:getExtensions()` | `frontend/document/documentregistry.lua:197` | Which formats KOReader can open (library scan, upload acceptance, supported-formats text) |
| `FileManagerBookInfo:getDocProps(file, nil, true)` (via `ui.bookinfo`) | `frontend/apps/filemanager/filemanagerbookinfo.lua:320` | Title/author from sidecar/custom metadata/Cover browser without opening the book |
| `FileManagerBookInfo:getDocProps(file)` (metadata-only open) | same | Title/author of a just-received book |
| `BookList.getBookInfo(file)` → `percent_finished`, `status`, `been_opened` | `frontend/ui/widget/booklist.lua:337` | Progress in Continue Reading / Library |
| `BookList.resetBookInfoCache(file)` | `booklist.lua:328` | Drop cached info for a newly received file |
| `G_reader_settings:readSetting("lastfile")` | maintained by `frontend/readhistory.lua` | Continue Reading |
| `ReadHistory.hist[i].file/.time` | `frontend/readhistory.lua` | "Recent" sort order |
| `BookInfoManager:getBookInfo(file, true).cover_bb` (only when `ui.coverbrowser` exists) | `plugins/coverbrowser.koplugin/bookinfomanager.lua:325` | Cached cover on Home (never extracts) |
| `FileManager.instance:openFile(file, nil, nil, nil, after_open_callback)` | `frontend/apps/filemanager/filemanager.lua:1616` | Open a book (also handles non-document providers) |
| `ReaderUI:showReader(file, nil, nil, nil, after_open_callback)` | `frontend/apps/reader/readerui.lua:616` | Open a book when no FileManager exists |
| `ReaderUI:onHome()` | `readerui.lua:931` | "Kindle-style Home" from inside a book → FileManager → Home |
| `ReaderConfig:onShowConfigMenu()` (via `ui.config`) | `frontend/apps/reader/modules/readerconfig.lua:134` | Settings → Reading → Font, size and margins |
| `FileManager.instance:onRefresh()` | `filemanager.lua:857` | Refresh the file browser after a transfer |

## Network, HTTP, QR

| API | Location | Used for |
| --- | --- | --- |
| `NetworkMgr:isConnected()` (link + IP; no internet check) | `frontend/ui/network/manager.lua:187` | Wi-Fi pre-flight |
| `NetworkMgr:runWhenConnected(cb)` | `manager.lua:713` | "Turn on Wi-Fi" button (KOReader's normal connect flow) |
| `NetworkMgr:getNetworkInterfaceName()` | `manager.lua:192` (platform overrides) | Prefer the managed Wi-Fi interface |
| `NetInfo:new():retrieve()` / `:free()` | koreader-base `ffi/netinfo.lua:79` | Enumerate interfaces and IPv4 addresses (getifaddrs) |
| `Device:getDefaultRoute()` | `frontend/device/generic/device.lua:854` | Gateway for the route-lookup fallback |
| `Device:isKindle()` + `iptables` rule pattern | pattern from `plugins/SSH.koplugin/main.lua:67`, `plugins/httpinspector.koplugin/main.lua:87` | Open/close the port in the Kindle firewall |
| LuaSocket `socket.bind`, `accept`, `receive`, `send`, `select`, `udp`, `gettime` | bundled with KOReader (used by `ui/message/simpletcpserver.lua`) | The HTTP server |
| `UIManager:insertZMQ(obj)` / `removeZMQ(obj)` (obj has `waitEvent()`, `stop()`) | `frontend/ui/uimanager.lua:774`/`:779`, polled in `processZMQs` `:1524` every `ZMQ_TIMEOUT` (50 ms, `:32`) | Poll the server only while Send Book is open; `UIManager:quit` also calls `stop()` |
| `UIManager:preventStandby()` / `allowStandby()` | `uimanager.lua:1732`/`:1721` | No standby mid-transfer (balanced calls) |
| `ffi/qrencode.qrcode(text)` | koreader-base `ffi/qrencode.lua:1132` | Validate the payload before building the widget |
| `QRWidget:new{ text, width, height }` | `frontend/ui/widget/qrwidget.lua` | The QR code |
| `ffi/util.df(path)` | koreader-base `ffi/util.lua:114` | Free space before accepting an upload |
| `libs/libkoreader-lfs` | koreader-base | File attributes, directory scan |
| `util.getFileNameSuffix` | `frontend/util.lua:1035` | Extensions |
| `logger.info/warn/err` | `frontend/logger.lua` | Logging (prefixed `KindleUI`) |

## Uncertain / version-sensitive points

- `MenuSorter:findById` returns, for sub-menus, the placeholder entry
  `{ id, text, sub_item_table }`. That is fine for display, but it relies on an
  internal detail of MenuSorter. If an id is missing (user menu customisation,
  another platform), the Settings entry is simply left out.
- Calling a plugin's `addToMainMenu` a second time on a scratch table assumes
  the method has no side effects beyond filling the table. That is the
  convention, and KOReader's debug guard relies on it too, but a third-party
  plugin could break it. Errors are caught and logged, and the plugin is then
  shown as "No menu".
- `ReaderUI` is detected by `self.ui.document ~= nil` at plugin init time.
  `FileManager:setupLayout` (which creates `file_chooser`) runs *after* plugins
  are instantiated, so it cannot be used for detection.
