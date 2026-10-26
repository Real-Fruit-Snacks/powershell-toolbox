# Changelog

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
