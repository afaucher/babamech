class_name NetMechState
extends RefCounted
## One sample of a mech's OWNER state, as the owner's machine streams it (co-op step 2, cast's NetHeroState): what a
## puppet needs to pose believably on another machine. Plain data in world / ring terms; NetMechCodec packs it,
## NetPuppetBuffer interpolates it, the game reads it (scripts/game/mech_puppet.gd) and writes it (crew_sync.gd).
##
## `yaw` is the body's heading in the ring's local frame (the game converts: crew_sync.gd / mech_puppet.gd), so the net
## layer never needs the ring. `heat` is a fraction of the mech's heat_cap (SPAWN, the same everywhere).

var peer := 0                       ## the owner (crew peer id)
var t := 0.0                        ## the sample's moment on the shared clock (host_time seconds)
var tp := 0                         ## teleport counter (mod 16): a change means "jumped, don't blend across"
var pos := Vector3.ZERO             ## world position of the feet (m)
var vel := Vector3.ZERO             ## world velocity (m/s)
var yaw := 0.0                      ## body heading about local up (rad), in the ring's frame
var leg_yaw := 0.0                  ## hip twist (MechRig.leg_yaw, rad)
var heat := 0.0                     ## 0..1 of heat_cap
var last_impact := 0.0              ## m/s down at the last touchdown (the landing dip)
var aim := Vector3.ZERO             ## the aim point (world): a hook for combat across owners (co-op step 3)
var grounded := true
var thrusting := false              ## thrust this step (pilot's or emergency)
var emergency := false              ## the thrust is the automatic burn
var shutdown := false               ## overheated (no control until reboot)
var hover := false                  ## thrusting in the air with little vertical speed (derived by the owner; HUD / FX)
var designator := false             ## the guided-missile track is on (WeaponRack.designator_on): a step-3 hook


func copy() -> NetMechState:
	var s := NetMechState.new()
	s.peer = peer
	s.t = t
	s.tp = tp
	s.pos = pos
	s.vel = vel
	s.yaw = yaw
	s.leg_yaw = leg_yaw
	s.heat = heat
	s.last_impact = last_impact
	s.aim = aim
	s.grounded = grounded
	s.thrusting = thrusting
	s.emergency = emergency
	s.shutdown = shutdown
	s.hover = hover
	s.designator = designator
	return s
