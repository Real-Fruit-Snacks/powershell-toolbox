BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script = Join-Path $RepoRoot 'Get-RepoDigest.ps1'
}

Describe 'Get-RepoDigest' {
    BeforeEach {
        $log = Join-Path $TestDrive "gh-$([guid]::NewGuid()).log"
        $out = Join-Path $TestDrive "digest-$([guid]::NewGuid()).md"
        Enter-StubGh -LogPath $log
    }
    AfterEach { Exit-StubGh }

    It 'warns and writes nothing without -GitHub or -LocalRoot' {
        & $script -OutFile $out 3>&1 | Should -Match 'Nothing to do. Pass -GitHub, -Local'
        Test-Path $out | Should -BeFalse
    }

    Context '-GitHub' {
        BeforeEach {
            & $script -GitHub -OutFile $out 6>$null
            $digest = [IO.File]::ReadAllText($out)
        }

        It 'skips archived repos and forks by default' {
            $digest | Should -Match '## GitHub repos \(2\)'
            $digest | Should -Not -Match 'old-archive'
            $digest | Should -Not -Match 'forked-lib'
        }

        It 'records topics and the top-level listing' {
            $digest | Should -Match '- Topics: powershell, automation'
            $digest | Should -Match '- Top level: src/, README.md'
        }

        It 'keeps README text as UTF-8' {
            $digest | Should -Match 'Caf\u00e9 \u2014 with a fence inside'
        }

        It 'fences each README with more backticks than it contains' {
            $digest | Should -Match '(?m)^````` markdown$'
        }

        It 'writes push dates as dates on both PowerShell versions' {
            $digest | Should -Match '\| test-owner/alpha-tool \| PowerShell \| False \| 2026-10-01 \|'
            $digest | Should -Match '- Last push: 2026-10-01 12:00 UTC'
        }

        It 'uses LF line endings only, on every OS' {
            $digest | Should -Not -Match "`r"
        }

        It 'notes a missing README instead of failing' {
            $digest | Should -Match '(?s)### test-owner/no-readme.*_No README found._'
        }
    }

    It 'writes repos-digest.md in the projects folder by default' {
        & $script -GitHub 6>$null
        Test-Path (Join-Path $env:RFS_PROJECTS 'repos-digest.md') | Should -BeTrue
    }

    It 'scans the projects folder with -Local' {
        New-Item -ItemType Directory -Path (Join-Path $env:RFS_PROJECTS 'some-project') -Force | Out-Null
        Set-Content -Path (Join-Path $env:RFS_PROJECTS 'some-project/README.md') -Value '# some project'
        & $script -Local 6>$null
        $digest = [IO.File]::ReadAllText((Join-Path $env:RFS_PROJECTS 'repos-digest.md'))
        $digest | Should -Match '## Local repos \(1\)'
        $digest | Should -Match '### some-project'
        $digest | Should -Match '# some project'
    }

    It 'includes archived repos and forks when asked' {
        & $script -GitHub -IncludeArchived -IncludeForks -OutFile $out 6>$null
        [IO.File]::ReadAllText($out) | Should -Match '## GitHub repos \(4\)'
    }

    It 'passes -Owner through to gh' {
        & $script -GitHub -Owner some-org -OutFile $out 6>$null
        Get-GhCalls $log | Where-Object { $_ -like 'repo list*' } | Should -BeLike 'repo list some-org *'
    }

    It 'cuts READMEs at -MaxReadmeChars' {
        & $script -GitHub -MaxReadmeChars 20 -OutFile $out 6>$null
        [IO.File]::ReadAllText($out) | Should -Match 'truncated at 20 chars'
    }

    Context '-LocalRoot' {
        BeforeAll {
            $root = Join-Path $TestDrive 'src'
            $plain = Join-Path $root 'plain-folder'
            New-Item -ItemType Directory -Path (Join-Path $plain 'node_modules/dep') -Force | Out-Null
            # CRLF on purpose, on every OS: the digest must still come out LF-only.
            [IO.File]::WriteAllText((Join-Path $plain 'README.md'), "# plain folder`r`n`r`nSecond line`r`n")
            Set-Content -Path (Join-Path $plain 'main.py') -Value 'print(1)'
            Set-Content -Path (Join-Path $plain 'package.json') -Value '{}'
            1..5 | ForEach-Object { Set-Content -Path (Join-Path $plain "node_modules/dep/f$_.js") -Value 'x' }

            $repo = Join-Path $root 'git-no-remote'
            New-Item -ItemType Directory -Path $repo | Out-Null
            $hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
            if ($hasGit) { git init -q $repo 2>$null }
        }

        It 'treats every top-level folder as a project' {
            & $script -LocalRoot $root -OutFile $out 6>$null
            $digest = [IO.File]::ReadAllText($out)
            $digest | Should -Match '## Local repos \(2\)'
            $digest | Should -Match '### plain-folder'
            $digest | Should -Match '- Manifests: package.json'
            $digest | Should -Match "# plain folder`n`nSecond line"
            $digest | Should -Not -Match "`r"
        }

        It 'leaves node_modules out of the file-type count' {
            & $script -LocalRoot $root -OutFile $out 6>$null
            [IO.File]::ReadAllText($out) | Should -Not -Match '\.js='
        }

        It 'handles a git repo with no remote and no commits' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
            & $script -LocalRoot $root -OutFile $out 6>$null
            [IO.File]::ReadAllText($out) | Should -Match '(?s)### git-no-remote.*Uncommitted changes: 0'
        }

        It 'warns about a missing root and carries on' {
            & $script -LocalRoot (Join-Path $TestDrive 'nope'), $root -OutFile $out 3>&1 6>$null | Should -Match 'Not found'
            [IO.File]::ReadAllText($out) | Should -Match '### plain-folder'
        }
    }
}
