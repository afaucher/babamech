class_name CityQuality
extends RefCounted
## How much of the city one machine draws (docs/design/city-ramps-and-stack.md section 8, "Quality levels"). STRICTLY
## local presentation: a level changes which meshes are drawn, how far, the lights and the environment's extras, never a
## plan, a checksum, a prop, a collision shape, a random draw, a life timetable or who can be hit. A LOW machine and a
## HIGH machine play the same game. Set with CityStack.set_quality(q) and AmbientLife.set_quality(q), at any time.
## HIGH is exactly the look the city had before levels existed.
##
## The levels themselves (GraphicsQuality.LOW / MEDIUM / HIGH = 0 / 1 / 2, their names, clamp_level) are GraphicsQuality's,
## the player's setting; this class holds what each level means for the city. One place for the numbers (LEVELS[q]):
##   decks_above / decks_below  decks drawn above / below the active one (-1: all); the rest are hidden (visible =
##                              false on the deck node: its collision, props simulation and life keep running)
##   sun_shadows                the daylight casts shadows (on the active deck only, as always)
##   shadow_splits / shadow_distance   the daylight's PSSM splits (2 or 4) and max distance (m)
##   sun_below                  the daylight also lights the drawn deck below (no shadows: a lower deck seen through a hole
##                              whose own fills are off)
##   fill_every                 keep every n-th fill light of the active deck (1 all, 2 half, 0 none)
##   other_fill_every           the same for the other drawn decks (0: off); fills of hidden decks are always off
##   ambient_add                added to the preset's ambient energy, times the preset's fill energy x the share of the
##                              active deck's fills switched off (keeps the picture as bright without them)
##   ssao / glow                the environment's screen-space extras
##   block_range                m: a building block mesh is hidden beyond this from the camera (0: never)
##   life_draw_r                m: civilians, vehicles and the tram are drawn within this of a viewer (AmbientLife.DRAW_R
##                              at HIGH; evaluation, hit tests and the host's decisions do not use it)

const LEVELS := [     ## indexed by GraphicsQuality.LOW / MEDIUM / HIGH
	{"decks_above": 0, "decks_below": 1, "sun_shadows": false, "shadow_splits": 2, "shadow_distance": 160.0,
			"sun_below": true, "fill_every": 0, "other_fill_every": 0, "ambient_add": 1.0, "ssao": false, "glow": false,
			"block_range": 230.0, "life_draw_r": 110.0},
	{"decks_above": 1, "decks_below": 1, "sun_shadows": true, "shadow_splits": 2, "shadow_distance": 220.0,
			"sun_below": false, "fill_every": 2, "other_fill_every": 2, "ambient_add": 0.5, "ssao": false, "glow": true,
			"block_range": 320.0, "life_draw_r": 160.0},
	{"decks_above": -1, "decks_below": -1, "sun_shadows": true, "shadow_splits": 4, "shadow_distance": 320.0,
			"sun_below": false, "fill_every": 1, "other_fill_every": 1, "ambient_add": 0.0, "ssao": true, "glow": true,
			"block_range": 0.0, "life_draw_r": 200.0},
]


static func level(q: int) -> Dictionary:
	return LEVELS[GraphicsQuality.clamp_level(q)]


## Whether deck k is drawn with deck `active` active at level q.
static func deck_drawn(q: int, k: int, active: int) -> bool:
	var lv := level(q)
	if k < active:
		return int(lv["decks_above"]) < 0 or active - k <= int(lv["decks_above"])
	if k > active:
		return int(lv["decks_below"]) < 0 or k - active <= int(lv["decks_below"])
	return true
