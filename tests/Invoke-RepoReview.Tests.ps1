BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script = Join-Path $RepoRoot 'Invoke-RepoReview.ps1'

    # Answers fed to Read-Host, in order. Running out fails the test instead of hanging.
    function Set-Answers ([string[]] $Answers) {
        $global:RfsTestAnswers = [System.Collections.Generic.Queue[string]]::new()
        foreach ($a in $Answers) { $global:RfsTestAnswers.Enqueue($a) }
    }
    function Invoke-Review {
        param([hashtable] $Params = @{})
        $output = & $script -LogPath $reviewLog @Params 6>&1 3>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{
            Text  = $output -join "`n"
            Log   = @(if (Test-Path $reviewLog) { Get-Content $reviewLog })
            Calls = @(Get-GhCalls $ghLog)
        }
    }
}

Describe 'Invoke-RepoReview' {
    BeforeEach {
        $ghLog = Join-Path $TestDrive "gh-$([guid]::NewGuid()).log"
        $reviewLog = Join-Path $TestDrive "review-$([guid]::NewGuid()).log"
        Enter-StubGh -LogPath $ghLog
        Mock Read-Host {
            if ($global:RfsTestAnswers.Count -eq 0) { throw 'Read-Host called more often than the test expected' }
            $global:RfsTestAnswers.Dequeue()
        }
        Mock Start-Process { }
    }
    AfterEach { Exit-StubGh; Remove-Variable RfsTestAnswers -Scope Global -ErrorAction SilentlyContinue }

    It 'skips forks and archived repos, oldest push first, and logs keeps' {
        Set-Answers 'k', 'K'
        $r = Invoke-Review
        $r.Text | Should -Match 'Reviewing 2 repos, sorted by pushed'
        $r.Log[0] | Should -Match 'KEPT\s+test-owner/no-readme'
        $r.Log[1] | Should -Match 'KEPT\s+test-owner/alpha-tool'
        $r.Text | Should -Match 'Done. Deleted: 0  Archived: 0  Kept: 2  Failed: 0'
        $r.Text | Should -Match 'last push never'
    }

    It 'deletes only after the exact, case-sensitive name' {
        Set-Answers 'd', 'No-Readme', 'd', 'no-readme', 'k'
        $r = Invoke-Review
        $r.Text | Should -Match "Name didn't match. Not deleted."
        @($r.Calls | Where-Object { $_ -like 'repo delete*' }) | Should -Be @('repo delete test-owner/no-readme --yes')
        $r.Log[0] | Should -Match 'DELETED\s+test-owner/no-readme'
    }

    It 'archives' {
        Set-Answers 'k', 'a'
        $r = Invoke-Review
        $r.Calls | Should -Contain 'repo archive test-owner/alpha-tool --yes'
        $r.Log[1] | Should -Match 'ARCHIVED\s+test-owner/alpha-tool'
    }

    It 'quits without closing the PowerShell session' {
        Set-Answers 'q'
        $r = Invoke-Review
        $r.Text | Should -Match 'Stopped. Deleted: 0  Archived: 0  Kept: 0  Failed: 0  Remaining: 2'
        $r.Log[0] | Should -Match 'QUIT\s+test-owner/no-readme\s+stopped at 1/2'
    }

    It 'changes nothing under -WhatIf' {
        Set-Answers 'd', 'no-readme', 'a'
        $r = Invoke-Review -Params @{ WhatIf = $true }
        $r.Text | Should -Match 'Dry run: nothing will change.'
        $r.Calls | Where-Object { $_ -match '^repo (delete|archive)' } | Should -BeNullOrEmpty
        $r.Log | Should -Match 'WHATIF'
    }

    It 'counts and logs a failed delete' {
        $env:RFS_TEST_FAIL = 'delete'
        Set-Answers 'd', 'no-readme', 'k'
        $r = Invoke-Review
        $r.Text | Should -Match 'Delete failed'
        $r.Log[0] | Should -Match 'FAILED\s+test-owner/no-readme\s+gh repo delete returned non-zero'
        $r.Text | Should -Match 'Failed: 1'
    }

    It 'offers to add the delete_repo scope when the token lacks it' {
        $env:RFS_TEST_SCOPES = "'repo', 'gist'"
        Set-Answers 'n', 'q'
        $r = Invoke-Review
        $r.Text | Should -Match 'does not have the delete_repo scope'
        $r.Text | Should -Match 'Continuing. Deletes may be rejected.'
        $r.Calls | Should -Not -Contain 'auth refresh -h github.com -s delete_repo'
    }

    It 'opens the repo in the browser, then asks again' {
        Set-Answers 'o', 'x', 'k', 'k'
        $r = Invoke-Review
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $FilePath -eq 'https://github.com/test-owner/no-readme' }
        $r.Text | Should -Match 'Enter D, A, K, O or Q.'
    }

    It 'sorts by size, largest first' {
        Set-Answers 'q'
        $r = Invoke-Review -Params @{ SortBy = 'size'; IncludeForks = $true; IncludeArchived = $true }
        $r.Text | Should -Match '\[1/4\]\s+test-owner/forked-lib'
        $r.Text | Should -Match '4\.8 GB'
    }

    It 'writes its log to the projects folder by default, even under -WhatIf' {
        Set-Answers 'k', 'k'
        & $script -WhatIf 6>$null 3>$null | Out-Null
        $logs = @(Get-ChildItem -Path $env:RFS_PROJECTS -Filter 'repo-review-*.log')
        $logs.Count | Should -Be 1
        Get-Content $logs[0].FullName | Should -Match 'KEPT'
    }

    It 'says so and stops when nothing matches' {
        $empty = Join-Path $TestDrive 'empty'
        New-Item -ItemType Directory $empty -Force | Out-Null
        Set-Content (Join-Path $empty 'repos.json') '[]'
        $env:RFS_TEST_FIXTURES = $empty
        $r = Invoke-Review
        $r.Text | Should -Match 'No repos matched.'
    }
}
