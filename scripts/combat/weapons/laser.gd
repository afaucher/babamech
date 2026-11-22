extends WeaponBehaviour
## Side Laser (weapons.md §3.1): hold to charge (stats.charge s, the telegraph), then a pulse: one hitscan ray from the
## hardpoint along the fire record's direction, resolved ONCE at beam start (a scheduled effect: every machine computes
## the same ray from the record; only the deciding machine applies the hit, through CombatWorld.resolve_hit), then a
## teal Beam that shows for stats.beam_time: a fat faceted lance, stats.size wide at the muzzle growing × growth by
## growth_full m (0.35 m -> 1.0 m at 150 m). When the firer registered a live muzzle (CombatWorld.set_muzzle) the beam's
## start follows it for its life (cosmetic: the ray was resolved at pulse start). Damage × falloff, Δv stats.knockback
## along the ray (a city prop on the ray takes it through its verb), impact R with a teal flash and molten orange shards.
## The charge telegraph is ChargeGlow, drawn by whoever draws the mount. The cycle (1 / rate) includes the charge: charge starts interval - charge after a
## pulse, so a held trigger pulses every 1 / rate s. Per-mount state: WeaponMount.charge (OWNER).

const FLASH_COLOR := Color(0.55, 0.95, 0.92)   ## the impact's flash ball: teal, a touch pale
const RAY_RADIUS := 0.15          ## m: the ray's hit thickness against target spheres (never against world geometry)


func tick(m: WeaponMount, held: bool, dt: float) -> void:
	var need := float(m.stats.get("charge", 0.0))
	if not held:
		m.charge = 0.0          # releasing early cancels the charge
		return
	if m.cooldown > 0.0 or m.charge >= need:
		return
	# Count only the part of this step since the weapon was ready (cooldown crossed zero mid-step).
	m.charge += dt if m.cooldown >= 0.0 else minf(-m.cooldown, dt)
	if m.charge >= need:
		m.cooldown = -(m.charge - need)    # the pulse leaves the moment the charge completed (frame-rate independent)


func wants_fire(m: WeaponMount, held: bool) -> bool:
	return held and m.charge >= float(m.stats.get("charge", 0.0))


func spread(_m: WeaponMount) -> float:
	return 0.0


func on_shot(m: WeaponMount) -> void:
	m.charge = 0.0
	m.cooldown -= float(m.stats.get("charge", 0.0))    # the next charge is part of the 1 / rate cycle


func look() -> Dictionary:
	return {"color": MechMeshes.TEAL, "trail_color": MechMeshes.TEAL, "width": 0.2}


## The beam's look for these stats: width size -> size × growth at growth_full m.
static func beam_look(st: Dictionary) -> Dictionary:
	var w0 := float(st.get("size", 0.35))
	return {"core": MechMeshes.TEAL, "sides": 6, "w0": w0, "w1": w0 * float(st.get("growth", 2.86)),
		"w_full": float(st.get("growth_full", 150.0)), "core_share": 0.6, "pulse": 0.18, "pulse_hz": 11.0, "spin": 90.0}


## The ray of one pulse, a pure function of the record + seed + the world's targets / geometry:
## {from, to, dir, hit (CombatWorld.first_hit result or {})}.
static func trace(world: CombatWorld, record: Dictionary, st: Dictionary) -> Dictionary:
	var from: Vector3 = record["origin"]
	var dir: Vector3 = record["dir"]
	if float(record.get("spread", 0.0)) > 0.0:
		var rng := Combat.shot_rng(world.mission_seed, str(record["shooter"]), str(record["hardpoint"]), int(record["shot_index"]))
		dir = Combat.spread_dir(dir, float(record["spread"]), rng)
	dir = dir.normalized()
	var to := from + dir * float(st.get("range", 150.0))
	var h := world.first_hit(from, to, RAY_RADIUS, str(record.get("shooter", "")))
	if not h.is_empty():
		to = h["point"]
	return {"from": from, "to": to, "dir": dir, "hit": h}


func spawn(world: CombatWorld, record: Dictionary, st: Dictionary) -> CombatEffect:
	var r := trace(world, record, st)
	world.life_sweep(record, r["from"], r["to"], RAY_RADIUS)     # ambient life: the ray, once per pulse (as the hit)
	var h: Dictionary = r["hit"]
	if not h.is_empty():
		var target: CombatTarget = h["target"]
		var from: Vector3 = r["from"]
		if target != null:
			world.resolve_hit(record, st, target, str(h["component"]), h["point"], h["normal"], r["dir"],
				float(st.get("damage", 0.0)) * Combat.falloff(st, from.distance_to(h["point"])))
		world.hit_prop(record, st, h, r["dir"])
		world.spawn_impact(h["point"], h["normal"], float(st.get("impact_radius", 2.0)), MechMeshes.ORANGE, false, FLASH_COLOR)
	var b := Beam.new()
	b.look = beam_look(st)
	b.start(world, record, st)
	b.life = float(st.get("beam_time", 0.3))
	b.set_points(r["from"], r["to"])
	b.follow = world.muzzle_of(record)
	return b
