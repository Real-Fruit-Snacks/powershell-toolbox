# Design: the powershell-toolbox page (docs/) and README index

## Concept

Every PowerShell command is Verb-Noun, with the verb from a fixed list (`Get-Verb`), and the repo's tests fail a script whose verb isn't on it. So the page hangs each script's name on its hyphen: the verbs right-aligned to the left of one vertical axis, the nouns to the right. Read down the left and you see what kind of thing the scripts do (Get, Get, Invoke); read down the right and you see what they act on (all three, for now, a Repo). The same axis runs the length of the page: section labels sit right-aligned against it and their content starts on it, the way `Get-Help` hangs SYNTAX and PARAMETERS in its margin. A visitor should leave knowing which script does what, that each one runs on its own, and that the one that deletes things asks twice.

## Audience and primary action

People who have a lot of GitHub repos and want to see, digest or prune them, plus anyone browsing the RFS tools. They need to find the right script in five seconds, see it run, trust the delete path, then copy a line: the whole set, or just the one script.

## Type

- Display and text: Chivo, one variable file (weights 400 to 800 in use). It's a sturdy grotesque with a heavy 800 that holds up as a label at 55px and as one word at 16px, and it's wide enough that the three names make a real block of type.
- Mono: Chivo Mono, the same family's monospace, for every command, transcript, syntax line and the Get-Help margin labels. Same skeleton as the display, so the names and the console read as one voice.
- Scale: `scale.mjs`, 16px to 18px, ratio 1.2 to 1.333. Script names have their own size, `--name`: `clamp(2rem, 0.95rem + 3.85vw, 4.1rem)` below 1180px, `clamp(2.6rem, 4.6vw - 0.7rem, 3.45rem)` beside the console, because the console needs about 77 columns.
- Self-hosted in `fonts/` (Google Fonts latin subsets), with their OFL licences.

## Color

The RFS Nightshift and Dayshift values and nothing else, used the way the scripts' own `Write-Ink` uses them (CONTRIBUTING: "Ember marks one thing per screen. Mint only ever means success."). The OS setting decides the theme; the Nightshift/Dayshift switch overrides it and saves `rfs-theme`.

| Role | Nightshift | Dayshift | Use |
|---|---|---|---|
| bg / surface / raised | `#0C0D10` / `#13151A` / `#1A1D24` | `#F6F5F2` / `#FFFFFF` / `#ECEAE4` | Page; keys and copy buttons; the picked row |
| code | `#070809` | `#FFFFFF` | The console and command boxes |
| line / line-strong | `#262A33` / `#636872` | `#D6D3CB` / `#89867F` | Rules; the hyphens of names not picked; Format-Table dashes |
| ink / mute | `#E8E6E1` / `#8A8F99` | `#1A1B1E` / `#666A73` | Text; names not picked |
| Ember | `#FF6A3D` | `#C03B0A` | The hyphen of the picked script, focus rings, copy on hover. In the console, the `[n/16]` counter, as the script prints it |
| Amber | `#FFC247` | `#925F00` | The review's prompt and its keys: something waiting for you |
| Mint | `#3DDC97` | `#15794D` | Success only: `Wrote ... repos-digest.md` |
| Raspberry | `#F06292` | `#B0306A` | The word "delete" on the D key |

Colour never carries a state alone: the picked row is also raised and in full ink, the keys say what they do, and every console line is the script's own words. The scripts' Dayshift palette was brought up to these values in the same change, so the console on the page and a real light terminal match.

## Layout

A 1240px wrap. From 1180px the hero is two columns: the headline and the index on the left, the console on the right, stretched to the same height. Below that it stacks: headline, index, console. Every section after the hero is a two-column hang on the axis (`--verb-w`, the width of "Invoke" at `--name`): the label right-aligned on the left, the content on the right. The script reference repeats each name at full size, hung on the same axis, with `Get-Help`'s own headings in its margin. Tables take Format-Table's shape: mono headers underlined with as many dashes as they have letters.

## Signature

The hyphen. Names hung on it, the picked one in Ember, and the axis it makes carried through every section. The favicon is the index in miniature: three bars of different lengths split by one Ember column.

## Wow moment

On load the names assemble at their hyphens (verbs in from the left, nouns from the right, the hyphens drawn last), and the console beside them replays a real `Invoke-RepoReview.ps1 -SortBy size -WhatIf` run: it types the command, prints the first repo, presses K, prints the second, presses A and prints PowerShell's own `What if: Performing the operation "Archive repository"...`, then stops at the third repo with a caret, waiting. The keys under it are live: D asks for the repo name and checks it case-sensitively, A prints the What if line, K keeps, O opens the repo, Q prints the summary with the right counts, and K through all 16 ends with `Done.`. Every line comes from a recording; the replay only chooses which recorded line comes next, following the script's own logic. Picking another name plays that script's run: the repo table, or the digest counting to `Wrote ... (94 KB)` and the top of the file it wrote.

- **No JS:** the index and all three transcripts, as text, stacked; the review transcript is the K, A, Q run.
- **Reduced motion:** no entrance, no typing, no caret blink. The console prints the same state at once and the keys still work.
- **Phone:** headline, index, then the console full width. Long lines wrap, as they would in a 45-column window; the table scrolls sideways.

## README index

`art/make-art.py` draws the same index as `assets/index-{dark,light}.svg`: the three names on their hyphens with each `.SYNOPSIS` beside them, and a console under them that replays the list, the digest and the review in a 21 s loop, the picked name following along. Text is converted to paths from `fonts/` (an `<img>` can't load fonts). The SVG's base styles are its last frame, the review waiting at its prompt, which is what reduced motion shows. CI regenerates it, with `runs.js` and the transcripts spliced into `index.html` and `README.md`, and fails if anything differs. `card.html` renders the 1280 x 640 social card (`assets/social.png`). Don't wrap the README's `<picture>` in a link: GitHub then shows the light image in dark mode.

## The recordings

`art/Record-Runs.ps1` runs the scripts for real against the account gh is logged in as and saves the console output with its ANSI colours to `art/runs/`. While it records, `gh repo list` sees public repos only, `gh repo archive` and `gh repo delete` throw before reaching GitHub, Read-Host answers come from a list, and output files go to a temp folder. Paths read `C:\Users\you\Projects`, in place of the account name and that temp folder; the captions say so. The digest took 17.5 s for 16 repos when timed; the page plays it faster and says so.

## Motion

Hover and selection: 150 to 180ms colour changes. Entrance: 720ms with a 90ms stagger, under 1.2 s in all. Typing: 28ms a character. Nothing loops on the page except the caret, once a second.

## Voice

Plain, first person, exact, as in the README. Every script description is its `.SYNOPSIS`; every parameter description is its `.PARAMETER` text. `tests/Docs.Tests.ps1` fails if the README or the page names a parameter or a value a script doesn't take, or if the page's synopses or parameter tables drift from the scripts.

## Files

- `index.html`, `styles.css`, `script.js`, `runs.js` (generated), `fonts/`, the icons and manifest (built by killer-design's `icons.mjs` from `art/mark.svg`), `card.html`.
- `assets/cover-*`, `assets/social-*.png` and `assets/cover.toml` are the older RFS brand cover from rfs-brand's `make-cover.py`. The page and README no longer use them; they stay because other RFS pages may load them.

## Alternatives considered

- A shadow board: each script a tool on a pegboard with its painted outline, taken off when you pick it. Concrete, but it means drawing objects by hand and a dot grid that reads as a default.
- The page as one long `Get-Help -Full`: NAME, SYNOPSIS, SYNTAX as the whole layout, in mono. Honest and very PowerShell, but quiet; it hides the three names that are the point. Its margin headings live on in the reference.
