<#
.SYNOPSIS
Prints the release notes for a version, from its section in CHANGELOG.md.

.DESCRIPTION
The notes are the summary paragraph at the top of the version's section, then "Full list in
CHANGELOG.md.", the way the earlier releases have them. Throws if the newest section in
CHANGELOG.md isn't "## v<Version> - <date>" (with an em dash), or has no summary paragraph
before its first ### heading. .github/workflows/release.yml runs it on the tag, before
building anything and again to publish.

.PARAMETER Version
The version without the v, such as 1.1.0.

.EXAMPLE
pwsh ./tools/release-notes.ps1 -Version 1.1.0
#>
#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $Version)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'CHANGELOG.md'
$lines = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) -split '\r?\n'
$heads = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -like '## *') { $i } })
if (-not $heads) { throw 'CHANGELOG.md has no ## sections' }
$want = '^## v' + [regex]::Escape($Version) + ' ' + [char]0x2014 + ' \d{4}-\d{2}-\d{2}$'
if ($lines[$heads[0]] -notmatch $want) {
    throw "The newest section in CHANGELOG.md is '$($lines[$heads[0]])', not v$Version with its date. Move Unreleased to v$Version first."
}
$end = if ($heads.Count -gt 1) { $heads[1] } else { $lines.Count }
$summary = for ($i = $heads[0] + 1; $i -lt $end -and $lines[$i] -notlike '### *'; $i++) { $lines[$i] }
$paragraphs = (@($summary) -join "`n").Trim() -split '\n\s*\n' | Where-Object { $_.Trim() } | ForEach-Object {
    (@($_ -split '\n' | ForEach-Object { $_.Trim() }) -join ' ')
}
if (-not $paragraphs) { throw "The v$Version section in CHANGELOG.md has no summary paragraph before its first ### heading" }
(@($paragraphs) -join "`n`n") + ' Full list in CHANGELOG.md.'
