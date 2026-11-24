# Design: powershell-toolbox (`docs/` and README index)

## Concept

Every PowerShell script follows `Verb-Noun`, so the page hangs every script name on a single vertical hyphen axis (`Get - RepoList`, `Get - RepoDigest`, `Invoke - RepoReview`) paired with an interactive `-WhatIf` console replaying real recorded runs.

## Brand System

Built on **Cyclorama Dawn `v2.1.0`** (`Real-Fruit-Snacks/rfs-brand`):
- **Default mode:** Beacon Horizon Dark (`LX 263`, matte `#050507`) with opt-in Alabaster Day Light (`LX 512`, `#F5F7F9`) toggle synced across tabs via `localStorage['rfs-theme']`.
- **Two chromatic poles:** Glacial Steel (`#1F547A` / `#74B8E8` / `#164669`) and Maritime Beacon Orange (`#F06E2B` / `#FF9254` / `#AD3D0A`), interpolated strictly in Cartesian `in oklab`.
- **Semantic signals:** Mint (`#3DDC97` / `#127247`), Amber (`#FFC247` / `#885800`), and **Signal Crimson** (`#FF5C6C` / `#C92438` / `#B91C2E`) for `[D] delete`, delete confirmation buttons, and safety rules.
- **Typography:** Self-hosted variable WOFF2 only — `Big Shoulders Stencil` (display headings), `Albert Sans` (UI, prose, and Verb-Noun names), and `Azeret Mono` (console, parameters, and code).
- **Shell & scrollbars:** Uses `.rfs-shell` + `.rfs-shell-header` + `.rfs-scroll-region` so the vertical scrollbar starts strictly below the top header bar.

## Generated Art & CI Verification

`docs/art/make-art.py` reads real recorded runs from `docs/art/runs/*.txt` and each script's `.SYNOPSIS`, writes `docs/assets/index-{dark,light}.svg` and `docs/runs.js`, and patches the `<!-- run:* -->` markers in `docs/index.html` and `README.md`. `.github/workflows/ci.yml` (`art` job) regenerates and enforces zero diff, while `tests/Docs.Tests.ps1` verifies every documented script call and parameter against the scripts.

## Cover & Social Preview

`docs/assets/cover-{dark,light}.{svg,png}` and `docs/assets/social-{dark,light}.png` are generated from `docs/assets/cover.toml` via `rfs-brand/tools/make-cover.py`.
