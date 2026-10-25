# powershell-toolbox

Grab-bag of PowerShell scripts for automating my own workflow.

## Scripts

- **Get-RepoDigest.ps1** - build a single Markdown digest of GitHub and/or local repos (metadata, file tree, README) for uploading to Claude.
- **Review-GitHubRepos.ps1** - walk through GitHub repos one at a time and delete, archive or keep each.

## Usage

Run any script from its folder:

```powershell
.\Review-GitHubRepos.ps1
```

If PowerShell blocks it with an execution-policy error:

```powershell
powershell -ExecutionPolicy Bypass -File .\Review-GitHubRepos.ps1
```

Every script has comment-based help:

```powershell
Get-Help .\Get-RepoDigest.ps1 -Full
```

### Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- [GitHub CLI](https://cli.github.com/) (`gh`), logged in (`gh auth login`), for anything that touches GitHub
- `Review-GitHubRepos.ps1` needs the `delete_repo` scope to delete: `gh auth refresh -h github.com -s delete_repo`

## Adding a script

1. Name it `Verb-Noun.ps1` and give it a comment-based help block (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`).
2. Drop it in the repo root.
3. Add a one-line entry under **Scripts** (alphabetical): `- **Name.ps1** - what it does.`
4. `git add . ; git commit -m "Add Name" ; git push`
