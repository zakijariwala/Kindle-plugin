# Handoff — state of work

Last updated: 2026-09-25. Branch: `main` of `zakijariwala/Kindle-plugin`.

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
- Unit tests: `tests/run.sh`, all passing.
- Emulator smoke test: `tests/e2e/smoke.sh`, 31 steps, passing.
- **Plugin installer, part 1/4:** `kindleui/util/pluginzip.lua` (pure zip analysis) plus 31 tests.

## In progress: Install plugin from phone (ROADMAP #21)

`kindleui/util/plugininstaller.lua` is committed as **WIP**. Nothing loads it yet, and it is not tested. It already has:

- `userPluginsDir`, `incomingDir`, `clearIncoming`, `builtins`;
- `analyze(zip, name)`;
- `install(zip, analysis, candidate)`: stage `.X.new`, then `loadfile` check, then swap.

To finish:

1. **Fix the replace branch in `install()`.** It currently calls `Updater.swapIn`, which deletes the old version. Replace that call with:
   1. purge `.X.undo`;
   2. `os.rename(target, old)`;
   3. `os.rename(staged, target)`, putting `old` back if this fails;
   4. `os.rename(old, undo)`.
2. **Add `Installer.undo()` and `Installer.canUndo()`.**
   - Record Config `last_plugin_install = {name, had_previous}`.
   - Undo either restores `.X.undo` or removes the newly added plugin, then asks for a restart.
   - `Updater.cleanupLeftovers` only handles `.new`/`.old`; keep it away from `.undo`.
3. **Add a plugin mode to Send Book** (session, server, upload page, `ui/transfer.lua`):
   - one `.zip`, max 20 MB, saved to `incomingDir()`;
   - page title "Send plugin", `multiple = false`.
   - On receive:
     - run `analyze`;
     - if there are several candidates, let the user pick one;
     - refuse built-in plugins;
     - show a confirm screen with the name, description, "new" or "replaces", a full-access warning and a "disabled" note;
     - Install, then the restart prompt.
4. **Entry points:**
   - Settings → Advanced: "Install plugin from phone" and "Undo last plugin install";
   - a row in Installed Plugins.
5. **Startup:** call `Installer.clearIncoming()` in `main.lua`, next to the stale-upload cleanup.
6. **Tests:**
   - unit tests where the code is pure;
   - emulator end-to-end: upload a GitHub-layout zip that contains junk files, install it, restart, check the plugin appears, then test Undo;
   - extend `tests/e2e/patches/2-kindleui-smoke.lua`.
7. **Docs:** update README, ARCHITECTURE and ROADMAP.

## Next, in ranked order (see docs/ROADMAP.md)

- #12 last 2–3 reading books on Home
- #13 cover hold menu
- #14 collections
- #15 multi-select batch actions (delete, and so on)
- #16 series
- #17 quick settings
- #18 time left
- #19 send into collection
- #20 landscape Home

Housekeeping: in the ROADMAP table, mark #9 (Recently added), #10 (e-ink refresh) and #11 (Prepare covers) as done.

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
- **Not verified on a real Kindle:** battery and Wi-Fi status, iptables, lipc, e-ink refresh, installer.
- **Repo visibility:** the repo must be public for the updater to work without a token.
