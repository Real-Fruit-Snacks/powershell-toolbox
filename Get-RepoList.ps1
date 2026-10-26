<#
.SYNOPSIS
Lists every GitHub repo for an owner with its description and status flags.

.DESCRIPTION
Pulls the repo list through the gh CLI, so private repos are included when your
token can see them. Emits one row per repo: Name, Description, Visibility,
Archived, Fork, Template, Empty, Language, Pushed, Stars, Url. Writes a table,
objects on the pipeline, CSV, JSON, or a Markdown table.

Needs gh (https://cli.github.com), logged in with `gh auth login`. For an org's
private repos the token also needs the read:org scope.

.PARAMETER Owner
GitHub user or org. Defaults to the account gh is logged in as.

.PARAMETER Format
Table (default), Object, Csv, Json or Markdown.

.PARAMETER OutFile
Write the output to a file instead of the console. A relative path goes in your
projects folder (see RFS_PROJECTS); an absolute path is used as given. Table
output is written as plain text, Object output as Clixml.

.PARAMETER Limit
Max repos to fetch. Default 1000.

.PARAMETER ExcludeForks
Leave forks out. They are listed by default.

.EXAMPLE
.\Get-RepoList.ps1
Table of your own repos.

.EXAMPLE
.\Get-RepoList.ps1 -Owner Real-Fruit-Snacks -Format Markdown -OutFile repos.md
Writes C:\Users\<you>\Projects\repos.md.

.EXAMPLE
.\Get-RepoList.ps1 -Format Object | Where-Object Archived | Select-Object Name, Pushed

.EXAMPLE
.\Get-RepoList.ps1 -Format Csv -OutFile repos.csv -ExcludeForks
#>

#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $Owner,

    [ValidateSet('Table', 'Object', 'Csv', 'Json', 'Markdown')]
    [string] $Format = 'Table',

    [string] $OutFile,

    [ValidateRange(1, 10000)]
    [int] $Limit = 1000,

    [switch] $ExcludeForks
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

# --- fetch -------------------------------------------------------------------

$fields = @(
    'name', 'nameWithOwner', 'description', 'visibility',
    'isArchived', 'isFork', 'isTemplate', 'isEmpty',
    'primaryLanguage', 'pushedAt', 'stargazerCount', 'url'
) -join ','

$ghArgs = @('repo', 'list')
if ($Owner) { $ghArgs += $Owner }
$ghArgs += @('--limit', "$Limit", '--json', $fields)
if ($ExcludeForks) { $ghArgs += '--source' }

$result = Invoke-Gh $ghArgs
if ($result.ExitCode -ne 0) {
    throw "gh repo list failed:`n$($result.Err)"
}

$ownerLabel = if ($Owner) { $Owner } else { 'current user' }
$repos = @(ConvertFrom-GhJson $result.Out)
if ($repos.Count -eq 0) {
    Write-Warning "No repos returned for '$ownerLabel'."
    return
}

# --- shape -------------------------------------------------------------------

$rows = foreach ($r in $repos) {
    [pscustomobject]@{
        Name        = $r.name
        Description = $r.description
        Visibility  = "$($r.visibility)".ToLower()     # public | private | internal
        Archived    = [bool]$r.isArchived
        Fork        = [bool]$r.isFork
        Template    = [bool]$r.isTemplate
        Empty       = [bool]$r.isEmpty
        Language    = if ($r.primaryLanguage) { $r.primaryLanguage.name } else { '' }
        Pushed      = if ($r.pushedAt) { ([datetime]$r.pushedAt).ToString('yyyy-MM-dd') } else { '' }
        Stars       = [int]$r.stargazerCount
        Url         = $r.url
    }
}
$rows = @($rows | Sort-Object Name)

# Compact flag string for the table and Markdown views.
function Get-Status ([pscustomobject] $Row) {
    $flags = @($Row.Visibility)
    if ($Row.Archived) { $flags += 'archived' }
    if ($Row.Fork)     { $flags += 'fork' }
    if ($Row.Template) { $flags += 'template' }
    if ($Row.Empty)    { $flags += 'empty' }
    $flags -join ', '
}

# --- output ------------------------------------------------------------------

# Object output goes straight to the pipeline (or Clixml). It must not pass
# through the $text assignment below, or `return` swallows the objects.
if ($Format -eq 'Object') {
    if ($OutFile) {
        $path = Resolve-OutputPath $OutFile
        $rows | Export-Clixml -LiteralPath $path
        Write-Ink "Wrote $($rows.Count) repos to $path" mint
    } else {
        $rows
    }
    return
}

$text = switch ($Format) {
    'Csv' {
        ($rows | ConvertTo-Csv -NoTypeInformation) -join [Environment]::NewLine
    }
    'Json' {
        ConvertTo-Json -InputObject $rows -Depth 3
    }
    'Markdown' {
        $lines = @(
            "# Repos: $ownerLabel ($($rows.Count))",
            '',
            '| Repo | Description | Status | Language | Pushed |',
            '|---|---|---|---|---|'
        )
        foreach ($row in $rows) {
            $desc = "$($row.Description)" -replace '\|', '\|' -replace '\r?\n', ' '
            $lines += "| [$($row.Name)]($($row.Url)) | $desc | $(Get-Status $row) | $($row.Language) | $($row.Pushed) |"
        }
        $lines -join "`n"
    }
    'Table' {
        $rows |
            Select-Object Name,
                @{ n = 'Status'; e = { Get-Status $_ } },
                Language, Pushed, Description |
            Format-Table -AutoSize -Wrap |
            Out-String -Width 4096
    }
}

if ($OutFile) {
    $path = Resolve-OutputPath $OutFile
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
    Write-Ink "Wrote $($rows.Count) repos to $path" mint
} else {
    $text
}
