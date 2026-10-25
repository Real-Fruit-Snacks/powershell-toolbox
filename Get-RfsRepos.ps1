#requires -Version 5.1
<#
.SYNOPSIS
Lists every GitHub repo for an owner with its description and status flags.

.DESCRIPTION
Pulls the repo list through the authenticated gh CLI, so private repos are
included when your token can see them. Emits one object per repo with:
Name, Description, Visibility, Archived, Fork, Template, Empty, Language,
Pushed, Stars, Url. Output can be a table, objects on the pipeline, CSV,
JSON, or a Markdown table.

Requires: gh (https://cli.github.com) and a login (`gh auth login`).
For an org's private repos the token needs the read:org scope.

.PARAMETER Owner
GitHub user or org. Defaults to Real-Fruit-Snacks. Pass '' for the
account you are logged in as.

.PARAMETER Format
Table (default) · Object · Csv · Json · Markdown

.PARAMETER OutFile
Write the output here instead of the console. Table output is written
as plain text.

.PARAMETER Limit
Max repos to fetch. Default 1000.

.PARAMETER IncludeForks
Forks are listed by default; pass -IncludeForks:$false to drop them.

.EXAMPLE
.\Get-RfsRepos.ps1
Table of Real-Fruit-Snacks repos.

.EXAMPLE
.\Get-RfsRepos.ps1 -Format Markdown -OutFile repos.md

.EXAMPLE
.\Get-RfsRepos.ps1 -Format Object | Where-Object Archived | Select-Object Name, Pushed

.EXAMPLE
.\Get-RfsRepos.ps1 -Owner '' -Format Csv -OutFile my-repos.csv
#>
[CmdletBinding()]
param(
    [string] $Owner = 'Real-Fruit-Snacks',

    [ValidateSet('Table', 'Object', 'Csv', 'Json', 'Markdown')]
    [string] $Format = 'Table',

    [string] $OutFile,

    [ValidateRange(1, 10000)]
    [int] $Limit = 1000,

    [switch] $IncludeForks = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- preflight ---------------------------------------------------------------

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'gh CLI not found. Install from https://cli.github.com and run `gh auth login`.'
}

& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'gh is not logged in. Run `gh auth login`.'
}

# --- fetch -------------------------------------------------------------------

$fields = @(
    'name', 'nameWithOwner', 'description', 'visibility',
    'isArchived', 'isPrivate', 'isFork', 'isTemplate', 'isEmpty',
    'primaryLanguage', 'pushedAt', 'stargazerCount', 'url'
) -join ','

$ghArgs = @('repo', 'list')
if ($Owner) { $ghArgs += $Owner }
$ghArgs += @('--limit', $Limit, '--json', $fields)
if (-not $IncludeForks) { $ghArgs += '--source' }

$raw = & gh @ghArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "gh repo list failed:`n$raw"
}

$repos = ($raw -join "`n") | ConvertFrom-Json
$ownerLabel = if ($Owner) { $Owner } else { 'current user' }
if (-not $repos) {
    Write-Warning "No repos returned for '$ownerLabel'."
    return
}

# --- shape -------------------------------------------------------------------

$rows = foreach ($r in $repos) {
    [pscustomobject]@{
        Name        = $r.name
        Description = $r.description
        Visibility  = $r.visibility.ToLower()     # public | private | internal
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
$rows = $rows | Sort-Object Name

# Compact flag string for table/markdown views.
function Get-Status ([pscustomobject] $row) {
    $flags = @($row.Visibility)
    if ($row.Archived) { $flags += 'archived' }
    if ($row.Fork)     { $flags += 'fork' }
    if ($row.Template) { $flags += 'template' }
    if ($row.Empty)    { $flags += 'empty' }
    $flags -join ', '
}

# --- output ------------------------------------------------------------------

# Object output goes straight to the pipeline (or Clixml); it must not pass
# through the $text assignment below or the objects are swallowed by `return`.
if ($Format -eq 'Object') {
    if ($OutFile) {
        $rows | Export-Clixml -Path $OutFile
        Write-Host "Wrote $(@($rows).Count) repos to $OutFile"
    }
    else {
        $rows
    }
    return
}

$text = switch ($Format) {
    'Csv' {
        $rows | ConvertTo-Csv -NoTypeInformation
    }
    'Json' {
        $rows | ConvertTo-Json -Depth 3
    }
    'Markdown' {
        $lines = @(
            "# Repos: $ownerLabel ($(@($rows).Count))",
            '',
            '| Repo | Description | Status | Language | Pushed |',
            '|---|---|---|---|---|'
        )
        foreach ($row in $rows) {
            $desc = "$($row.Description)" -replace '\|', '\|'
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
    $text | Set-Content -Path $OutFile -Encoding utf8
    Write-Host "Wrote $(@($rows).Count) repos to $OutFile"
}
else {
    $text
}
