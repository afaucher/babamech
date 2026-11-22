class_name RingFrame
extends RefCounted
## Geometry of one ring deck of the rotating habitat (docs/design/vertical-slice.md D1).
##
## The habitat spins about an axis parallel to world X that passes through (0, radius, 0), so the deck floor at the
## world origin is at y = 0 and "up" there is +Y. Gravity points OUTWARD from the axis everywhere: up at a point is the
## direction from that point toward the axis (perpendicular to X). The floor curves upward along +/-Z (the spin
## direction) and is level along X.
##
## Arc coordinates: (x, s, h) = (along the axis, arc length along the floor from the origin (+ toward +Z), height above
## the floor toward the axis). Pure math: no nodes, safe in tests.

var radius := 120.0   ## floor distance from the axis, metres


func _init(r: float = 120.0) -> void:
	radius = maxf(r, 1.0)


func axis_point() -> Vector3:
	return Vector3(0.0, radius, 0.0)


## Unit "up" at p: toward the axis, perpendicular to X. +Y on the axis itself (degenerate).
func up_at(p: Vector3) -> Vector3:
	var d := Vector3(0.0, radius - p.y, -p.z)
	if d.length_squared() < 1e-10:
		return Vector3.UP
	return d.normalized()


func gravity_dir(p: Vector3) -> Vector3:
	return -up_at(p)


func dist_to_axis(p: Vector3) -> float:
	return Vector2(p.y - radius, p.z).length()


## Height of p above the floor (negative below it).
func height(p: Vector3) -> float:
	return radius - dist_to_axis(p)


## Angle around the axis from the origin's floor point, + toward +Z.
func angle(p: Vector3) -> float:
	return atan2(p.z, radius - p.y)


func arc_to_world(x: float, s: float, h: float = 0.0) -> Vector3:
	var th := s / radius
	var r := radius - h
	return Vector3(x, radius - r * cos(th), r * sin(th))


func world_to_arc(p: Vector3) -> Vector3:
	return Vector3(p.x, angle(p) * radius, height(p))


## Unit tangent along the floor in the +s direction at p.
func tangent_at(p: Vector3) -> Vector3:
	var th := angle(p)
	return Vector3(0.0, sin(th), cos(th))


## An orthonormal basis at p: Y = up, -Z = `forward_hint` flattened onto the local floor plane (Godot's forward).
func basis_at(p: Vector3, forward_hint: Vector3 = Vector3.FORWARD) -> Basis:
	var up := up_at(p)
	var f := forward_hint - up * forward_hint.dot(up)
	if f.length_squared() < 1e-8:
		f = -tangent_at(p)
	f = f.normalized()
	return Basis(f.cross(up), up, -f)


## Basis for a floor-aligned object at arc position s, facing +s (so its local -Z points along +s).
func basis_at_arc(s: float) -> Basis:
	var p := arc_to_world(0.0, s)
	return basis_at(p, tangent_at(p))
