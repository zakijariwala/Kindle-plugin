# Feature list / roadmap

Rule for every item: **no background work, no timers while idle, nothing
running on screens that don't need it.** Each entry notes its runtime cost.
"Cheap" means it reuses data the plugin already has (the library cache,
KOReader settings), with no document opening and no extra polling.

Status: ✅ done · 🔜 next · 💡 idea

## Requested

| Status | Feature | How | Cost |
| --- | --- | --- | --- |
| 🔜 | **Pin / favourite plugins on Home** | Hold a plugin in *Installed Plugins* → **Pin to Home** (or Unpin). Pinned plugins appear as a short row of buttons under the main entries (max ~4, so Home stays simple). Tapping one opens that plugin's own menu exactly like *Installed Plugins → Open*. Stored as plugin *names* in the `kindleui` setting; a pinned plugin that has been removed or disabled just doesn't show. | Cheap: a list of names. The plugin's menu is built only when tapped. No change to Home's open time beyond a few buttons. |
| ✅ | **Check for updates** (Settings → About) | Compare the installed build with the latest commit on `main` of the public repo; download the repo archive, extract only `kindleui.koplugin/`, replace files, ask to restart KOReader. | Network only when the user taps it; nothing automatic. |

## Home

| Status | Feature | How | Cost |
| --- | --- | --- | --- |
| 💡 | **Quick settings bar** (Kindle's swipe-down panel): frontlight, warmth, night mode, Wi-Fi, sleep | Swipe down on Home (or a small ⚙ row) opens a compact panel built from KOReader's own actions (`FrontLightWidget`, `ToggleNightMode`, NetworkMgr). | Cheap; built on demand. |
| 💡 | **Status line**: battery %, Wi-Fi on/off, time | Read once when Home is shown or refreshed. **No clock timer**, so the time is "as of when Home was drawn". | Cheap: a few sysfs reads per Home open. |
| 💡 | **Recently added** row (last 3 books received or copied) | Taken from the library cache (sorted by file time). Covers are already cached. | Cheap. |
| 💡 | **More than one "currently reading"** (last 2–3 books) | From KOReader's reading history; covers from the cache. | Cheap. |
| 💡 | **Time left in chapter/book** on the Continue Reading card | Only if KOReader's Statistics plugin is enabled (its data already exists); read one small query when Home opens. | Low, and optional (off if Statistics is disabled). |

## Library

| Status | Feature | How | Cost |
| --- | --- | --- | --- |
| 💡 | **Filter: All / Unread / Reading / Finished** | Filter the in-memory book list (status is already cached). | Cheap. |
| 💡 | **Search** by title/author | On-screen keyboard; filter the in-memory list, no disk access. | Cheap. |
| 💡 | **Collections** (Kindle "Collections") | Use KOReader's own collections (the same ones as KOReader's file browser), shown as a filter. No second system. | Cheap. |
| 💡 | **Series grouping** | Group by the series name from book metadata. | Cheap once metadata is extracted. |
| 💡 | **Hold menu on a cover**: Mark as read/unread, Remove from Continue Reading, Delete book, Book details | Status and deletion through KOReader's own functions (they also clean the sidecar). | Cheap; delete asks for confirmation. |
| 💡 | **Remember the page** you were on when coming back to the Library | Keep the page number in memory for the session. | Free. |
| 💡 | **Prepare all covers now** (Library options) | Run the existing child-process extractor over every book once, e.g. while charging. The user starts it; it stops when the Library closes. | Heavy but explicit and one-off; memory stays flat (child process). |
| 💡 | **Faster e-ink page turns** in the grid | Use a fast refresh for page turns and a full refresh every N turns to clear ghosting. | Improves perceived speed. |

## Send Book

| Status | Feature | How | Cost |
| --- | --- | --- | --- |
| 💡 | **Send into a collection** | The phone page shows your collections; received books are added to the chosen one. | Cheap. |
| 💡 | **Transfer speed and time left** on the Kindle screen | Computed from bytes received (already tracked). | Free. |
| 💡 | **Send from the phone's share menu** | The page can be added to the phone's home screen, so sending needs one tap after scanning once per session. | None on the Kindle. |

## Look and feel

| Status | Feature | How | Cost |
| --- | --- | --- | --- |
| 💡 | **Text size for Home and Library** (Small / Medium / Large) | One setting scaling the few fonts used. | Free. |
| 💡 | **Landscape layouts** tuned for Home | The grid already supports 5×2; Home needs a two-column variant. | Free. |
| 💡 | **Page-flip keys** on Home/Library for Kindles with buttons (Oasis) | Already mapped for the grid; add Home. | Free. |

## Not planned (on purpose)

- Clock or battery that updates live on Home: it needs a timer and wakes the device.
- Automatic background indexing or cover extraction: it drains the battery and uses memory the reader needs.
- Automatic update checks: they need the network and would happen without being asked.
- Locking users out of KOReader menus: the shell must never be a dead end.
