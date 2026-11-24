#!/usr/bin/env python3
"""Self-test for pacing_report.py: builds a fixture log (new records) and an older-style log (no threat / shot /
deck_sum records), runs the report on each, and checks the HTML has the expected series, the quiet-stretch labels and
the summary cells. Exit 0 = pass.

    python tools/pacing_report/selftest.py
"""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pacing_report  # noqa: E402


def flow(t: float, tag: str, mt: float, body: str) -> str:
    return f"[Flow] t={t:.3f} {tag} mt={mt:.1f} peer=1 {body}"


def new_log() -> str:
    lines = ["Godot Engine v4.7.stable", "[Flow] t=0.500 peer=1 solo bot deck: now on deck 0"]
    # 0-40 quiet (a 40 s stretch, over 30), 40-80 engaged, 80-112 quiet (32 s), 112-140 engaged.
    for s in range(1, 141):
        eng = 1 if (40 <= s < 80 or s >= 112) else 0
        i = min(100, (s - 40) * 3) if 40 <= s < 80 else 0
        tot = 100 - max(0, s - 40) // 2
        lines.append(flow(10 + s, "threat", s, f"i={i} src=local eng={eng} engaging={eng * 3} near=5 sees={eng * 2} "
                          f"seen_by={eng} nearest=60.0 est=0 crew_i={i} crew_eng={eng} deck=0 alive=5 tot={tot} core={tot - 5} "
                          f"heat=0.40 rays=5"))
    for s in range(1, 30):   # a host's hangar bot: its own threat lines
        lines.append(flow(10 + s, "threat", s, f"i={s} src=local eng=1 engaging=2 near=4 sees=2 seen_by=1 nearest=40.0 est=0 "
                          f"crew_i={s} crew_eng=1 deck=0 alive=5 tot=90 core=80 heat=0.20 rays=4 pilot=-2 bot=1"))
    lines.append(flow(50, "dmg_in", 45.0, "src=e1/tank wpn=cannon comp=torso amt=42.0 n=1 dur=0.00 hp=- tot=90 core=85 "
                      "heat=0.40 shut=0 heat_in=0.0"))
    lines.append(flow(51, "dmg_out", 46.0, "tgt=e1/tank wpn=autocannon amt=88.0 n=4 dur=0.80 thp=40 kill=0 est=0"))
    lines.append(flow(51, "shot", 46.0, "src=player1/player tgt=e1/tank wpn=autocannon n=4 hits=4 hit=1 dist=60.0 est=0"))
    lines.append(flow(52, "pace", 41.0, "deck=0 from=rest to=build i=10 reason=cap"))
    lines.append(flow(53, "pace", 70.0, "deck=0 from=build to=peak i=72 reason=-"))
    lines.append(flow(54, "pace", 76.0, "deck=0 from=peak to=fade i=60 reason=-"))
    lines.append(flow(55, "release", 41.0, "wave=w1 deck=0 src=gate_1 size=4 kinds=tank:1,trooper:3 reason=cap"))
    lines.append(flow(56, "scout", 60.0, "ev=completed drone=dr_2 deck=0"))
    lines.append(flow(57, "depot", 90.0, "ev=grant depot=dep_0 left=1"))
    lines.append(flow(58, "down", 100.0, "cause=head src=e1/tank wpn=cannon"))
    lines.append(flow(59, "quiet", 0.0, "from=0.0 dur=40.0 deck=0"))
    lines.append(flow(150, "deck_sum", 140.0, "deck=0 from=0.0 dur=140.0 eng_s=68.0 eng_pct=49 quiet_max=40.0 quiet_max_mt=0.0 "
                      "quiet30=0.0+40.0;80.0+32.0 peaks=1 peak_mt=70.0 kills=3 kint_med=14.0 kint_p90=20.0 kint_max=20.0 "
                      "in_pm=18.0 out_pm=37.7 hp_min=20 hp_min_mt=100.0 core_min=0 core_min_c=head core_min_mt=100.0 deaths=1 est=0"))
    lines.append(flow(150, "end", 140.0, "outcome=won reason=- in=42.0 out=88.0 kills=3 est=0 taken_by=tank:42.0 "
                      "dealt_by=autocannon:88.0 hp_min=20 hp_min_mt=100.0 core_min=0 core_min_mt=100.0 deaths=1 death_mt=100.0 "
                      "respawns=0 respawn_mt=- combat_s=70.0 quiet_s=70.0 longest_combat=40.0 longest_combat_mt=40.0 "
                      "longest_quiet=40.0 longest_quiet_mt=0.0 eng_s=68.0 eng_pct=49 quiet_max=40.0 quiet_max_mt=0.0 "
                      "quiet30=0.0+40.0;80.0+32.0 peaks=1 peak_mt=70.0 kint_med=14.0 kint_p90=20.0 kint_max=20.0 in_pm=18.0 "
                      "out_pm=37.7 core_min_c=head est_eng=0"))
    return "\n".join(lines) + "\n"


def old_log() -> str:
    lines = ["Godot Engine v4.7.stable"]
    for k in range(1, 13):
        mt = k * 10.0
        combat = 1 if 4 <= k <= 7 else 0
        lines.append(flow(mt, "summary", mt, f"hp={100 - k * 3} core={95 - k * 3} comp=torso:90 heat=0.30 shut=0 in=10.0 "
                          f"out=20.0 near=2 nearest=80.0 combat={combat} deck=0 obj=d0_p down=0"))
    lines.append(flow(41, "dmg_in", 41.0, "src=e1/tank wpn=cannon comp=torso amt=30.0 n=1 dur=0.00 hp=- tot=88 core=80 "
                      "heat=0.30 shut=0 heat_in=0.0"))
    lines.append(flow(42, "dmg_out", 42.0, "tgt=e1/tank wpn=autocannon amt=50.0 n=2 dur=0.30 thp=50 kill=0 est=0"))
    return "\n".join(lines) + "\n"


def main() -> int:
    fails = []

    def check(cond: bool, what: str):
        if not cond:
            fails.append(what)

    with tempfile.TemporaryDirectory() as d:
        dp = Path(d)
        a = dp / "new.log"
        a.write_text(new_log(), encoding="utf-8")
        b = dp / "old.log"
        b.write_text(old_log(), encoding="utf-8")
        check(pacing_report.main([str(a), "-o", str(dp / "new.html")]) == 0, "new log: exit 0")
        h = (dp / "new.html").read_text(encoding="utf-8")
        for s in ("Structure %", "Intensity", "Enemies", "Damage per 10 s", "Director state and events",
                  "Quiet stretches: time with nobody engaged", "quiet 40 s at 0:00", "quiet 32 s at 1:20",
                  "45 s cap", 'class="st-build"', 'class="st-peak"', 'class="m-release"', 'class="m-scout"',
                  'class="m-down"', 'class="m-depot"', "engaging", "in sight", "seeing the pilot", "deck 0", "mission",
                  "49 %", "&#10007; out", "Pilot bot -2", "Pilot peer 1", "&#10003; in", "20 % at 1:40", "14 s/20 s/20 s", "0.0+40.0, 80.0+32.0"):
            check(s in h, f"new log report contains {s!r}")
        check("http://" not in h and "https://" not in h, "no external URL")
        check("<script src" not in h and "<link" not in h, "no external files")
        check("{y:" not in h and "nan" not in h.lower().replace("nanos", ""), "no unfilled placeholder / nan")
        check(h.count('class="q-long"') >= 2, "both quiet stretches over 30 s drawn as long")
        check(pacing_report.main([str(b), "-o", str(dp / "old.html")]) == 0, "old log: exit 0")
        o = (dp / "old.html").read_text(encoding="utf-8")
        for s in ("Structure %", "Damage per 10 s", "estimate from combat activity", "No threat records",
                  "mission (estimate)"):
            check(s in o, f"old log report contains {s!r}")
        check("Intensity" not in o.split("<main>")[1].split("No threat records")[0], "old log: no intensity chart")
        # -Latest picks the newest mission log and skips test logs.
        logs = dp / "logs"
        logs.mkdir()
        (logs / "a_mission.log").write_text(new_log(), encoding="utf-8")
        import os, time
        t = time.time()
        os.utime(logs / "a_mission.log", (t - 100, t - 100))
        (logs / "b_test.log").write_text("Godot Engine\nRunning test: test_x\n" + new_log(), encoding="utf-8")
        check(pacing_report.latest_log(logs) == logs / "a_mission.log", "-Latest skips test logs")
        check(pacing_report.main(["-Latest", "--logs-dir", str(logs), "-o", str(dp / "latest.html")]) == 0, "-Latest runs")
    if fails:
        for f in fails:
            print("FAIL:", f)
        print(f"selftest: {len(fails)} failure(s)")
        return 1
    print("selftest: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
