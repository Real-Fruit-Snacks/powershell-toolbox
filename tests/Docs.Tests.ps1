BeforeDiscovery {
    $root = Split-Path $PSScriptRoot -Parent
    $scripts = Get-ChildItem -Path $root -Filter '*.ps1' | ForEach-Object { @{ Name = $_.BaseName; Path = $_.FullName } }
    $docs = @('README.md', 'docs/index.html') | ForEach-Object { @{ Doc = $_; Path = Join-Path $root $_ } }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $page = [IO.File]::ReadAllText((Join-Path $RepoRoot 'docs/index.html'))
    $readme = [IO.File]::ReadAllText((Join-Path $RepoRoot 'README.md'))
    $notListed = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters | Where-Object { $_ -ne 'WhatIf' })
}

Describe 'The README and the project page' {
    It '<Doc> only uses parameters and values the scripts accept' -ForEach $docs {
        $text = [System.Net.WebUtility]::HtmlDecode([IO.File]::ReadAllText($Path))
        # Every .\Verb-Noun.ps1 call, up to the end of the line, a pipe, a comment or markup.
        $calls = [regex]::Matches($text, '\.\\(?<name>[A-Z][a-z]+-[A-Za-z]+)\.ps1(?<rest>[^\r\n|;<`#]*)')
        $calls.Count | Should -BeGreaterThan 0
        $bad = foreach ($c in $calls) {
            $file = Join-Path $RepoRoot ($c.Groups['name'].Value + '.ps1')
            if (-not (Test-Path -LiteralPath $file)) { "$($c.Value): no such script"; continue }
            $cmd = Get-Command $file
            foreach ($m in [regex]::Matches($c.Groups['rest'].Value, '(?:^|\s)-(?<p>[A-Za-z]+)(?:\s+(?<v>[^\s-]\S*))?')) {
                $p = $m.Groups['p'].Value
                if (-not $cmd.Parameters.ContainsKey($p)) { "$($c.Value): no -$p"; continue }
                $set = $cmd.Parameters[$p].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
                if ($set -and $m.Groups['v'].Success -and ($set.ValidValues -notcontains $m.Groups['v'].Value)) {
                    "$($c.Value): -$p $($m.Groups['v'].Value) is not one of $($set.ValidValues -join ', ')"
                }
            }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'the page index shows the .SYNOPSIS of <Name>' -ForEach $scripts {
        $m = [regex]::Match($page, "<!-- run:syn-$Name -->(.*?)<!-- /run:syn-$Name -->")
        $m.Success | Should -BeTrue -Because "docs/index.html needs a row for $Name (and docs/art/make-art.py lists it in SCRIPTS)"
        [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) | Should -BeExactly ((Get-Help $Path).Synopsis.Trim())
    }

    It 'the README index lists <Name>' -ForEach $scripts {
        $readme | Should -Match ([regex]::Escape("| [``$Name.ps1``]($Name.ps1) | $((Get-Help $Path).Synopsis.Trim()) |"))
    }

    It 'the page reference for <Name> lists exactly its parameters' -ForEach $scripts {
        $m = [regex]::Match($page, "(?s)<article[^>]*id=""ref-$Name"".*?</article>")
        $m.Success | Should -BeTrue
        $listed = @([regex]::Matches($m.Value, 'data-param="(\w+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object) -join ', '
        $actual = @((Get-Command $Path).Parameters.Keys | Where-Object { $_ -notin $notListed } | Sort-Object) -join ', '
        $listed | Should -Be $actual
    }
}
