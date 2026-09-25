# Installing on a Kindle

This plugin runs inside **KOReader**. It does not replace the Kindle's own
software; it adds a Kindle-style Home screen to KOReader.

> **Status:** everything has been tested in a KOReader emulator, not yet on
> a real Kindle. If something looks wrong, see [Troubleshooting](#troubleshooting)
> for the log file to send.

## What you need

1. **A jailbroken Kindle with KOReader installed.** This plugin cannot do
   that part for you. Which jailbreak works depends on your Kindle model and
   firmware version, so follow the current guides:
   - KOReader's guide: <https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices>
   - The Kindle developer forum on MobileRead: <https://www.mobileread.com/forums/forumdisplay.php?f=150>

   Once you can open KOReader on the Kindle (usually from KUAL or the
   KOReader entry in the Kindle library), you are ready.
2. **A computer and the Kindle's USB cable** (only for this first install;
   updates later happen on the Kindle itself).

## Step 1: Download the plugin

1. On the computer, open <https://github.com/zakijariwala/Kindle-plugin>.
2. Click **Code → Download ZIP**, and unzip it.
3. Inside you will find a folder named **`kindleui.koplugin`**. That folder
   is the plugin. (The rest — README, docs, tests, tools — is not needed on
   the Kindle.)

Check that `kindleui.koplugin` directly contains `main.lua`, `_meta.lua`
and a `kindleui` folder.

## Step 2: Copy it to the Kindle

1. Connect the Kindle to the computer with USB. It shows up as a drive named
   **Kindle**. (If KOReader is open, it may ask to enter USB mode first.)
2. On that drive, open the **`koreader`** folder, then **`plugins`**. You
   will see KOReader's own plugins there (`statistics.koplugin`,
   `coverbrowser.koplugin`, …).
3. Copy the whole **`kindleui.koplugin`** folder into `koreader/plugins/`.
   The result must be:

   ```
   Kindle (drive)
   └── koreader
       └── plugins
           ├── kindleui.koplugin      ← this plugin
           │   ├── main.lua
           │   ├── _meta.lua
           │   └── kindleui/ …
           ├── statistics.koplugin
           └── …
   ```

   Not `plugins/Kindle-plugin-main/kindleui.koplugin`, and not
   `plugins/kindleui.koplugin/kindleui.koplugin`: KOReader only finds
   plugins placed directly in `plugins/`.
4. **Eject** the Kindle properly (Finder: ⏏; Windows: "Safely remove") before
   unplugging.

## Step 3: Start KOReader

1. On the Kindle, start KOReader the way you normally do. If KOReader was
   already running, close it and start it again (a running KOReader only
   loads new plugins at start).
2. The **Home** screen appears: Continue Reading, My Library, + Send Book,
   Installed Plugins, Settings.

If you do not see it:
- open KOReader's menu (tap the top of the screen) → **☰ → Kindle-style
  Home**;
- if that entry is missing, the plugin was not loaded: check the folder
  layout from step 2, and **Tools (🛠) → More tools → Plugin management** (it must be enabled).

KOReader itself is untouched: **Settings → Advanced → Open KOReader
Settings** or the Back key reaches all of it, and **Settings → Library →
Show Home screen at startup** turns the Home screen off.

## Step 4: A first check

- **My Library:** your books as covers. The first time, covers appear page
  by page (or use ☰ → *Prepare all covers now*, ideally while charging).
- **+ Send Book:** turn on your phone's hotspot, connect the Kindle to it
  (Send Book offers **Turn on Wi-Fi**), then scan the QR code with the same
  phone and choose a book. Details: [README → Using Send Book](../README.md#using-send-book-phone-hotspot).
- **Swipe down on Home** (or tap the time at the top right) for quick
  settings: light, night mode, Wi-Fi, sleep.
- **Hold a book** for its menu (finished, collections, delete, …).

## Updating

After the first install, no computer is needed:

**Settings → About → Check for updates** (the Kindle needs internet, e.g.
the phone hotspot with mobile data on). It shows what changed; tap
**Update**, then restart KOReader. Your settings, library cache and covers
are kept.

This downloads the latest version from the repository's `main` branch, so
the repository has to be public. The first check after a hand install shows
the installed build as "unknown" and offers the latest version; that is
expected.

Updating by hand also works: delete `koreader/plugins/kindleui.koplugin`
on the Kindle and copy the new folder in (do not copy on top of the old
folder, or deleted files would stay behind).

## Uninstalling

Delete the `koreader/plugins/kindleui.koplugin` folder (over USB), or
disable it in **Tools (🛠) → More tools → Plugin management**. KOReader goes back to its normal
file browser.

## Troubleshooting

| Problem | What to do |
| --- | --- |
| No Home screen and no "Kindle-style Home" in the menu | Folder layout (step 2). The folder name must be exactly `kindleui.koplugin`. |
| Something errors or looks wrong | Connect the Kindle over USB and copy **`koreader/crash.log`**. Plugin lines start with `KindleUI`. Send that file along with what you did. |
| Send Book: the phone cannot open the page | Both must be on the same hotspot or Wi-Fi; see [README → Troubleshooting](../README.md#troubleshooting-phone-hotspot). |
| "Check for updates" fails | The Kindle needs internet (not only the hotspot link), and the repository must be public. |

## Other devices

The same folder works on any device KOReader runs on: copy
`kindleui.koplugin` into KOReader's `plugins` folder (Kobo:
`.adds/koreader/plugins/`; other platforms: `<KOReader data folder>/plugins/`)
and restart KOReader. Kindle-only parts (firewall rule, sleep timer) are
skipped elsewhere.
