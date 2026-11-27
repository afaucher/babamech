class_name LowPolyPalette
extends RefCounted
## The shared flat colours of the low-poly art (one colour per face, carried in vertex colours): the mechs, their weapons
## and equipment, and everything else built with MeshKit that matches them (combat effects, depots, occupation props,
## city accents, UI swatches). Cosmetic only (no gameplay state).

const WHITE := Color(0.97, 0.94, 0.86)
const ORANGE := Color(0.93, 0.46, 0.12)
const GREY := Color(0.45, 0.46, 0.47)
const DARK := Color(0.21, 0.22, 0.24)
const STEEL := Color(0.62, 0.62, 0.60)
const GUN := Color(0.31, 0.32, 0.34)
const BLACK := Color(0.07, 0.07, 0.08)
const AMBER := Color(1.0, 0.74, 0.22)
const TEAL := Color(0.25, 0.95, 0.85)
const MISSILE_RED := Color(0.8, 0.16, 0.13)
const TANK := Color(0.8, 0.24, 0.1)   ## the flamer fuel tanks
const REPAIR_GREEN := Color(0.25, 1.0, 0.45)   ## the repair drone's eye and pad lights (RepairDroneLook.GREEN, its beams)

## Player accent colours (cosmetic): the faces built in ORANGE go to each mesh's "accent" surface, which takes the colour
## through LowPolyMaterials.apply_accent / MechModel.set_accent. Heads never take the accent. Ids in display order in
## ACCENT_ORDER.
const ACCENTS := {
	"orange": ORANGE,
	"blue": Color(0.16, 0.42, 0.85),
	"green": Color(0.2, 0.62, 0.3),
	"red": Color(0.8, 0.16, 0.13),
	"yellow": Color(0.95, 0.78, 0.15),
	"purple": Color(0.5, 0.3, 0.75),
}
const ACCENT_ORDER := ["orange", "blue", "green", "red", "yellow", "purple"]
