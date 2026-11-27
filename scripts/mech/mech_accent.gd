class_name MechAccent
extends RefCounted
## The player's accent colour as an id (Settings -> Accent; saved in GameSettings, carried in the crew handshake like the
## head). The palette and the recolouring belong to the mech art: LowPolyPalette.ACCENTS / ACCENT_ORDER (id -> Color) and
## MechModel.set_accent (tints each low-poly mesh's "accent" surface; orange = the baked default). This file is the thin
## layer the menus, settings and network use: ids (validated), display names, and apply(model, id).
## Cosmetic only. Ids, not colours, travel on the network and in the settings file.

const DEFAULT := "orange"
const ORDER := LowPolyPalette.ACCENT_ORDER
const NAMES := {"orange": "Safety orange", "blue": "Cobalt", "green": "Field green", "red": "Signal red",
	"yellow": "Hazard yellow", "purple": "Violet"}


static func sanitize(id: String) -> String:
	return id if LowPolyPalette.ACCENTS.has(id) else DEFAULT


static func color(id: String) -> Color:
	return LowPolyPalette.ACCENTS[sanitize(id)]


static func display_name(id: String) -> String:
	id = sanitize(id)
	return str(NAMES.get(id, id.capitalize()))


## Put accent `id` on a mech model.
static func apply(model: Node, id: String) -> void:
	if model is MechModel:
		(model as MechModel).set_accent(color(id))
	elif model != null:
		LowPolyMaterials.apply_accent(model, color(id))


## The accent id a model shows ("" when it isn't a MechModel or its colour isn't in the palette). For tests.
static func applied(model: Node) -> String:
	if not (model is MechModel):
		return ""
	for id: String in ORDER:
		if color(id).is_equal_approx((model as MechModel).accent):
			return id
	return ""
