class_name PilotTrack
extends RefCounted
## One pilot the combat log writes `threat` / `los` records for (CombatLog): the local pilot on every machine, plus the
## host's hangar bots (CrewBot: host-owned pilots, negative pilot ids, `bot=1`). Holds that pilot's intensity, which
## enemies engaged it, its p>e line-of-sight results and its share of the ray budget (LOS_RAYS a second each).
## Logging only: every var LOCAL.

var target: Variant = null        ## its PlayerTarget (Variant: may be freed under us; read through valid())
var mech: Variant = null          ## its MechController, or null: the target's own position (Variant, may be freed)
var peer := 1                     ## pilot id (the local peer, or a bot's negative id)
var bot := false
var intensity := PilotIntensity.new()
var eng_e: Dictionary = {}        ## enemy instance id -> mt it last engaged this pilot
var pe: Dictionary = {}           ## enemy instance id -> [in sight, mt of the ray]
var ray_q: Array = []             ## enemies to cast this second's rays at
var ray_i := 0
var rays_sec := 0
var cands: Array = []             ## [dist, enemy] nearest awake enemies within range (last threat tick)
var i_src := "local"
var host_i := 0.0                 ## its intensity in mission state (src=host)


func net_fields() -> Dictionary:
	var f := {}
	for v: String in ["target", "mech", "peer", "bot", "intensity", "eng_e", "pe", "ray_q", "ray_i", "rays_sec", "cands", "i_src",
			"host_i"]:
		f[v] = Net.LOCAL
	return f


func id() -> String:
	return (target as PlayerTarget).target_id if valid() else ""


## The pilot's PlayerTarget, or null once it is freed (never casts a freed object).
func pt() -> PlayerTarget:
	return target as PlayerTarget if valid() else null


func pos() -> Vector3:
	var v: Variant = mech if is_instance_valid(mech) and mech is Node3D else (target if valid() else null)
	if v == null:
		return Vector3.ZERO
	var n := v as Node3D
	return n.global_position if n.is_inside_tree() else n.position


func valid() -> bool:
	return is_instance_valid(target) and target is PlayerTarget


## The pilot's MechController, where its heat and shutdown live (the same source as the local pilot's
## CombatLog._heat / _shut): the one its target is bound to, else the track's own `mech`; null when neither is a live
## controller. A bound PlayerTarget's own `heat` gauge is never ticked (PlayerTarget.apply_heat forwards to the mech), so
## reading it for a bot logged heat 0 forever. Never casts a freed object.
func controller() -> MechController:
	if valid():
		var m: Variant = (target as PlayerTarget).mech
		if is_instance_valid(m) and m is MechController:
			return m as MechController
	if is_instance_valid(mech) and mech is MechController:
		return mech as MechController
	return null


## Heat 0..1 of the pilot's mech (its controller's gauge; the target's own gauge only without a controller).
func heat_frac() -> float:
	var m := controller()
	if m != null:
		return m.heat / maxf(m.heat_cap, 0.001)
	return (target as PlayerTarget).heat.fraction() if valid() and (target as PlayerTarget).heat != null else 0.0


func shutdown() -> bool:
	var m := controller()
	if m != null:
		return m.shutdown
	return valid() and (target as PlayerTarget).heat != null and (target as PlayerTarget).heat.shutdown


## The printed intensity: the host director's when mission state has it, else this machine's computation.
func shown_intensity() -> float:
	return host_i if i_src == "host" else intensity.value
