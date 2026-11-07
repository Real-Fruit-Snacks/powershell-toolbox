# Changelog

## Unreleased

### Fixed

- `Get-RepoDigest.ps1` copied credentials from a local repo's remote URL (`https://user:token@...`, `gcrypt::https://user:token@...`) into the digest. The `user:password@` part is now left out; an ssh login name with no password (`ssh://git@host/...`) stays.
- `Get-RepoDigest.ps1 -GitHub` wrote `No README found` when fetching a README failed (rate limit, network, permissions), and dropped the file list without a word. Only a 404 now counts as missing; other failures get a warning and a note in the digest.

## v1.1.0 — 2026-11-05

Each release now has two downloads: a zip of the three scripts, to install without git, and a dev kit to lint, test and work on them on Windows with no network. The scripts take the same parameters and do the same things as in v1.0.1, and still need gh and the network when they run.

### Added

- Two downloads on every release. `powershell-toolbox-<version>-offline.zip` is the three scripts with the README, changelog and licence, to install without git; the scripts still need `gh` and the network when they run. `powershell-toolbox-<version>-dev-windows-x64.zip` is the repo with Pester, PSScriptAnalyzer and the art's Python wheels, and `offline/setup.ps1`, to lint, test and regenerate the art on Windows with no network. `SHA256SUMS.txt` lists both.
- `tools/build-dev-kit.ps1` builds them. `tools/versions.psd1` pins Pester, PSScriptAnalyzer and Python for CI and the dev kit alike.
- The `offline` workflow builds the downloads, cuts off the network and runs the lint, tests and art check from the unzipped dev kit, on Windows PowerShell 5.1 and PowerShell 7. Pushing a `v*` tag now publishes the release through `release.yml`, once CI and those checks pass.

## v1.0.1 — 2026-11-05

Dayshift colours match the current RFS palette, and the README and project page are new. The scripts take the same parameters and do the same things as in v1.0.0.

### Changed

- Dayshift console colours (`RFS_THEME=dayshift`) now use the current RFS values: Mute `#666A73`, Ember `#C03B0A`, Amber `#925F00`, Mint `#15794D`.
- New README and project page: an index of the scripts, each name hung on its hyphen, beside real recorded runs. On the page you can step through a recorded `-WhatIf` review with the D, A, K, O and Q keys.

### Added

- `docs/art`: `Record-Runs.ps1` records real runs (public repos only, archive and delete blocked), `make-art.py` turns them into the README art, the page's replay data and the transcripts. CI fails if they're out of date.
- `tests/Docs.Tests.ps1`: the README and the page can only name parameters and values the scripts accept, and the page's synopses and parameter tables must match each script's help.
- A monthly link check.

## v1.0.0 — 2026-10-26

First public release.

### Breaking

- `Get-RfsRepos.ps1` is now `Get-RepoList.ps1`. `-Owner` defaults to the account `gh` is logged in as, no longer Real-Fruit-Snacks. `-IncludeForks:$false` is now `-ExcludeForks`.
- `Review-GitHubRepos.ps1` is now `Invoke-RepoReview.ps1`, because `Review` is not an approved PowerShell verb.

### Fixed

- `Get-Help` showed no help for `Get-RfsRepos.ps1`: `#requires` sat above the help block. All three scripts now put help first.
- `Get-RepoDigest.ps1` printed push dates as `10/01/2026 12:00:00` on PowerShell 7, where `ConvertFrom-Json` already returns a DateTime. Dates are now `yyyy-MM-dd` on both versions.
- Windows PowerShell 5.1 decoded `gh` output with the OEM code page, so non-ASCII READMEs and descriptions came out garbled. `gh` output is now read as UTF-8.
- Windows PowerShell 5.1 could throw on any `gh` or `git` stderr line under `$ErrorActionPreference = 'Stop'`, which hid the real error message.
- `Invoke-RepoReview.ps1` used `exit`, which closes the whole PowerShell window when the script is dot-sourced or piped to `iex`. It now returns.
- `Get-RepoList.ps1 -Format Json` returned an object, not an array, for one repo. Markdown output did not escape newlines in descriptions.
- `Get-RepoDigest.ps1` matched build-folder exclusions with `\` only, so on Linux and macOS it counted `node_modules` files.
- A repo that was never pushed (`pushedAt` empty) no longer breaks the review sort.
- On Windows `Get-RepoDigest.ps1` wrote CRLF for its own lines and kept README text as it came, so the digest had mixed line endings. It is LF throughout now.
- `Get-RfsRepos.ps1` help had a non-ASCII `·` in a BOM-less file, which 5.1 reads as two garbage characters. All scripts are ASCII now.

### Added

- Projects folder: every output file (digest, list `-OutFile`, review log) goes to `$HOME\Projects` by default, or `RFS_PROJECTS` when set. Relative paths resolve there; absolute paths are used as given. Previously files went to the current directory.
- `-Local` on `Get-RepoDigest.ps1`: scans the projects folder. Default digest path is now `Projects\repos-digest.md`.
- `-Owner` on `Get-RepoDigest.ps1`.
- `-WhatIf` on `Invoke-RepoReview.ps1`: walks the list, logs `WHATIF`, changes nothing.
- RFS palette for all console output (Nightshift by default, `RFS_THEME=dayshift`, `NO_COLOR`).
- Pester suite with a stub `gh`, PSScriptAnalyzer settings, CI on Windows PowerShell 5.1, PowerShell 7 on Windows, and PowerShell 7 on Ubuntu.
