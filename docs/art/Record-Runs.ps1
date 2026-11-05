<#
.SYNOPSIS
Records the console runs that the README art and the project page replay.

.DESCRIPTION
Runs each script for real, read-only or under -WhatIf, against the account gh
is logged in as, and saves what the console showed (ANSI colours included) to
docs/art/runs/<name>.txt. Then regenerate the art:

    python docs/art/make-art.py

While recording:

- gh is wrapped: `gh repo list` sees public repos only, and `gh repo archive`
  and `gh repo delete` throw before anything reaches GitHub.
- Read-Host answers come from a fixed list and are echoed the way the console
  echoes what you type. Start-Process (the [O] key) does nothing.
- RFS_PROJECTS points at a temp folder, so nothing in your projects folder is
  written or overwritten. In the saved text that folder, and any
  C:\Users\<name>\ prefix, reads C:\Users\you\Projects.

Run from the repo root in Windows PowerShell 5.1 or PowerShell 7:

    .\docs\art\Record-Runs.ps1
#>

#requires -Version 5.1
# The stand-ins for gh and Read-Host have to be global for the scripts under recording to find them.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Prompt')]
[CmdletBinding()]
param(
    # Internal: run one scenario in this process and write to stdout.
    [string] $Scenario,
    [string] $Answers = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

if ($Scenario) {
    # ---- inner: one run, in a fresh process so the console state is the script's own ----
    $global:RfsRealGh = (Get-Command gh -CommandType Application | Select-Object -First 1).Source
    function global:gh {
        $a = @($args)
        if ($a.Count -ge 2 -and $a[0] -eq 'repo' -and ($a[1] -eq 'archive' -or $a[1] -eq 'delete')) {
            throw "Record-Runs: blocked gh $($a -join ' ')"
        }
        if ($a.Count -ge 2 -and $a[0] -eq 'repo' -and $a[1] -eq 'list') { $a += @('--visibility', 'public') }
        & $global:RfsRealGh @a
    }
    $global:RfsAnswers = [System.Collections.Generic.Queue[string]]::new()
    foreach ($x in ($Answers -split ',')) { if ($x) { $global:RfsAnswers.Enqueue($x) } }
    function global:Read-Host {
        param([Parameter(Position = 0)] $Prompt)
        if ($global:RfsAnswers.Count -eq 0) { throw 'Record-Runs: out of answers' }
        $x = $global:RfsAnswers.Dequeue()
        Write-Host $x
        $x
    }
    function global:Start-Process { }

    Set-Location $repoRoot
    switch ($Scenario) {
        'list'   { .\Get-RepoList.ps1 }
        'digest' {
            .\Get-RepoDigest.ps1 -GitHub
            Write-Host '<<cmd>>'
            Get-Content (Join-Path $env:RFS_PROJECTS 'repos-digest.md') | Select-Object -Skip 4 -First 10
        }
        default  { .\Invoke-RepoReview.ps1 -SortBy size -WhatIf }
    }
    return
}

# ---- outer: every scenario, each in its own process ----
$exe = (Get-Process -Id $PID).Path
$outDir = Join-Path $PSScriptRoot 'runs'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$projects = Join-Path ([IO.Path]::GetTempPath()) "record-runs-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $projects | Out-Null

# The review scenarios answer per repo, so they need the order the script will show.
$json = & gh repo list --visibility public --limit 1000 --json name,isFork,isArchived,diskUsage
$order = @(ConvertFrom-Json -InputObject ($json -join "`n")) | ForEach-Object { $_ } |
    Where-Object { -not $_.isFork -and -not $_.isArchived } | Sort-Object diskUsage -Descending
$first = $order[0].name
$wrong = $first.Substring(0, 1).ToUpper() + $first.Substring(1)
if ($wrong -ceq $first) { $wrong = $first.ToUpper() }

$scenarios = [ordered]@{
    'list'           = @{ Command = '.\Get-RepoList.ps1' }
    'digest'         = @{ Command = '.\Get-RepoDigest.ps1 -GitHub'; Then = 'Get-Content $HOME\Projects\repos-digest.md | Select-Object -Skip 4 -First 10' }
    'review'         = @{ Command = '.\Invoke-RepoReview.ps1 -SortBy size -WhatIf'; Answers = 'k,a,q' }
    'review-all'     = @{ Command = '.\Invoke-RepoReview.ps1 -SortBy size -WhatIf'; Answers = (@('k') * $order.Count) -join ',' }
    'review-branches' = @{ Command = '.\Invoke-RepoReview.ps1 -SortBy size -WhatIf'; Answers = "o,x,d,$wrong,d,$first,q" }
}

$user = [regex]::Escape("\Users\$([Environment]::UserName)\")
try {
    foreach ($name in $scenarios.Keys) {
        $s = $scenarios[$name]
        $env:RFS_PROJECTS = $projects
        $childArgs = @('-NoProfile', '-File', $PSCommandPath, '-Scenario', $name)
        if ($s.ContainsKey('Answers')) { $childArgs += @('-Answers', $s.Answers) }
        $lines = & $exe @childArgs | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) { throw "Record-Runs: scenario $name exited $LASTEXITCODE" }
        $then = if ($s.ContainsKey('Then')) { $s.Then } else { '' }
        $text = @("<<cmd>>$($s.Command)") + @($lines | ForEach-Object { if ($_ -eq '<<cmd>>') { "<<cmd>>$then" } else { $_ } })
        $text = $text -join "`n"
        $text = $text.Replace($projects, 'C:\Users\you\Projects') -replace $user, '\Users\you\'
        $stamp = Get-Date -Format 'yyyy-MM-dd'
        $header = "<<recorded>>$stamp, Windows PowerShell $($PSVersionTable.PSVersion), gh $((& gh --version | Select-Object -First 1) -replace '^gh version (\S+).*', '$1')"
        [IO.File]::WriteAllText((Join-Path $outDir "$name.txt"), "$header`n$text`n", [Text.UTF8Encoding]::new($false))
        Write-Host "recorded $name"
    }
} finally {
    Remove-Item Env:RFS_PROJECTS -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $projects -Recurse -Force -ErrorAction SilentlyContinue
}
