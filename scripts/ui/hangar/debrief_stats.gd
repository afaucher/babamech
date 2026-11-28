class_name DebriefStats
extends RefCounted
## The debrief board's model (playtest R2.15a, after bridge-to-friendship's M19 stat registry): the stats it knows, and
## the pure mapping from the host's debrief payload (NetMission DEBRIEF: {v, outcome, reason, time, pilots: [{id, name,
## bot}], stats: {"<id>": {key: number}}}) to the board's table. Nothing here touches the world, the HUD or the net.
##
## Adding a stat is ONE entry here (label, which end is good, format) plus the host's counter (Missions): no wire change,
## no board change. A key the host sends that is not registered still shows, as an extra row after these, labelled from
## its key, so a new counter is never silently dropped.
##
## Leaders: per row the best value (the entry's `best` end) is marked on every pilot who has it (ties all lead, as joint
## firsts). Not marked: a MOST row whose best is 0 ("most kills: 0" says nothing), a row the whole crew ties (nothing
## distinguishes anybody: a solo board marks nothing), and rows with best NONE (lowest HP is a story, not a score).
## Ranking stays apart from stats: the board never orders pilots by a stat, they keep their seat order.

const MOST := 0
const LEAST := 1
const NONE := 2

## Row order is the board's order. APPEND, DON'T REORDER. `hidden`: a counter other rows read, no row of its own.
const STATS := {
	"kills": {"label": "Kills", "best": MOST},
	"damage_dealt": {"label": "Damage dealt", "best": MOST},
	"damage_taken": {"label": "Damage taken", "best": LEAST},
	"shots": {"label": "Shots fired", "best": NONE, "hidden": true},
	"hits": {"label": "Accuracy", "best": MOST, "percent_of": "shots"},
	"revives": {"label": "Revives given", "best": MOST},
	"downs": {"label": "Times downed", "best": LEAST},
	"cores": {"label": "Depot cores", "best": MOST},
	"hp_min": {"label": "Lowest HP", "best": NONE, "format": "percent"},
}

const OUTCOME_TITLE := {"won": "MISSION COMPLETE", "lost": "MISSION FAILED"}


## A row's label: the registry's, else the payload's `labels` entry, else the key prettified.
static func label_of(key: String, labels: Dictionary = {}) -> String:
	if STATS.has(key):
		return str(STATS[key]["label"])
	if labels.get(key) is String and str(labels[key]) != "":
		return str(labels[key])
	return key.replace("_", " ").capitalize()


static func best_of(key: String) -> int:
	return int(STATS.get(key, {}).get("best", MOST))


## The board for a (cleaned) debrief payload:
##   {title, subtitle, columns: [{id, name, bot}], rows: [{key, label, cells: [String per column], lead: [bool per column]}]}
## Columns keep the payload's pilot order (seat order). A pilot missing from `stats` shows "-" everywhere.
static func table(d: Dictionary) -> Dictionary:
	var columns: Array = []
	for p: Variant in d.get("pilots", []):
		if p is Dictionary:
			var id := int((p as Dictionary).get("id", 0))
			var nm := str((p as Dictionary).get("name", ""))
			if nm == "":
				nm = ("Bot %d" % -id) if id < 0 else ("Pilot %d" % id)
			columns.append({"id": id, "name": nm, "bot": id < 0, "left": bool((p as Dictionary).get("left", false))})
	var stats: Dictionary = d.get("stats", {}) if d.get("stats") is Dictionary else {}
	var labels: Dictionary = d.get("labels", {}) if d.get("labels") is Dictionary else {}
	var keys: Array = []
	for k: String in STATS:
		if not bool(STATS[k].get("hidden", false)):
			keys.append(k)
	var extra: Array = []
	for c: Dictionary in columns:
		var row_c := _row_of(stats, int(c["id"]))
		for k: Variant in row_c:
			var v: Variant = row_c[k]
			if not STATS.has(str(k)) and not extra.has(str(k)) and (v is int or v is float):   # no dict / array rows
				extra.append(str(k))
	# Extra rows: in the payload's `labels` order (Missions sends them in reading order), then unlabelled keys A-Z.
	var unlabelled: Array = extra.filter(func(k: String) -> bool: return not labels.has(k))
	unlabelled.sort()
	for k: Variant in labels:
		if extra.has(str(k)):
			keys.append(str(k))
	keys.append_array(unlabelled)
	var rows: Array = []
	for k: String in keys:
		var vals: Array = []   # float per column, NAN = no value
		var cells: Array = []
		for c: Dictionary in columns:
			var row := _row_of(stats, int(c["id"]))
			var v := value_of(row, k)
			vals.append(v)
			cells.append(format_value(k, row))
		rows.append({"key": k, "label": label_of(k, labels), "cells": cells, "lead": leaders(vals, best_of(k))})
	return {"title": str(OUTCOME_TITLE.get(str(d.get("outcome", "")), "MISSION OVER")), "subtitle": subtitle(d),
		"columns": columns, "rows": rows}


## "Mission complete  -  12:34" (the reason, then the mission time; either may be missing).
static func subtitle(d: Dictionary) -> String:
	var parts: Array = []
	if str(d.get("reason", "")) != "":
		parts.append(str(d["reason"]))
	var t := float(d.get("time", 0.0))
	if t > 0.0:
		parts.append("Time %s" % clock(t))
	return "   ".join(parts)


static func clock(seconds: float) -> String:
	var s := maxi(roundi(seconds), 0)
	return "%d:%02d" % [s / 60, s % 60]


## The number a row compares: the stat, or for a percent_of row the ratio (NAN with no base: never fired is not 0 %).
static func value_of(row: Dictionary, key: String) -> float:
	var base := str(STATS.get(key, {}).get("percent_of", ""))
	if base != "":
		var n := _num(row, base)
		var h := _num(row, key)
		if is_nan(n) or n <= 0.0 or is_nan(h):
			return NAN
		return h / n
	return _num(row, key)


## A stat as a number; NAN when missing or not a number (a dict or array never renders).
static func _num(row: Dictionary, key: String) -> float:
	var v: Variant = row.get(key)
	return float(v) if (v is int or v is float) else NAN


## The cell text: "-" for no value; "--" for accuracy with no shots; integers without decimals; percents with "%".
static func format_value(key: String, row: Dictionary) -> String:
	var base := str(STATS.get(key, {}).get("percent_of", ""))
	if base != "":
		var v := value_of(row, key)
		return "--" if is_nan(v) else "%d%%" % roundi(v * 100.0)
	var f := _num(row, key)
	if is_nan(f):
		return "-"
	if str(STATS.get(key, {}).get("format", "")) == "percent":
		return "%d%%" % roundi(f)
	if is_equal_approx(f, roundf(f)) or absf(f) >= 100.0:
		return str(roundi(f))
	return "%.1f" % f


## Which columns lead a row (the rules in the header). `vals`: float per column, NAN = no value (never leads).
static func leaders(vals: Array, best: int) -> Array:
	var out: Array = []
	out.resize(vals.size())
	out.fill(false)
	if best == NONE:
		return out
	var have: Array = vals.filter(func(v: float) -> bool: return not is_nan(v))
	if have.size() < 2:
		return out   # one pilot (or one with a value) wins everything, which is to say nothing
	var top: float = have[0]
	for v: float in have:
		top = minf(top, v) if best == LEAST else maxf(top, v)
	if best == MOST and top <= 0.0:
		return out
	var n := 0
	for i in vals.size():
		if not is_nan(float(vals[i])) and is_equal_approx(float(vals[i]), top):
			out[i] = true
			n += 1
	if n >= have.size():
		out.fill(false)   # everyone with a value ties: nobody stands out
	return out


static func _row_of(stats: Dictionary, id: int) -> Dictionary:
	var r: Variant = stats.get(str(id), stats.get(id, {}))
	return r if r is Dictionary else {}


## A plausible debrief for `crew` ([{peer, name, ...}] as Session.crew() gives it; bots negative) so the board can be
## shown and tested before the host's counters exist (and by --menu-screen debrief). Deterministic per pilot id.
static func stub(crew: Array, outcome: String = "won") -> Dictionary:
	var pilots: Array = []
	var stats := {}
	for e: Variant in crew:
		if not (e is Dictionary):
			continue
		var id := int((e as Dictionary).get("peer", (e as Dictionary).get("id", 0)))
		if id == 0:
			continue
		pilots.append({"id": id, "name": str((e as Dictionary).get("name", "")), "bot": id < 0})
		var k := absi(id) % 7
		var shots := 180 + 37 * k
		stats[str(id)] = {"kills": 4 + (k * 3) % 9, "damage_dealt": 1200 + 310 * k, "damage_taken": 420 + 95 * ((k + 2) % 5),
			"shots": shots, "hits": int(shots * (0.35 + 0.06 * (k % 4))), "revives": k % 3, "downs": (k + 1) % 3,
			"cores": k % 2, "hp_min": 18 + 11 * ((k + 3) % 6)}
	return {"v": 1, "outcome": outcome, "reason": "Mission complete" if outcome == "won" else "Crew lost", "time": 754.0,
		"pilots": pilots, "stats": stats}
