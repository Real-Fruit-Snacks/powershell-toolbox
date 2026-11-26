# powershell-toolbox Usage, Configuration & Tests

Install options, dry-run transcript, configuration variables, tested environments, known issues, and Pester test commands for `powershell-toolbox`.

## Taking One Script or Offline Zip

Each script stands alone: copy one out and it still runs:

```powershell
iwr https://raw.githubusercontent.com/Real-Fruit-Snacks/powershell-toolbox/main/Get-RepoList.ps1 -OutFile Get-RepoList.ps1
```

To install without git, download `powershell-toolbox-<version>-offline.zip` from the [latest release](https://github.com/Real-Fruit-Snacks/powershell-toolbox/releases/latest), `Unblock-File` it, and unzip into `$HOME\Projects`. They still need the [GitHub CLI](https://cli.github.com/) (`winget install GitHub.cli`, then `gh auth login`) and network access when they run.

`Get-Help .\<script>.ps1 -Full` lists every parameter. If execution policy blocks a script: `powershell -ExecutionPolicy Bypass -File .\Get-RepoList.ps1`.

## A Dry Run First

`Invoke-RepoReview.ps1` is the only script that changes anything on GitHub. With `-WhatIf` it walks the same list, prints what it would do, and changes nothing. A real run against public repos, largest first (`K`, `A`, `Q`):

<!-- run:review -->
```text
PS> .\Invoke-RepoReview.ps1 -SortBy size -WhatIf
Fetching repos

Reviewing 16 repos, sorted by size. Dry run: nothing will change.
Log: C:\Users\you\Projects\repo-review-20261122-214212.log

----------------------------------------------------------------------
[1/16] Real-Fruit-Snacks/open-file
   public   28.4 MB   last push 2026-11-16 (6 days ago)
   Learn and play chess in your browser, offline
   https://github.com/Real-Fruit-Snacks/open-file

   [D] delete   [A] archive   [K] keep   [O] open in browser   [Q] quit  k

----------------------------------------------------------------------
[2/16] Real-Fruit-Snacks/certapi
   public   7.1 MB    last push 2026-11-22 (0 days ago)
   mTLS API client for the Windows certificate store
   https://github.com/Real-Fruit-Snacks/certapi

   [D] delete   [A] archive   [K] keep   [O] open in browser   [Q] quit  a
What if: Performing the operation "Archive repository" on target "Real-Fruit-Snacks/certapi".

----------------------------------------------------------------------
[3/16] Real-Fruit-Snacks/rfs-brand
   public   3.6 MB    last push 2026-11-22 (0 days ago)
   RFS brand, profile art and repo templates
   https://github.com/Real-Fruit-Snacks/rfs-brand

   [D] delete   [A] archive   [K] keep   [O] open in browser   [Q] quit  q

Stopped. Deleted: 0  Archived: 0  Kept: 1  Failed: 0  Remaining: 14
Log: C:\Users\you\Projects\repo-review-20261122-214212.log
```
<!-- /run:review -->

Delete asks a second time: you type the repo name exactly, and case counts. Every decision goes to the log, `WHATIF` included.

## Configuration

| Variable | Effect |
|---|---|
| `RFS_PROJECTS` | Your projects folder. Default `$HOME\Projects` (`C:\Users\<you>\Projects`). Relative `-OutFile` / `-LogPath` values land here; absolute paths are used as given. |
| `RFS_THEME=light` | Light-terminal palette (`light` or `dayshift`). Dark (`LX 263`) is the default. |
| `NO_COLOR=1` | Plain text, no color at all ([no-color.org](https://no-color.org)) |

To set a different projects folder permanently: `[Environment]::SetEnvironmentVariable('RFS_PROJECTS', 'D:\code', 'User')`, then open a new window.

## Tested On

- Windows Server 2025 · Windows PowerShell 5.1 and PowerShell 7.6, and Ubuntu 24.04 · PowerShell 7.6: [CI](../.github/workflows/ci.yml) runs the Pester suite (Pester 5.7.1) on every push against a stub `gh` (`tests/stub/gh.ps1`)
- Windows 11 · Windows PowerShell 5.1 · gh 2.102: the recorded runs above and on the project page
- *Not* tested: macOS (should behave like Linux, unverified)

## Known Issues

- Deleting needs the `delete_repo` scope on your `gh` token. `Invoke-RepoReview.ps1` offers to add it (`gh auth refresh -h github.com -s delete_repo`). Tokens that don't list their scopes (such as fine-grained ones) skip the check, and a missing scope only shows up when a delete fails.
- Delete has no undo here. GitHub keeps most deleted repos restorable for 90 days (Settings › Repositories › Deleted repositories); forks and repos that were part of a fork network can't be restored there.
- `Get-RepoDigest.ps1 -GitHub` makes two API calls per repo (file list and README). At the 1,000-repo cap that is 2,000 of GitHub's 5,000 requests an hour, so a third run within the hour can hit the limit.
- All three fetch at most 1,000 repos by default (`-Limit` on two of them; the digest is fixed at 1,000).
- In an old `conhost` window without VT support, output falls back to the nearest 16 console colors.

## Tests & Art

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester ./tests
```

The README cover and runs on the project page are generated from recordings in [`docs/art`](art): `Record-Runs.ps1` records real runs, `make-art.py` draws them, and CI fails if committed files drift.
