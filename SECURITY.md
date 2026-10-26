# Security

These scripts run `gh` with your own login and can delete repos (`Invoke-RepoReview.ps1`). They send nothing anywhere except GitHub, through `gh`.

## Supported versions

Only the latest release gets fixes.

## Reporting

Use [private vulnerability reporting](https://github.com/Real-Fruit-Snacks/powershell-toolbox/security/advisories/new). Don't open a public issue. I'll answer within a week.

Worth reporting: anything that could delete or archive a repo without the typed confirmation, act on a repo other than the one shown, or write a token or credential into a log or digest file.
