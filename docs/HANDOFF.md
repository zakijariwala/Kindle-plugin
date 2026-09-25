# Handoff — state of work

Last updated: 2026-09-25. Branch: `claude/kindle-plugin-handoff-wndhwa` of `zakijariwala/Kindle-plugin` (not merged into `main` yet).

## Done (committed and pushed)

- Home screen:
  - status line (time · Wi-Fi · battery);
  - Continue Reading;
  - Recently added;
  - pinned plugins (up to 4, hold to unpin);
  - nav buttons.
- Library:
  - cover grid (3×3, or 5×2 in landscape) and list view;
  - filters (All / Unread / Reading / Finished), search and sorts;
  - cache in `kindleui_library.lua`;
  - covers extracted in a child process;
  - "Prepare all covers now";
  - a full e-ink refresh every 6 page turns.
- Installed Plugins: lazy, with pin/unpin on hold.
- Settings:
  - Reading / Library / Device / Connectivity / Advanced / About;
  - text size (small, medium, large);
  - Check for updates.
- Send Book:
  - QR code with a token and a local HTTP server;
  - several books per session;
  - speed and time shown;
  - sleep guard;
  - Kindle firewall handling (iptables);
  - idle expiry;
  - a read-only folder is refused before the upload starts.
- Self-updater: GitHub → zip → staging → compile check → swap, with its own TLS peer verification.
- Unit tests: `tests/run.sh`, all passing (including `test_plugininstaller.lua`).
- Emulator smoke test: `tests/e2e/smoke.sh`, 58 steps, passing.
- **Install plugin from phone (ROADMAP #21):**
  - `util/pluginzip.lua` (pure zip analysis) and `util/plugininstaller.lua`
    (stage → compile check → swap; a replaced version is kept as
    `.<name>.koplugin.undo`; Undo; startup cleanup);
  - plugin mode of Send Book (`kind = "plugin"`: one `.zip`, ≤ 20 MB, saved to
    `<settings>/kindleui-incoming/`, its own phone page wording and messages);
  - `ui/plugininstall.lua`: pick one plugin when a zip has several, confirm,
    install, restart prompt; Undo confirm;
  - entry points: Settings → Advanced ("Install plugin from phone", "Undo last
    plugin install") and a row at the end of Installed Plugins;
  - emulator end-to-end: `tests/e2e/plugininstall.sh` (GitHub-style zip with
    junk → install → restart → loaded; replace → restart; Undo → restart),
    passing;
  - a bug the e2e caught: KOReader's `Archiver.Reader` can only extract
    entries it has already iterated over, so `install()` iterates the zip
    once first. The unit-test fake now behaves the same way.

- **Other books being read on Home (ROADMAP #12):** up to two rows (title
  and %) under the Continue Reading card, from KOReader's reading history,
  finished books left out; Settings → Library toggle `home_more_reading`.
  Home now fits itself to the screen (`Home.FIT_LEVELS`): compact spacing
  first, then fewer optional parts. Before this, Home at large text with
  pinned plugins was taller than the screen (Settings cut off); the smoke
  test now checks the fit at every text size.

- **Hold menu on a book (ROADMAP #13):** `ui/bookmenu.lua`, from the Library
  grid and list and from every book on Home. KOReader's own status row
  (Reading / On hold / Finished), Reset (labelled "mark as unread"), Remove
  from Continue Reading (moves `lastfile` to the next history book), Book
  details, Delete (KOReader's dialog; the cache entry and thumbnail go too).

- **Collections (ROADMAP #14):** Library ☰ → "Collection: …" filters by one
  of KOReader's collections (`library_collection`); the hold menu has
  KOReader's own "Collections…" chooser, saved to `collection.lua` straight
  away (KOReader writes it only when its file browser closes). Checked with
  real taps in the emulator.

- **Multi-select (ROADMAP #15):** `ui/selection.lua` for the Library grid and
  list (☰ → Select books…, or hold → Select…): KOReader's batch status, Reset
  and Collections buttons, and Delete through `FileManager:deleteFile`.
  Installed Plugins: hold → Select plugins to remove… (user plugins only), one
  restart. Note: `Menu`/`FocusManager` use `self.selected` for key focus;
  don't name widget fields `selected`.

- **Series grouping (ROADMAP #16):** `util/series.lua` (pure, tested);
  cache entries carry `series`/`series_index` (per-entry `meta = 2`, older
  entries upgraded lazily); Library ☰ → Group series. Also checked in the
  emulator: series extracted from never-opened EPUBs (calibre:series), and
  the upgrade of a cache without series.

- **Quick settings (ROADMAP #17):** `ui/quicksettings.lua`, from Home (swipe
  down, or tap the status line ▾): KOReader's own events. The emulator image
  runs KOReader as a desktop (`KO_MULTIUSER`), so only Night mode is live
  there; frontlight, Wi-Fi and sleep need a device check.

- **Time left (ROADMAP #18):** `util/readingtime.lua` reads the book's row
  from `statistics.sqlite3` (by partial MD5, read-only), estimate tested in
  `test_readingtime.lua`; Settings → Library toggle `home_time_left`.

- **Send into a collection (ROADMAP #19):** phone page "Add to collection"
  (positions, not names, go back to the Kindle); `ui/transfer.lua` adds each
  book with `ReadCollection:addItem` and writes at once. Checked end to end
  with headless Chromium (`COLLECTION="To read" node tests/e2e/phone.js …`).

- **Landscape Home (ROADMAP #20):** two columns (reading left, navigation
  and pinned plugins right) when the screen is wider than tall. Home now
  rebuilds itself after a rotation (`KindleUI:onSetDimensions`, sent by
  KOReader's file browser when it re-lays out). Library, Installed Plugins
  and Send Book do not re-lay out if rotated while open (they are usually
  closed when rotating from Settings); they are right the next time they open.

## Next

The ranked list (#1–21) is done and no 💡 ideas are left in
docs/ROADMAP.md. What remains is checking on a real Kindle (see "Not
verified on a real Kindle" below and docs/TESTING.md, section 3).

ROADMAP: #1–21 are all marked ✅.

## Working notes

- **Emulator:**
  - start dockerd by hand first: `(dockerd > /tmp/dockerd.log 2>&1 &)`;
  - then use `tools/emulator.sh start <library>`;
  - after code changes, restart it (`tools/emulator.sh restart`), because Lua modules stay cached.
- **Lua and lint:**
  - name loop variables `__`, never `_` (that shadows gettext; `tests/run.sh` checks it);
  - keep luacheck clean;
  - use a plain `find` when the text contains `-`.
- **KOReader widgets:**
  - `FrameContainer` ignores `width`; use `CenterContainer` to centre;
  - TitleBar needs `subtitle = " "` at creation for `setSubTitle` to work.
- **Emulator tests that write to the plugins folder** (updater, plugin install)
  use `KO_PLUGINS_DIR`; the default mount holds only this plugin, read-only.
- **Not verified on a real Kindle:** battery and Wi-Fi status, iptables, lipc, e-ink refresh, plugin installer, quick settings (light, Wi-Fi, sleep).
- **Repo visibility:** the repo must be public for the updater to work without a token.
