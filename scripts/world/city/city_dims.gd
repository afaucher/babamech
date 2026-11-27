class_name CityDims
extends RefCounted
## The city's GAMEPLAY dimensions that the plans (CityPlan, which is checksummed; LifePlan; LifeTraffic; CityGraphs) and
## the meshers (CityStreets, CityWalls, CityBuildings) share: what a mech walks round and what a cut is snapped to. The
## meshers draw with these numbers and the plans keep things clear by them, so both read them here and a plan never
## reaches into a mesh builder. Plain constants and pure functions: no state, no randomness.

const EDGE := 1.6            ## a block's curb + furnishing band (the sidewalk's outer strip)
const HOLE_CURB := 0.5       ## curb round a floor hole: this wide and this high, solid

# --- Ceiling grid (docs/design/ceiling-and-pillars.md) -----------------------------------------------------------
# The underside of the deck above is a regular grid: girders along the arc every GIRDER_PITCH, ribs across every
# RIB_PITCH, panels of half a bay each way. An opening in the deck above is cut back to whole panels (ceiling_opening).
const RIB_PITCH := 24.0
const GIRDER_PITCH := 14.0
const PANEL_X := GIRDER_PITCH * 0.5
const PANEL_S := RIB_PITCH * 0.5
const DROP_PANEL := 5.0      ## how far a pillar's drop panel reaches past its core
const RIM := 1.6             ## width of the beam around an opening


## An opening snapped outward to whole ceiling panels: what is actually cut.
static func ceiling_opening(o: Rect2) -> Rect2:
	var x0 := floorf(o.position.x / PANEL_X) * PANEL_X
	var s0 := floorf(o.position.y / PANEL_S) * PANEL_S
	return Rect2(x0, s0, ceilf(o.end.x / PANEL_X) * PANEL_X - x0, ceilf(o.end.y / PANEL_S) * PANEL_S - s0)
