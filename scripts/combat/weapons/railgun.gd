extends WeaponBehaviour
## Coil Railgun (weapons.md §3.8): hold to charge (stats.charge = 1 s, the telegraph: ChargeGlow grows in
## stats.charge_steps steps, the coils lighting one by one), the slug leaves the moment the charge completes (exact time
## at any frame step), then the 1 / rate = 4 s cycle (it includes the next charge, like the laser). Releasing before full
## charge cancels it and costs stats.cancel_heat (paid through WeaponMount.heat_due); a full shot costs active_heat
## (paid by WeaponMount when the cycle starts). The shot is a RailSlug (scripts/combat/rail_slug.gd): a straight 200 m/s
## scheduled effect that pierces up to stats.pierce targets losing stats.pierce_loss each. Per-mount state:
## WeaponMount.charge (OWNER). AMMO: stats.ammo rounds (18; 27 with the ammo bin), one spent when the slug leaves (the
## charge completing, WeaponMount's fire loop), never on a cancelled charge; at 0 no charge starts (tick) and the rack's
## UNUSABLE rule deselects the slot until a supply depot's core refills it (WeaponRack.refill_ammo).


func tick(m: WeaponMount, held: bool, dt: float) -> void:
	var need := float(m.stats.get("charge", 0.0))
	if m.ammo == 0:
		m.charge = 0.0      # dry (stats.ammo, 18): no charge starts, no glow, no cancel heat (the rack deselects it too)
		return
	if not held:
		if m.charge > 0.0 and m.charge < need:
			m.heat_due += float(m.stats.get("cancel_heat", 0.0))    # an early release cancels, and still heats
		m.charge = 0.0
		return
	if m.cooldown > 0.0 or m.charge >= need:
		return
	# Count only the part of this step since the weapon was ready (cooldown crossed zero mid-step).
	m.charge += dt if m.cooldown >= 0.0 else minf(-m.cooldown, dt)
	if m.charge >= need:
		m.cooldown = -(m.charge - need)    # the slug leaves the moment the charge completed (frame-rate independent)


func wants_fire(m: WeaponMount, held: bool) -> bool:
	return held and m.charge >= float(m.stats.get("charge", 0.0))


func spread(_m: WeaponMount) -> float:
	return 0.0


func on_shot(m: WeaponMount) -> void:
	m.charge = 0.0
	m.cooldown -= float(m.stats.get("charge", 0.0))    # the next charge is part of the 1 / rate cycle


func look() -> Dictionary:
	return {"color": LowPolyPalette.TEAL, "trail_color": LowPolyPalette.TEAL, "width": 0.3, "glow": true}


func spawn(world: CombatWorld, record: Dictionary, st: Dictionary) -> CombatEffect:
	var p := RailSlug.new()
	p.look = look()
	p.start(world, record, st)
	return p


func prewarm(st: Dictionary) -> void:
	RailSlug.prewarm_slug(look(), st)
