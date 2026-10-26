BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script = Join-Path $RepoRoot 'Get-RepoList.ps1'
}

Describe 'Get-RepoList' {
    BeforeEach {
        $log = Join-Path $TestDrive "gh-$([guid]::NewGuid()).log"
        Enter-StubGh -LogPath $log
    }
    AfterEach { Exit-StubGh }

    It 'emits one object per repo, sorted by name, with flags shaped' {
        $rows = @(& $script -Format Object)
        $rows.Count | Should -Be 4
        $rows.Name | Should -Be @('alpha-tool', 'forked-lib', 'no-readme', 'old-archive')
        $alpha = $rows | Where-Object Name -eq 'alpha-tool'
        $alpha.Visibility | Should -Be 'public'
        $alpha.Language | Should -Be 'PowerShell'
        $alpha.Pushed | Should -Be '2026-10-01'
        ($rows | Where-Object Name -eq 'no-readme').Pushed | Should -Be ''
        ($rows | Where-Object Name -eq 'old-archive').Archived | Should -BeTrue
    }

    It 'lists your own account when -Owner is left out' {
        & $script -Format Object | Out-Null
        Get-GhCalls $log | Where-Object { $_ -like 'repo list*' } | Should -BeLike 'repo list --limit 1000 --json *'
    }

    It 'passes -Owner and -Limit through to gh' {
        & $script -Owner some-org -Limit 5 -Format Object | Out-Null
        Get-GhCalls $log | Where-Object { $_ -like 'repo list*' } | Should -BeLike 'repo list some-org --limit 5 --json *'
    }

    It 'drops forks with -ExcludeForks' {
        $rows = @(& $script -Format Object -ExcludeForks)
        $rows.Name | Should -Not -Contain 'forked-lib'
        Get-GhCalls $log | Where-Object { $_ -like 'repo list*' } | Should -Match '--source'
    }

    It 'writes a Markdown table with pipes and newlines escaped' {
        $md = & $script -Format Markdown
        $md | Should -Match '^# Repos: current user \(4\)'
        $md | Should -Match '\| \[alpha-tool\]\(https://github.com/test-owner/alpha-tool\) \| Pipes \\\| and newlines, caf. \| public \|'
        $md | Should -Match 'private, template, empty'
    }

    It 'keeps JSON an array even for one repo' {
        $one = Join-Path $TestDrive 'one'
        New-Item -ItemType Directory $one | Out-Null
        $all = Get-Content -Raw (Join-Path $env:RFS_TEST_FIXTURES 'repos.json') | ConvertFrom-Json
        ConvertTo-Json -InputObject @($all[0]) -Depth 5 | Set-Content (Join-Path $one 'repos.json')
        $env:RFS_TEST_FIXTURES = $one
        $json = & $script -Format Json
        $json.TrimStart() | Should -BeLike '`[*'
    }

    It 'writes CSV to -OutFile as UTF-8 without a BOM' {
        $out = Join-Path $TestDrive 'repos.csv'
        & $script -Format Csv -OutFile $out
        $bytes = [IO.File]::ReadAllBytes($out)
        $bytes[0] | Should -Not -Be 0xEF
        (Import-Csv $out).Count | Should -Be 4
        [IO.File]::ReadAllText($out) | Should -Match 'caf\u00e9'
    }

    It 'writes a relative -OutFile into the projects folder' {
        & $script -Format Markdown -OutFile repos.md 6>$null
        Test-Path (Join-Path $env:RFS_PROJECTS 'repos.md') | Should -BeTrue
    }

    It 'prints a table by default' {
        $text = & $script
        $text | Should -Match 'alpha-tool'
        $text | Should -Match 'private, archived'
    }

    It 'throws with gh''s own message when the list call fails' {
        $env:RFS_TEST_FAIL = 'list'
        { & $script -Format Object } | Should -Throw '*HTTP 404*'
    }

    It 'throws a plain message when gh is logged out' {
        $env:RFS_TEST_AUTH = 'fail'
        { & $script -Format Object } | Should -Throw '*gh auth login*'
    }
}
