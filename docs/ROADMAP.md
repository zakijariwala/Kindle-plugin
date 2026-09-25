# Feature list / roadmap

Rule for every item: **no background work, no timers while idle, nothing
running on screens that don't need it.** Each entry notes its runtime cost.
"Cheap" means it reuses data the plugin already has (the library cache,
KOReader settings), with no document opening and no extra polling.

Status: ✅ done · 🔜 next · 💡 idea

## Build order (easiest first)

Ranked by effort and risk; built top to bottom, one commit per feature, each
checked in the KOReader emulator before the next.

| # | Feature | Effort | Status |
| --- | --- | --- | --- |
| 1 | Remember the Library page | tiny | ✅ |
| 2 | Updater: startup cleanup after an interrupted update | small | ✅ |
| 3 | Send Book: size, speed and time left | small | ✅ |
| 4 | Library filter: All / Unread / Reading / Finished | small | ✅ |
| 5 | Pin plugins to Home | small | ✅ |
| 6 | Home status line (time · Wi-Fi · battery, no timer) | small | ✅ |
| 7 | Library search (title / author) | small | ✅ |
| 8 | Text size for Home, Library, Send Book | small | ✅ |
| 9 | "Recently added" row on Home | small | ✅ |
| 10 | Faster e-ink page turns in the grid | small (tuning needs a device) | ✅ |
| 11 | Prepare all covers now | small (reuses the extractor) | ✅ |
| 12 | Last 2–3 books you're reading on Home | medium | ✅ |
| 13 | Hold menu on a cover: mark read/unread, remove from Continue Reading, delete, details | medium | ✅ |
| 14 | Collections (KOReader's own) as a Library filter | medium | ✅ |
| 15 | Multi-select and batch actions (Library + Installed Plugins) | medium | 🔜 |
| 16 | Series grouping | medium | |
| 17 | Quick settings panel (frontlight, warmth, night mode, Wi-Fi) | medium | |
| 18 | Time left in book (only with the Statistics plugin) | medium | |
| 19 | Send Book into a collection | medium (after 14) | |
| 20 | Landscape layout for Home | medium | |
| 21 | Install plugin from phone | large | ✅ |

Dropped after a closer look:
- **Page-flip keys on Home**: Home has a single page, so there is nothing to
  flip. The Library grid already handles page keys.
- **"Send from the phone's share menu" / home-screen shortcut**: the upload
  address changes every session (new code each time, by design), so a saved
  shortcut would always be dead. Scanning the QR code is the shortest safe path.

## Requested

| Status | Feature | How | Cost |
| --- | --- | --- | --- |
| ✅ | **Pin / favourite plugins on Home** | Hold a plugin in *Installed Plugins* → **Pin to Home** (or Unpin). Pinned plugins appear as a short row of buttons under the main entries (max ~4, so Home stays simple). Tapping one opens that plugin's own menu exactly like *Installed Plugins → Open*. Stored as plugin *names* in the `kindleui` setting; a pinned plugin that has been removed or disabled just doesn't show. | Cheap: a list of names. The plugin's menu is built only when tapped. No change to Home's open time beyond a few buttons. |
| 🔜 | **Multi-select and batch actions** | **Library:** ☰ → *Select* (or hold a cover → *Select*) puts the grid/list in selection mode. Tap covers to tick them, with *Select all on this page* / *Select all*. A bar at the bottom offers **Delete** (one confirmation showing the count and total size), **Mark as read / unread**, **Add to collection**. Deletion goes through KOReader's own file deletion, so each book's sidecar (progress, highlights) goes with it. The library cache entries and thumbnails are removed too, and Continue Reading/history are updated. **Installed Plugins:** the same selection mode offers **Remove** for user-installed plugins (built-in KOReader plugins can only be *disabled*, never deleted), then one restart. | Cheap: selection is an in-memory set; the work happens once, when confirmed. |
| ✅ | **Install plugin from phone** (Settings → Advanced, or Installed Plugins) | Same QR flow as Send Book, but for one `.zip` (e.g. GitHub → Code → Download ZIP). The Kindle finds the `*.koplugin` folder in it (containing `main.lua` + `_meta.lua`), shows its name/description *read as text, not run*, asks for confirmation, then stages → checks it compiles → swaps folders → offers restart. Refuses to overwrite built-in KOReader plugins; keeps the replaced version once for **Undo last plugin install**. Stray files: see below. | Only while that screen is open; one restart per install. |
| ✅ | **Startup cleanup for the updater** (gap found while designing the plugin installer) | The updater cleans up after itself, but a crash or power loss in the middle of an update can leave `.kindleui.koplugin.new`, `.kindleui.koplugin.old` or `kindleui-update.zip` behind. On the next start, remove them the same way stale `.part` uploads are removed. Special case: if `kindleui.koplugin` itself is missing and `.old` exists, restore it rather than delete it. | A few `stat()` calls once per start. |
| ✅ | **Check for updates** (Settings → About) | Compare the installed build with the latest commit on `main` of the public repo; download the repo archive, extract only `kindleui.koplugin/`, replace files, ask to restart KOReader. | Network only when the user taps it; nothing automatic. |

### Install plugin from phone: what happens to stray files

A downloaded zip usually carries much more than the plugin (README, docs,
tests, screenshots, `.git` folders, macOS `__MACOSX/` junk). None of that is
ever written into the plugins folder:

1. **The zip itself** streams into a hidden temporary file (like a Send Book
   upload) in `<settings>/kindleui-incoming/`, and that folder is emptied as
   soon as the install finishes, fails or is cancelled (and at every start).
2. **Only the chosen `*.koplugin/` folder is extracted.** Everything outside it
   is never unpacked. Inside it, known junk is skipped: `__MACOSX/`, `._*`,
   `.DS_Store`, `Thumbs.db`, `.git/`. The rest of the folder is the plugin's
   own business (some plugins ship data, icons or translations) and is kept.
3. **It is extracted into a hidden staging folder** (`.<name>.koplugin.new`),
   which KOReader never loads because it does not end in `.koplugin`. If
   anything fails (not a plugin, too big, a file does not compile, disk full),
   the staging folder is deleted and nothing else has changed.
4. **Replacement swaps whole folders** instead of copying on top. Files that the
   new version no longer has disappear with the old folder, so an update
   never leaves orphaned files from the previous version.
5. **One backup** (`.<name>.koplugin.undo`) is kept for *Undo last plugin
   install* until the next successful install (of any plugin) or the Undo.
   Only the last install can be undone.
6. **Limits against broken or malicious zips:** at most 50 MB unpacked and
   5 000 files, no paths with `..`, no absolute paths, no symbolic links.
7. **Crash or power loss mid-install:** the startup cleanup (above) removes
   leftover staging folders and temporary zips, and restores the backup if the
   plugin folder is missing. `.undo` folders that the Undo record no longer
   points to are removed at startup too.

## Home

| Status | Feature | How | Cost |
| --- | --- | --- | --- |
| 💡 | **Quick settings bar** (Kindle's swipe-down panel): frontlight, warmth, night mode, Wi-Fi, sleep | Swipe down on Home (or a small ⚙ row) opens a compact panel built from KOReader's own actions (`FrontLightWidget`, `ToggleNightMode`, NetworkMgr). | Cheap; built on demand. |
| ✅ | **Status line**: battery %, Wi-Fi on/off, time | Read once when Home is shown or refreshed. **No clock timer**, so the time is "as of when Home was drawn". | Cheap: a few sysfs reads per Home open. |
| ✅ | **Recently added** row (last 3 books received or copied) | Taken from the library cache (sorted by file time). Covers are already cached. | Cheap. |
| ✅ | **More than one "currently reading"** (last 2–3 books) | Under the Continue Reading card, up to two more books from KOReader's reading history (newest first, finished books left out) as one-line rows: title and %. Tap to open. Settings → Library → *Show other books being read on Home*. Home fits itself to the screen: it first tightens spacing and shrinks covers, then drops the second row, then *Recently added*, then the last row; the nav buttons and pinned plugins always stay. | Cheap: the history list is in memory; one `stat()` pair per row (sidecar re-read only when it changed). |
| 💡 | **Time left in chapter/book** on the Continue Reading card | Only if KOReader's Statistics plugin is enabled (its data already exists); read one small query when Home opens. | Low, and optional (off if Statistics is disabled). |

## Library

| Status | Feature | How | Cost |
| --- | --- | --- | --- |
| ✅ | **Filter: All / Unread / Reading / Finished** | Filter the in-memory book list (status is already cached). | Cheap. |
| ✅ | **Search** by title/author | On-screen keyboard; filter the in-memory list, no disk access. | Cheap. |
| ✅ | **Collections** (Kindle "Collections") | KOReader's own collections (the same ones as its file browser). Library ☰ → *Collection: …* picks one (with book counts) or all books; it combines with the reading-state filter and search, and shows in the subtitle. A book's hold menu has KOReader's own **Collections…** chooser (add/remove); the change is saved at once (KOReader itself writes `collection.lua` only when its file browser closes). A collection that was deleted falls back to all books. Books of a collection outside the home folder are not shown (the Library only lists the home folder). | Cheap: KOReader keeps collections in memory; one table lookup per book, only while a collection is selected. |
| 💡 | **Series grouping** | Group by the series name from book metadata. | Cheap once metadata is extracted. |
| ✅ | **Hold menu on a cover** (Library grid and list, and every book on Home): Reading / On hold / Finished, Reset (mark as unread)…, Remove from Continue Reading, Book details, Delete book… | Status, Reset and Delete are KOReader's own buttons and dialogs (`filemanagerutil`, `FileManager:showDeleteFileDialog`), so they also clean the sidecar, history and collections. Removing the book in Continue Reading moves the next book of the history there. | Cheap; Reset and Delete ask for confirmation. |
| ✅ | **Remember the page** you were on when coming back to the Library | Keep the page number in memory for the session. | Free. |
| 💡 | **Prepare all covers now** (Library options) | Run the existing child-process extractor over every book once, e.g. while charging. The user starts it; it stops when the Library closes. | Heavy but explicit and one-off; memory stays flat (child process). |
| 💡 | **Faster e-ink page turns** in the grid | Use a fast refresh for page turns and a full refresh every N turns to clear ghosting. | Improves perceived speed. |

## Send Book

| Status | Feature | How | Cost |
| --- | --- | --- | --- |
| 💡 | **Send into a collection** | The phone page shows your collections; received books are added to the chosen one. | Cheap. |
| ✅ | **Transfer speed and time left** on the Kindle screen | Computed from bytes received (already tracked). | Free. |
| ❌ | **Send from the phone's share menu** | The page can be added to the phone's home screen, so sending needs one tap after scanning once per session. | None on the Kindle. |

## Look and feel

| Status | Feature | How | Cost |
| --- | --- | --- | --- |
| ✅ | **Text size for Home and Library** (Small / Medium / Large) | One setting scaling the few fonts used. | Free. |
| 💡 | **Landscape layouts** tuned for Home | The grid already supports 5×2; Home needs a two-column variant. | Free. |
| ❌ | **Page-flip keys** on Home/Library for Kindles with buttons (Oasis) | Already mapped for the grid; add Home. | Free. |

## Not planned (on purpose)

- Clock or battery that updates live on Home: it needs a timer and wakes the device.
- Automatic background indexing or cover extraction: it drains the battery and uses memory the reader needs.
- Automatic update checks: they need the network and would happen without being asked.
- Locking users out of KOReader menus: the shell must never be a dead end.
