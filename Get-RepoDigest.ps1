<#
.SYNOPSIS
Builds one Markdown digest of your repos, GitHub and/or local, READMEs included.

.DESCRIPTION
Made for handing a whole set of repos to an LLM as a single upload.

For GitHub repos (through the gh CLI) it writes a summary table, then per repo
the metadata, topics, top-level file list and README. For local folders it
treats every top-level directory under each root as a project and records git
info (remote, branch, commit count, uncommitted files), manifests, a file-type
count and the README.

.PARAMETER GitHub
Include GitHub repos. Needs gh, logged in with `gh auth login`.

.PARAMETER Owner
GitHub user or org for -GitHub. Defaults to the account gh is logged in as.

.PARAMETER Local
Include every folder in your projects folder (see RFS_PROJECTS; default
C:\Users\<you>\Projects).

.PARAMETER LocalRoot
Other folders whose top-level subfolders are treated as projects. Combines with -Local.

.PARAMETER OutFile
Where to write the digest. Default: repos-digest.md in your projects folder. A
relative path goes in the projects folder; an absolute path is used as given.

.PARAMETER MaxReadmeChars
Cut each README after this many characters. Default 8000.

.PARAMETER IncludeArchived
Include archived GitHub repos. Skipped by default.

.PARAMETER IncludeForks
Include forked GitHub repos. Skipped by default.

.EXAMPLE
.\Get-RepoDigest.ps1 -GitHub
Your GitHub repos only.

.EXAMPLE
.\Get-RepoDigest.ps1 -Local
Everything in C:\Users\<you>\Projects, written to C:\Users\<you>\Projects\repos-digest.md.

.EXAMPLE
.\Get-RepoDigest.ps1 -GitHub -Owner Real-Fruit-Snacks -Local -OutFile all.md -MaxReadmeChars 12000
GitHub and local together, another owner, bigger README cap, written to Projects\all.md.
#>

#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]   $GitHub,
    [string]   $Owner,
    [switch]   $Local,
    [string[]] $LocalRoot = @(),
    [string]   $OutFile = 'repos-digest.md',
    [ValidateRange(1, 1000000)]
    [int]      $MaxReadmeChars = 8000,
    [switch]   $IncludeArchived,
    [switch]   $IncludeForks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region rfs-common -- identical in every script; tests/Common.Tests.ps1 fails if they drift
function Write-Ink {
    # One line of console output in the RFS palette. Nightshift unless RFS_THEME=dayshift.
    # 24-bit color when the host understands VT sequences, the nearest ConsoleColor
    # otherwise, plain text when NO_COLOR is set.
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [AllowEmptyString()] [string] $Text = '',
        [Parameter(Position = 1)] [ValidateSet('text', 'mute', 'ember', 'amber', 'mint')] [string] $Ink = 'text',
        [switch] $NoNewline
    )
    $dayshift = "$env:RFS_THEME" -ieq 'dayshift'
    if ($env:NO_COLOR) { Write-Host $Text -NoNewline:$NoNewline; return }
    if ($Host.UI.SupportsVirtualTerminal) {
        $rgb = if ($dayshift) {
            @{ text = '26;27;30'; mute = '107;111;120'; ember = '196;63;17'; amber = '154;103;0'; mint = '22;122;78' }
        } else {
            @{ text = '232;230;225'; mute = '138;143;153'; ember = '255;106;61'; amber = '255;194;71'; mint = '61;220;151' }
        }
        $esc = [char]27
        Write-Host "$esc[38;2;$($rgb[$Ink])m$Text$esc[0m" -NoNewline:$NoNewline
    } else {
        $console = if ($dayshift) {
            @{ text = 'Black'; mute = 'DarkGray'; ember = 'DarkRed'; amber = 'DarkYellow'; mint = 'DarkGreen' }
        } else {
            @{ text = 'Gray'; mute = 'DarkGray'; ember = 'DarkYellow'; amber = 'Yellow'; mint = 'Green' }
        }
        Write-Host $Text -ForegroundColor $console[$Ink] -NoNewline:$NoNewline
    }
}

function Invoke-Gh {
    # Runs gh and returns Out, Err and ExitCode. Reads gh's output as UTF-8 (Windows
    # PowerShell 5.1 otherwise decodes it with the OEM code page) and stops gh's stderr
    # from turning into a terminating error under $ErrorActionPreference = 'Stop'.
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)] [string[]] $Arguments)
    $savedPreference = $ErrorActionPreference
    $savedEncoding = $null
    try {
        $ErrorActionPreference = 'Continue'
        try {
            $savedEncoding = [Console]::OutputEncoding
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        } catch {
            Write-Verbose "Console encoding left as is: $_"
            $savedEncoding = $null
        }
        $all = & gh @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        if ($savedEncoding) { [Console]::OutputEncoding = $savedEncoding }
        $ErrorActionPreference = $savedPreference
    }
    [pscustomobject]@{
        Out      = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
        Err      = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n"
        ExitCode = $code
    }
}

function Assert-Gh {
    # Stops with a plain message when gh is missing or logged out.
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'gh not found. Install it from https://cli.github.com, then run: gh auth login'
    }
    if ((Invoke-Gh @('auth', 'status')).ExitCode -ne 0) {
        throw 'gh is not logged in. Run: gh auth login'
    }
}
function Get-ProjectsDir {
    # The folder output files go to and -Local scans: $env:RFS_PROJECTS when set,
    # otherwise Projects in your user profile (C:\Users\<you>\Projects on Windows).
    if ($env:RFS_PROJECTS) { return $env:RFS_PROJECTS }
    Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Projects'
}

function Resolve-OutputPath ([string] $Path) {
    # Relative output paths land in the projects folder, which is created if missing.
    # Absolute paths and ~ paths are used as given.
    if ([System.IO.Path]::IsPathRooted($Path) -or $Path -like '~*') {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    } else {
        $full = [System.IO.Path]::GetFullPath((Join-Path (Get-ProjectsDir) $Path))
    }
    $dir = Split-Path $full -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null }
    $full
}
#endregion rfs-common

$roots = @($LocalRoot)
if ($Local) { $roots = @(Get-ProjectsDir) + $roots }
if (-not $GitHub -and $roots.Count -eq 0) {
    Write-Warning 'Nothing to do. Pass -GitHub, -Local, or -LocalRoot <path>.'
    return
}
if ($GitHub) { Assert-Gh }

$sb = [System.Text.StringBuilder]::new()
function Add-Line ([string] $Line = '') { [void]$sb.AppendLine($Line) }

function Limit-Text ([string] $Text, [int] $Max) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + "`n`n[... truncated at $Max chars ...]"
}

function Get-Fence ([string] $Text) {
    # A fence longer than any backtick run in the text, so the text can never close it.
    $longest = 0
    foreach ($m in [regex]::Matches("$Text", '`+')) { if ($m.Length -gt $longest) { $longest = $m.Length } }
    return ('`' * [Math]::Max(4, $longest + 1))
}

function Format-Pushed ($Value, [string] $Format) {
    # gh gives an ISO string; PowerShell 7's ConvertFrom-Json has already made it a DateTime.
    if (-not $Value) { return '' }
    ([datetime]$Value).ToUniversalTime().ToString($Format)
}

function Add-Readme ([string] $Text, [int] $Max) {
    Add-Line
    if ($Text) {
        $body = Limit-Text $Text $Max
        $fence = Get-Fence $body
        Add-Line "$fence markdown"
        Add-Line $body
        Add-Line $fence
    } else {
        Add-Line '_No README found._'
    }
    Add-Line
}

Add-Line '# Repo digest'
Add-Line
Add-Line "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm') on $([Environment]::MachineName)"
Add-Line

# --- GitHub ------------------------------------------------------------------

if ($GitHub) {
    Write-Ink 'Listing GitHub repos' mute
    $fields = 'name,nameWithOwner,description,isPrivate,isFork,isArchived,primaryLanguage,pushedAt,url,repositoryTopics,stargazerCount'
    $ghArgs = @('repo', 'list')
    if ($Owner) { $ghArgs += $Owner }
    $ghArgs += @('--limit', '1000', '--json', $fields)
    $list = Invoke-Gh $ghArgs
    if ($list.ExitCode -ne 0) { throw "gh repo list failed:`n$($list.Err)" }

    $repos = @(@($list.Out | ConvertFrom-Json) | Where-Object {
            ($IncludeArchived -or -not $_.isArchived) -and ($IncludeForks -or -not $_.isFork)
        } | Sort-Object pushedAt -Descending)
    if ($repos.Count -eq 0) { Write-Warning 'No GitHub repos matched.' }

    Add-Line "## GitHub repos ($($repos.Count))"
    Add-Line
    Add-Line '| Repo | Lang | Private | Last push | Description |'
    Add-Line '|---|---|---|---|---|'
    foreach ($r in $repos) {
        $lang = if ($r.primaryLanguage) { $r.primaryLanguage.name } else { '' }
        $desc = "$($r.description)" -replace '\|', '\|' -replace '\r?\n', ' '
        Add-Line "| $($r.nameWithOwner) | $lang | $($r.isPrivate) | $(Format-Pushed $r.pushedAt 'yyyy-MM-dd') | $desc |"
    }
    Add-Line

    $i = 0
    foreach ($r in $repos) {
        $i++
        Write-Ink "  [$i/$($repos.Count)] $($r.nameWithOwner)" mute
        Add-Line "### $($r.nameWithOwner)"
        Add-Line
        Add-Line "- URL: $($r.url)"
        if ($r.description) { Add-Line "- Description: $($r.description)" }
        $lang = if ($r.primaryLanguage) { $r.primaryLanguage.name } else { 'n/a' }
        Add-Line "- Language: $lang | Private: $($r.isPrivate) | Fork: $($r.isFork) | Archived: $($r.isArchived) | Stars: $($r.stargazerCount)"
        Add-Line "- Last push: $(Format-Pushed $r.pushedAt 'yyyy-MM-dd HH:mm') UTC"
        $topics = @($r.repositoryTopics | Where-Object { $_ } | ForEach-Object { $_.name }) -join ', '
        if ($topics) { Add-Line "- Topics: $topics" }

        $tree = Invoke-Gh @('api', "repos/$($r.nameWithOwner)/contents")
        if ($tree.ExitCode -eq 0 -and $tree.Out) {
            $names = @($tree.Out | ConvertFrom-Json) | ForEach-Object { $_ } |
                ForEach-Object { if ($_.type -eq 'dir') { "$($_.name)/" } else { $_.name } }
            Add-Line "- Top level: $($names -join ', ')"
        }

        $readme = Invoke-Gh @('api', "repos/$($r.nameWithOwner)/readme", '-H', 'Accept: application/vnd.github.raw')
        Add-Readme -Max $MaxReadmeChars -Text $(if ($readme.ExitCode -eq 0) { $readme.Out } else { '' })
    }
}

# --- Local -------------------------------------------------------------------

if ($roots.Count -gt 0) {
    Write-Ink 'Scanning local folders' mute
    $projects = foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { Write-Warning "Not found: $root"; continue }
        # Every top-level folder is a project, so unzipped repos without .git count too.
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    }
    $projects = @($projects | Sort-Object -Unique)
    $hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
    $skip = '[\\/](\.git|node_modules|\.venv|venv|dist|build|bin|obj|target)([\\/]|$)'

    Add-Line "## Local repos ($($projects.Count))"
    Add-Line
    $i = 0
    foreach ($repoPath in $projects) {
        $i++
        Write-Ink "  [$i/$($projects.Count)] $repoPath" mute
        Add-Line "### $(Split-Path $repoPath -Leaf)"
        Add-Line
        Add-Line "- Path: $repoPath"

        $files = @(Get-ChildItem -LiteralPath $repoPath -File -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName.Substring($repoPath.Length) -notmatch $skip })

        if ($hasGit -and (Test-Path -LiteralPath (Join-Path $repoPath '.git'))) {
            # 'Continue' so git's stderr (no remote, no commits yet) is dropped, not thrown, on 5.1.
            $ErrorActionPreference = 'Continue'
            try {
                $remote = git -C $repoPath remote get-url origin 2>$null
                $branch = git -C $repoPath rev-parse --abbrev-ref HEAD 2>$null
                $last   = git -C $repoPath log -1 --format='%ci %s' 2>$null
                $count  = git -C $repoPath rev-list --count HEAD 2>$null
                $dirty  = @(git -C $repoPath status --porcelain 2>$null).Count
            } finally {
                $ErrorActionPreference = 'Stop'
            }
            if ($remote) { Add-Line "- Remote: $remote" }
            Add-Line "- Branch: $branch | Commits: $count | Uncommitted changes: $dirty"
            if ($last) { Add-Line "- Last commit: $last" }
        } else {
            $newest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newest) { Add-Line "- Newest file: $($newest.LastWriteTime.ToString('yyyy-MM-dd')) ($($newest.Name))" }
        }

        $top = @(Get-ChildItem -LiteralPath $repoPath -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.git' })
        $names = $top | ForEach-Object { if ($_.PSIsContainer) { "$($_.Name)/" } else { $_.Name } }
        Add-Line "- Top level: $($names -join ', ')"
        $manifests = $top | Where-Object { $_.Name -match '^(package\.json|pyproject\.toml|requirements\.txt|Cargo\.toml|go\.mod|.*\.csproj|.*\.sln|pom\.xml|build\.gradle|Gemfile|composer\.json|Dockerfile|docker-compose\.ya?ml|Makefile|.*\.psd1)$' } |
            ForEach-Object { $_.Name }
        if ($manifests) { Add-Line "- Manifests: $($manifests -join ', ')" }

        $ext = $files | Group-Object Extension | Sort-Object Count -Descending | Select-Object -First 8 |
            ForEach-Object { "$($_.Name)=$($_.Count)" }
        if ($ext) { Add-Line "- File types: $($ext -join ', ')" }

        $readmeFile = $top | Where-Object { -not $_.PSIsContainer -and $_.Name -match '^readme(\.(md|markdown|txt|rst))?$' } | Select-Object -First 1
        Add-Readme -Max $MaxReadmeChars -Text $(if ($readmeFile) { Get-Content -LiteralPath $readmeFile.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } else { '' })
    }
}

$outPath = Resolve-OutputPath $OutFile
[System.IO.File]::WriteAllText($outPath, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
$size = [Math]::Max(1, [Math]::Round((Get-Item -LiteralPath $outPath).Length / 1KB))
Write-Ink ''
Write-Ink "Wrote $outPath ($size KB)" mint
