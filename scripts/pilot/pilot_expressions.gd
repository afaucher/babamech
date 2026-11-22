class_name PilotExpressions
extends RefCounted
## The expression tables of docs/design/pilot-heads.md section 3, as pure data: the face channels, the moods (standing
## states, one absolute row of channel values each) and the reactions (one-shots: an additive channel row with an attack /
## hold / release envelope, plus neck poses and kicks). Every head has every expression by construction, because each head
## maps channels to its own pieces (PilotFace); a head may override a row where its anatomy needs it (PilotFace.overrides).
##
## Channel ranges: see CHANNELS. Signs: brow_raise + = up; brow_anger + = inner ends down (angry), - = inner ends up
## (worried); brow_skew + = left brow up and right brow down (the lids follow it, PilotFace.lid_skew_gain); lid 0 = open,
## 1 = shut; pupil_size - = pin-prick, + = big; gaze_x + = toward the head's right (+X), gaze_y + = up; jaw 0 = shut,
## 1 = wide open; mouth_curve + = corners / beak up (smirk), - = down (grim); flair - = dropped, + = raised; flush - = pale,
## + = red; tremble 0..1.
##
## Neck poses (MOOD_POSE, a reaction's "pose" and "kick") are in degrees (pitch + = nose up / head back, yaw + = to the
## head's left, roll + = top of the head toward its left, -X), metres for "sink" (+ = down into the hatch) and "push"
## (+ = forward), a fraction for "squash" (+ = skull shorter), degrees for "flair_back" (+ = flair swept back). Kicks are
## angular velocities in degrees per second, added once when the reaction starts.
## Cosmetic only (Net.LOCAL): nothing here is synced or read by gameplay.

## channel -> [min, max, neutral].
const CHANNELS := {
	"brow_raise": [-1.0, 1.0, 0.0], "brow_anger": [-1.0, 1.0, 0.0], "brow_skew": [-1.0, 1.0, 0.0],
	"lid": [0.0, 1.0, 0.0], "pupil_size": [-1.0, 1.0, 0.0], "gaze_x": [-1.0, 1.0, 0.0], "gaze_y": [-1.0, 1.0, 0.0],
	"jaw": [0.0, 1.0, 0.0], "mouth_curve": [-1.0, 1.0, 0.0], "flair": [-1.0, 1.0, 0.0], "flush": [-1.0, 1.0, 0.0],
	"tremble": [0.0, 1.0, 0.0],
}
const CHANNEL_ORDER: Array[String] = ["brow_raise", "brow_anger", "brow_skew", "lid", "pupil_size", "gaze_x", "gaze_y",
	"jaw", "mouth_curve", "flair", "flush", "tremble"]

## Mood priority, highest first (PilotHead picks the first whose condition holds; stern is the floor).
const MOOD_ORDER: Array[String] = ["dazed", "afraid", "overheated", "strained", "focused", "stern"]
## Seconds for a mood cross-fade.
const MOOD_FADE := 0.25

## Absolute channel rows; a missing channel is its neutral value. Stern is the floor: brows low and angled in, lids 35 %
## down, mouth shut.
const MOODS := {
	"stern": {"brow_raise": -0.3, "brow_anger": 0.7, "lid": 0.35, "mouth_curve": -0.2},
	"focused": {"brow_raise": -0.5, "brow_anger": 0.85, "lid": 0.55, "pupil_size": -0.45, "mouth_curve": -0.3},
	"strained": {"brow_raise": -0.3, "brow_anger": 0.8, "lid": 0.45, "jaw": 0.15, "mouth_curve": -0.45, "flair": -0.25,
		"flush": 0.4},
	"overheated": {"brow_raise": -0.1, "brow_anger": 0.4, "lid": 0.65, "jaw": 0.45, "mouth_curve": -0.3, "flair": -0.65,
		"flush": 1.0},
	"afraid": {"brow_raise": 0.8, "brow_anger": -0.9, "lid": 0.0, "pupil_size": -0.85, "mouth_curve": -0.5, "flair": 0.8,
		"flush": -0.6, "tremble": 1.0},
	"dazed": {"brow_raise": 0.1, "brow_anger": -0.25, "brow_skew": 0.45, "lid": 0.5, "pupil_size": 0.6, "jaw": 0.25,
		"mouth_curve": -0.1, "flair": -1.0},
}

## Standing neck pose per mood (units in the header) and its procedural motion: "sway" degrees of slow roll / yaw at
## "sway_hz"; "pant_hz" / "pant_jaw" / "pant_nod" (overheated); "twitch" (strained: one brow twitching, as brow_skew);
## "drift" (dazed: pupils circling in opposite directions, gaze units); "dart" (afraid: fast darting glances, 0..1).
const MOOD_POSE := {
	"stern": {},
	"focused": {"pitch": -6.0, "push": 0.06, "flair_back": 20.0},
	"strained": {"sway": 2.5, "sway_hz": 0.5, "twitch": 0.35},
	"overheated": {"pitch": -12.0, "sink": 0.05, "pant_hz": 3.0, "pant_jaw": 0.25, "pant_nod": 2.5},
	"afraid": {"pitch": -4.0, "sink": 0.12, "dart": 1.0},
	"dazed": {"pitch": -10.0, "roll": 16.0, "sink": 0.04, "sway": 6.0, "sway_hz": 0.35, "drift": 0.6},
}

## Reactions: "a" / "h" / "r" = attack / hold / release seconds; "ch" = additive channel row at full strength; "pose" =
## neck pose offsets (scaled by the envelope); "kick" = {pitch, yaw, roll, flair, squash} velocity impulses at the start.
## Extras: "held" (stays at the peak while the driver holds it: effort), "shake" ({hz, deg, from, to}: yaw oscillation),
## "blinks" (times in seconds at which a blink fires), "fx" (an effect cue, see PilotHead.FX_KINDS, with "fx_min" the
## strength it needs), "look" (turns toward the reaction's direction, if it has one).
const REACTIONS := {
	"flinch": {"a": 0.08, "h": 0.1, "r": 0.35,
		"ch": {"lid": 0.9, "brow_raise": -0.5, "brow_anger": 0.3, "jaw": -0.3, "mouth_curve": -0.3},
		"pose": {"pitch": 8.0, "away": 22.0, "away_roll": 8.0}, "kick": {"flair": 120.0},
		"fx": "flash", "fx_min": 0.6},
	"pain": {"a": 0.1, "h": 0.5, "r": 0.6,
		"ch": {"jaw": 0.9, "brow_skew": 1.0, "brow_anger": -0.3, "brow_raise": 0.1, "lid": 0.15, "pupil_size": 0.3,
			"flush": 0.3},
		"pose": {"pitch": 18.0}, "kick": {"pitch": 160.0, "flair": 260.0}, "fx": "chips", "fx_min": 0.0},
	"effort": {"a": 0.15, "h": 0.4, "r": 0.3, "held": true,
		"ch": {"lid": 0.35, "jaw": -0.2, "mouth_curve": -0.6, "brow_raise": -0.3, "brow_anger": 0.2, "flush": 0.15},
		"pose": {"pitch": -10.0, "push": 0.05, "flair_back": 30.0}},
	"impact": {"a": 0.05, "h": 0.08, "r": 0.4,
		"ch": {"lid": 0.8, "jaw": 0.4},
		"pose": {"pitch": -6.0, "squash": 0.15, "sink": 0.04}, "kick": {"pitch": -90.0, "flair": -150.0, "squash": 2.0}},
	"smirk": {"a": 0.15, "h": 0.9, "r": 0.4,
		"ch": {"brow_skew": 0.7, "brow_raise": 0.1, "lid": 0.15, "mouth_curve": 0.7},
		"pose": {"pitch": 6.0}, "kick": {"pitch": 120.0, "flair": 90.0}},
	"revived": {"a": 0.05, "h": 0.5, "r": 0.65,
		"ch": {"lid": -0.35, "pupil_size": 0.4, "brow_raise": 0.6, "brow_anger": -0.5, "flair": 0.5},
		"shake": {"hz": 3.3, "deg": 22.0, "from": 0.05, "to": 0.656}, "blinks": [0.12, 0.32], "kick": {"flair": 200.0},
		"fx": "stars", "fx_min": 0.0, "fx_strength": 0.0},
	"alert": {"a": 0.1, "h": 0.4, "r": 0.3,
		"ch": {"brow_raise": 0.8, "brow_anger": -0.5, "lid": -0.25, "flair": 0.8},
		"pose": {"pitch": 4.0}, "kick": {"flair": 120.0}, "look": true},
	"blink": {"a": 0.04, "h": 0.03, "r": 0.06, "ch": {"lid": 1.0}},
}
const REACTION_ORDER: Array[String] = ["flinch", "pain", "effort", "impact", "smirk", "revived", "alert", "blink"]


## A full channel row for a mood (every channel present), with a head's overrides ({"moods": {id: {channel: v}}}) merged.
static func mood_row(id: String, overrides: Dictionary = {}) -> Dictionary:
	var src: Dictionary = MOODS.get(id, MOODS["stern"])
	var over: Dictionary = (overrides.get("moods", {}) as Dictionary).get(id, {})
	var out := {}
	for c: String in CHANNEL_ORDER:
		out[c] = float(over.get(c, src.get(c, CHANNELS[c][2])))
	return out


## A mood's pose / motion params, overrides ({"poses": {id: {...}}}) merged key by key.
static func mood_pose(id: String, overrides: Dictionary = {}) -> Dictionary:
	var out: Dictionary = (MOOD_POSE.get(id, {}) as Dictionary).duplicate()
	out.merge((overrides.get("poses", {}) as Dictionary).get(id, {}), true)
	return out


## A reaction's data, overrides ({"reactions": {id: {...}}}) merged: top-level keys replace, "ch" merges per channel.
static func reaction(id: String, overrides: Dictionary = {}) -> Dictionary:
	var out: Dictionary = (REACTIONS.get(id, REACTIONS["blink"]) as Dictionary).duplicate(true)
	var over: Dictionary = (overrides.get("reactions", {}) as Dictionary).get(id, {})
	for k: String in over:
		if k == "ch":
			(out["ch"] as Dictionary).merge(over["ch"], true)
		else:
			out[k] = over[k]
	return out


static func duration(r: Dictionary) -> float:
	return float(r["a"]) + float(r["h"]) + float(r["r"])


## 0 -> 1 over the attack, 1 through the hold, back to 0 over the release (smoothstep ramps).
static func envelope(t: float, a: float, h: float, r: float) -> float:
	if t < 0.0:
		return 0.0
	if t < a:
		return smoothstep(0.0, a, t)
	if t < a + h:
		return 1.0
	if t < a + h + r:
		return 1.0 - smoothstep(a + h, a + h + r, t)
	return 0.0


static func clamp_channel(c: String, v: float) -> float:
	var r: Array = CHANNELS[c]
	return clampf(v, r[0], r[1])
