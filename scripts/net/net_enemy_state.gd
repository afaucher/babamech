class_name NetEnemyState
extends RefCounted
## One sample of a host-owned enemy, as the host streams it (W4, co-op enemies; cast's M3 host-owned actors): what a
## client's puppet needs to pose and show it. Plain data; NetEnemyCodec packs it, NetEnemyBuffer interpolates it, the
## game fills it from EnemyBase.puppet_state() and writes it back with EnemyBase.puppet_apply() (scripts/game/enemy_sync.gd).
##
## `yaw` is the hull's heading in the ring's local frame (the game converts, as for mechs), so the net layer never needs
## the ring. `state` is an index into NetEnemyCodec.STATES.

var n := 0                          ## net id (the enemy's number in the host's manifest)
var t := 0.0                        ## the sample's moment on the shared clock (host_time seconds)
var pos := Vector3.ZERO             ## world position of the enemy's origin (its feet / base)
var yaw := 0.0                      ## hull heading about local up (rad), ring frame
var aim := Vector2.ZERO             ## the subclass's aim pose: turret yaw + pitch, tank turret yaw, strider torso yaw (rad)
var state := 0                      ## NetEnemyCodec.STATES index (EnemyBase.ai_state)
var shutdown := false               ## overheated
var stagger := false
var dead := false
var heat := 0.0                     ## 0..1 of heat cap
var kick := 0.0                     ## aim_kick, degrees (turret recoil droop)
var lock := Vector3.ZERO            ## the telegraph's locked aim point (world)
var hp := PackedFloat32Array()      ## component HP fractions, EnemyBase.comp_order() order


func copy() -> NetEnemyState:
	var c := NetEnemyState.new()
	c.n = n
	c.t = t
	c.pos = pos
	c.yaw = yaw
	c.aim = aim
	c.state = state
	c.shutdown = shutdown
	c.stagger = stagger
	c.dead = dead
	c.heat = heat
	c.kick = kick
	c.lock = lock
	c.hp = hp.duplicate()
	return c


## True when this differs from `o` enough to be worth a sample at the active rate.
func changed_from(o: NetEnemyState) -> bool:
	if o == null:
		return true
	if state != o.state or shutdown != o.shutdown or stagger != o.stagger or dead != o.dead or hp != o.hp:
		return true
	if pos.distance_squared_to(o.pos) > 0.0001 or absf(angle_difference(yaw, o.yaw)) > 0.002:
		return true
	if absf(angle_difference(aim.x, o.aim.x)) > 0.002 or absf(aim.y - o.aim.y) > 0.002:
		return true
	return absf(heat - o.heat) > 0.004 or absf(kick - o.kick) > 0.1 or lock.distance_squared_to(o.lock) > 0.01
