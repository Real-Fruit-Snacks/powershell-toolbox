<!-- This is offline/README.md in the dev kit. tools/build-dev-kit.ps1 copies it there, fills in each kit: block and replaces {{VERSION}}. -->
# powershell-toolbox dev kit

Everything to work on powershell-toolbox on a Windows x64 machine with no network: the repo at <!-- kit:ref -->a release<!-- /kit:ref -->, and every package its lint, tests and art check install. `offline/setup.ps1` points a PowerShell window at them. Nothing is downloaded.

What it can't give you is the network the scripts need when they run. They work on your GitHub repos through `gh`, so running them for real still takes `gh`, logged in, and the network. The tests don't: they run against a stub `gh` (`tests/stub/gh.ps1`).

## What's in it

<!-- kit:contents -->
<!-- /kit:contents -->

## What it doesn't include

Runtimes and outside tools aren't bundled. Each link is the official offline installer for Windows x64, at the version CI built and tested this kit with.

<!-- kit:toolchain -->
<!-- /kit:toolchain -->

## Steps

1. Unblock the zip, so Windows doesn't mark every file in it as downloaded, and unzip it where you keep projects:

   ```powershell
   Unblock-File .\powershell-toolbox-{{VERSION}}-dev-windows-x64.zip
   Expand-Archive .\powershell-toolbox-{{VERSION}}-dev-windows-x64.zip -DestinationPath $HOME\Projects
   cd $HOME\Projects\powershell-toolbox-{{VERSION}}-dev
   ```

2. In the window you'll work in, Windows PowerShell 5.1 or PowerShell 7:

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass   # only if scripts are blocked; this window only
   .\offline\setup.ps1
   ```

   It loads Pester and PSScriptAnalyzer from `offline/powershell` at the pinned versions, makes a Python venv in `offline/venv` from the wheels in `offline/python`, looks for PowerShell 7, Python, git and gh, and says what's missing. It sets up that window only: in a new window, run it again.

3. Run what it prints, the same checks CI runs:

   ```powershell
   Invoke-ScriptAnalyzer -Path . -Settings .\PSScriptAnalyzerSettings.psd1
   Invoke-Pester .\tests
   .\offline\venv\Scripts\python.exe docs\art\make-art.py
   ```

   `make-art.py` rewrites the README art, `docs/runs.js` and the transcripts in `docs/index.html` and `README.md`, and CI fails if they differ from what's committed. The kit has no `.git`, so to see what you changed, run `git init` and commit everything before you start.

`CONTRIBUTING.md` has the rest: how a script is laid out and what the tests check.
