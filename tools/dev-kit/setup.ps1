<#
.SYNOPSIS
Sets up the powershell-toolbox dev kit in this window, with no network.

.DESCRIPTION
Run it from the unzipped dev kit, in the window you'll work in:

    .\offline\setup.ps1

It downloads nothing and changes nothing outside the kit folder:

- Puts offline\powershell first on PSModulePath and loads Pester and PSScriptAnalyzer from it,
  at exactly the versions in tools\versions.psd1.
- Makes a Python venv in offline\venv and installs docs\art\requirements.txt into it from the
  wheels in offline\python (pip install --no-index), for the art check.
- Checks for PowerShell 7, Python, git and gh, and says what's missing and where to get it.
- Ends with the commands to lint, test and check the art.

It sets up this window only. In a new window, run it again.

The source is tools\dev-kit\setup.ps1 in the repo; tools\build-dev-kit.ps1 copies it into the kit.

.PARAMETER Python
The Python to make the venv with, when it isn't found as `py -3.14` or as `python` on PATH.

.EXAMPLE
.\offline\setup.ps1

.EXAMPLE
.\offline\setup.ps1 -Python C:\Python314\python.exe
#>
#requires -Version 5.1
[CmdletBinding()]
param([string] $Python)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Native {
    # Runs a program and returns Out (stdout and stderr as text) and ExitCode. Stops stderr from
    # becoming a terminating error in Windows PowerShell 5.1 under $ErrorActionPreference = 'Stop'.
    param([Parameter(Mandatory)] [string] $FilePath, [string[]] $ArgumentList = @())
    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Out = "$FilePath not found"; ExitCode = -1 }
    }
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $all = & $FilePath @ArgumentList 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    [pscustomobject]@{ Out = (@($all | ForEach-Object { "$_" }) -join "`n").Trim(); ExitCode = $code }
}

function Write-Check {
    param([string] $State, [string] $Text)
    $colors = @{ ok = 'Green'; missing = 'Yellow'; optional = 'DarkGray' }
    $line = '  {0,-9}{1}' -f $State, $Text
    if ($env:NO_COLOR) { Write-Host $line } else { Write-Host $line -ForegroundColor $colors[$State] }
}

$offline = $PSScriptRoot
$kit = Split-Path $offline -Parent
$toolchainFile = Join-Path $offline 'toolchain.psd1'
$versionsFile = Join-Path $kit 'tools\versions.psd1'
if (-not (Test-Path -LiteralPath $toolchainFile) -or -not (Test-Path -LiteralPath $versionsFile)) {
    throw 'Run this from an unzipped dev kit, as .\offline\setup.ps1. In the repo, tools\build-dev-kit.ps1 builds the kit.'
}
$toolchain = Import-PowerShellDataFile -LiteralPath $toolchainFile
$versions = Import-PowerShellDataFile -LiteralPath $versionsFile
function Get-Tool ([string] $Name) { @($toolchain.Tools | Where-Object { $_.Name -eq $Name })[0] }

$missing = New-Object System.Collections.Generic.List[string]
Write-Host "$($toolchain.Kit), in $kit"
if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
    Write-Check missing 'Windows: this kit is for Windows x64. The modules load anywhere, but the Python wheels are for Windows only.'
}

# Files unzipped from a download carry the internet zone mark, and with the RemoteSigned policy
# PowerShell won't run them. They came from the release, so clear the mark, inside the kit only.
$venv = Join-Path $offline 'venv'
if (Get-Command Unblock-File -ErrorAction SilentlyContinue) {
    Get-ChildItem -LiteralPath $kit -Recurse -File | Where-Object { -not $_.FullName.StartsWith($venv) } | Unblock-File
}

# ---- PowerShell
$pwsh7 = Get-Tool 'PowerShell'
if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Check ok "PowerShell $($PSVersionTable.PSVersion) (this window)"
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        Write-Check ok 'Windows PowerShell 5.1 (powershell.exe), which CI tests on too'
    }
} else {
    Write-Check ok "Windows PowerShell $($PSVersionTable.PSVersion) (this window)"
    $r = Invoke-Native pwsh @('-NoProfile', '-NoLogo', '-Command', '$PSVersionTable.PSVersion.ToString()')
    if ($r.ExitCode -eq 0) {
        Write-Check ok "PowerShell $($r.Out) (pwsh), which CI tests on too"
    } else {
        Write-Check optional "PowerShell 7: not found. CI also tests on PowerShell $($pwsh7.Version): $($pwsh7.Url)"
    }
}

# ---- Pester and PSScriptAnalyzer, from the kit at the pinned versions
$modules = Join-Path $offline 'powershell'
$sep = [IO.Path]::PathSeparator
$rest = @($env:PSModulePath -split [regex]::Escape($sep) | Where-Object { $_ -and $_.TrimEnd('\') -ne $modules })
$env:PSModulePath = (@($modules) + $rest) -join $sep
foreach ($m in $versions.Modules) {
    $base = Join-Path $modules "$($m.Name)\$($m.Version)"
    $manifest = Join-Path $base "$($m.Name).psd1"
    if (-not (Test-Path -LiteralPath $manifest)) {
        Write-Check missing "$($m.Name) $($m.Version): not in offline\powershell. This kit is incomplete; download it again."
        $missing.Add("$($m.Name) $($m.Version)")
        continue
    }
    # The window may already have another version loaded, such as the Pester 3.4 that comes with Windows.
    Get-Module $m.Name | Where-Object { $_.ModuleBase -ne $base } | Remove-Module -Force
    Import-Module $manifest -Global -Force
    $loaded = @(Get-Module $m.Name)
    if ($loaded.Count -ne 1 -or "$($loaded[0].Version)" -ne $m.Version -or $loaded[0].ModuleBase -ne $base) {
        Write-Check missing "$($m.Name) $($m.Version): loading it from the kit failed. Loaded: $(($loaded | ForEach-Object { "$($_.Version) from $($_.ModuleBase)" }) -join ', ')"
        $missing.Add("$($m.Name) $($m.Version)")
        continue
    }
    Write-Check ok "$($m.Name) $($m.Version), loaded from offline\powershell"
}

# ---- Python, and the art's packages in a venv from the kit's wheels
$py = Get-Tool 'Python'
$want = $versions.Python
$wheels = Join-Path $offline 'python'
$requirements = Join-Path $kit 'docs\art\requirements.txt'
$probe = 'import sys; print(sys.version.split()[0]); print(sys.executable)'
$candidates = @()
if ($Python) { $candidates += , @($Python) }
$candidates += , @('py', "-$want")
$candidates += , @('python')
$found = $null
foreach ($c in $candidates) {
    $r = Invoke-Native $c[0] (@($c | Select-Object -Skip 1) + @('-c', $probe))
    if ($r.ExitCode -ne 0) { continue }
    $lines = @($r.Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -ge 2 -and $lines[0] -like "$want.*") { $found = @{ Version = $lines[0]; Exe = $lines[1] }; break }
}
$venvPython = Join-Path $venv 'Scripts\python.exe'
if (-not $found) {
    Write-Check missing "Python ${want}: not found, and the art check (docs\art\make-art.py) needs it. Install Python $($py.Version): $($py.Url) then run this again, or pass -Python <path to python.exe>."
    $missing.Add("Python $want")
} else {
    Write-Check ok "Python $($found.Version) ($($found.Exe))"
    $cfg = Join-Path $venv 'pyvenv.cfg'
    if ((Test-Path -LiteralPath $cfg) -and -not ((Get-Content -LiteralPath $cfg) -match "^version(_info)?\s*=\s*$([regex]::Escape($want))\.")) {
        Remove-Item -LiteralPath $venv -Recurse -Force
    }
    $steps = @()
    if (-not (Test-Path -LiteralPath $venvPython)) { $steps += , @($found.Exe, @('-m', 'venv', $venv)) }
    $steps += , @($venvPython, @('-m', 'pip', 'install', '--no-index', '--find-links', $wheels, '--disable-pip-version-check', '--no-cache-dir', '--quiet', '-r', $requirements))
    $failed = $null
    foreach ($s in $steps) {
        $r = Invoke-Native $s[0] $s[1]
        if ($r.ExitCode -ne 0) { $failed = "$($s[0]) $($s[1] -join ' ')`n$($r.Out)"; break }
    }
    if ($failed) {
        Write-Check missing "The art's Python packages: installing them from offline\python failed:`n$failed"
        $missing.Add('the art packages')
    } else {
        $pins = @(Get-Content -LiteralPath $requirements | Where-Object { $_ -match '^\s*[A-Za-z0-9_.-]+==' } | ForEach-Object { $_.Trim() })
        # No quotes in the code: Windows PowerShell 5.1 mangles quotes inside native arguments.
        $check = 'import importlib.metadata as m, sys; print(chr(32).join(a + 2 * chr(61) + m.version(a) for a in sys.argv[1:]))'
        $r = Invoke-Native $venvPython (@('-c', $check) + @($pins | ForEach-Object { ($_ -split '==')[0] }))
        if ($r.ExitCode -eq 0 -and $r.Out -eq ($pins -join ' ')) {
            Write-Check ok "$($pins -join ', ') in offline\venv, from offline\python"
        } else {
            Write-Check missing "The art's Python packages: offline\venv has $($r.Out), not $($pins -join ' ')"
            $missing.Add('the art packages')
        }
    }
}

# ---- git and gh, optional
$git = Get-Tool 'Git'
$r = Invoke-Native git @('--version')
if ($r.ExitCode -eq 0) {
    Write-Check ok ($r.Out -replace '^git version ', 'git ')
} else {
    Write-Check optional "git: not found. Without it one test is skipped and Get-RepoDigest -Local leaves out git details. Install git $($git.Version): $($git.Url)"
}
$gh = Get-Tool 'GitHub CLI'
$r = Invoke-Native gh @('--version')
if ($r.ExitCode -eq 0) {
    Write-Check ok (($r.Out -split "`n")[0] -replace '^gh version (\S+).*', 'gh $1')
} else {
    Write-Check optional "gh: not found. The tests don't need it (they use tests\stub\gh.ps1); running the scripts for real does. Install gh $($gh.Version): $($gh.Url)"
}

# ---- what next
Write-Host ''
if ($missing.Count) {
    Write-Host "Not ready: missing $($missing -join ', '). See above. Until then, in this window:"
} else {
    Write-Host 'Ready. Next, in this window:'
}
Write-Host ''
if ((Get-Location).ProviderPath -ne $kit) { Write-Host "  Set-Location '$kit'" }
Write-Host '  Invoke-ScriptAnalyzer -Path . -Settings .\PSScriptAnalyzerSettings.psd1'
Write-Host '  Invoke-Pester .\tests'
if (Test-Path -LiteralPath $venvPython) {
    Write-Host '  .\offline\venv\Scripts\python.exe docs\art\make-art.py'
    Write-Host ''
    Write-Host 'make-art.py rewrites the README art, docs\runs.js and the transcripts in docs\index.html and'
    Write-Host 'README.md. If you changed no recorded run and no script help, they come out the same.'
}
Write-Host 'In a new window, run .\offline\setup.ps1 again first.'
if ($missing.Count) { throw "Dev kit setup is incomplete: missing $($missing -join ', ')." }
