# The versions the checks pin, in one place. .github/workflows/ci.yml, offline.yml and
# tools/build-dev-kit.ps1 all read this file, so the dev kit carries exactly what CI tests with.
# The Python packages for the art are pinned in docs/art/requirements.txt.
@{
    # PowerShell modules for the lint and the tests.
    Modules = @(
        @{ Name = 'Pester'; Version = '5.7.1' }
        @{ Name = 'PSScriptAnalyzer'; Version = '1.25.0' }
    )

    # Python for the art check (docs/art/make-art.py): what setup-python is asked for, and the
    # CPython the dev kit's wheels are built for.
    Python = '3.14'

    # The gh the real runs on the project page were recorded with. CI doesn't use gh (the tests
    # run against tests/stub/gh.ps1); the dev kit's README names this one.
    Gh = '2.102.0'
}
