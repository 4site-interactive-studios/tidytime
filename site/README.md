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
