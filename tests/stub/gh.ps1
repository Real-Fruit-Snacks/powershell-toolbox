# Stand-in for the gh CLI, first on PATH during tests. Never touches GitHub.
#   RFS_TEST_FIXTURES  folder holding repos.json, contents.json, readme.md
#   RFS_TEST_GH_LOG    file that gets one line per call
#   RFS_TEST_AUTH      'fail' makes `gh auth status` exit 1
#   RFS_TEST_SCOPES    scope list printed by `gh auth status`
#   RFS_TEST_FAIL      'list', 'archive' or 'delete' makes that call exit 1
$line = $args -join ' '
if ($env:RFS_TEST_GH_LOG) { Add-Content -LiteralPath $env:RFS_TEST_GH_LOG -Value $line -WhatIf:$false }
$fixtures = $env:RFS_TEST_FIXTURES

switch -Regex ($line) {
    '^auth status' {
        if ($env:RFS_TEST_AUTH -eq 'fail') { Write-Error 'You are not logged into any GitHub hosts.'; exit 1 }
        $scopes = if ($env:RFS_TEST_SCOPES) { $env:RFS_TEST_SCOPES } else { "'repo', 'delete_repo'" }
        'github.com'
        "  - Token scopes: $scopes"
        exit 0
    }
    '^repo list' {
        if ($env:RFS_TEST_FAIL -eq 'list') { Write-Error 'HTTP 404: Not Found'; exit 1 }
        $repos = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $fixtures 'repos.json') | ConvertFrom-Json
        if ($args -contains '--source') { $repos = @($repos | Where-Object { -not $_.isFork }) }
        ConvertTo-Json -InputObject @($repos) -Depth 5
        exit 0
    }
    '^api repos/[^/]+/[^/]+/contents' {
        Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $fixtures 'contents.json')
        exit 0
    }
    '^api repos/[^/]+/(?<name>[^/]+)/readme' {
        if ($Matches.name -eq 'no-readme') { Write-Error 'HTTP 404: Not Found'; exit 1 }
        Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $fixtures 'readme.md')
        exit 0
    }
    '^repo (?<verb>archive|delete) ' {
        if ($env:RFS_TEST_FAIL -eq $Matches.verb) { Write-Error 'HTTP 403'; exit 1 }
        exit 0
    }
    default {
        Write-Error "stub gh: unexpected call: $line"
        exit 2
    }
}
