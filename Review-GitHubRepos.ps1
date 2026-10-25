<#
.SYNOPSIS
    Walk through your GitHub repos one at a time and decide whether to delete each one.

.DESCRIPTION
    Uses the GitHub CLI (gh). For every repo it shows name, visibility, size,
    last push date, fork/archived status and description, then asks:

        [D] delete   [A] archive   [K] keep   [O] open in browser   [Q] quit

    Deleting requires a second confirmation (type the repo name), and every
    decision is appended to a log file so you have a record.

.PARAMETER Owner
    GitHub user or org to list repos for. Defaults to the logged-in account.

.PARAMETER Limit
    Max number of repos to fetch (default 1000).

.PARAMETER SortBy
    pushed (oldest first, default), name, or size (largest first).

.PARAMETER IncludeForks
    Also include forked repos (skipped by default).

.PARAMETER IncludeArchived
    Also include archived repos (skipped by default).

.PARAMETER LogPath
    Where to write the decision log. Defaults to .\repo-review-<timestamp>.log

.EXAMPLE
    .\Review-GitHubRepos.ps1
    .\Review-GitHubRepos.ps1 -Owner my-org -SortBy size
    .\Review-GitHubRepos.ps1 -IncludeForks -IncludeArchived

.NOTES
    gh needs the delete_repo scope. If you get a 403 on delete, run:
        gh auth refresh -h github.com -s delete_repo
#>
[CmdletBinding()]
param(
    [string]$Owner,
    [int]$Limit = 1000,
    [ValidateSet('pushed', 'name', 'size')]
    [string]$SortBy = 'pushed',
    [switch]$IncludeForks,
    [switch]$IncludeArchived,
    [string]$LogPath = (Join-Path (Get-Location) ("repo-review-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date)))
)

$ErrorActionPreference = 'Stop'

# ---------- preflight ----------
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Error "GitHub CLI (gh) not found on PATH. Install from https://cli.github.com/"
    exit 1
}

gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Not logged in to gh. Run: gh auth login"
    exit 1
}

# Make sure the token can actually delete repos; offer to add the scope if not.
$scopes = (gh auth status 2>&1 | Select-String -Pattern 'Token scopes:' | Select-Object -First 1) -join ''
if ($scopes -and $scopes -notmatch 'delete_repo') {
    Write-Host ""
    Write-Host "Your gh token does not have the 'delete_repo' scope, so deletes will fail." -ForegroundColor Yellow
    $ans = Read-Host "Add it now? (gh auth refresh -h github.com -s delete_repo) [y/N]"
    if ($ans -match '^[Yy]') {
        gh auth refresh -h github.com -s delete_repo
        if ($LASTEXITCODE -ne 0) { Write-Error "Scope refresh failed."; exit 1 }
    } else {
        Write-Host "Continuing anyway - deletes may be rejected." -ForegroundColor Yellow
    }
}

# ---------- fetch repos ----------
$fields = 'name,nameWithOwner,description,isPrivate,isFork,isArchived,diskUsage,pushedAt,url'
$ghArgs = @('repo', 'list')
if ($Owner) { $ghArgs += $Owner }
$ghArgs += @('--limit', $Limit, '--json', $fields)

Write-Host "Fetching repos..." -ForegroundColor Cyan
$raw = gh @ghArgs
if ($LASTEXITCODE -ne 0) { Write-Error "gh repo list failed."; exit 1 }
$repos = $raw | ConvertFrom-Json

if (-not $IncludeForks)    { $repos = $repos | Where-Object { -not $_.isFork } }
if (-not $IncludeArchived) { $repos = $repos | Where-Object { -not $_.isArchived } }

switch ($SortBy) {
    'pushed' { $repos = $repos | Sort-Object { [datetime]$_.pushedAt } }
    'name'   { $repos = $repos | Sort-Object name }
    'size'   { $repos = $repos | Sort-Object diskUsage -Descending }
}

$repos = @($repos)
if ($repos.Count -eq 0) { Write-Host "No repos matched."; exit 0 }

# ---------- helpers ----------
function Format-Size([int]$kb) {
    if ($kb -ge 1048576) { return ('{0:N1} GB' -f ($kb / 1048576)) }
    if ($kb -ge 1024)    { return ('{0:N1} MB' -f ($kb / 1024)) }
    return "$kb KB"
}

function Write-Log([string]$action, $repo, [string]$note = '') {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1,-8} {2}  {3}' -f (Get-Date), $action, $repo.nameWithOwner, $note
    Add-Content -Path $LogPath -Value $line
}

# ---------- main loop ----------
$deleted = 0; $archived = 0; $kept = 0; $failed = 0
$total = $repos.Count

Write-Host ""
Write-Host "Reviewing $total repos (sorted by $SortBy). Log: $LogPath" -ForegroundColor Cyan
Write-Host ""

for ($i = 0; $i -lt $total; $i++) {
    $r = $repos[$i]
    $pushed = [datetime]$r.pushedAt
    $age = (New-TimeSpan -Start $pushed -End (Get-Date)).Days
    $vis = if ($r.isPrivate) { 'private' } else { 'public' }
    $flags = @()
    if ($r.isFork)     { $flags += 'FORK' }
    if ($r.isArchived) { $flags += 'ARCHIVED' }

    Write-Host ("=" * 70) -ForegroundColor DarkGray
    Write-Host ("[{0}/{1}] " -f ($i + 1), $total) -NoNewline -ForegroundColor DarkGray
    Write-Host $r.nameWithOwner -ForegroundColor White
    Write-Host ("   {0,-11} {1,-10} last push {2:yyyy-MM-dd} ({3} days ago) {4}" -f `
        $vis, (Format-Size $r.diskUsage), $pushed, $age, ($flags -join ' ')) -ForegroundColor Gray
    if ($r.description) {
        Write-Host "   $($r.description)" -ForegroundColor DarkCyan
    }
    Write-Host "   $($r.url)" -ForegroundColor DarkGray
    Write-Host ""

    $decided = $false
    while (-not $decided) {
        $archiveOpt = if ($r.isArchived) { '' } else { '[A] archive   ' }
        Write-Host "   [D] delete   ${archiveOpt}[K] keep   [O] open in browser   [Q] quit  " -NoNewline -ForegroundColor Yellow
        $choice = (Read-Host).Trim().ToUpper()

        switch ($choice) {
            'A' {
                if ($r.isArchived) {
                    Write-Host "   Already archived." -ForegroundColor DarkYellow
                    break
                }
                gh repo archive $r.nameWithOwner --yes
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "   Archived (read-only; can be unarchived later from repo settings)." -ForegroundColor DarkYellow
                    Write-Log 'ARCHIVED' $r
                    $archived++
                } else {
                    Write-Host "   Archive FAILED." -ForegroundColor Magenta
                    Write-Log 'FAILED' $r 'gh repo archive returned non-zero'
                    $failed++
                }
                $decided = $true
            }
            'D' {
                Write-Host "   Type the repo name '" -NoNewline -ForegroundColor Red
                Write-Host $r.name -NoNewline -ForegroundColor White
                Write-Host "' to confirm deletion: " -NoNewline -ForegroundColor Red
                $confirm = (Read-Host).Trim()
                if ($confirm -ceq $r.name) {
                    gh repo delete $r.nameWithOwner --yes
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "   Deleted." -ForegroundColor Red
                        Write-Log 'DELETED' $r
                        $deleted++
                    } else {
                        Write-Host "   Delete FAILED (missing delete_repo scope? run: gh auth refresh -h github.com -s delete_repo)" -ForegroundColor Magenta
                        Write-Log 'FAILED' $r 'gh repo delete returned non-zero'
                        $failed++
                    }
                    $decided = $true
                } else {
                    Write-Host "   Name didn't match - not deleted." -ForegroundColor Yellow
                }
            }
            'K' {
                Write-Log 'KEPT' $r
                $kept++
                $decided = $true
            }
            'O' {
                Start-Process $r.url
            }
            'Q' {
                Write-Log 'QUIT' $r "stopped at $($i + 1)/$total"
                Write-Host ""
                Write-Host "Stopped. Deleted: $deleted  Archived: $archived  Kept: $kept  Failed: $failed  Remaining: $($total - $i)" -ForegroundColor Cyan
                Write-Host "Log: $LogPath"
                exit 0
            }
            default {
                Write-Host "   Please enter D, A, K, O or Q." -ForegroundColor DarkYellow
            }
        }
    }
    Write-Host ""
}

Write-Host ("=" * 70) -ForegroundColor DarkGray
Write-Host "Done. Deleted: $deleted  Archived: $archived  Kept: $kept  Failed: $failed" -ForegroundColor Cyan
Write-Host "Log: $LogPath"
