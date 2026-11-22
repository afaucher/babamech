extends WeaponBehaviour
## Rotary Gatling (weapons.md §3.3): the close-range hose. 12 small darts a second after a 0.6 s spin-up, a cone that
## blooms from 1.2° to 4.0° while the trigger is held (so at range most of a held stream misses), recovering when it
## stops. Every number is MechCatalog.WEAPONS["gatling"] (spin_up, spin_hold, spread, spread_max, bloom, bloom_recover).
##
## SPIN lives in WeaponMount.spin (OWNER state of the shooter), on one number in 0..2:
##   0..1   barrel speed share: climbs 1/spin_up per s while held, falls at the same rate once the hold has run out;
##          the gun fires only at 1 or above
##   1..2   at full speed, with (spin - 1) × spin_hold s of hold left: held = 2; released, it counts down to 1 over
##          spin_hold s, so a re-press inside the hold fires at once
## BLOOM lives in WeaponMount.bloom: extra degrees over the base spread, +bloom per round up to spread_max, recovering
## bloom_recover °/s whenever the gun is not firing (released, or still spinning up).
## The spread in force goes out in each fire record (record.spread); the round's deviation is drawn from the shot
## generator by Projectile.start, so remote machines never need the shooter's bloom or spin.

const DART_COLOR: Color = LowPolyFlame.CORE     ## yellow-white (the one flame palette)


func tick(mount: WeaponMount, held: bool, dt: float) -> void:
	var st := mount.stats
	var up := float(st.get("spin_up", 0.0))
	var hold := float(st.get("spin_hold", 0.0))
	if held:
		if mount.spin < 1.0:
			if up <= 0.0:
				mount.spin = 2.0
			else:
				var s := mount.spin + dt / up
				if s >= 1.0:
					# Ready mid-step: the first round leaves at the exact moment the barrels reach speed (it is due
					# `overshoot` s before the end of this step, i.e. on the next step's clock), so the delay doesn't
					# depend on the frame rate.
					var overshoot := (s - 1.0) * up
					mount.cooldown = maxf(mount.cooldown, dt - overshoot)
					mount.spin = 2.0
				else:
					mount.spin = s
		else:
			mount.spin = 2.0
	else:
		var left := dt
		if mount.spin > 1.0:
			if hold <= 0.0:
				mount.spin = 1.0
			else:
				var used := minf(left, (mount.spin - 1.0) * hold)
				mount.spin -= used / hold
				left -= used
				if mount.spin <= 1.0 + 1e-9:
					mount.spin = minf(mount.spin, 1.0)
		if mount.spin <= 1.0 and left > 0.0:
			mount.spin = maxf(mount.spin - (left / up if up > 0.0 else 1.0), 0.0)
	if not wants_fire(mount, held):
		mount.bloom = maxf(mount.bloom - float(st.get("bloom_recover", 0.0)) * dt, 0.0)


func wants_fire(mount: WeaponMount, held: bool) -> bool:
	return held and mount.spin >= 1.0


func spread(mount: WeaponMount) -> float:
	var base := float(mount.stats.get("spread", 0.0))
	return minf(base + mount.bloom, maxf(float(mount.stats.get("spread_max", base)), base))


func on_shot(mount: WeaponMount) -> void:
	var base := float(mount.stats.get("spread", 0.0))
	var room := maxf(float(mount.stats.get("spread_max", base)) - base, 0.0)
	mount.bloom = minf(mount.bloom + float(mount.stats.get("bloom", 0.0)), room)


## Barrel speed share 0..1 (for a spinning-barrel look).
static func barrel_speed(mount: WeaponMount) -> float:
	return clampf(mount.spin, 0.0, 1.0)


func look() -> Dictionary:
	return {"color": DART_COLOR, "trail_color": LowPolyFlame.MID, "width": 0.22, "glow": true}
