<#
.SYNOPSIS
Builds the release downloads: the dev kit, the offline zip of the scripts, and SHA256SUMS.txt.

.DESCRIPTION
Writes three files to -OutDir:

  powershell-toolbox-<version>-dev-windows-x64.zip
      Unzips to powershell-toolbox-<version>-dev\: the repo at -Ref (git archive, no .git) plus
      offline\ with Pester and PSScriptAnalyzer (Save-Module), the wheels in
      docs\art\requirements.txt for CPython on Windows x64, the licence of each, setup.ps1
      (from tools\dev-kit), README.md (from tools\dev-kit, filled in) and toolchain.psd1.
  powershell-toolbox-<version>-offline.zip
      Unzips to powershell-toolbox-<version>\: the three scripts, README.md, LICENSE and
      CHANGELOG.md, to install without git.
  SHA256SUMS.txt
      Both zips, in sha256sum format.

Every version comes from tools\versions.psd1 and docs\art\requirements.txt at -Ref, the files
CI reads. The kit's README also records the PowerShell 7, Windows PowerShell, Python and git
this runs with, as the versions CI used, so run it where CI runs: windows-latest under pwsh,
after setup-python (.github/workflows/offline.yml does). Needs the network: the PowerShell
Gallery, PyPI and GitHub.

.PARAMETER Version
The version in the file names, such as 1.1.0. Default: the newest heading in CHANGELOG.md at
-Ref, so "## v1.1.0 ..." gives 1.1.0 and "## Unreleased" gives unreleased.

.PARAMETER Ref
The commit or tag to package. Default HEAD.

.PARAMETER OutDir
Where to write the downloads. Default dist in the repo, which git ignores.

.PARAMETER Python
The Python to run pip download with, when it isn't python on PATH or py -<version>. It has to
be the Python version in tools\versions.psd1, since the kit records it.

.EXAMPLE
pwsh ./tools/build-dev-kit.ps1

.EXAMPLE
pwsh ./tools/build-dev-kit.ps1 -Version 1.1.0 -Ref v1.1.0 -OutDir $env:TEMP\dist
#>
#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $Version,
    [string] $Ref = 'HEAD',
    [string] $OutDir,
    [string] $Python
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = 'powershell-toolbox'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
$OutDir = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutDir)

# The files that make up the offline zip of the scripts.
$runFiles = 'Get-RepoDigest.ps1', 'Get-RepoList.ps1', 'Invoke-RepoReview.ps1', 'README.md', 'LICENSE', 'CHANGELOG.md'

# Licences the module packages don't carry themselves, as URL templates ({0} is the version).
# Pester's package has no licence file. Its LICENSE at the tag is the Apache 2.0 notice, which
# points at the full licence text, so both.
$moduleLicences = @{
    Pester = @('https://raw.githubusercontent.com/pester/Pester/{0}/LICENSE', 'https://www.apache.org/licenses/LICENSE-2.0.txt')
}
# Every assembly in the saved modules. A new one fails the build until it's listed here with
# where its licence comes from: the module's own licence, a notices file the module ships, or a
# URL template ({0} is the assembly's product version).
$assemblies = @{
    'Pester.dll'                                                  = @{ Own = $true }
    'Microsoft.Windows.PowerShell.ScriptAnalyzer.dll'             = @{ Own = $true }
    'Microsoft.Windows.PowerShell.ScriptAnalyzer.BuiltinRules.dll' = @{ Own = $true }
    'Microsoft.PowerShell.CrossCompatibility.dll'                 = @{ Own = $true }
    'Newtonsoft.Json.dll'                                         = @{ Name = 'Newtonsoft.Json'; Notices = 'ThirdPartyNotices.txt' }
    'Pluralize.NET.dll'                                           = @{ Name = 'Pluralize.NET'; Url = 'https://raw.githubusercontent.com/sarathkcm/Pluralize.NET/v{0}/LICENCE' }
}

function Invoke-Checked {
    # Runs a program, returns its output (stdout and stderr) as text, throws if it exits non-zero.
    param([Parameter(Mandatory)] [string] $FilePath, [string[]] $ArgumentList = @())
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $all = & $FilePath @ArgumentList 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    $out = (@($all | ForEach-Object { "$_" }) -join "`n").Trim()
    if ($code -ne 0) { throw "$FilePath $($ArgumentList -join ' ') exited $code`n$out" }
    $out
}

function Invoke-WithRetry {
    # Hosted runners lose the PowerShell Gallery and other hosts now and then. 5 tries, 15/30/45/60 s apart.
    param([Parameter(Mandatory)] [string] $What, [Parameter(Mandatory)] [scriptblock] $Action)
    for ($try = 1; $true; $try++) {
        try { return (& $Action) } catch {
            if ($try -ge 5) { throw }
            Write-Warning "$What failed (try $try): $_"
            Start-Sleep -Seconds (15 * $try)
        }
    }
}

function Save-Url ([string] $Url, [string] $OutFile) {
    Invoke-WithRetry "Downloading $Url" { Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing }
}

function Assert-Url ([string] $Url) {
    Invoke-WithRetry "Checking $Url" { Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing | Out-Null }
}

function Format-Block ([string] $Text, [string] $Name, [string] $Body) {
    $pattern = "(?s)(<!-- kit:$Name -->).*?(<!-- /kit:$Name -->)"
    if ($Text -notmatch $pattern) { throw "tools/dev-kit/README.md has no <!-- kit:$Name --> block" }
    [regex]::Replace($Text, $pattern, { param($m) $m.Groups[1].Value + $Body + $m.Groups[2].Value })
}

function ConvertTo-Psd1String ([string] $Value) { "'" + $Value.Replace("'", "''") + "'" }

function Compress-Folder ([string] $Folder, [string] $ZipPath, [DateTimeOffset] $Time) {
    # One top folder, / separators on every PowerShell, entries in ordinal order, all stamped with
    # the commit time, so the same commit and packages give the same zip.
    $base = Split-Path $Folder -Parent
    $files = @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Force | ForEach-Object {
            [pscustomobject]@{ Path = $_.FullName; Name = $_.FullName.Substring($base.Length + 1).Replace('\', '/') }
        })
    $names = [string[]]@($files.Name)
    $paths = [string[]]@($files.Path)
    [Array]::Sort($names, $paths, [StringComparer]::Ordinal)
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $stream = [IO.File]::Open($ZipPath, [IO.FileMode]::CreateNew)
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        for ($i = 0; $i -lt $names.Count; $i++) {
            $entry = $zip.CreateEntry($names[$i], [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $Time
            $in = [IO.File]::OpenRead($paths[$i])
            $out = $entry.Open()
            try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
        }
    } finally {
        $zip.Dispose()
        $stream.Dispose()
    }
}

$stage = Join-Path ([IO.Path]::GetTempPath()) "$repo-build-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    # ---- the repo at -Ref
    $commit = Invoke-Checked git @('-C', $root, 'rev-parse', '--short', "$Ref^{commit}")
    $time = [DateTimeOffset]::Parse((Invoke-Checked git @('-C', $root, 'log', '-1', '--format=%cI', $commit)))
    $tag = try { Invoke-Checked git @('-C', $root, 'describe', '--tags', '--exact-match', $commit) } catch { $null }
    $archive = Join-Path $stage 'src.zip'
    Invoke-Checked git @('-C', $root, 'archive', '--format=zip', '-o', $archive, $commit) | Out-Null
    $tree = Join-Path $stage 'tree'
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $tree)
    Remove-Item -LiteralPath $archive

    if (-not $Version) {
        $top = @(Get-Content -LiteralPath (Join-Path $tree 'CHANGELOG.md') -Encoding utf8 | Where-Object { $_ -like '## *' })[0]
        $Version = if ($top -match '^## v(\d+\.\d+\.\d+)\b') { $Matches[1] } elseif ($top -match '^## Unreleased\b') { 'unreleased' } else { throw "Can't read a version from CHANGELOG.md: $top" }
    }
    if ($Version -notmatch '^(\d+\.\d+\.\d+|unreleased)$') { throw "-Version should look like 1.1.0, not $Version" }
    $kitName = "$repo-$Version-dev"
    $kit = Join-Path $stage $kitName
    Rename-Item -LiteralPath $tree -NewName $kitName
    $at = if ($tag) { "$tag (commit $commit)" } else { "commit $commit" }
    Write-Host "Building $repo $Version from $at"

    $versions = Import-PowerShellDataFile -LiteralPath (Join-Path $kit 'tools/versions.psd1')
    $offline = Join-Path $kit 'offline'
    $licences = Join-Path $offline 'licences'
    New-Item -ItemType Directory -Path $licences -Force | Out-Null
    $bundled = New-Object System.Collections.Generic.List[string]

    # ---- PowerShell modules, as Save-Module saves them, and their licences
    $psDir = Join-Path $offline 'powershell'
    New-Item -ItemType Directory -Path $psDir | Out-Null
    foreach ($m in $versions.Modules) {
        Invoke-WithRetry "Saving $($m.Name) $($m.Version)" {
            if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
                Write-Host 'PSGallery is not registered; registering it'
                Register-PSRepository -Default -ErrorAction Stop
            }
            Save-Module -Name $m.Name -RequiredVersion $m.Version -Repository PSGallery -Path $psDir -Force -ErrorAction Stop
        }
        $base = Join-Path $psDir "$($m.Name)/$($m.Version)"
        if (-not (Test-Path -LiteralPath (Join-Path $base "$($m.Name).psd1"))) { throw "Save-Module left no $($m.Name) $($m.Version) in $psDir" }

        $dest = Join-Path $licences "$($m.Name)-$($m.Version)"
        New-Item -ItemType Directory -Path $dest | Out-Null
        Get-ChildItem -LiteralPath $base -File | Where-Object { $_.Name -match '^(LICEN[CS]E|NOTICE|COPYING|ThirdPartyNotices)' } | Copy-Item -Destination $dest
        foreach ($url in @($moduleLicences[$m.Name] | Where-Object { $_ })) {
            $u = $url -f $m.Version
            Save-Url $u (Join-Path $dest (Split-Path $u -Leaf))
        }
        if (-not (Get-ChildItem -LiteralPath $dest)) { throw "No licence for $($m.Name) $($m.Version): add one to `$moduleLicences in tools/build-dev-kit.ps1" }

        foreach ($dll in @(Get-ChildItem -LiteralPath $base -Recurse -Filter '*.dll' | Sort-Object Name -Unique)) {
            $known = $assemblies[$dll.Name]
            if (-not $known) { throw "$($m.Name) $($m.Version) bundles $($dll.Name), which tools/build-dev-kit.ps1 has no licence for. Find its licence and add it to `$assemblies." }
            if ($known.ContainsKey('Own')) { continue }
            $v = ([Diagnostics.FileVersionInfo]::GetVersionInfo($dll.FullName).ProductVersion -split '\+')[0]
            if ($known.ContainsKey('Notices')) {
                $notices = Join-Path $dest $known.Notices
                if (-not (Test-Path -LiteralPath $notices) -or -not (Select-String -LiteralPath $notices -SimpleMatch $known.Name -Quiet)) {
                    throw "$($m.Name) bundles $($known.Name), but its $($known.Notices) doesn't cover it"
                }
            } else {
                $u = $known.Url -f $v
                $sub = Join-Path $dest "$($known.Name)-$v"
                New-Item -ItemType Directory -Path $sub | Out-Null
                Save-Url $u (Join-Path $sub (Split-Path $u -Leaf))
            }
            $bundled.Add("$($known.Name) $v (in $($m.Name))")
        }
    }

    # ---- Python wheels for CPython on Windows x64, and their licences
    $want = $versions.Python
    $candidates = @()
    if ($Python) { $candidates += , @($Python) }
    $candidates += , @('python')
    $candidates += , @('py', "-$want")
    $py = $null
    foreach ($c in $candidates) {
        if (-not (Get-Command $c[0] -ErrorAction SilentlyContinue)) { continue }
        $pre = @($c | Select-Object -Skip 1)
        try { $v = Invoke-Checked $c[0] ($pre + @('-c', 'import sys; print(sys.version.split()[0])')) } catch { continue }
        if ($v -like "$want.*") { $py = @{ Exe = $c[0]; Pre = $pre; Version = $v }; break }
    }
    if (-not $py) { throw "Needs Python $want (tools/versions.psd1) with pip, as python or py -$want. Pass -Python." }
    $pyDir = Join-Path $offline 'python'
    $requirements = Join-Path $kit 'docs/art/requirements.txt'
    Invoke-WithRetry 'pip download' {
        Invoke-Checked $py.Exe ($py.Pre + @('-m', 'pip', 'download', '--no-cache-dir', '--disable-pip-version-check',
                '--only-binary=:all:', '--platform', 'win_amd64', '--implementation', 'cp', '--python-version', $want,
                '-r', $requirements, '-d', $pyDir)) | Out-Null
    }
    $wheels = @(Get-ChildItem -LiteralPath $pyDir -Filter '*.whl' | Sort-Object Name)
    $normal = { param($n) ($n -replace '[-_.]+', '_').ToLowerInvariant() }
    foreach ($pin in @(Get-Content -LiteralPath $requirements | Where-Object { $_ -match '^\s*[A-Za-z0-9_.-]+==' })) {
        $name, $ver = $pin.Trim() -split '=='
        if (-not ($wheels | Where-Object { (& $normal ($_.Name -split '-')[0]) -eq (& $normal $name) -and ($_.Name -split '-')[1] -eq $ver })) {
            throw "pip download left no wheel for $pin in $pyDir"
        }
    }
    foreach ($w in $wheels) {
        $dist = ($w.Name -split '-')[0..1] -join '-'
        $dest = Join-Path $licences $dist
        New-Item -ItemType Directory -Path $dest | Out-Null
        $zip = [IO.Compression.ZipFile]::OpenRead($w.FullName)
        try {
            $entries = @($zip.Entries | Where-Object { $_.FullName -match '^[^/]+\.dist-info/(licenses/.+|(LICEN[CS]E|COPYING|NOTICE|AUTHORS)[^/]*)$' -and $_.Name })
            if (-not $entries) { throw "$($w.Name) carries no licence file" }
            foreach ($e in $entries) { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $dest $e.Name), $true) }
        } finally {
            $zip.Dispose()
        }
    }

    # ---- the toolchain CI uses, which the kit doesn't bundle, with official offline installers
    $pwshVersion = $PSVersionTable.PSVersion.ToString()
    $winPs = Invoke-Checked powershell.exe @('-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.ToString()')
    $git = (Invoke-Checked git @('--version')) -replace '^git version ', ''
    if ($git -notmatch '^(\d+\.\d+\.\d+)\.windows\.(\d+)$') { throw "Expected Git for Windows, got git $git" }
    $gitFile = if ($Matches[2] -eq '1') { "Git-$($Matches[1])-64-bit.exe" } else { "Git-$($Matches[1]).$($Matches[2])-64-bit.exe" }
    $gh = $versions.Gh
    $tools = @(
        [ordered]@{ Name = 'Windows PowerShell'; Version = $winPs; For = 'Running and testing. CI tests on it.'; Url = '' }
        [ordered]@{ Name = 'PowerShell'; Version = $pwshVersion; For = 'Testing. CI tests on PowerShell 7 too.'; Url = "https://github.com/PowerShell/PowerShell/releases/download/v$pwshVersion/PowerShell-$pwshVersion-win-x64.msi" }
        [ordered]@{ Name = 'Python'; Version = $py.Version; For = "The art check. Any $want.x works: the wheels are for CPython $want."; Url = "https://www.python.org/ftp/python/$($py.Version)/python-$($py.Version)-amd64.exe" }
        [ordered]@{ Name = 'Git'; Version = $git; For = 'Optional. One test, and the git details in Get-RepoDigest.ps1 -Local.'; Url = "https://github.com/git-for-windows/git/releases/download/v$git/$gitFile" }
        [ordered]@{ Name = 'GitHub CLI'; Version = $gh; For = 'Only to run the scripts for real. The tests use a stub. Not used by CI; the recorded runs used this one.'; Url = "https://github.com/cli/cli/releases/download/v$gh/gh_${gh}_windows_amd64.msi" }
    )
    foreach ($t in $tools) { if ($t.Url) { Assert-Url $t.Url } }

    $psd1 = @('# Written by tools/build-dev-kit.ps1. The toolchain CI built and tested this kit with; offline/setup.ps1 reads it.', '@{')
    $psd1 += "    Kit = $(ConvertTo-Psd1String $kitName)"
    $psd1 += "    Version = $(ConvertTo-Psd1String $Version)"
    $psd1 += "    Commit = $(ConvertTo-Psd1String $commit)"
    $psd1 += '    Tools = @('
    foreach ($t in $tools) {
        $psd1 += '        @{ ' + (($t.Keys | ForEach-Object { "$_ = $(ConvertTo-Psd1String $t[$_])" }) -join '; ') + ' }'
    }
    $psd1 += '    )', '}'
    [IO.File]::WriteAllText((Join-Path $offline 'toolchain.psd1'), ($psd1 -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($false))

    # ---- setup.ps1 and README.md
    Copy-Item -LiteralPath (Join-Path $kit 'tools/dev-kit/setup.ps1') -Destination (Join-Path $offline 'setup.ps1')
    $modulesText = @($versions.Modules | ForEach-Object { "$($_.Name) $($_.Version)" }) -join ' and '
    $wheelsText = @($wheels | ForEach-Object { '`' + $_.Name + '`' }) -join ', '
    $bundledText = if ($bundled.Count) { ', and of what they bundle: ' + ($bundled -join ', ') } else { '' }
    $contents = @(
        "- The repo at $at, as ``git archive`` makes it: no ``.git``."
        "- ``offline/powershell/``: $modulesText, as ``Save-Module`` saves them from the PowerShell Gallery."
        "- ``offline/python/``: $wheelsText. That's ``docs/art/requirements.txt`` for CPython $want on Windows x64."
        "- ``offline/licences/``: the licence of each of those$bundledText."
        '- `offline/setup.ps1`: sets up a PowerShell window to use them.'
        '- `offline/toolchain.psd1`: the versions and links below, for `setup.ps1`.'
    ) -join "`n"
    $table = @('| Tool | Version | What for | Offline installer |', '|---|---|---|---|')
    foreach ($t in $tools) {
        $link = if ($t.Url) { "[$(Split-Path $t.Url -Leaf)]($($t.Url))" } else { 'Built into Windows 10 and 11, and Windows Server 2016 and later' }
        $table += "| $($t.Name) | $($t.Version) | $($t.For) | $link |"
    }
    $readme = [IO.File]::ReadAllText((Join-Path $kit 'tools/dev-kit/README.md'))
    $readme = $readme -replace '^<!-- This is offline/README\.md.*?-->\r?\n', ''
    $readme = Format-Block -Text $readme -Name ref -Body $at
    $readme = Format-Block -Text $readme -Name contents -Body "`n$contents`n"
    $readme = Format-Block -Text $readme -Name toolchain -Body "`n$($table -join "`n")`n"
    $readme = $readme.Replace('{{VERSION}}', $Version)
    [IO.File]::WriteAllText((Join-Path $offline 'README.md'), $readme, [Text.UTF8Encoding]::new($false))

    # ---- the offline zip of the scripts
    $run = Join-Path $stage "run/$repo-$Version"
    New-Item -ItemType Directory -Path $run -Force | Out-Null
    foreach ($f in $runFiles) { Copy-Item -LiteralPath (Join-Path $kit $f) -Destination $run }

    # ---- zips and sums
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $kitZip = Join-Path $OutDir "$repo-$Version-dev-windows-x64.zip"
    $runZip = Join-Path $OutDir "$repo-$Version-offline.zip"
    Compress-Folder -Folder $kit -ZipPath $kitZip -Time $time
    Compress-Folder -Folder $run -ZipPath $runZip -Time $time
    $sums = foreach ($z in $kitZip, $runZip) { '{0}  {1}' -f (Get-FileHash -LiteralPath $z -Algorithm SHA256).Hash.ToLowerInvariant(), (Split-Path $z -Leaf) }
    [IO.File]::WriteAllText((Join-Path $OutDir 'SHA256SUMS.txt'), ($sums -join "`n") + "`n", [Text.UTF8Encoding]::new($false))

    foreach ($f in $kitZip, $runZip, (Join-Path $OutDir 'SHA256SUMS.txt')) {
        Write-Host ('{0,10:N1} KB  {1}' -f ((Get-Item -LiteralPath $f).Length / 1KB), $f)
    }
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
