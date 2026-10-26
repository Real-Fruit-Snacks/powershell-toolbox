# Dot-sourced by every test file. Puts tests/stub/gh.ps1 first on PATH so the
# scripts under test never reach the real gh or GitHub.
$RepoRoot = Split-Path $PSScriptRoot -Parent
$StubVars = 'RFS_TEST_FIXTURES', 'RFS_TEST_GH_LOG', 'RFS_TEST_AUTH', 'RFS_TEST_SCOPES', 'RFS_TEST_FAIL', 'NO_COLOR', 'RFS_THEME', 'RFS_PROJECTS'

function Enter-StubGh {
    # RFS_PROJECTS points at a throwaway folder so nothing lands in your real ~/Projects.
    param([Parameter(Mandatory)] [string] $LogPath, [string] $ProjectsDir = (Join-Path $TestDrive 'Projects'))
    $script:SavedPath = $env:PATH
    $env:PATH = (Join-Path $PSScriptRoot 'stub') + [IO.Path]::PathSeparator + $env:PATH
    foreach ($name in $StubVars) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    $env:RFS_TEST_FIXTURES = Join-Path $PSScriptRoot 'fixtures'
    $env:RFS_TEST_GH_LOG = $LogPath
    $env:NO_COLOR = '1'
    $env:RFS_PROJECTS = $ProjectsDir
}

function Exit-StubGh {
    $env:PATH = $script:SavedPath
    foreach ($name in $StubVars) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
}

function Get-GhCalls {
    param([Parameter(Mandatory)] [string] $LogPath)
    if (Test-Path -LiteralPath $LogPath) { @(Get-Content -LiteralPath $LogPath) } else { @() }
}

# Loads one function out of a script without running the script.
function Import-ScriptFunction {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Name)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $fn) { throw "No function $Name in $Path" }
    $fn.Extent.Text
}
