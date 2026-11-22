class_name Knockback
extends RefCounted
## Kinematic knockback for a target (weapons.md §2): no RigidBody, mechs are kinematic. Knockback Δv (already scaled by
## the mass class) is added to a velocity that loses Combat.FRICTION m/s² on the ground (none in the air, where gravity
## pulls it down); for Combat.HIT_SLIDE_TIME s after each shove it loses only Combat.SLIDE_FRICTION (the hit-slide).
## Δv accumulating to Combat.STAGGER_DV within Combat.STAGGER_WINDOW s staggers for STAGGER_TIME.
## Moving into a wall faster than SLAM_SPEED reports a slam speed (CombatTarget turns it into damage). OWNER state of
## the target's owner, stepped only there (CombatWorld.advance).

var velocity := Vector3.ZERO
var stagger_left := 0.0
var slide_left := 0.0        ## s of hit-slide left (reduced friction after a shove)
var _clock := 0.0
var _recent: Array = []      ## [time, |Δv|] within the stagger window


func net_fields() -> Dictionary:
	return {"velocity": Net.OWNER, "stagger_left": Net.OWNER, "slide_left": Net.OWNER, "_clock": Net.PRIVATE, "_recent": Net.PRIVATE}


## Add a velocity change. True when it starts a stagger.
func add(dv: Vector3) -> bool:
	velocity += dv
	if dv.length_squared() > 1e-8:
		slide_left = Combat.HIT_SLIDE_TIME
	_recent.append([_clock, dv.length()])
	_trim()
	var sum := 0.0
	for r: Array in _recent:
		sum += float(r[1])
	if sum >= Combat.STAGGER_DV and stagger_left <= 0.0:
		stagger_left = Combat.STAGGER_TIME
		_recent.clear()
		return true
	return false


func staggered() -> bool:
	return stagger_left > 0.0


func moving() -> bool:
	return velocity.length_squared() > 1e-6


## Move `pos` (the target's origin, on the ground plane) by the velocity for dt. The ground frame: `up` (default world
## +Y) and the ground plane {p : p.dot(up) = ground_y} (with the default up, ground_y is the flat ground height), so a
## target on a curved deck works in its local frame. `space` (optional) finds walls: a ray from the body's centre
## (pos + up × probe_height) along the motion across the ground, `radius` ahead. Returns
## {"position": Vector3, "slam": float (speed into a wall, 0 if none)}.
func step(dt: float, pos: Vector3, ground_y: float, space: PhysicsDirectSpaceState3D = null, probe_height: float = 1.0,
		radius: float = 0.8, up: Vector3 = Vector3.UP) -> Dictionary:
	_clock += dt
	stagger_left = maxf(stagger_left - dt, 0.0)
	var friction := Combat.SLIDE_FRICTION if slide_left > 0.0 else Combat.FRICTION
	slide_left = maxf(slide_left - dt, 0.0)
	_trim()
	var vu := velocity.dot(up)
	var grounded := pos.dot(up) <= ground_y + 0.001
	if grounded and vu <= 1e-4:      # a hair of tolerance: in a tilted frame "along the ground" isn't exactly 0 up
		pos += up * (ground_y - pos.dot(up))
		var h := velocity - up * vu
		var sp := maxf(h.length() - friction * dt, 0.0)
		velocity = h.normalized() * sp if sp > 0.0 else Vector3.ZERO
	else:
		velocity -= up * (Combat.GRAVITY * dt)
	var slam := 0.0
	var delta := velocity * dt
	if delta.length_squared() > 1e-10 and space != null:
		var c := pos + up * probe_height
		var hd := delta - up * delta.dot(up)
		if hd.length_squared() > 1e-10:
			var q := PhysicsRayQueryParameters3D.create(c, c + hd + hd.normalized() * radius)
			var hit := space.intersect_ray(q)
			if not hit.is_empty() and absf((hit["normal"] as Vector3).dot(up)) < 0.7:
				var n: Vector3 = hit["normal"]
				var into := -velocity.dot(n)
				if into > 0.0:
					slam = into
					velocity += n * into
					var stop: Vector3 = hit["position"] + n * radius
					var across := stop - c
					delta = across - up * across.dot(up) + up * delta.dot(up)
	pos += delta
	var below := ground_y - pos.dot(up)
	if below > 0.0:
		pos += up * below
		velocity += up * maxf(-velocity.dot(up), 0.0)
	return {"position": pos, "slam": slam}


func reset() -> void:
	velocity = Vector3.ZERO
	stagger_left = 0.0
	slide_left = 0.0
	_recent.clear()


func _trim() -> void:
	while not _recent.is_empty() and float(_recent[0][0]) < _clock - Combat.STAGGER_WINDOW:
		_recent.pop_front()
