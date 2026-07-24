# 0010 — Chrome only in v1, behind BrowserAdapter

v1 watches only Chrome, via AppleScript over Apple Events, but every browser interaction sits behind
a `BrowserAdapter` protocol so Safari/Firefox/Dia can be added later without touching the pipeline.

Related: [README.md](README.md) · [../architecture/module-map.md](../architecture/module-map.md) ·
[../reference/chrome-scripting.md](../reference/chrome-scripting.md) ·
[0007](0007-accessibility-not-screen-recording.md)

**Status:** Accepted · **Date:** 2026-07-23

## Context

The browser is the richest attribution source — URL, title, and visible page text carry client
signals (EN account names, staging URLs, client domains). But each browser has a different scripting
story, and building all of them at once is scope the personal v1 doesn't need: Bryan uses Chrome
(PLAN §2, §4). The risk is baking Chrome specifics into the capture pipeline so that adding a
browser later means surgery.

## Decision

Support **Chrome only in v1**, behind a **`BrowserAdapter` protocol** (PLAN §4;
[module-map.md](../architecture/module-map.md)). The `ChromeAdapter` uses AppleScript over Apple
Events: URL + title need no configuration; visible page text comes from `execute javascript`
snapshotting `document.body.innerText` on tab focus / meaningful title-or-URL change, truncated to
~4 KB and content-hashed to skip duplicates (→ `page_snapshots`). This requires the one-time Chrome
toggle **View → Developer → "Allow JavaScript from Apple Events"**; if it's off or scripting fails,
the adapter **degrades silently to URL + title**. Details:
[../reference/chrome-scripting.md](../reference/chrome-scripting.md).

## Consequences

- The `BrowserAdapter` seam means Safari/Firefox/Dia land later as new implementations **without
  touching sessionization or classification** — the durable path is a WebExtension + native
  messaging (PLAN §13).
- Chrome scripting is Google's to break (PLAN §12); the URL+title fallback keeps the app functional
  if `execute javascript` ever changes, and the extension route is the successor when other browsers
  arrive.
- Apple Events into Chrome need the **Automation** TCC grant, which leans on stable signing
  ([0009](0009-stable-signing-for-tcc.md)); page *text* comes from the browser, never Screen
  Recording ([0007](0007-accessibility-not-screen-recording.md)).
- Non-Chrome browsing is invisible in v1 — accepted for a single-user Chrome workflow.

## Alternatives considered

- **All browsers in v1.** Rejected: unneeded scope; the user is on Chrome, and the adapter keeps the
  door open cheaply.
- **A WebExtension from the start.** Deferred: heavier setup (native messaging host, per-browser
  packaging) than AppleScript for a single browser; it becomes the right tool at multi-browser time.
- **Chrome logic inline (no protocol).** Rejected: would make every later browser a pipeline rewrite;
  the seam is the whole point.
