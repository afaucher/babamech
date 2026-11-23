class_name EnemyTelegraphFx
extends Node3D
## Diegetic-only enemy weapon & signal visuals (docs/design/enemies.md §2, §4):
##   - Spinning faceted muzzle charge orb during attack telegraphs (>= 0.3 s).
##   - Scout Drone physical Alert Beacon flare + expanding broadcast ring while calling support.
##   - Dropship ventral bay glow inside the open bay (no floating ground UI ring).
##   - Physical rising signal flare (ember + trailing smoke puffs launched periodically) when a straggler reveals.
##   - No non-diegetic targeting lasers, comms relay rings, or floating UI pillars/halos.
## Purely cosmetic (all Net.LOCAL).

const SPIN := 9.0
const FLARE_INTERVAL := 5.0       ## s between physical signal flares launched by a revealed straggler
const FLARE_LIFE := 2.4           ## s each physical signal flare rises and fades
const FLARE_SPEED := 15.0         ## m/s initial upward launch velocity
const FLARE_PUFFS := 3            ## trailing faceted smoke puffs behind each rising flare

var _t := 0.0
var _shell: MeshInstance3D
var _core: MeshInstance3D
var _beacon_ring: MeshInstance3D  ## physical Alert Beacon broadcast ring (Scout Drone only)
var _flare_ember: MeshInstance3D  ## physical rising distress/signal flare ember for revealed stragglers
var _flare_puffs: Array[MeshInstance3D] = []
var _flare_cycle := -1.0          ## s into current FLARE_INTERVAL cycle (< 0 = inactive)
var _flare_origin := Vector3.ZERO
var _flare_up := Vector3.UP


func net_fields() -> Dictionary:
	return {"_t": Net.LOCAL, "_shell": Net.LOCAL, "_core": Net.LOCAL, "_beacon_ring": Net.LOCAL,
		"_flare_ember": Net.LOCAL, "_flare_puffs": Net.LOCAL, "_flare_cycle": Net.LOCAL,
		"_flare_origin": Net.LOCAL, "_flare_up": Net.LOCAL}


func _init() -> void:
	top_level = true
	_shell = CombatMeshes.instance(CombatMeshes.ico(EnemyMeshes.OPTIC_GLOW, true))
	add_child(_shell)
	_core = CombatMeshes.instance(CombatMeshes.ico(Color(1.0, 0.88, 0.48), true))
	add_child(_core)
	_beacon_ring = CombatMeshes.instance(CombatMeshes.ring(EnemyMeshes.OPTIC_GLOW, 0.86, 18))
	add_child(_beacon_ring)
	_flare_ember = CombatMeshes.instance(CombatMeshes.ico(Color(1.0, 0.78, 0.24), true))
	add_child(_flare_ember)
	for _i in FLARE_PUFFS:
		var p := CombatMeshes.instance(CombatMeshes.ico(Color(0.55, 0.52, 0.50), false))
		add_child(p)
		_flare_puffs.append(p)
	hide_telegraph()
	hide_reveal_flare()


func hide_telegraph() -> void:
	_shell.visible = false
	_core.visible = false
	_beacon_ring.visible = false


func hide_reveal_flare() -> void:
	_flare_cycle = -1.0
	if _flare_ember != null:
		_flare_ember.visible = false
	for p in _flare_puffs:
		if p != null:
			p.visible = false


## Diegetic last-enemy reveal: periodically launches a physical rising signal flare + smoke puffs from the unit itself.
func show_reveal_flare(eye: Vector3, up: Vector3, dt: float) -> void:
	_t += dt
	if not is_inside_tree():
		hide_reveal_flare()
		return
	if _flare_cycle < 0.0:
		_flare_cycle = 0.0
		_flare_origin = eye
		_flare_up = up.normalized() if up.length_squared() > 1e-6 else Vector3.UP
	else:
		_flare_cycle += dt
		if _flare_cycle >= FLARE_INTERVAL:
			_flare_cycle = fmod(_flare_cycle, FLARE_INTERVAL)
			_flare_origin = eye
			_flare_up = up.normalized() if up.length_squared() > 1e-6 else Vector3.UP
	if _flare_cycle > FLARE_LIFE:
		_flare_ember.visible = false
		for p in _flare_puffs:
			p.visible = false
		return
	var age := _flare_cycle
	var u := clampf(age / FLARE_LIFE, 0.0, 1.0)
	# Ballistic rise with gentle air drag: h(t) = v0 * t - 2.6 * t^2
	var h := maxf(FLARE_SPEED * age - 2.6 * age * age, 0.2)
	var pos := _flare_origin + _flare_up * h
	var ember_r := lerpf(0.42, 0.14, u) * (0.9 + 0.2 * sin(_t * 36.0))
	_flare_ember.visible = true
	_flare_ember.global_transform = Transform3D(Basis(Vector3(0.3, 1.0, 0.2).normalized(), _t * SPIN) * Basis.from_scale(Vector3.ONE * ember_r), pos)
	for i in _flare_puffs.size():
		var lag := float(i + 1) * 0.28
		var p_age := age - lag
		var p := _flare_puffs[i]
		if p_age <= 0.0:
			p.visible = false
			continue
		var pu := clampf(p_age / FLARE_LIFE, 0.0, 1.0)
		var ph := maxf(FLARE_SPEED * p_age - 2.6 * p_age * p_age, 0.2)
		var pr := lerpf(0.28, 0.95, pu) * (1.0 - pu * 0.35)
		p.visible = true
		p.global_transform = Transform3D(Basis(Vector3.UP, _t + float(i)) * Basis.from_scale(Vector3.ONE * pr), _flare_origin + _flare_up * ph)


## Non-diegetic comms relay rings are disabled (Scout Drone's physical Alert Beacon uses show_beacon_flare).
func trigger_relay_ring(_at: Vector3, _up: Vector3 = Vector3.UP) -> void:
	pass


## Diegetic weapon muzzle charge orb during attack telegraphs (>= 0.3 s). `frac` 0..1 (<= 0 hides).
func show_telegraph(muzzle: Vector3, _aim: Vector3, frac: float, _locked: bool, max_radius: float,
		_show_beam: bool, dt: float) -> void:
	_t += dt
	if frac <= 0.0 or not is_inside_tree():
		hide_telegraph()
		return
	var f := clampf(frac, 0.0, 1.0)
	var r := lerpf(max_radius * 0.22, max_radius, f) * (1.0 + 0.16 * sin(_t * 68.0))
	_shell.visible = true
	_core.visible = true
	_beacon_ring.visible = false
	_shell.global_transform = Transform3D(Basis(Vector3(0.3, 1.0, 0.2).normalized(), _t * SPIN) * Basis.from_scale(Vector3.ONE * r), muzzle)
	var core_r := r * lerpf(0.55, 0.96, f)
	_core.global_transform = Transform3D(Basis(Vector3(1.0, 0.2, 0.4).normalized(), -_t * SPIN * 1.4) * Basis.from_scale(Vector3.ONE * core_r), muzzle)


## Diegetic Scout Drone Alert Beacon flare + expanding broadcast ring while actively calling for support.
func show_beacon_flare(at: Vector3, up: Vector3, frac: float, dt: float) -> void:
	_t += dt
	if frac <= 0.0 or not is_inside_tree():
		hide_telegraph()
		return
	var f := clampf(frac, 0.0, 1.0)
	var pulse := 1.0 + 0.24 * sin(_t * 48.0)
	var r := lerpf(0.55, 1.45, f) * pulse
	_shell.visible = true
	_core.visible = true
	_shell.global_transform = Transform3D(Basis(Vector3(0.2, 1.0, 0.3).normalized(), _t * SPIN * 1.4) * Basis.from_scale(Vector3.ONE * r), at)
	_core.global_transform = Transform3D(Basis(Vector3(1.0, 0.3, 0.2).normalized(), -_t * SPIN * 1.8) * Basis.from_scale(Vector3.ONE * r * 0.85), at)
	var u_up := up.normalized() if up.length_squared() > 1e-6 else Vector3.UP
	var fwd := Vector3.FORWARD if absf(u_up.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := fwd.cross(u_up).normalized()
	var b := Basis(x, u_up, x.cross(u_up).normalized())
	var rad := lerpf(1.6, 5.8, f) * (0.92 + 0.14 * sin(_t * 36.0))
	_beacon_ring.visible = true
	_beacon_ring.global_transform = Transform3D(b * Basis.from_scale(Vector3.ONE * rad), at)


## Diegetic ventral bay glow inside EnemyDropDrone's open bay (floating ground UI ring removed).
func show_drop_ring(bay_pos: Vector3, _drop_pos: Vector3, _up: Vector3, frac: float, dt: float) -> void:
	_t += dt
	_beacon_ring.visible = false
	if frac <= 0.0 or not is_inside_tree():
		hide_telegraph()
		return
	var f := clampf(frac, 0.0, 1.0)
	var pulse := 1.0 + 0.18 * sin(_t * 42.0)
	var r := lerpf(0.55, 1.25, f) * pulse
	_shell.visible = true
	_core.visible = true
	_shell.global_transform = Transform3D(Basis(Vector3(0.2, 1.0, 0.2).normalized(), _t * SPIN) * Basis.from_scale(Vector3.ONE * r), bay_pos)
	_core.global_transform = Transform3D(Basis(Vector3(1.0, 0.2, 0.3).normalized(), -_t * SPIN * 1.4) * Basis.from_scale(Vector3.ONE * r * 0.8), bay_pos)


func tick_only(dt: float) -> void:
	_t += dt
