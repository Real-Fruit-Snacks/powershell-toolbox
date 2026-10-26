BeforeDiscovery {
    $scripts = Get-ChildItem -Path (Split-Path $PSScriptRoot -Parent) -Filter '*.ps1' | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $all = Get-ChildItem -Path $RepoRoot -Filter '*.ps1'
    function Get-CommonBlock ([string] $Path) {
        $text = [IO.File]::ReadAllText($Path) -replace '\r\n', "`n"
        $m = [regex]::Match($text, '(?s)#region rfs-common.*?#endregion rfs-common')
        if ($m.Success) { $m.Value } else { $null }
    }
}

Describe 'Every script' {
    It '<Name> parses' -ForEach $scripts {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It '<Name> is ASCII only, so Windows PowerShell 5.1 reads it the same without a BOM' -ForEach $scripts {
        $bytes = [IO.File]::ReadAllBytes($Path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It '<Name> uses an approved verb' -ForEach $scripts {
        $verb = ($Name -replace '\.ps1$', '') -split '-' | Select-Object -First 1
        Get-Verb -Verb $verb | Should -Not -BeNullOrEmpty
    }

    It '<Name> has a synopsis and at least one example' -ForEach $scripts {
        $help = Get-Help $Path -Full
        "$($help.Synopsis)" | Should -Not -BeLike "*$Name*"
        "$($help.description.Text)" | Should -Not -BeNullOrEmpty
        @($help.examples.example).Count | Should -BeGreaterThan 0
    }

    It '<Name> carries the shared rfs-common block' -ForEach $scripts {
        Get-CommonBlock $Path | Should -Not -BeNullOrEmpty
    }

    It 'all carry the same rfs-common block' {
        $blocks = @($all | ForEach-Object { Get-CommonBlock $_.FullName } | Sort-Object -Unique)
        $blocks.Count | Should -Be 1
    }

    It 'pass PSScriptAnalyzer with the repo settings' -Skip:(-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        $found = Invoke-ScriptAnalyzer -Path $RepoRoot -Settings (Join-Path $RepoRoot 'PSScriptAnalyzerSettings.psd1')
        $found | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.RuleName) $($_.Message)" } | Should -BeNullOrEmpty
    }
}

Describe 'Write-Ink' {
    BeforeAll {
        Invoke-Expression (Import-ScriptFunction -Path (Join-Path $RepoRoot 'Get-RepoList.ps1') -Name 'Write-Ink')
    }
    AfterEach { Remove-Item Env:NO_COLOR, Env:RFS_THEME -ErrorAction SilentlyContinue }

    It 'writes plain text when NO_COLOR is set' {
        $env:NO_COLOR = '1'
        $record = Write-Ink 'ok' mint 6>&1
        $record.MessageData.Message | Should -BeExactly 'ok'
        $record.MessageData.Message | Should -Not -Match ([char]27)
        $record.MessageData.ForegroundColor | Should -Not -Be 'Green'
    }

    It 'uses Mint for mint in Nightshift' {
        $record = Write-Ink 'ok' mint 6>&1
        if ($Host.UI.SupportsVirtualTerminal) { $record.MessageData.Message | Should -Match '38;2;61;220;151m' }
        else { $record.MessageData.ForegroundColor | Should -Be 'Green' }
    }

    It 'switches to Dayshift values with RFS_THEME=dayshift' {
        $env:RFS_THEME = 'Dayshift'
        $record = Write-Ink 'ok' mint 6>&1
        if ($Host.UI.SupportsVirtualTerminal) { $record.MessageData.Message | Should -Match '38;2;22;122;78m' }
        else { $record.MessageData.ForegroundColor | Should -Be 'DarkGreen' }
    }

    It 'rejects inks outside the palette' {
        { Write-Ink 'x' red } | Should -Throw
    }
}

Describe 'Projects folder' {
    BeforeAll {
        $listScript = Join-Path $RepoRoot 'Get-RepoList.ps1'
        Invoke-Expression (Import-ScriptFunction -Path $listScript -Name 'Get-ProjectsDir')
        Invoke-Expression (Import-ScriptFunction -Path $listScript -Name 'Resolve-OutputPath')
    }
    AfterEach { Remove-Item Env:RFS_PROJECTS -ErrorAction SilentlyContinue }

    It 'defaults to Projects in the user profile' {
        Remove-Item Env:RFS_PROJECTS -ErrorAction SilentlyContinue
        Get-ProjectsDir | Should -Be (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Projects')
    }

    It 'follows RFS_PROJECTS when set' {
        $env:RFS_PROJECTS = Join-Path $TestDrive 'elsewhere'
        Get-ProjectsDir | Should -Be (Join-Path $TestDrive 'elsewhere')
    }

    It 'puts a relative output path in the projects folder and creates it' {
        $env:RFS_PROJECTS = Join-Path $TestDrive 'new-projects'
        $path = Resolve-OutputPath 'sub/out.md'
        $path | Should -Be ([IO.Path]::GetFullPath((Join-Path $TestDrive 'new-projects/sub/out.md')))
        Test-Path (Join-Path $TestDrive 'new-projects/sub') | Should -BeTrue
    }

    It 'leaves an absolute output path alone' {
        $env:RFS_PROJECTS = Join-Path $TestDrive 'unused'
        $abs = Join-Path $TestDrive 'abs/out.md'
        Resolve-OutputPath $abs | Should -Be $abs
        Test-Path (Join-Path $TestDrive 'unused') | Should -BeFalse
    }
}

Describe 'Invoke-Gh' {
    BeforeAll {
        Invoke-Expression (Import-ScriptFunction -Path (Join-Path $RepoRoot 'Get-RepoList.ps1') -Name 'Invoke-Gh')
        $log = Join-Path $TestDrive 'gh.log'
        Enter-StubGh -LogPath $log
    }
    AfterAll { Exit-StubGh }

    It 'returns stdout and exit code 0' {
        $r = Invoke-Gh @('auth', 'status')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'Token scopes'
    }

    It 'keeps stderr apart and does not throw under ErrorActionPreference Stop' {
        $ErrorActionPreference = 'Stop'
        $env:RFS_TEST_FAIL = 'list'
        $r = Invoke-Gh @('repo', 'list')
        $r.ExitCode | Should -Be 1
        $r.Err | Should -Match '404'
        $r.Out | Should -BeNullOrEmpty
        $ErrorActionPreference | Should -Be 'Stop'
    }
}
