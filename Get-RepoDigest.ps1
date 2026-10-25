<#
.SYNOPSIS
    Build a single Markdown digest of your repos (GitHub and/or local) with their READMEs,
    so you can upload one file to Claude.

.DESCRIPTION
    For GitHub repos (via the gh CLI) it writes a summary table plus, per repo, the
    metadata, topics, top-level file list and README. For local folders it treats every
    top-level directory under each root as a project and records git info (remote,
    branch, commit count, dirty files), manifests, a file-type fingerprint and the README.

.PARAMETER GitHub
    Include repos from the logged-in GitHub account (needs gh; run 'gh auth login' first).

.PARAMETER LocalRoot
    One or more folders whose top-level subfolders are treated as projects.

.PARAMETER OutFile
    Where to write the digest. Default: .\repos-digest.md

.PARAMETER MaxReadmeChars
    Truncate each README after this many characters. Default 8000.

.PARAMETER IncludeArchived
    Include archived GitHub repos (skipped by default).

.PARAMETER IncludeForks
    Include forked GitHub repos (skipped by default).

.EXAMPLE
    .\Get-RepoDigest.ps1 -GitHub
    GitHub only.

.EXAMPLE
    .\Get-RepoDigest.ps1 -LocalRoot "C:\src","D:\projects"
    Local repos only.

.EXAMPLE
    .\Get-RepoDigest.ps1 -GitHub -LocalRoot "C:\src" -OutFile .\my-repos.md -MaxReadmeChars 12000
    Both, custom output path, bigger README cap.
#>
[CmdletBinding()]
param(
    [switch]  $GitHub,
    [string[]]$LocalRoot = @(),
    [string]  $OutFile = ".\repos-digest.md",
    [int]     $MaxReadmeChars = 8000,
    [switch]  $IncludeArchived,
    [switch]  $IncludeForks
)

$ErrorActionPreference = "Continue"

if (-not $GitHub -and $LocalRoot.Count -eq 0) {
    Write-Warning "Nothing to do. Pass -GitHub and/or -LocalRoot <path>."
    return
}
$sb = [System.Text.StringBuilder]::new()
function Add-Line([string]$s = "") { [void]$sb.AppendLine($s) }
function Trim-Text([string]$t, [int]$max) {
    if ([string]::IsNullOrEmpty($t)) { return "" }
    if ($t.Length -le $max) { return $t }
    return $t.Substring(0, $max) + "`n`n[... truncated at $max chars ...]"
}
function Fence([string]$t) {
    # Use a fence longer than any backtick run inside the text so it never breaks out.
    $longest = ([regex]::Matches($t, '`+') | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    $n = [Math]::Max(4, ([int]$longest) + 1)
    return ('`' * $n)
}

Add-Line "# Repo digest"
Add-Line ""
Add-Line "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm') on $env:COMPUTERNAME"
Add-Line ""

# ---------------------------------------------------------------- GitHub ----
if ($GitHub) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warning "gh CLI not found. Install from https://cli.github.com and run 'gh auth login'. Skipping GitHub."
    } else {
        Write-Host "Listing GitHub repos..." -ForegroundColor Cyan
        $fields = "name,nameWithOwner,description,isPrivate,isFork,isArchived,primaryLanguage,pushedAt,url,repositoryTopics,stargazerCount"
        $repos = gh repo list --limit 1000 --json $fields 2>$null | ConvertFrom-Json
        if (-not $repos) { Write-Warning "No GitHub repos returned (are you logged in? try: gh auth status)." }

        $repos = $repos | Where-Object {
            ($IncludeArchived -or -not $_.isArchived) -and ($IncludeForks -or -not $_.isFork)
        } | Sort-Object pushedAt -Descending

        Add-Line "## GitHub repos ($($repos.Count))"
        Add-Line ""
        Add-Line "| Repo | Lang | Private | Last push | Description |"
        Add-Line "|---|---|---|---|---|"
        foreach ($r in $repos) {
            $lang = if ($r.primaryLanguage) { $r.primaryLanguage.name } else { "" }
            $desc = ($r.description -replace '\|', '\|' -replace "`r?`n", ' ')
            Add-Line "| $($r.nameWithOwner) | $lang | $($r.isPrivate) | $(($r.pushedAt -split 'T')[0]) | $desc |"
        }
        Add-Line ""

        $i = 0
        foreach ($r in $repos) {
            $i++
            Write-Host "  [$i/$($repos.Count)] $($r.nameWithOwner)" -ForegroundColor DarkGray
            Add-Line "### $($r.nameWithOwner)"
            Add-Line ""
            Add-Line "- URL: $($r.url)"
            if ($r.description) { Add-Line "- Description: $($r.description)" }
            $lang = if ($r.primaryLanguage) { $r.primaryLanguage.name } else { "n/a" }
            Add-Line "- Language: $lang | Private: $($r.isPrivate) | Fork: $($r.isFork) | Archived: $($r.isArchived) | Stars: $($r.stargazerCount)"
            Add-Line "- Last push: $($r.pushedAt)"
            $topics = @($r.repositoryTopics | ForEach-Object { $_.name }) -join ", "
            if ($topics) { Add-Line "- Topics: $topics" }

            # Top-level tree
            $tree = gh api "repos/$($r.nameWithOwner)/contents" 2>$null | ConvertFrom-Json
            if ($tree) {
                $names = ($tree | ForEach-Object { if ($_.type -eq 'dir') { "$($_.name)/" } else { $_.name } }) -join ", "
                Add-Line "- Top level: $names"
            }

            # README (raw)
            $readme = gh api "repos/$($r.nameWithOwner)/readme" -H "Accept: application/vnd.github.raw" 2>$null
            Add-Line ""
            if ($readme) {
                $txt = Trim-Text ($readme -join "`n") $MaxReadmeChars
                $f = Fence $txt
                Add-Line "$f markdown"
                Add-Line $txt
                Add-Line $f
            } else {
                Add-Line "_No README found._"
            }
            Add-Line ""
        }
    }
}

# ----------------------------------------------------------------- Local ----
if ($LocalRoot.Count -gt 0) {
    Write-Host "Scanning local folders..." -ForegroundColor Cyan
    $gitDirs = foreach ($root in $LocalRoot) {
        if (-not (Test-Path $root)) { Write-Warning "Not found: $root"; continue }
        # Every top-level folder is a project (works for unzipped repos without .git)
        Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    }
    $gitDirs = @($gitDirs | Sort-Object -Unique)

    Add-Line "## Local repos ($($gitDirs.Count))"
    Add-Line ""
    $i = 0
    foreach ($repoPath in $gitDirs) {
        $i++
        $name = Split-Path $repoPath -Leaf
        Write-Host "  [$i/$($gitDirs.Count)] $repoPath" -ForegroundColor DarkGray
        Add-Line "### $name"
        Add-Line ""
        Add-Line "- Path: $repoPath"

        if ((Test-Path (Join-Path $repoPath ".git")) -and (Get-Command git -ErrorAction SilentlyContinue)) {
            Push-Location $repoPath
            try {
                $remote = (git remote get-url origin 2>$null)
                $branch = (git rev-parse --abbrev-ref HEAD 2>$null)
                $last   = (git log -1 --format='%ci %s' 2>$null)
                $count  = (git rev-list --count HEAD 2>$null)
                $dirty  = (git status --porcelain 2>$null | Measure-Object).Count
                if ($remote) { Add-Line "- Remote: $remote" }
                Add-Line "- Branch: $branch | Commits: $count | Uncommitted changes: $dirty"
                if ($last) { Add-Line "- Last commit: $last" }
            } finally { Pop-Location }
        } else {
            $newest = Get-ChildItem -Path $repoPath -File -Recurse -Force -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newest) { Add-Line "- Newest file: $($newest.LastWriteTime.ToString('yyyy-MM-dd')) ($($newest.Name))" }
        }

        # Top-level listing and manifest hints
        $top = Get-ChildItem -Path $repoPath -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.git' }
        $names = ($top | ForEach-Object { if ($_.PSIsContainer) { "$($_.Name)/" } else { $_.Name } }) -join ", "
        Add-Line "- Top level: $names"
        $manifests = $top | Where-Object { $_.Name -match '^(package\.json|pyproject\.toml|requirements\.txt|Cargo\.toml|go\.mod|.*\.csproj|.*\.sln|pom\.xml|build\.gradle|Gemfile|composer\.json|Dockerfile|docker-compose\.ya?ml|Makefile)$' } |
            ForEach-Object { $_.Name }
        if ($manifests) { Add-Line "- Manifests: $($manifests -join ', ')" }

        # File-type counts (quick fingerprint)
        $ext = Get-ChildItem -Path $repoPath -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(\.git|node_modules|\.venv|venv|dist|build|bin|obj|target)\\' } |
            Group-Object Extension | Sort-Object Count -Descending | Select-Object -First 8 |
            ForEach-Object { "$($_.Name)=$($_.Count)" }
        if ($ext) { Add-Line "- File types: $($ext -join ', ')" }

        # README
        $readmeFile = $top | Where-Object { $_.Name -match '^readme(\.(md|markdown|txt|rst))?$' } | Select-Object -First 1
        Add-Line ""
        if ($readmeFile) {
            $txt = Trim-Text (Get-Content $readmeFile.FullName -Raw -ErrorAction SilentlyContinue) $MaxReadmeChars
            $f = Fence $txt
            Add-Line "$f markdown"
            Add-Line $txt
            Add-Line $f
        } else {
            Add-Line "_No README found._"
        }
        Add-Line ""
    }
}

$outPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
$outDir  = Split-Path $outPath -Parent
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
[System.IO.File]::WriteAllText($outPath, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
$size = [Math]::Round((Get-Item $outPath).Length / 1KB)
Write-Host "`nWrote $outPath ($size KB). Upload it to Claude." -ForegroundColor Green
