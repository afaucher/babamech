#!/usr/bin/env python3
"""Pacing timeline from babamech run logs (docs/design/pacing-director.md section 3).

Reads the combat log's "[Flow]" records (scripts/mission/pacing/combat_log.gd, docs/testing.md "Combat log") from one or more run
logs (one per machine: each logs its own pilot) and writes ONE self-contained HTML file (inline SVG and CSS, a few lines
of inline JS for hover; no CDN, no external files):
  per pilot over mission time: structure % (total and weakest core), intensity, enemies engaging / in sight / seeing
  the pilot, damage in and out per window, the director state as a coloured band, releases / scout calls / deaths /
  depot claims as marks, quiet stretches (nobody engaged) against the 45 s cap (every one over 30 s labelled);
  a per-deck summary table against the targets of pacing-research.md 8.2, each cell marked in / out of target.
Older logs without threat / shot / deck_sum records still chart: structure from summary / dmg_in, damage from dmg_in /
dmg_out, quiet stretches estimated from the summary's combat flag (marked "estimate").

Usage:
  python tools/pacing_report/pacing_report.py <run.log> [more.log ...] [-o report.html]
  python tools/pacing_report/pacing_report.py -Latest [-o report.html]
      (the newest mission log in %APPDATA%/Godot/app_userdata/babamech/logs (godot.log and its dated copies) or
      test_logs/playtest/; test runs are skipped)
Bot pilots (threat lines with bot=1, a host's hangar bots) get their own section ("bot <pilot id>").
Python 3 standard library only.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
from pathlib import Path

QUIET_CAP = 45.0
QUIET_LIST = 30.0
WINDOW = 10.0  # s per damage bar
TARGETS = {  # pacing-research.md 8.2
    "eng_solo": (60.0, 75.0),
    "eng_crew": (65.0, 80.0),
    "peaks": (3, 4),
    "quiet_max": 45.0,
    "hp_min": 25.0,
    "kint_solo": (12.0, 18.0),
    "kint_crew": (6.0, 10.0),
}
STATE_ORDER = ["rest", "build", "peak", "fade"]

LINE_RE = re.compile(r"^\[Flow\] t=(-?[0-9.]+) ([a-z_]+) (mt=.*)$")


def default_logs_dir() -> Path:
    appdata = os.environ.get("APPDATA") or str(Path.home() / "AppData" / "Roaming")
    return Path(appdata) / "Godot" / "app_userdata" / "babamech" / "logs"


def is_mission_log(p: Path) -> bool:
    try:
        with p.open("r", encoding="utf-8", errors="replace") as f:
            head = f.read(4096)
            if "Running test:" in head:
                return False
            f.seek(0)
            for line in f:
                if line.startswith("[Flow] ") and " mt=" in line and " peer=" in line:
                    return True
    except OSError:
        return False
    return False


def default_dirs() -> list[Path]:
    """Godot's user logs (run.ps1 games, the user's playtests: godot.log and its dated copies) and test_logs/playtest/."""
    return [default_logs_dir(), Path(__file__).resolve().parents[2] / "test_logs" / "playtest"]


def latest_log(d: Path | list[Path]) -> Path | None:
    dirs = d if isinstance(d, list) else [d]
    found = []
    for x in dirs:
        if x.is_dir():
            found.extend(x.glob("*.log"))
    for p in sorted(found, key=lambda q: q.stat().st_mtime, reverse=True):
        if is_mission_log(p):
            return p
    return None


def num(v, default=None):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def parse_log(path: Path) -> list[dict]:
    recs = []
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = LINE_RE.match(line.rstrip("\r\n"))
            if not m:
                continue
            d = {"_t": num(m.group(1), 0.0), "_tag": m.group(2)}
            for tok in m.group(3).split(" "):
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    d[k] = v
            if "mt" not in d or "peer" not in d:
                continue
            d["mt"] = num(d["mt"], 0.0)
            recs.append(d)
    return recs


class Pilot:
    def __init__(self, key: str, source: str):
        self.key = key
        self.source = source
        self.recs: list[dict] = []

    def tag(self, t: str) -> list[dict]:
        return [r for r in self.recs if r["_tag"] == t]


def split_pilots(paths: list[Path]) -> list[Pilot]:
    pilots: dict[str, Pilot] = {}
    for p in paths:
        for r in parse_log(p):
            who = f"bot {r.get('pilot')}" if r.get("bot") == "1" else f"peer {r['peer']}"
            key = f"{p.name} {who}" if len(paths) > 1 else who
            if key not in pilots:
                pilots[key] = Pilot(key, p.name)
            pilots[key].recs.append(r)
    return list(pilots.values())


# --- Derived series ---------------------------------------------------------------------------------------------

def quiet_stretches(pilot: Pilot) -> tuple[list[tuple[float, float]], bool, float]:
    """[(start, dur)] with nobody engaged, whether estimated, and the end time."""
    th = pilot.tag("threat")
    end = max((r["mt"] for r in pilot.recs), default=0.0)
    out = []
    if th:
        start = 0.0
        quiet = True
        last = 0.0
        for r in th:
            eng = r.get("crew_eng", r.get("eng", "0")) == "1"
            if eng and quiet:
                out.append((start, r["mt"] - start))
                quiet = False
            elif not eng and not quiet:
                start = r["mt"]
                quiet = True
            last = r["mt"]
        if quiet:
            out.append((start, max(end, last) - start))
        return [q for q in out if q[1] > 0], False, end
    sm = pilot.tag("summary")
    if not sm:
        return [], True, end
    start = 0.0
    quiet = True
    for r in sm:
        c = r.get("combat") == "1"
        if c and quiet:
            out.append((start, r["mt"] - 10.0 - start))
            quiet = False
        elif not c and not quiet:
            start = r["mt"] - 10.0
            quiet = True
    if quiet:
        out.append((start, end - start))
    return [(max(s, 0.0), d) for s, d in out if d > 0], True, end


def structure_series(pilot: Pilot):
    th = pilot.tag("threat")
    if th:
        return ([(r["mt"], num(r.get("tot"), 100)) for r in th], [(r["mt"], num(r.get("core"), 100)) for r in th])
    pts_t, pts_c = [(0.0, 100.0)], [(0.0, 100.0)]
    for r in pilot.recs:
        if r["_tag"] == "summary":
            pts_t.append((r["mt"], num(r.get("hp"), 100)))
            pts_c.append((r["mt"], num(r.get("core"), 100)))
        elif r["_tag"] == "dmg_in" and "tot" in r:
            pts_t.append((r["mt"], num(r.get("tot"), 100)))
            pts_c.append((r["mt"], num(r.get("core"), 100)))
        elif r["_tag"] == "respawn":
            pts_t.append((r["mt"], 100.0))
            pts_c.append((r["mt"], 100.0))
    pts_t.sort()
    pts_c.sort()
    return pts_t, pts_c


def damage_bins(pilot: Pilot, end: float):
    n = int(end // WINDOW) + 1
    din = [0.0] * n
    dout = [0.0] * n
    for r in pilot.recs:
        i = min(int(r["mt"] // WINDOW), n - 1)
        if r["_tag"] == "dmg_in":
            din[i] += num(r.get("amt"), 0.0)
        elif r["_tag"] == "dmg_out":
            dout[i] += num(r.get("amt"), 0.0)
    return din, dout


def pace_intervals(pilot: Pilot, end: float):
    """[(start, end, state, deck)] from pace lines (the latest change of any deck wins: one band)."""
    pl = pilot.tag("pace")
    out = []
    for i, r in enumerate(pl):
        e = pl[i + 1]["mt"] if i + 1 < len(pl) else end
        out.append((r["mt"], e, r.get("to", "-"), r.get("deck", "-")))
    return out


# --- SVG helpers ------------------------------------------------------------------------------------------------

W = 1080
PAD_L = 56
PAD_R = 16


class Axis:
    def __init__(self, end: float):
        self.end = max(end, 1.0)

    def x(self, t: float) -> float:
        return PAD_L + (W - PAD_L - PAD_R) * max(0.0, min(t, self.end)) / self.end

    def ticks(self):
        step = 30.0 if self.end <= 400 else 60.0 if self.end <= 900 else 120.0
        t = 0.0
        while t <= self.end + 1e-6:
            yield t
            t += step


def esc(s) -> str:
    return html.escape(str(s), quote=True)


def fmt_t(t: float) -> str:
    return f"{int(t // 60)}:{int(t % 60):02d}"


def panel(ax: Axis, title: str, h: int, ymax: float, body: str, yticks=None, unit="", legend="") -> str:
    top, bot = 8, h - 22
    def y(v):
        return bot - (bot - top) * max(0.0, min(v, ymax)) / ymax if ymax > 0 else bot
    grid = []
    for v in (yticks if yticks is not None else [0, ymax / 2, ymax]):
        grid.append(f'<line class="grid" x1="{PAD_L}" x2="{W - PAD_R}" y1="{y(v):.1f}" y2="{y(v):.1f}"/>'
                    f'<text class="ylab" x="{PAD_L - 6}" y="{y(v) + 4:.1f}">{v:g}{unit}</text>')
    for t in ax.ticks():
        grid.append(f'<text class="xlab" x="{ax.x(t):.1f}" y="{h - 6}">{fmt_t(t)}</text>')
    return (f'<figure class="panel"><figcaption><span class="ptitle">{esc(title)}</span>{legend}</figcaption>'
            f'<svg viewBox="0 0 {W} {h}" width="100%" role="img" aria-label="{esc(title)}" data-end="{ax.end}">'
            + "".join(grid) + re.sub(r"\{y:([0-9.e+-]+)\}", lambda m: f"{y(float(m.group(1))):.1f}", body) +
            f'<line class="hover" x1="0" x2="0" y1="{top}" y2="{bot}" visibility="hidden"/></svg></figure>')


def poly(ax: Axis, pts, cls: str, step=False) -> str:
    if not pts:
        return ""
    d = []
    prev = None
    for t, v in pts:
        if step and prev is not None:
            d.append(f"{ax.x(t):.1f},{{y:{prev}}}")
        d.append(f"{ax.x(t):.1f},{{y:{v}}}")
        prev = v
    return f'<polyline class="{cls}" points="{" ".join(d)}"/>'


def legend(items) -> str:
    return '<span class="legend">' + "".join(f'<span class="key"><i class="{c}"></i>{esc(n)}</span>' for c, n in items) + "</span>"


# --- Report -----------------------------------------------------------------------------------------------------

def pilot_section(p: Pilot) -> tuple[str, dict]:
    end = max((r["mt"] for r in p.recs), default=1.0)
    ax = Axis(end)
    th = p.tag("threat")
    has_threat = bool(th)
    parts = []
    hover = {"end": ax.end, "rows": []}

    # Director band + marks.
    band = []
    for s, e, st, deck in pace_intervals(p, end):
        cls = f"st-{st}" if st in STATE_ORDER else "st-other"
        band.append(f'<rect class="{cls}" x="{ax.x(s):.1f}" y="10" width="{max(ax.x(e) - ax.x(s), 0.5):.1f}" height="16">'
                    f'<title>{esc(st)} (deck {esc(deck)}) {fmt_t(s)}-{fmt_t(e)}</title></rect>')
    marks = []
    for r in p.recs:
        tg = r["_tag"]
        x = ax.x(r["mt"])
        if tg == "release":
            marks.append(f'<path class="m-release" d="M{x:.1f},34 l5,9 h-10 z"><title>release {esc(r.get("wave"))} deck '
                         f'{esc(r.get("deck"))} {esc(r.get("kinds"))} ({esc(r.get("reason"))}) {fmt_t(r["mt"])}</title></path>')
        elif tg == "scout":
            marks.append(f'<path class="m-scout" d="M{x:.1f},33 l5,5 l-5,5 l-5,-5 z"><title>scout {esc(r.get("ev"))} '
                         f'{esc(r.get("drone"))} {fmt_t(r["mt"])}</title></path>')
        elif tg == "down":
            marks.append(f'<path class="m-down" d="M{x - 5:.1f},33 l10,10 M{x + 5:.1f},33 l-10,10"><title>disabled ('
                         f'{esc(r.get("cause"))}, {esc(r.get("src"))}) {fmt_t(r["mt"])}</title></path>')
        elif tg == "depot":
            marks.append(f'<rect class="m-depot" x="{x - 4:.1f}" y="34" width="8" height="8"><title>depot {esc(r.get("ev"))} '
                         f'{esc(r.get("depot"))} left {esc(r.get("left"))} {fmt_t(r["mt"])}</title></rect>')
        elif tg == "deck_sum":
            marks.append(f'<line class="deckline" x1="{x:.1f}" x2="{x:.1f}" y1="6" y2="48"/>'
                         f'<text class="decklab" x="{x + 3:.1f}" y="56">left deck {esc(r.get("deck"))}</text>')
    if not band:
        band.append(f'<text class="note" x="{PAD_L}" y="22">no director state in this log</text>')
    h = 64
    grid = "".join(f'<text class="xlab" x="{ax.x(t):.1f}" y="{h - 2}">{fmt_t(t)}</text>' for t in ax.ticks())
    lg = legend([("st-rest", "rest"), ("st-build", "build"), ("st-peak", "peak"), ("st-fade", "fade"),
                 ("m-release", "release"), ("m-scout", "scout call"), ("m-down", "disabled"), ("m-depot", "depot")])
    parts.append(f'<figure class="panel"><figcaption><span class="ptitle">Director state and events</span>{lg}</figcaption>'
                 f'<svg viewBox="0 0 {W} {h}" width="100%" role="img" aria-label="Director state and events">{grid}'
                 + "".join(band) + "".join(marks) + "</svg></figure>")

    # Structure.
    tot, core = structure_series(p)
    body = poly(ax, tot, "s1", step=not has_threat) + poly(ax, core, "s2", step=not has_threat)
    body += f'<line class="target" x1="{PAD_L}" x2="{W - PAD_R}" y1="{{y:25}}" y2="{{y:25}}"/>'
    body += f'<text class="tlab" x="{W - PAD_R - 4}" y="{{y:25}}" dy="-4">25 % close call</text>'
    parts.append(panel(ax, "Structure %", 150, 100, body, [0, 25, 50, 75, 100], "",
                       legend([("s1", "total"), ("s2", "weakest core component")])))

    # Intensity.
    if has_threat:
        ipts = [(r["mt"], num(r.get("i"), 0)) for r in th]
        cpts = [(r["mt"], num(r.get("crew_i"), 0)) for r in th]
        src = "host" if any(r.get("src") == "host" for r in th) else "local"
        body = poly(ax, ipts, "s1")
        items = [("s1", f"pilot (src={src})")]
        if any(a[1] != b[1] for a, b in zip(ipts, cpts)):
            body += poly(ax, cpts, "s3 dash")
            items.append(("s3", "crew"))
        body += f'<line class="target" x1="{PAD_L}" x2="{W - PAD_R}" y1="{{y:70}}" y2="{{y:70}}"/>'
        body += f'<text class="tlab" x="{W - PAD_R - 4}" y="{{y:70}}" dy="-4">peak 70</text>'
        parts.append(panel(ax, "Intensity", 130, 100, body, [0, 35, 70, 100], "", legend(items)))

        # Enemies.
        e_eng = [(r["mt"], num(r.get("engaging"), 0)) for r in th]
        e_see = [(r["mt"], num(r.get("sees"), 0)) for r in th]
        e_by = [(r["mt"], num(r.get("seen_by"), 0)) for r in th]
        ymax = max([v for _, v in e_eng + e_see + e_by] + [4])
        ymax = float(int(ymax + 1))
        est = any(r.get("est") == "1" for r in th)
        body = poly(ax, e_eng, "s1", True) + poly(ax, e_see, "s2", True) + poly(ax, e_by, "s3", True)
        parts.append(panel(ax, "Enemies" + (" (estimates: client)" if est else ""), 140, ymax, body,
                           [0, ymax / 2, ymax], "", legend([("s1", "engaging"), ("s2", "in sight"), ("s3", "seeing the pilot")])))
        hover["rows"] = [[r["mt"], num(r.get("i"), 0), num(r.get("tot"), 0), num(r.get("core"), 0),
                          num(r.get("engaging"), 0), num(r.get("sees"), 0), num(r.get("seen_by"), 0),
                          num(r.get("near"), 0)] for r in th]
    else:
        parts.append('<p class="note">No threat records in this log (older combat log): no intensity or line-of-sight '
                     'charts; structure from summaries and damage lines.</p>')

    # Damage per window.
    din, dout = damage_bins(p, end)
    ymax = max(din + dout + [10.0])
    ymax = float(int(ymax / 10 + 1) * 10)
    bw = (ax.x(WINDOW) - ax.x(0)) / 2 - 2
    bars = []
    for i, (a, b) in enumerate(zip(din, dout)):
        x0 = ax.x(i * WINDOW) + 1
        if a > 0:
            bars.append(f'<rect class="b1" x="{x0:.1f}" y="{{y:{a}}}" width="{bw:.1f}" height="{{h:{a}}}" rx="2">'
                        f'<title>{fmt_t(i * WINDOW)}: damage taken {a:.0f}</title></rect>')
        if b > 0:
            bars.append(f'<rect class="b2" x="{x0 + bw + 2:.1f}" y="{{y:{b}}}" width="{bw:.1f}" height="{{h:{b}}}" rx="2">'
                        f'<title>{fmt_t(i * WINDOW)}: damage dealt {b:.0f}</title></rect>')
    body = "".join(bars)
    body = re.sub(r"\{h:([0-9.e+-]+)\}", lambda m: f"{{hh:{m.group(1)}}}", body)
    parts.append(_panel_bars(ax, f"Damage per {WINDOW:g} s", 140, ymax, body,
                             legend([("b1", "taken"), ("b2", "dealt")])))

    # Quiet stretches against the cap.
    qs, q_est, _ = quiet_stretches(p)
    h = 120
    top, bot = 8, h - 22
    ymax = 60.0
    def yq(v):
        return bot - (bot - top) * min(v, ymax) / ymax
    q_svg = []
    for v, cls, lab in ((QUIET_CAP, "cap", "45 s cap"), (QUIET_LIST, "target", "30 s")):
        q_svg.append(f'<line class="{cls}" x1="{PAD_L}" x2="{W - PAD_R}" y1="{yq(v):.1f}" y2="{yq(v):.1f}"/>'
                     f'<text class="tlab" x="{W - PAD_R - 4}" y="{yq(v) - 4:.1f}">{lab}</text>')
    for v in (0, 30, 45, 60):
        q_svg.append(f'<text class="ylab" x="{PAD_L - 6}" y="{yq(v) + 4:.1f}">{v} s</text>')
    for s, d in qs:
        x0, x1 = ax.x(s), ax.x(s + d)
        cls = "q-over" if d > QUIET_CAP else "q-long" if d > QUIET_LIST else "q"
        # the quiet timer: rises with time since the last engagement, drops to 0 at the next one
        q_svg.append(f'<path class="{cls}" d="M{x0:.1f},{bot} L{x1:.1f},{yq(d):.1f} L{x1:.1f},{bot} Z">'
                     f'<title>nobody engaged {fmt_t(s)} for {d:.0f} s</title></path>')
        if d > QUIET_LIST:
            q_svg.append(f'<text class="qlab" x="{(x0 + x1) / 2:.1f}" y="{max(yq(d) - 4, 12):.1f}">quiet {d:.0f} s at {fmt_t(s)}</text>')
    for t in ax.ticks():
        q_svg.append(f'<text class="xlab" x="{ax.x(t):.1f}" y="{h - 6}">{fmt_t(t)}</text>')
    title = "Quiet stretches: time with nobody engaged" + (" (estimate from combat activity, older log)" if q_est else "")
    parts.append(f'<figure class="panel"><figcaption><span class="ptitle">{esc(title)}</span>'
                 + legend([("q", "under 30 s"), ("q-long", "over 30 s"), ("q-over", "over the 45 s cap")]) +
                 f'</figcaption><svg viewBox="0 0 {W} {h}" width="100%" role="img" aria-label="{esc(title)}">'
                 + "".join(q_svg) + "</svg></figure>")
    return "".join(parts), {"quiet": qs, "q_est": q_est, "end": end, "hover": hover}


def _panel_bars(ax: Axis, title, h, ymax, body, lg) -> str:
    top, bot = 8, h - 22
    def y(v):
        return bot - (bot - top) * min(v, ymax) / ymax
    body = re.sub(r"\{y:([0-9.e+-]+)\}", lambda m: f"{y(float(m.group(1))):.1f}", body)
    body = re.sub(r"\{hh:([0-9.e+-]+)\}", lambda m: f"{max(bot - y(float(m.group(1))), 0.5):.1f}", body)
    grid = []
    for v in (0, ymax / 2, ymax):
        grid.append(f'<line class="grid" x1="{PAD_L}" x2="{W - PAD_R}" y1="{y(v):.1f}" y2="{y(v):.1f}"/>'
                    f'<text class="ylab" x="{PAD_L - 6}" y="{y(v) + 4:.1f}">{v:g}</text>')
    for t in ax.ticks():
        grid.append(f'<text class="xlab" x="{ax.x(t):.1f}" y="{h - 6}">{fmt_t(t)}</text>')
    return (f'<figure class="panel"><figcaption><span class="ptitle">{esc(title)}</span>{lg}</figcaption>'
            f'<svg viewBox="0 0 {W} {h}" width="100%" role="img" aria-label="{esc(title)}">' + "".join(grid) + body
            + "</svg></figure>")


# --- Summary table ----------------------------------------------------------------------------------------------

def cell(value: str, ok: bool | None, target: str) -> str:
    if ok is None:
        return f'<td><span class="val">{esc(value)}</span><span class="tg">{esc(target)}</span></td>'
    mark = '<span class="ok">&#10003; in</span>' if ok else '<span class="bad">&#10007; out</span>'
    return f'<td class="{"in" if ok else "out"}"><span class="val">{esc(value)}</span>{mark}<span class="tg">{esc(target)}</span></td>'


def summary_rows(p: Pilot, crew: bool, quiet_info) -> list[dict]:
    rows = []
    for r in p.tag("deck_sum"):
        rows.append({"name": f"deck {r.get('deck')}", "dur": num(r.get("dur"), 0), "eng": num(r.get("eng_pct")),
                     "peaks": num(r.get("peaks")), "quiet": num(r.get("quiet_max")), "quiet30": r.get("quiet30", "-"),
                     "hp": num(r.get("hp_min")), "hp_t": num(r.get("hp_min_mt")), "core": num(r.get("core_min")),
                     "kmed": num(r.get("kint_med")), "kp90": num(r.get("kint_p90")), "kmax": num(r.get("kint_max")),
                     "kills": num(r.get("kills")), "in": num(r.get("in_pm")), "out": num(r.get("out_pm")),
                     "deaths": num(r.get("deaths")), "est": r.get("est") == "1", "mission": False})
    end = p.tag("end")
    if end:
        e = end[-1]
        dur = e["mt"]
        rows.append({"name": "mission", "dur": dur, "eng": num(e.get("eng_pct")), "peaks": num(e.get("peaks")),
                     "quiet": num(e.get("quiet_max"), num(e.get("longest_quiet"))), "quiet30": e.get("quiet30", "-"),
                     "hp": num(e.get("hp_min")), "hp_t": num(e.get("hp_min_mt")), "core": num(e.get("core_min")),
                     "kmed": num(e.get("kint_med")), "kp90": num(e.get("kint_p90")), "kmax": num(e.get("kint_max")),
                     "kills": num(e.get("kills")), "in": num(e.get("in_pm")), "out": num(e.get("out_pm")),
                     "deaths": num(e.get("deaths")), "est": e.get("est_eng") == "1" or "eng_pct" not in e,
                     "mission": True, "old": "eng_pct" not in e})
        if "eng_pct" not in e:   # older end line: combat activity share, damage per minute from the totals
            r = rows[-1]
            cs, qs_ = num(e.get("combat_s"), 0.0), num(e.get("quiet_s"), 0.0)
            r["eng"] = 100.0 * cs / (cs + qs_) if cs + qs_ > 0 else None
            if dur > 0:
                r["in"] = num(e.get("in"), 0.0) * 60.0 / dur
                r["out"] = num(e.get("out"), 0.0) * 60.0 / dur
    elif not rows:
        # Older log, no end: estimate from summaries.
        qs, _, endt = quiet_info
        sm = p.tag("summary")
        if sm:
            comb = sum(1 for r in sm if r.get("combat") == "1")
            rows.append({"name": "mission (estimate)", "dur": endt, "eng": 100.0 * comb / len(sm), "peaks": None,
                         "quiet": max((d for _, d in qs), default=None), "quiet30": "-",
                         "hp": min(num(r.get("hp"), 100) for r in sm), "hp_t": None,
                         "core": min(num(r.get("core"), 100) for r in sm), "kmed": None, "kp90": None, "kmax": None,
                         "kills": None, "in": None, "out": None, "deaths": None, "est": True, "mission": True, "old": True})
    return rows


def f1(v, unit="") -> str:
    return "-" if v is None or v < 0 else f"{v:.0f}{unit}"


def summary_table(p: Pilot, crew: bool, quiet_info) -> str:
    rows = summary_rows(p, crew, quiet_info)
    if not rows:
        return '<p class="note">No deck or end summary in this log.</p>'
    elo, ehi = TARGETS["eng_crew" if crew else "eng_solo"]
    klo, khi = TARGETS["kint_crew" if crew else "kint_solo"]
    out = ['<table><thead><tr><th>stretch</th><th>time</th><th>time engaged</th><th>peaks</th><th>longest quiet</th>'
           '<th>lowest structure</th><th>kill interval (median / p90 / longest)</th><th>damage / min (in / out)</th>'
           '<th>deaths</th></tr></thead><tbody>']
    for r in rows:
        old = r.get("old")
        eng_lab = "time with any enemy engaging" if not old else "time in combat (activity, older log)"
        out.append(f'<tr><th scope="row">{esc(r["name"])}{" *" if r["est"] else ""}</th><td>{fmt_t(r["dur"] or 0)}</td>')
        out.append(cell(f1(r["eng"], " %"), None if r["eng"] is None else elo <= r["eng"] <= ehi,
                        f"{elo:g}-{ehi:g} % ({eng_lab})"))
        out.append(cell(f1(r["peaks"]), None if r["peaks"] is None or r["mission"]
                        else TARGETS["peaks"][0] <= r["peaks"] <= TARGETS["peaks"][1], "3-4 per deck"))
        out.append(cell(f1(r["quiet"], " s"), None if r["quiet"] is None else r["quiet"] <= TARGETS["quiet_max"],
                        "<= 45 s" + ("" if r["quiet30"] in ("-", None) else f"; over 30 s: {r['quiet30'].replace(';', ', ')}")))
        hp = r["hp"]
        hp_txt = f1(hp, " %") + ("" if r.get("hp_t") is None else f" at {fmt_t(r['hp_t'])}")
        out.append(cell(hp_txt, (hp < TARGETS["hp_min"]) if (r["mission"] and hp is not None) else None,
                        "< 25 % once a mission" + ("" if r["mission"] else " (mission row)")))
        k = "/".join(f1(v, " s") for v in (r["kmed"], r["kp90"], r["kmax"]))
        out.append(cell(k, None if r["kmed"] is None or r["kmed"] < 0 else klo <= r["kmed"] <= khi,
                        f"{klo:g}-{khi:g} s over a deck"))
        out.append(f'<td>{f1(r["in"])} / {f1(r["out"])}</td><td>{f1(r["deaths"])}</td></tr>')
    out.append("</tbody></table>")
    if any(r["est"] for r in rows):
        out.append('<p class="note">* engagement from replicated enemy state (a client) or older-log activity: an estimate.</p>')
    return "".join(out)


CSS = """
:root{color-scheme:light;--bg:#fcfcfb;--panel:#ffffff;--ink:#0b0b0b;--ink2:#52514e;--muted:#8a8984;--grid:#e6e5e1;
--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a;--good:#0a7a33;--bad:#c62828;--cap:#c62828;
--rest:#9fc9a6;--build:#f0c060;--peak:#e06a5a;--fade:#a99ad8;--q:#c9c7c0;--qlong:#eda100;--qover:#e34948}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){color-scheme:dark;--bg:#151514;--panel:#1a1a19;
--ink:#f0efec;--ink2:#c3c2b7;--muted:#8f8e86;--grid:#2e2d2b;--s1:#3987e5;--s2:#d95926;--s3:#199e70;--good:#4cc27a;
--bad:#ef6b6b;--cap:#ef6b6b;--rest:#3f6b47;--build:#8a6b1f;--peak:#9a3b30;--fade:#5a4f8a;--q:#4a4945;--qlong:#c98500;
--qover:#e66767}}
:root[data-theme="dark"]{color-scheme:dark;--bg:#151514;--panel:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;--muted:#8f8e86;
--grid:#2e2d2b;--s1:#3987e5;--s2:#d95926;--s3:#199e70;--good:#4cc27a;--bad:#ef6b6b;--cap:#ef6b6b;--rest:#3f6b47;
--build:#8a6b1f;--peak:#9a3b30;--fade:#5a4f8a;--q:#4a4945;--qlong:#c98500;--qover:#e66767}
body{background:var(--bg);color:var(--ink);font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif;margin:0;padding:16px}
main{max-width:1120px;margin:0 auto}
h1{font-size:20px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 8px}p.meta,p.note{color:var(--ink2);margin:4px 0}
.panel{background:var(--panel);border:1px solid var(--grid);border-radius:8px;margin:10px 0;padding:8px 10px 2px;position:relative}
figcaption{display:flex;flex-wrap:wrap;gap:6px 16px;align-items:center;margin-bottom:2px}
.ptitle{font-weight:600}.legend{display:flex;flex-wrap:wrap;gap:4px 12px;color:var(--ink2);font-size:12px}
.key{display:inline-flex;align-items:center;gap:5px}.key i{display:inline-block;width:14px;height:10px;border-radius:2px;background:var(--muted)}
svg text{font-size:11px;fill:var(--ink2)}.xlab{text-anchor:middle}.ylab{text-anchor:end}.tlab{text-anchor:end;fill:var(--muted)}
.grid{stroke:var(--grid);stroke-width:1}
polyline{fill:none;stroke-width:2;stroke-linejoin:round}
polyline.s1{stroke:var(--s1)}polyline.s2{stroke:var(--s2)}polyline.s3{stroke:var(--s3)}.dash{stroke-dasharray:5 3}
.key i.s1,.key i.b1{background:var(--s1)}.key i.s2,.key i.b2{background:var(--s2)}.key i.s3{background:var(--s3)}
rect.b1{fill:var(--s2)}rect.b2{fill:var(--s1)}.key i.b1{background:var(--s2)}.key i.b2{background:var(--s1)}
.target{stroke:var(--muted);stroke-dasharray:4 4}.cap{stroke:var(--cap);stroke-width:1.5;stroke-dasharray:6 3}
.st-rest{fill:var(--rest)}.st-build{fill:var(--build)}.st-peak{fill:var(--peak)}.st-fade{fill:var(--fade)}.st-other{fill:var(--q)}
.key i.st-rest{background:var(--rest)}.key i.st-build{background:var(--build)}.key i.st-peak{background:var(--peak)}.key i.st-fade{background:var(--fade)}
.m-release{fill:var(--s1)}.m-scout{fill:var(--s3)}.m-down{stroke:var(--bad);stroke-width:2.5;fill:none}.m-depot{fill:var(--s2)}
.key i.m-release{background:var(--s1)}.key i.m-scout{background:var(--s3)}.key i.m-down{background:var(--bad)}.key i.m-depot{background:var(--s2)}
.deckline{stroke:var(--ink2);stroke-dasharray:2 3}.decklab{fill:var(--ink2)}
path.q{fill:var(--q)}path.q-long{fill:var(--qlong)}path.q-over{fill:var(--qover)}
.key i.q{background:var(--q)}.key i.q-long{background:var(--qlong)}.key i.q-over{background:var(--qover)}
.qlab{text-anchor:middle;fill:var(--ink);font-weight:600}
.hover{stroke:var(--ink2);stroke-width:1}
.tip{position:absolute;pointer-events:none;background:var(--panel);border:1px solid var(--grid);border-radius:6px;
padding:4px 8px;font-size:12px;color:var(--ink);white-space:nowrap;box-shadow:0 2px 6px rgba(0,0,0,.15)}
table{border-collapse:collapse;width:100%;background:var(--panel);font-size:13px}
th,td{border:1px solid var(--grid);padding:6px 8px;text-align:left;vertical-align:top}
thead th{color:var(--ink2);font-weight:600}td .val{display:block;font-weight:600}td .tg{display:block;color:var(--muted);font-size:11px}
.ok{color:var(--good);font-size:12px}.bad{color:var(--bad);font-size:12px}
.tablewrap{overflow-x:auto}
"""

JS = """
(function(){var data=JSON.parse(document.getElementById('hover-data').textContent);
document.querySelectorAll('section.pilot').forEach(function(sec,pi){var d=data[pi];if(!d||!d.rows.length)return;
var tip=document.createElement('div');tip.className='tip';tip.style.display='none';sec.appendChild(tip);
sec.querySelectorAll('svg[data-end]').forEach(function(svg){var line=svg.querySelector('line.hover');
svg.addEventListener('mousemove',function(ev){var r=svg.getBoundingClientRect();var vb=svg.viewBox.baseVal;
var x=(ev.clientX-r.left)*vb.width/r.width;var t=(x-%PL%)/(vb.width-%PL%-%PR%)*d.end;if(t<0||t>d.end){tip.style.display='none';return;}
var best=d.rows[0];for(var i=0;i<d.rows.length;i++){if(Math.abs(d.rows[i][0]-t)<Math.abs(best[0]-t))best=d.rows[i];}
var bx=%PL%+(vb.width-%PL%-%PR%)*best[0]/d.end;line.setAttribute('x1',bx);line.setAttribute('x2',bx);line.setAttribute('visibility','visible');
var m=Math.floor(best[0]/60),s=Math.floor(best[0]%60);
tip.textContent=m+':'+(s<10?'0':'')+s+'  intensity '+best[1]+'  structure '+best[2]+'% (core '+best[3]+'%)  engaging '+best[4]+'  in sight '+best[5]+'  seeing pilot '+best[6]+'  within 200 m '+best[7];
var sr=sec.getBoundingClientRect();tip.style.display='block';tip.style.left=Math.min(ev.clientX-sr.left+12,sr.width-tip.offsetWidth-4)+'px';tip.style.top=(ev.clientY-sr.top+14)+'px';});
svg.addEventListener('mouseleave',function(){tip.style.display='none';line.setAttribute('visibility','hidden');});});});})();
""".replace("%PL%", str(PAD_L)).replace("%PR%", str(PAD_R))


def build_report(paths: list[Path]) -> str:
    pilots = split_pilots(paths)
    crew = len(pilots) > 1
    secs = []
    hover = []
    for p in pilots:
        body, info = pilot_section(p)
        table = summary_table(p, crew, (info["quiet"], info["q_est"], info["end"]))
        over = [(s, d) for s, d in info["quiet"] if d > QUIET_LIST]
        qtxt = ", ".join(f"{fmt_t(s)} for {d:.0f} s" for s, d in over) or "none"
        secs.append(f'<section class="pilot"><h2>Pilot {esc(p.key)}</h2>'
                    f'<p class="meta">{len(p.recs)} records; mission time {fmt_t(info["end"])}; quiet stretches over 30 s: '
                    f'{esc(qtxt)}</p>{body}<h2>Summary against the targets (pacing-research.md 8.2)</h2>'
                    f'<div class="tablewrap">{table}</div></section>')
        hover.append(info["hover"])
    if not pilots:
        secs.append('<p class="note">No combat log records ([Flow] ... mt= peer=) in the given log(s).</p>')
    srcs = ", ".join(esc(p.name) for p in paths)
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" '
            'content="width=device-width,initial-scale=1"><title>Pacing timeline</title><style>' + CSS +
            '</style></head><body><main><h1>Pacing timeline</h1>'
            f'<p class="meta">From {srcs}. Solo targets unless several pilots are present. Hover a chart for values.</p>'
            + "".join(secs) +
            '<script type="application/json" id="hover-data">' + json.dumps(hover).replace("</", "<\\/") +
            '</script><script>' + JS + '</script></main></body></html>')


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    argv = ["--latest" if a.lower() in ("-latest", "--latest") else a for a in argv]
    ap = argparse.ArgumentParser(description="Pacing timeline (one HTML file) from babamech run logs.")
    ap.add_argument("logs", nargs="*", type=Path, help="run log(s); one per machine")
    ap.add_argument("-o", "--out", type=Path, help="output HTML (default: <first log>.pacing.html)")
    ap.add_argument("--latest", action="store_true", help="the newest mission log in Godot's babamech user logs")
    ap.add_argument("--logs-dir", type=Path, default=None, help="where --latest looks (default: %%APPDATA%%/Godot/app_userdata/babamech/logs and test_logs/playtest)")
    a = ap.parse_args(argv)
    logs = list(a.logs)
    if a.latest:
        d = [a.logs_dir] if a.logs_dir else default_dirs()
        p = latest_log(d)
        if p is None:
            print(f"no mission log (with combat log records) in {', '.join(str(x) for x in d)}", file=sys.stderr)
            return 2
        print(f"latest mission log: {p}")
        logs.append(p)
    if not logs:
        ap.print_usage(sys.stderr)
        return 2
    for p in logs:
        if not p.is_file():
            print(f"not a file: {p}", file=sys.stderr)
            return 2
    out = a.out or logs[0].with_suffix(".pacing.html")
    out.write_text(build_report(logs), encoding="utf-8")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
