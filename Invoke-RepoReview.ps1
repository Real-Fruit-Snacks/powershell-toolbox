<#
.SYNOPSIS
Walks through your GitHub repos one at a time: delete, archive or keep each.

.DESCRIPTION
Uses the gh CLI. For every repo it shows the name, visibility, size, last push,
fork/archived flags and description, then asks:

    [D] delete   [A] archive   [K] keep   [O] open in browser   [Q] quit

Delete asks a second time: type the repo name exactly. Every decision is
appended to a log file. -WhatIf walks the same list without changing anything.

.PARAMETER Owner
GitHub user or org to list repos for. Defaults to the account gh is logged in as.

.PARAMETER Limit
Max repos to fetch. Default 1000.

.PARAMETER SortBy
pushed (oldest first, default), name, or size (largest first).

.PARAMETER IncludeForks
Include forked repos. Skipped by default.

.PARAMETER IncludeArchived
Include archived repos. Skipped by default.

.PARAMETER LogPath
Where to write the decision log. Default: repo-review-<timestamp>.log in your
projects folder. A relative path goes in the projects folder; an absolute path
is used as given.

.EXAMPLE
.\Invoke-RepoReview.ps1

.EXAMPLE
.\Invoke-RepoReview.ps1 -Owner my-org -SortBy size

.EXAMPLE
.\Invoke-RepoReview.ps1 -IncludeForks -IncludeArchived -WhatIf

.NOTES
Deleting needs the delete_repo scope. The script offers to add it; to do it by hand:
    gh auth refresh -h github.com -s delete_repo
#>

#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Owner,

    [ValidateRange(1, 10000)]
    [int] $Limit = 1000,

    [ValidateSet('pushed', 'name', 'size')]
    [string] $SortBy = 'pushed',

    [switch] $IncludeForks,

    [switch] $IncludeArchived,

    [string] $LogPath
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

function ConvertFrom-GhJson ([string] $Json) {
    # One output object per element of a JSON array. Windows PowerShell 5.1's
    # ConvertFrom-Json returns the whole array as a single object, so @(... | ConvertFrom-Json)
    # holds one item there and N items on PowerShell 7. The foreach makes both the same.
    if ([string]::IsNullOrWhiteSpace($Json)) { return }
    $parsed = ConvertFrom-Json -InputObject $Json
    foreach ($item in $parsed) { $item }
}
#endregion rfs-common

Assert-Gh
if (-not $LogPath) { $LogPath = 'repo-review-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date) }
$LogPath = Resolve-OutputPath $LogPath

# Deletes fail without the delete_repo scope; offer to add it up front. Skipped
# under -WhatIf, and when gh does not print scopes (fine-grained tokens).
$status = Invoke-Gh @('auth', 'status')
$scopeLine = ("$($status.Out)`n$($status.Err)" -split '\r?\n' | Where-Object { $_ -match 'Token scopes:' } | Select-Object -First 1)
if (-not $WhatIfPreference -and $scopeLine -and $scopeLine -notmatch 'delete_repo') {
    Write-Ink ''
    Write-Ink "Your gh token does not have the delete_repo scope, so deletes will fail." amber
    $answer = "$(Read-Host 'Add it now with gh auth refresh -h github.com -s delete_repo? [y/N]')".Trim()
    if ($answer -match '^[Yy]') {
        # Interactive: gh opens a browser, so it runs directly rather than through Invoke-Gh.
        & gh auth refresh -h github.com -s delete_repo
        if ($LASTEXITCODE -ne 0) { throw 'gh auth refresh failed.' }
    } else {
        Write-Ink 'Continuing. Deletes may be rejected.' amber
    }
}

# --- fetch -------------------------------------------------------------------

$ghArgs = @('repo', 'list')
if ($Owner) { $ghArgs += $Owner }
$ghArgs += @('--limit', "$Limit", '--json', 'name,nameWithOwner,description,isPrivate,isFork,isArchived,diskUsage,pushedAt,url')

Write-Ink 'Fetching repos' mute
$list = Invoke-Gh $ghArgs
if ($list.ExitCode -ne 0) { throw "gh repo list failed:`n$($list.Err)" }
$repos = @(ConvertFrom-GhJson $list.Out)

if (-not $IncludeForks)    { $repos = @($repos | Where-Object { -not $_.isFork }) }
if (-not $IncludeArchived) { $repos = @($repos | Where-Object { -not $_.isArchived }) }

switch ($SortBy) {
    'pushed' { $repos = $repos | Sort-Object { if ($_.pushedAt) { [datetime]$_.pushedAt } else { [datetime]::MinValue } } }
    'name'   { $repos = $repos | Sort-Object name }
    'size'   { $repos = $repos | Sort-Object diskUsage -Descending }
}

$repos = @($repos)
if ($repos.Count -eq 0) { Write-Ink 'No repos matched.'; return }

# --- helpers -----------------------------------------------------------------

function Format-Size ([long] $KB) {
    if ($KB -ge 1048576) { return ('{0:N1} GB' -f ($KB / 1048576)) }
    if ($KB -ge 1024)    { return ('{0:N1} MB' -f ($KB / 1024)) }
    return "$KB KB"
}

function Add-ReviewLog ([string] $Action, [pscustomobject] $Repo, [string] $Note = '') {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1,-8} {2}  {3}' -f (Get-Date), $Action, $Repo.nameWithOwner, $Note
    # -WhatIf:$false: a dry run still records what it would have done.
    Add-Content -LiteralPath $LogPath -Value $line.TrimEnd() -Encoding UTF8 -WhatIf:$false
}

function Write-Summary ([string] $Label, [string] $Tail = '') {
    Write-Ink "$Label Deleted: $deleted  Archived: $archived  Kept: $kept  Failed: $failed$Tail"
    Write-Ink "Log: $LogPath" mute
}

# --- review ------------------------------------------------------------------

$deleted = 0; $archived = 0; $kept = 0; $failed = 0
$total = $repos.Count
$rule = '-' * 70
$dryRun = if ($WhatIfPreference) { ' Dry run: nothing will change.' } else { '' }

Write-Ink ''
Write-Ink "Reviewing $total repos, sorted by $SortBy.$dryRun" text
Write-Ink "Log: $LogPath" mute
Write-Ink ''

for ($i = 0; $i -lt $total; $i++) {
    $r = $repos[$i]
    $pushed = if ($r.pushedAt) { [datetime]$r.pushedAt } else { $null }
    $when = if ($pushed) { '{0:yyyy-MM-dd} ({1} days ago)' -f $pushed, (New-TimeSpan -Start $pushed -End (Get-Date)).Days } else { 'never' }
    $vis = if ($r.isPrivate) { 'private' } else { 'public' }
    $flags = @()
    if ($r.isFork)     { $flags += 'fork' }
    if ($r.isArchived) { $flags += 'archived' }

    Write-Ink $rule mute
    Write-Ink ('[{0}/{1}] ' -f ($i + 1), $total) ember -NoNewline
    Write-Ink $r.nameWithOwner
    Write-Ink ('   {0,-8} {1,-9} last push {2} {3}' -f $vis, (Format-Size $r.diskUsage), $when, ($flags -join ' ')).TrimEnd() mute
    if ($r.description) { Write-Ink "   $($r.description)" }
    Write-Ink "   $($r.url)" mute
    Write-Ink ''

    $decided = $false
    while (-not $decided) {
        $archiveOption = if ($r.isArchived) { '' } else { '[A] archive   ' }
        Write-Ink "   [D] delete   $archiveOption[K] keep   [O] open in browser   [Q] quit  " amber -NoNewline
        $choice = "$(Read-Host)".Trim().ToUpper()

        switch ($choice) {
            'A' {
                if ($r.isArchived) { Write-Ink '   Already archived.' mute; break }
                if (-not $PSCmdlet.ShouldProcess($r.nameWithOwner, 'Archive repository')) {
                    Add-ReviewLog -Action 'WHATIF' -Repo $r -Note 'archive'
                } elseif ((Invoke-Gh @('repo', 'archive', $r.nameWithOwner, '--yes')).ExitCode -eq 0) {
                    Write-Ink '   Archived. Read-only now; unarchive from the repo settings.' mint
                    Add-ReviewLog -Action 'ARCHIVED' -Repo $r
                    $archived++
                } else {
                    Write-Warning 'Archive failed.'
                    Add-ReviewLog -Action 'FAILED' -Repo $r -Note 'gh repo archive returned non-zero'
                    $failed++
                }
                $decided = $true
            }
            'D' {
                Write-Ink "   Type '$($r.name)' to confirm deletion: " amber -NoNewline
                $confirm = "$(Read-Host)".Trim()
                if ($confirm -cne $r.name) {
                    Write-Ink "   Name didn't match. Not deleted." mute
                    break
                }
                if (-not $PSCmdlet.ShouldProcess($r.nameWithOwner, 'Delete repository')) {
                    Add-ReviewLog -Action 'WHATIF' -Repo $r -Note 'delete'
                } elseif ((Invoke-Gh @('repo', 'delete', $r.nameWithOwner, '--yes')).ExitCode -eq 0) {
                    Write-Ink '   Deleted.' mint
                    Add-ReviewLog -Action 'DELETED' -Repo $r
                    $deleted++
                } else {
                    Write-Warning 'Delete failed. Missing delete_repo scope? Run: gh auth refresh -h github.com -s delete_repo'
                    Add-ReviewLog -Action 'FAILED' -Repo $r -Note 'gh repo delete returned non-zero'
                    $failed++
                }
                $decided = $true
            }
            'K' {
                Add-ReviewLog -Action 'KEPT' -Repo $r
                $kept++
                $decided = $true
            }
            'O' {
                Start-Process $r.url
            }
            'Q' {
                Add-ReviewLog -Action 'QUIT' -Repo $r -Note "stopped at $($i + 1)/$total"
                Write-Ink ''
                Write-Summary -Label 'Stopped.' -Tail "  Remaining: $($total - $i)"
                return
            }
            default {
                Write-Ink '   Enter D, A, K, O or Q.' mute
            }
        }
    }
    Write-Ink ''
}

Write-Ink $rule mute
Write-Summary -Label 'Done.'
