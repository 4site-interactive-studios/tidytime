# TidyTime companion site

A single-page static website describing TidyTime — what it is, its features, and how to use it.

- **`index.html`** — the whole site (self-contained; inline CSS; light/dark aware).
- **`assets/*.svg`** — the visuals.

## About the "screenshots"

TidyTime is a native macOS **menu bar** app. It cannot be launched or screenshotted in the
headless build environment this was developed in, so the visuals in `assets/` are **illustrative
mockups drawn with synthetic data**, not live captures — each is labeled as such on the page and in
the SVG. They reflect the shipped read-models and UI structure (`RecapAssembler` → recap window,
the menu bar popover, and the AI-overhead dashboard). Replace them with real screenshots once the
app is built and running on a Mac (`make run`).

## Viewing

Open `index.html` in any browser, or serve the folder:

```bash
cd site && python3 -m http.server 8000   # then open http://localhost:8000
```

No build step, no dependencies, no network calls.


## What's on the page

Hero · What it does (pipeline) · See it (3 mockups) · Features (8 cards) · The classification ladder
(5 rungs) · **Measuring the thrash** (context-switching metric + dwell strip) · Privacy & guardrails ·
Getting started · Library status.

## Assets

- `recap-window.svg` — end-of-day recap (timeline + suggestion stack + questions)
- `menubar.svg` — menu bar popover
- `dashboard.svg` — weekly dashboard incl. AI overhead
- `context-switches.svg` — context-switching tiles + the **dwell strip**

## Maintenance rule (read before editing)

This page asserts a **test count**, a **feature list**, and a **status**. All three go stale — the
first version of this page shipped claiming 117 tests and "Claude escalation" months after both
stopped being true, and a review round had to catch it. So:

1. Regenerate the test count from `make test` (it prints `Executed N tests`) — never copy it from a
   commit message or another doc.
2. Check the feature/ladder claims against `docs/PROJECT-REVIEW.md` (newest round) and
   `config.example.json` before publishing.
3. Keep the honest-status note in the Library status section accurate about the app shell.

**Hard constraints:** inline CSS only, no JavaScript, no external fonts/CDNs, no network requests.
The page must render correctly opened straight from disk.
