"""Build everything that shows a recorded run, from docs/art/runs/*.txt and the scripts' own help.

    docs/assets/index-dark.svg, index-light.svg   the README's animated index (text drawn as paths)
    docs/runs.js                                  the data the page replays
    docs/index.html, README.md                    the transcripts between <!-- run:NAME --> markers

The runs are real console output with its ANSI colours, recorded by docs/art/Record-Runs.ps1.
Each script's one-line description is its .SYNOPSIS, read from the script itself. The output
is deterministic, so CI regenerates it and fails if anything committed differs. From the repo root:

    python -m pip install -r docs/art/requirements.txt
    python docs/art/make-art.py
"""
import html
import json
import os
import re
import sys

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
DOCS = os.path.join(ROOT, "docs")
RUNS = os.path.join(HERE, "runs")

# The five inks Write-Ink prints, by the RGB it prints them in (Nightshift, then Dayshift).
INKS = {
    (232, 230, 225): "text", (138, 143, 153): "mute", (255, 106, 61): "ember", (255, 194, 71): "amber", (61, 220, 151): "mint",
    (26, 27, 30): "text", (102, 106, 115): "mute", (192, 59, 10): "ember", (146, 95, 0): "amber", (21, 121, 77): "mint",
}
ANSI = re.compile(r"\x1b\[38;2;(\d+);(\d+);(\d+)m(.*?)\x1b\[0m")

# The scripts in the order the README and the page list them: see them, read them, decide.
SCRIPTS = ["Get-RepoList", "Get-RepoDigest", "Invoke-RepoReview"]
# A first line to try with each, for the README's index.
TRY = {
    "Get-RepoList": (r".\Get-RepoList.ps1 -Owner Real-Fruit-Snacks -Format Markdown -OutFile repos.md", r"-> Projects\repos.md"),
    "Get-RepoDigest": (r".\Get-RepoDigest.ps1 -GitHub -Local", r"-> Projects\repos-digest.md"),
    "Invoke-RepoReview": (r".\Invoke-RepoReview.ps1 -SortBy size -WhatIf", r"log -> Projects\repo-review-<time>.log"),
}


# ---------------------------------------------------------------- reading
def segments(raw):
    """One console line -> [(ink, text)], with trailing spaces dropped."""
    out, pos = [], 0
    for m in ANSI.finditer(raw):
        if m.start() > pos:
            out.append(("text", raw[pos:m.start()]))
        rgb = tuple(int(g) for g in m.groups()[:3])
        if rgb not in INKS:
            sys.exit(f"unknown ink {rgb} in {raw!r}")
        out.append((INKS[rgb], m.group(4)))
        pos = m.end()
    if pos < len(raw):
        out.append(("text", raw[pos:]))
    while out and not out[-1][1].rstrip():
        out.pop()
    if out:
        out[-1] = (out[-1][0], out[-1][1].rstrip())
    return [(k, t) for k, t in out if t]


def plain(line):
    return "".join(t for _, t in line)


def read_run(name):
    """-> (recorded, [(command, [line, ...]), ...]) with blank lines trimmed at each end."""
    with open(os.path.join(RUNS, name + ".txt"), encoding="utf-8") as fh:
        rows = fh.read().split("\n")
    recorded = rows[0].removeprefix("<<recorded>>")
    cmds = []
    for raw in rows[1:]:
        if raw.startswith("<<cmd>>"):
            cmds.append((raw.removeprefix("<<cmd>>"), []))
        elif cmds:
            cmds[-1][1].append(segments(raw))
    trimmed = []
    for cmd, lines in cmds:
        while lines and not lines[0]:
            lines.pop(0)
        while lines and not lines[-1]:
            lines.pop()
        trimmed.append((cmd, lines))
    return recorded, trimmed


def synopsis(script):
    with open(os.path.join(ROOT, script + ".ps1"), encoding="ascii") as fh:
        text = fh.read()
    m = re.search(r"^\.SYNOPSIS\s*\n(.+?)\n\s*\n", text, re.S | re.M)
    return " ".join(m.group(1).split())


# ---------------------------------------------------------------- the review run, taken apart
def review_parts():
    rec, [(cmd, lines)] = read_run("review-all")
    _, [(_, short)] = read_run("review")
    _, [(_, branch)] = read_run("review-branches")
    texts = [plain(l) for l in lines]
    rule = next(i for i, t in enumerate(texts) if t.startswith("-" * 20))
    head = lines[:rule]
    prompt_i = [i for i, t in enumerate(texts) if "[K] keep" in t]
    blocks, start = [], rule
    for p in prompt_i:
        block = lines[start:p]
        title = plain(block[1])
        m = re.match(r"\[(\d+)/(\d+)\] (\S+)", title)
        url = plain(block[-2] if not block[-1] else block[-1]).strip()
        url = next(plain(l).strip() for l in block if plain(l).strip().startswith("https://"))
        blocks.append({"repo": m.group(3), "url": url, "lines": block})
        start = p + 2  # past the prompt and the blank line Write-Ink '' prints after a decision
    prompt = [(k, t) for k, t in lines[prompt_i[0]] if k == "amber"]
    # the amber prompt keeps its two trailing spaces: what you type follows them
    done = lines[prompt_i[-1] + 3:]
    find = lambda src, s: next(l for l in src if s in plain(l))
    first = blocks[0]["repo"]
    name = first.split("/")[1]
    whatif_a = plain(find(short, "What if:")).replace(blocks[1]["repo"], "{repo}")
    whatif_d = plain(find(branch, "What if:")).replace(first, "{repo}")
    confirm = [(k, t.replace(f"'{name}'", "'{name}'")) for k, t in find(branch, "to confirm deletion") if k == "amber"]
    stopped = plain(find(short, "Stopped."))
    stopped = re.sub(r"Kept: \d+", "Kept: {kept}", stopped)
    stopped = re.sub(r"Remaining: \d+", "Remaining: {remaining}", stopped)
    done_line = re.sub(r"Kept: \d+", "Kept: {kept}", plain(done[0]))
    return {
        "recorded": rec, "cmd": cmd, "head": head, "blocks": blocks, "prompt": prompt,
        "confirm": confirm[0][1], "mismatch": plain(find(branch, "didn't match")),
        "invalid": plain(find(branch, "Enter D, A")), "whatifArchive": whatif_a, "whatifDelete": whatif_d,
        "stopped": stopped, "done": done_line, "log": plain(done[1]), "rule": plain(lines[rule]),
        "short": short,
    }


# ---------------------------------------------------------------- page data and transcripts
def html_line(line):
    out = []
    for ink, t in line:
        t = html.escape(t, quote=False)
        out.append(t if ink == "text" else f'<span class="i-{ink}">{t}</span>')
    return "".join(out)


def transcript(cmds):
    rows = []
    for cmd, lines in cmds:
        rows.append(f'<span class="ps">PS&gt;</span> <span class="typed">{html.escape(cmd, quote=False)}</span>')
        rows += [html_line(l) for l in lines]
        rows.append("")
    return "\n".join(rows).rstrip("\n")


def text_transcript(cmds):
    rows = []
    for cmd, lines in cmds:
        rows.append(f"PS> {cmd}")
        rows += [plain(l) for l in lines]
        rows.append("")
    return "\n".join(rows).rstrip("\n")


def splice(path, name, body):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    pat = re.compile(rf"(<!-- run:{name} -->)(.*?)(<!-- /run:{name} -->)", re.S)
    if not pat.search(text):
        sys.exit(f"no <!-- run:{name} --> markers in {path}")
    text = pat.sub(lambda m: m.group(1) + body + m.group(3), text)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


# ---------------------------------------------------------------- text as paths
_fonts, _glyphs = {}, {}
CHIVO, MONO = "chivo-latin-wght.woff2", "chivo-mono-latin-wght.woff2"


def glyphset(fname, wght):
    key = (fname, wght)
    if key not in _fonts:
        f = _fonts.setdefault(fname, None) or TTFont(os.path.join(DOCS, "fonts", fname))
        _fonts[fname] = f
        _fonts[key] = (f.getGlyphSet(location={"wght": wght}), f.getBestCmap(), f["head"].unitsPerEm)
    return _fonts[key]


def advance(s, size, fname, wght, ls=0.0):
    gs, cmap, upm = glyphset(fname, wght)
    return sum(gs[cmap[ord(c)]].width for c in s) * size / upm + ls * size * max(0, len(s) - 1)


def text(s, x, y, size, fname, wght, fill=None, ls=0.0, cls=None, maxw=None):
    """<g> of glyph <use>s for s, baseline at y. maxw drops glyphs past x + maxw (a clipped window)."""
    gs, cmap, upm = glyphset(fname, wght)
    k = size / upm
    pen, uses = 0.0, []
    for ch in s:
        if ord(ch) not in cmap:
            sys.exit(f"{fname} has no glyph for {ch!r}")
        n = cmap[ord(ch)]
        if maxw is not None and pen * k > maxw:
            break
        key = (fname, wght, n)
        if key not in _glyphs:
            p = SVGPathPen(gs, ntos=lambda v: "%g" % round(v))
            gs[n].draw(p)
            _glyphs[key] = (ident(len(_glyphs)), p.getCommands())
        gid, d = _glyphs[key]
        if d:
            uses.append(f'<use href="#{gid}" x="{round(pen)}"/>')
        pen += gs[n].width + ls * upm
    attrs = f' transform="matrix({k:.4f} 0 0 {-k:.4f} {x:.1f} {y:.1f})"'
    if fill:
        attrs += f' fill="{fill}"'
    if cls:
        attrs += f' class="{cls}"'
    return f'<g{attrs}>{"".join(uses)}</g>'


def ident(i):
    chars = "abcdefghijklmnopqrstuvwxyz"
    out = ""
    while True:
        out = chars[i % 26] + out
        i = i // 26 - 1
        if i < 0:
            return "q" + out


def wrap(s, size, fname, wght, width):
    words, lines, cur = s.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if cur and advance(t, size, fname, wght) > width:
            lines.append(cur)
            cur = w
        else:
            cur = t
    return lines + [cur]


# ---------------------------------------------------------------- the README index, animated
THEMES = {
    "dark": dict(plate="#13151A", line="#262A33", strong="#636872", ink="#E8E6E1", mute="#8A8F99", code="#070809",
                 text="#E8E6E1", ember="#FF6A3D", amber="#FFC247", mint="#3DDC97", sel="#1A1D24"),
    "light": dict(plate="#FFFFFF", line="#D6D3CB", strong="#89867F", ink="#1A1B1E", mute="#666A73", code="#F6F5F2",
                  text="#1A1B1E", ember="#C03B0A", amber="#925F00", mint="#15794D", sel="#ECEAE4"),
}
W, H = 1000, 584
CYCLE = 21.0
PAD = 44
NAME_SIZE, NAME_W = 52, 800
CON_X, CON_Y, CON_W, CON_H = PAD, 292, W - 2 * PAD, H - 292 - PAD
MONO_SIZE, LH = 15, 21
CAP = 11            # console lines visible at once
TYPE_CPS = 22       # characters per second when a command is typed


def pct(t):
    return f"{t / CYCLE * 100:.3f}%"


def windows_css(name, windows, prop="opacity", on="1", off="0"):
    shown = lambda t: any(a <= t < b for a, b in windows)
    points = sorted({0.0} | {t for w in windows for t in w if 0 < t < CYCLE})
    body = "".join(f"{pct(t)}{{{prop}:{on if shown(t) else off}}}" for t in points)
    return f"@keyframes {name}{{{body}100%{{{prop}:{on if shown(0.0) else off}}}}}"


def sessions(rv):
    """Three console sessions: commands typed, then output lines at given times."""
    _, [(lcmd, llines)] = read_run("list")
    _, dig = read_run("digest")
    out = []

    # Get-RepoList: the table, its first rows.
    s = {"script": 0, "start": 0.0, "end": 6.4, "rows": []}
    tt = 0.15
    s["rows"].append(("cmd", lcmd, tt))
    tt += len(lcmd) / TYPE_CPS + 0.35
    for line in llines[:CAP - 2]:
        s["rows"].append(("out", line, tt))
    out.append(s)

    # Get-RepoDigest: progress, the file it wrote, the top of that file.
    s = {"script": 1, "start": 6.4, "end": 13.0, "rows": []}
    (dcmd, dlines), (gcmd, glines) = dig
    tt = s["start"] + 0.4
    s["rows"].append(("cmd", dcmd, tt))
    tt += len(dcmd) / TYPE_CPS + 0.3
    for line in dlines:
        s["rows"].append(("out", line, tt))
        tt += 0.11 if "/16]" in plain(line) else 0.2
    s["rows"].append(("out", [], tt))
    s["rows"].append(("cmd", gcmd, tt + 0.5))
    tt += 0.5 + len(gcmd) / TYPE_CPS + 0.3
    for line in glines[:7]:
        s["rows"].append(("out", line, tt))
    out.append(s)

    # Invoke-RepoReview: two repos, K then A, waiting at the third.
    s = {"script": 2, "start": 13.0, "end": CYCLE, "rows": []}
    tt = s["start"] + 0.4
    s["rows"].append(("cmd", rv["cmd"], tt))
    tt += len(rv["cmd"]) / TYPE_CPS + 0.5
    for line in rv["head"]:
        s["rows"].append(("out", line, tt))
        tt += 0.08
    keys = iter(["k", "a", None])
    for b in rv["blocks"][:3]:
        for line in b["lines"]:
            s["rows"].append(("out", line, tt))
        tt += 0.9
        key = next(keys)
        prompt = list(rv["prompt"])
        if key is None:
            s["rows"].append(("out", prompt, tt - 0.9))
            break
        s["rows"].append(("out", prompt, tt - 0.9))
        s["rows"].append(("key", key, tt))  # the key typed after the prompt
        tt += 0.25
        if key == "a":
            s["rows"].append(("out", [("text", rv["whatifArchive"].replace("{repo}", b["repo"]))], tt))
        s["rows"].append(("out", [], tt))
        tt += 0.3
    out.append(s)
    return out


def build_svg(theme, rv, syn):
    c = THEMES[theme]
    css, body = [], []

    # ---- the index: names hung on their hyphens ----
    verbs = [s.split("-")[0] for s in SCRIPTS]
    nouns = [s.split("-", 1)[1] for s in SCRIPTS]
    vw = max(advance(v, NAME_SIZE, CHIVO, NAME_W, -0.01) for v in verbs)
    hyph = advance("-", NAME_SIZE, CHIVO, NAME_W)
    axis = PAD + 8 + vw
    syn_x = PAD + 8 + vw + hyph + max(advance(n, NAME_SIZE, CHIVO, NAME_W, -0.01) for n in nouns) + 40
    syn_w = W - PAD - 16 - syn_x
    row_y = [100, 176, 252]
    sess = sessions(rv)
    for i, (v, n) in enumerate(zip(verbs, nouns)):
        win = [(s["start"], s["end"]) for s in sess if s["script"] == i]
        sel_static = i == 2   # the still frame: Invoke-RepoReview, waiting at its prompt
        y = row_y[i]
        cls = f"r{i}"
        css.append(windows_css(f"{cls}bg", win))
        css.append(windows_css(f"{cls}nm", win, "fill", c["ink"], c["mute"]))
        css.append(windows_css(f"{cls}hy", win, "fill", c["ember"], c["strong"]))
        body.append(f'<rect class="{cls}bg" x="{PAD - 4}" y="{y - 46}" width="{W - 2 * PAD + 8}" height="62" rx="10" fill="{c["sel"]}"'
                    f' style="opacity:{1 if sel_static else 0}"/>')
        nm_fill = c["ink"] if sel_static else c["mute"]
        body.append(f'<g class="{cls}nm" style="fill:{nm_fill}">')
        body.append(text(v, axis - advance(v, NAME_SIZE, CHIVO, NAME_W, -0.01), y, NAME_SIZE, CHIVO, NAME_W, ls=-0.01))
        body.append(text(n, axis + hyph, y, NAME_SIZE, CHIVO, NAME_W, ls=-0.01))
        body.append("</g>")
        # the hyphen as a bar, so its colour can carry the selection
        hy_fill = c["ember"] if sel_static else c["strong"]
        body.append(f'<rect class="{cls}hy" x="{axis + hyph * 0.14:.1f}" y="{y - NAME_SIZE * 0.36:.1f}" width="{hyph * 0.72:.1f}" height="{NAME_SIZE * 0.12:.1f}" style="fill:{hy_fill}"/>')
        lines = wrap(syn[i], 16, CHIVO, 400, syn_w)
        if len(lines) > 2:
            sys.exit(f"synopsis of {SCRIPTS[i]} needs {len(lines)} lines; the index has room for 2")
        for j, ln in enumerate(lines):
            body.append(text(ln, syn_x, y - 22 + j * 21 + (10 if len(lines) == 1 else 0), 16, CHIVO, 400, c["mute"]))
    css.append(".r0bg,.r1bg,.r2bg{animation-timing-function:step-end}")

    # ---- the console ----
    body.append(f'<rect x="{CON_X}" y="{CON_Y}" width="{CON_W}" height="{CON_H}" rx="12" fill="{c["code"]}" stroke="{c["line"]}"/>')
    body.append(f'<clipPath id="con"><rect x="{CON_X + 1}" y="{CON_Y + 1}" width="{CON_W - 2}" height="{CON_H - 2}" rx="11"/></clipPath>')
    body.append('<g clip-path="url(#con)">')
    cx, cy = CON_X + 20, CON_Y + 30
    maxw = CON_W - 40
    char = advance("0", MONO_SIZE, MONO, 400)
    ink = lambda k: c[k] if k != "text" else c["text"]
    still = sess[2]   # the still frame shows the review session as it ends
    for si, s in enumerate(sess):
        sid = f"s{si}"
        css.append(windows_css(sid, [(s["start"], s["end"])]))
        body.append(f'<g class="{sid}" style="opacity:{1 if s is still else 0}">')
        # rows -> lines; a key joins the line before it
        lines, times = [], []
        for kind, val, t in s["rows"]:
            if kind == "key":
                lines[-1] = ("keyed", lines[-1][1], val, t, lines[-1][4])
                continue
            lines.append((kind, val, None, None, t))
            times.append(t)
        # scrolling: once more than CAP lines are out, the block moves up a line per line
        shift_at = [(t, max(0, n - CAP)) for n, t in enumerate(times, 1)]
        final_shift = max(0, len(lines) - CAP)
        sk = {0.0: 0}
        for t, n in shift_at:
            sk[t] = n
        frames = "".join(f"{pct(t)}{{transform:translateY({-n * LH}px)}}" for t, n in sorted(sk.items()))
        css.append(f"@keyframes {sid}_y{{{frames}{pct(s['end'] - 0.001)}{{transform:translateY({-final_shift * LH}px)}}100%{{transform:translateY({-final_shift * LH if s is still else 0}px)}}}}")
        body.append(f'<g class="{sid}_y" style="transform:translateY({-final_shift * LH if s is still else 0}px)">')
        for li, (kind, val, key, key_t, t) in enumerate(lines):
            y = cy + li * LH
            lc = f"{sid}l{li}"
            css.append(windows_css(lc, [(t, s["end"])]))
            parts = []
            if kind in ("cmd",):
                parts.append(text("PS>", cx, y, MONO_SIZE, MONO, 400, c["mute"]))
                x0 = cx + char * 4
                parts.append(text(val, x0, y, MONO_SIZE, MONO, 400, c["ink"], maxw=maxw - char * 4))
                # typing: a cover in the console colour steps off the command
                tw = char * len(val)
                n = len(val)
                t1 = t + n / TYPE_CPS
                tc = f"{lc}_t"
                css.append(f"@keyframes {tc}{{0%{{transform:translateX(0)}}{pct(t)}{{transform:translateX(0);animation-timing-function:steps({n},end)}}"
                           f"{pct(t1)}{{transform:translateX({tw:.1f}px)}}100%{{transform:translateX({tw:.1f}px)}}}}")
                parts.append(f'<rect class="{tc}" x="{x0:.1f}" y="{y - MONO_SIZE:.1f}" width="{tw + 2:.1f}" height="{LH}" fill="{c["code"]}" style="transform:translateX({tw:.1f}px)"/>')
            else:
                x = cx
                for k2, seg in val:
                    parts.append(text(seg, x, y, MONO_SIZE, MONO, 400, ink(k2), maxw=maxw - (x - cx)))
                    x += char * len(seg)
                if key:
                    kc = f"{lc}k"
                    css.append(windows_css(kc, [(key_t, s["end"])]))
                    parts.append(f'<g class="{kc}" style="opacity:{1 if s is still else 0}">{text(key, x, y, MONO_SIZE, MONO, 400, c["ink"])}</g>')
                elif s is still and li == len(lines) - 1:
                    # the review waits here for you: a caret after its prompt
                    parts.append(f'<rect class="caret" x="{x:.1f}" y="{y - MONO_SIZE + 2:.1f}" width="{char:.1f}" height="{MONO_SIZE + 2}" fill="{c["ink"]}"/>')
            body.append(f'<g class="{lc}" style="opacity:{1 if s is still else 0}">{"".join(parts)}</g>')
        body.append("</g></g>")
    # lines wider than the console fade out at its right edge
    body.append(f'<linearGradient id="fade" x1="0" x2="1"><stop offset="0" stop-color="{c["code"]}" stop-opacity="0"/><stop offset="1" stop-color="{c["code"]}"/></linearGradient>'
                f'<rect x="{CON_X + CON_W - 56}" y="{CON_Y + 1}" width="55" height="{CON_H - 2}" fill="url(#fade)"/>')
    body.append("</g>")

    # caption under the console
    cap = f"Replays of real runs against my public repos, {rv['recorded'].split(',')[0]}. Review runs with -WhatIf: nothing changed."
    body.append(text(cap, CON_X + 2, H - 16, 13, CHIVO, 400, c["mute"]))

    anim = []
    for rule in css:
        m = re.match(r"@keyframes (\S+?)\{", rule)
        if m:
            nm = m.group(1)
            timing = "linear" if nm.endswith("_t") else "step-end"
            anim.append(f".{nm}{{animation:{nm} {CYCLE}s {timing} infinite}}")
    keyframes = "".join(r for r in css if r.startswith("@keyframes"))
    other = "".join(r for r in css if not r.startswith("@keyframes"))
    blink = "@keyframes blink{0%{opacity:1}50%{opacity:0}}.caret{animation:blink 1s step-end infinite}"
    style = f"<style>@media (prefers-reduced-motion:no-preference){{{keyframes}{''.join(anim)}{other}{blink}}}</style>"

    defs = "".join(f'<path id="{gid}" d="{d}"/>' for gid, d in _glyphs.values() if d)
    head = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img">'
            f"<defs>{defs}</defs>{style}"
            f'<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="20" fill="{c["plate"]}" stroke="{c["line"]}"/>')
    return head + "".join(body) + "</svg>"


# ---------------------------------------------------------------- go
def main():
    rv = review_parts()
    syn = [synopsis(s) for s in SCRIPTS]
    rec_list, list_cmds = read_run("list")
    _, dig_cmds = read_run("digest")

    # page data
    data = {
        "recorded": rv["recorded"],
        "scripts": [{"name": s, "synopsis": syn[i]} for i, s in enumerate(SCRIPTS)],
        "list": [{"cmd": c, "lines": l} for c, l in list_cmds],
        "digest": [{"cmd": c, "lines": l} for c, l in dig_cmds],
        "review": {k: rv[k] for k in ("cmd", "head", "prompt", "confirm", "mismatch", "invalid", "whatifArchive",
                                     "whatifDelete", "stopped", "done", "log", "rule")},
    }
    data["review"]["blocks"] = rv["blocks"]
    js = ("// Generated by docs/art/make-art.py from docs/art/runs/*.txt. Do not edit.\n"
          "window.RUNS = " + json.dumps(data, separators=(",", ":"), ensure_ascii=True) + ";\n")
    with open(os.path.join(DOCS, "runs.js"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(js)

    # transcripts baked into the page (what it shows without JavaScript) and the README
    page = os.path.join(DOCS, "index.html")
    splice(page, "list", transcript(list_cmds))
    splice(page, "digest", transcript(dig_cmds))
    splice(page, "review", transcript([(rv["cmd"], rv["short"])]))
    for i, s in enumerate(SCRIPTS):
        splice(page, f"syn-{s}", html.escape(syn[i], quote=False))
    splice(page, "date", rv["recorded"].split(",")[0])
    readme = os.path.join(ROOT, "README.md")
    rows = ["", "| Script | What its `Get-Help` says |", "|---|---|"]
    rows += [f"| [`{s}.ps1`]({s}.ps1) | {syn[i]} |" for i, s in enumerate(SCRIPTS)]
    width = max(len(TRY[s][0]) for s in SCRIPTS) + 3
    rows += ["", "```powershell"] + [f"{TRY[s][0].ljust(width)}# {TRY[s][1]}" for s in SCRIPTS] + ["```"]
    splice(readme, "index", "\n".join(rows) + "\n")
    splice(readme, "review", "\n```text\n" + text_transcript([(rv["cmd"], rv["short"])]) + "\n```\n")

    for theme in THEMES:
        _glyphs.clear()
        svg = build_svg(theme, rv, syn)
        path = os.path.join(DOCS, "assets", f"index-{theme}.svg")
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(svg + "\n")
        print(f"wrote {os.path.relpath(path, ROOT)} ({os.path.getsize(path) // 1024} KB)")
    print(f"wrote docs/runs.js ({os.path.getsize(os.path.join(DOCS, 'runs.js')) // 1024} KB), spliced docs/index.html and README.md")


main()
