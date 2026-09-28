---
schema: 2
slug: kindle-style-home-koreader
title: Kindle-style Home for KOReader
tagline: Simple Kindle-like home screen plugin for KOReader
publish: true
reason: ""
status: active
kind: tool
size: medium
started: 2026-09
ended: null
role: "Owner — scoped, designed, built, tested"
summary: A KOReader plugin that adds a simple Kindle-style home, library and offline phone-to-e-reader book transfer, with no patches to KOReader and nothing running in the background.
problem: KOReader reads well but its file-browser front end is hard for non-technical readers, and getting books onto a device usually needs a cable, a cloud account or extra tools.
stack: [Lua, LuaJIT, LuaSocket, KOReader, JavaScript, Python, Bash, GitHub Actions]
categories: [embedded, security, reliability]
links: { live: "", docs: "", demo: "" }
metrics:
  - value: "23"
    label: "roadmap features shipped, one commit each"
    evidence: "docs/ROADMAP.md ; commits 13d2bfd..4eee4a6"
  - value: "84 ms"
    label: "median Home open on a Kindle Paperwhite over three days of real use (51 opens, 163–496-book library)"
    evidence: "docs/PERFORMANCE.md (Kindle Paperwhite: real use)"
  - value: "985"
    label: "unit checks and a 67-step walk through every screen, passing on the Kindle itself"
    evidence: "docs/TESTING.md (section 3, results) ; tools/kindle.sh"
  - value: "+6 MB"
    label: "memory growth for 81 cover extractions after moving work to a child process (was +137 MB)"
    evidence: "docs/PERFORMANCE.md (Emulator: Memory)"
  - value: "3–5 MB/s"
    label: "phone-to-Kindle transfer over Wi-Fi; 9 PDFs (66 MB) in 21 s in one session"
    evidence: "docs/PERFORMANCE.md (Send Book and Send Plugin)"
highlights:
  recruiter:
    - Owned the design from a written audit of what KOReader already provides, deciding to reuse its APIs rather than fork it, so upstream updates keep working.
    - Measured memory before shipping, found a 137 MB leak pattern in cover extraction and redesigned it to a child process, cutting growth to 6 MB.
    - Delivered 23 prioritised features, then took the plugin onto a real Kindle and replaced emulator estimates with measured device numbers in every document.
    - Built a device test tool that runs the full suite on the owner's Kindle without touching their books or settings, after learning the hard way that restarting KOReader the wrong way reboots the device.
  engineer:
    - Thin presentation layer over KOReader's own APIs with no monkey-patching; every API used is recorded with its source location so compatibility breaks can be traced.
    - Send Book runs a non-blocking HTTP/1.1 server polled from the UI loop only while its screen is open, with a 128-bit per-session token, 15-minute idle expiry and a temporary firewall rule.
    - Uploads stream to a hidden temp file, then are size-checked, type-sniffed and atomically renamed; interrupted or rejected files are deleted, and leftovers are cleared at next start.
    - Self-updater and phone plugin installer stage files, check they compile, swap folders with rollback and keep one level of undo; zip traversal, symlinks and size bombs are refused.
    - Four test layers: LuaJIT unit tests with curl as the phone, scripted runs inside a real KOReader build with headless Chromium, and the same suites on a Kindle over SSH, where a one-shot KOReader patch points the data folder at a scratch profile and restarts use KOReader's own exit code 85.
    - The Kindle's own Wi-Fi settings (airplane mode, saved networks, forget, details) through its lipc services, with passwords never read into Lua.
  story: ""
skills: [Security-first design, Failure and rollback handling, Performance measurement, Test strategy, On-device testing, Roadmap prioritisation, Technical documentation, Platform integration]
ai_assisted: true
media: []
todo_owner:
  - "Why did you build this, and who is it for? A 1–3 sentence first-person story would fill highlights.story."
  - "Any users, downloads or feedback from the KOReader community you want to cite?"
  - "Is there a public release or forum thread to use as links.live or links.docs?"
generated: { at: 2026-09-28, commit: 8f98d6d }
---

## Overview

Kindle-style Home is a KOReader plugin that puts a deliberately simple, Kindle-like shell on top of KOReader: Continue Reading, My Library, Send Book, Installed Plugins, Settings and a way back to the Kindle's own home screen. It runs on the author's Kindle Paperwhite. KOReader still does all the reading, rendering and metadata work. The plugin only adds a simpler front door, and every KOReader feature stays one or two taps away.

## The problem

KOReader is a capable reader but its default interface is a file browser, which is a poor fit for someone who just wants to see their books and keep reading. Getting a new book onto the device is also awkward: a USB cable, a cloud account or extra tools such as SSH or FTP.

## What I built

- A Home screen with the current book and progress, up to 2 more books in progress, recently added books, pinned plugins, a status line and a quick settings panel.
- A Library with a cover grid or list, sort, filter by reading status or collection, search, series grouping, a hold menu per book and multi-select batch actions.
- Send Book: the phone shares a hotspot, the e-reader shows a QR code, the phone's browser opens it and uploads one or several books over the local link. No internet, account or phone app is needed.
- Send Plugin, a button on the Send Book screen that takes a plugin zip through the same QR flow, with confirmation and one-step undo. A third-party plugin was installed this way from its 27.6 MB GitHub download.
- The Kindle's own Wi-Fi settings inside the plugin: airplane mode, networks, join a hidden network, saved networks with connect or forget, and network details.
- Exit to Kindle Home, which closes KOReader the way its own menu does.
- A self-updater that checks the latest commit on the public repository only when asked, verifies the download and swaps folders safely.
- A device test tool (`tools/kindle.sh`) that deploys, restarts, and runs the unit, screen-walk, transfer and benchmark suites on a Kindle over SSH.
- Install, testing, performance, architecture and roadmap documentation, including a record of every KOReader API the plugin depends on.

## Architecture

- Plugin entry point shows Home whenever KOReader builds a file browser, which is how Home returns after closing a book without patching KOReader.
- UI modules for Home, Library (list and grid), book menu, Installed Plugins, Settings and the transfer screens.
- Transfer layer: a provider registry, a local Wi-Fi provider with network pre-flight and sleep guard, a session module (token, expiry, routing, validation) and a streaming HTTP server.
- Utility layer: library cache validated by file modification time, a cover extractor run in a child process, filename and path security, HTTPS with certificate host checks, zip analysis, updater and plugin installer.
- Tests: LuaJIT unit suites, emulator end-to-end scripts with a fake GitHub server, and a benchmark harness, run in GitHub Actions on every push; the same suites run on a Kindle through two test-only KOReader patches (a control channel and a one-shot scratch profile).

## Key decisions

- **Reuse KOReader, never fork or patch it.** I audited KOReader's plugin loader, menus, metadata, network and QR facilities first and recorded a decision for each need. Only the HTTP server was written from scratch, because KOReader's reads headers only and would buffer uploads in memory.
- **Cover extraction in a child process.** In-process extraction grew memory by 137 MB over 81 covers with no plateau, because document engines hold memory per file. Moving it to a child process held growth to 6 MB, at the cost of slower extraction when the CPU is scarce.
- **Nothing runs in the background.** The server, timers and cover jobs exist only while the screen that needs them is open. This rule is applied to every roadmap item and each entry notes its runtime cost.
- **Plain HTTP on the local link, protected by session design.** A trusted certificate is impossible for a hotspot IP, so protection comes from a short-lived random token, a server that stops with the screen, strict filename handling and a content security policy on the phone page. The residual risk is stated in the README.
- **Build plugin menus only when tapped.** Benchmarks showed eager menu building cost about 1 ms, so the change was not for speed. It was made to avoid running third-party plugin code every time the screen opens.
- **Test on the device without risking the owner's data.** The screen-walk test deletes books, so on the Kindle it runs in a scratch profile that a KOReader patch switches to for one start only. Killing and relaunching KOReader rebooted the Paperwhite twice, so the tool only uses KOReader's own restart.
- **Dropped features with reasons.** A phone share-menu shortcut was rejected because the upload address changes every session by design.

## Results

- All 23 roadmap items are marked done, each delivered as its own commit.
- Tested on a Kindle Paperwhite (firmware 5.19.5): 985 unit checks and a 67-step scripted walk through every screen pass on the device, run over SSH by a purpose-built tool that never touches the owner's books or settings.
- On the device, CPU-bound work ran 3–10 times faster than the throttled-emulator estimate, while file access was slower, because the Kindle's storage is a FUSE file system.
- Measured in three days of real use with a 163–496-book library: Home opens in 84 ms (median), a Library page turns in 62 ms, and memory stays at 27–35 MB when idle.
- Phone-to-Kindle transfer over Wi-Fi runs at 3–5 MB/s: 9 PDFs (66 MB) arrived in 21 s in one session.
- Device testing found a bug no emulator showed: phone file pickers greyed out plugin zips because of the page's file-type filter.

## What's next

- Speed up the folder scan, which dominates Library opens on a real library (230–580 ms on the Kindle's FUSE storage).
- Confirm by hand on the Kindle: Exit landing on the Kindle home, joining and forgetting networks, and a phone picking a plugin zip since the fix.
- Verify real phone browsers (iOS Safari, Android Chrome) by name over a real hotspot.
- Check non-touch Kindles, where key navigation is implemented but untested.
