# Contributing

Bug reports with the exact command and the PowerShell version (`$PSVersionTable.PSVersion`) are the most useful thing. Pull requests are welcome; for anything bigger than a fix, open an issue first.

## Adding or changing a script

1. Name it with an approved verb (`Get-Verb`) and a singular noun: `Verb-Noun.ps1`, in the repo root.
2. Put comment-based help first in the file (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`), then `#requires -Version 5.1`. If `#requires` comes before the help, `Get-Help` shows nothing.
3. Paste the `#region rfs-common` block from an existing script, unchanged. Each script stands alone, so the block is copied, not imported. `tests/Common.Tests.ps1` fails if the copies drift. To change the block, change it in every script.
4. Pass every output path through `Resolve-OutputPath`, so relative paths land in the projects folder (`Get-ProjectsDir`). Don't write to the current directory or hard-code a user name.
5. Write all console output through `Write-Ink` (inks: `text`, `mute`, `ember`, `amber`, `mint`) and call `gh` only through `Invoke-Gh`. Ember marks one thing per screen. Mint only ever means success. Warnings and failures go through `Write-Warning`.
6. Keep the file ASCII only. Windows PowerShell 5.1 misreads UTF-8 without a BOM.
7. Add `tests/<Script>.Tests.ps1`. The stub at `tests/stub/gh.ps1` stands in for `gh`; add a case there if your script makes a new kind of call.
8. List it: add it to `SCRIPTS` and `TRY` in `docs/art/make-art.py` and run that (it writes the README's index), give it a row, a panel and a reference block in `docs/index.html`, and add a line to `CHANGELOG.md`. `tests/Docs.Tests.ps1` fails until the page and the README match the script's help. If it's safe to run for real, add a scenario to `docs/art/Record-Runs.ps1` so the page can replay it.

## Checks

```powershell
Invoke-ScriptAnalyzer -Path . -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester ./tests
```

CI runs both on Windows PowerShell 5.1, PowerShell 7 on Windows, and PowerShell 7 on Ubuntu. It also reruns `python docs/art/make-art.py` (after `pip install -r docs/art/requirements.txt`) and fails if the README art, `docs/runs.js` or the transcripts in `docs/index.html` and `README.md` change.

## Developing offline

Every release has `powershell-toolbox-<version>-dev-windows-x64.zip`, a dev kit for a Windows x64 machine with no network: the repo at that tag, plus Pester and PSScriptAnalyzer, the Python wheels for the art, their licences, and `offline/setup.ps1`.

```powershell
Unblock-File .\powershell-toolbox-<version>-dev-windows-x64.zip
Expand-Archive .\powershell-toolbox-<version>-dev-windows-x64.zip -DestinationPath $HOME\Projects
cd $HOME\Projects\powershell-toolbox-<version>-dev
.\offline\setup.ps1
```

`setup.ps1` loads the bundled modules into that window at the pinned versions, builds a Python venv from the wheels, says what's missing, and prints the lint, test and art commands to run next. It sets up that window only; in a new one, run it again. If scripts are blocked, run `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` first.

The kit doesn't bundle runtimes or outside tools. `offline/README.md` in it lists each with the exact version CI built and tested the kit with and a link to its offline installer: PowerShell 7 (Windows PowerShell 5.1 comes with Windows), Python 3.14 for the art check, and, optionally, git and gh. The tests don't need gh; they use the stub.

`tools/build-dev-kit.ps1` builds the kit, the offline zip of the scripts and `SHA256SUMS.txt` into `dist/` (`pwsh ./tools/build-dev-kit.ps1`, with the network). `tools/dev-kit/` holds the kit's `setup.ps1` and `README.md`. Pester, PSScriptAnalyzer and the Python version are pinned in `tools/versions.psd1`, which CI reads too, so change them there.

## Releasing

1. Move `## Unreleased` in `CHANGELOG.md` to `## vX.Y.Z — <date>`, with a one-paragraph summary under it. The summary becomes the release notes.
2. Push, then run the `offline` workflow on main (Actions > offline > Run workflow). It builds the downloads and runs the lint, tests and art check from the unzipped kit with the network cut off, on Windows PowerShell 5.1 and PowerShell 7.
3. When it and CI are green, tag the commit `vX.Y.Z` and push the tag. `release.yml` checks the changelog, runs CI and the offline checks again, and publishes the release with the downloads.

## Writing

Plain, specific, no emoji, no exclamation marks. Error messages say what to run next.
