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
8. Add a row to the README's "What's in it" table and a line to `CHANGELOG.md`.

## Checks

```powershell
Invoke-ScriptAnalyzer -Path . -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester ./tests
```

CI runs both on Windows PowerShell 5.1, PowerShell 7 on Windows, and PowerShell 7 on Ubuntu.

## Writing

Plain, specific, no emoji, no exclamation marks. Error messages say what to run next.
