class_name PilotPuppetLink
extends PilotCombatLink
## A teammate's pilot head on this machine (docs/design/pilot-heads.md §7): the puppet twin of PilotCombatLink, cosmetic
## only. One per remote crew mech (child "PilotLink" of that mech, made by CrewSync next to its MechPuppet). It only READS
## the puppet (MechPuppet, its MechController, its PlayerTarget) and CombatWorld signals, and only writes the head.
##
##   var link := PilotPuppetLink.new()
##   mech.add_child(link)
##   link.bind_puppet(puppet, combat_world)          # world optional / null-safe
##
## Each physics frame (after MechPuppet applied the snapshot, before MechRig feeds the head) it sets the sticky inputs:
##   heat / shutdown / effort   the puppet MechController (MechPuppet.apply writes heat, shutdown, thrusting from the stream)
##   hp / disabled              the puppet PlayerTarget (fear_hp, disabled), which MechPuppet mirrors every frame from the
##                              owner's streamed component fractions and downed flag (NetMechState.comp / disabled)
##   firing                     a CombatWorld.fired record whose shooter is this teammate, in the last FIRING_HOLD s
##   aiming                     firing, or the teammate's laser designator on (MechPuppet.designator, streamed)
## Look: while firing / designating and LOOK_HOLD s after the last shot, look_at_point(MechPuppet.aim_point); else clear.
## Movement, turning, landings, footfalls, running effort and idle come from MechRig, which poses the puppet like any mech.
##
## Events:
##   shutdown true -> false (reboot), PlayerTarget.disabled true -> false  -> react("revived")
##   CombatWorld.impact_spawned near the puppet's hit spheres (a shot SEEN striking it here, whoever decides the hit: the
##     victim's machine does, so this is the only hit cue a third machine has today) -> react_hit(outward from the struck
##     sphere = toward the source, in the head frame; amount from the impact radius, splash falling off with distance)
##   PlayerTarget.damaged (when damage reaches the puppet target), CombatWorld.remote_hit naming its target_id -> react_hit
##     with the real amount; within HIT_DEDUPE s of an impact flinch only the pain part is added (no double flinch)
##   streamed HP drops (MechPuppet.components vs the previous sync): THE real hit signal, since hits on player mechs never
##     cross the wire (combat_net.gd) and this machine may not draw the shot (an enemy shot simulated on the host). Each
##     component's drop is added to a pending pool (a rise, i.e. a repair, takes back from that component's pending, never
##     below 0, so 1/255 jitter cannot add up); a component first seen (bind, first snapshot) is a baseline, not a drop.
##     When the largest pending component drop reaches STREAM_MIN:
##       a seen flinch (impact / damage event) within _dedupe_window() s -> only the pain part with the real amount
##         (the impact is drawn first, its HP arrives a snapshot + interpolation delay later: one hit never flinches twice)
##       else a stream flinch within STREAM_GAP s -> keep pooling (burn: a flamer's many tiny drops flinch at most once
##         per STREAM_GAP, with the amount pooled meanwhile)
##       else react_hit(toward the struck component's side, largest pending component drop); pool cleared
##     Side: *_l -> the mech's left, *_r -> right, back -> behind, torso / head -> front (puppet mech basis -> head frame).
##   a streamed component fraction falling from > 0 to 0 since the previous frame -> react("pain", 1)
##     (the puppet's hp is written directly, so PlayerTarget.player_component_destroyed never fires on it; a component
##     first seen already at 0, e.g. the first snapshot after bind, does not react)
##   CombatWorld.hit_landed with this teammate as shooter and the target newly destroyed -> react("smirk") (PilotCombatLink)
## No random rolls here (the head's own look generator does the variety).

const DIRECT_MARGIN := 0.6       ## m beyond a hit sphere within which an impact counts as striking the mech
const IMPACT_AMOUNT := 0.03      ## head "amount" (fraction of HP) per m of impact radius: 2 m laser 0.06, 6 m mortar 0.18
const IMPACT_MAX := 0.25
const IMPACT_GAP := 0.12         ## s: a salvo's impacts flinch at most this often
const HIT_DEDUPE := 0.3          ## s after an impact flinch in which a damage event for the same hit adds no new flinch
const STREAM_MIN := 0.01         ## fraction of a component's HP: a streamed drop below this is pooled, not a hit (1/255 = 0.004)
const STREAM_GAP := 0.5          ## s: stream flinches at most this often (burn / rapid fire pools in between)

var puppet: MechPuppet = null
var flinches := 0                    ## react_hit calls made by this link (tests / diagnostics)
var _was_down := false
var _since_impact := INF
var _since_seen := INF               ## s since a flinch from a seen event (impact, damage event, remote hit)
var _since_stream := INF             ## s since a flinch from a streamed HP drop
var _prev_comp: Dictionary = {}      ## MechPuppet.components as of the previous sync (part-lost / drop detection)
var _pending: Dictionary = {}        ## component -> streamed drop pooled since the last stream hit (0..1)


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"puppet": Net.LOCAL, "flinches": Net.LOCAL, "_was_down": Net.LOCAL, "_since_impact": Net.LOCAL,
		"_since_seen": Net.LOCAL, "_since_stream": Net.LOCAL, "_prev_comp": Net.LOCAL, "_pending": Net.LOCAL})
	return f


func _ready() -> void:
	process_physics_priority = 7   # after MechPuppet (5) wrote the snapshot, before MechRig (10) feeds the head


func bind_puppet(pp: MechPuppet, combat_world: CombatWorld = null) -> void:
	var rig_or_null: Node = pp.rig if pp != null else null
	bind(rig_or_null, pp.mech if pp != null else null, null, pp.target if pp != null else null, combat_world)
	puppet = pp
	_was_down = mech != null and mech.shutdown
	_since_impact = INF
	_since_seen = INF
	_since_stream = INF
	_prev_comp = pp.components.duplicate() if pp != null else {}
	_pending = {}
	_connect(world, "fired", _on_world_fired)
	_connect(world, "remote_hit", _on_remote_hit)
	_connect(world, "impact_spawned", _on_impact)
	sync()


func unbind() -> void:
	_disconnect(world, "fired", _on_world_fired)
	_disconnect(world, "remote_hit", _on_remote_hit)
	_disconnect(world, "impact_spawned", _on_impact)
	puppet = null
	_prev_comp = {}
	_pending = {}
	super.unbind()


func _physics_process(delta: float) -> void:
	if is_finite(delta) and delta > 0.0:
		_since_impact += delta
		_since_seen += delta
		_since_stream += delta
	super._physics_process(delta)


## The shooter id this teammate's fire records and hits carry ("player<peer>", as CrewSync / TestDriveCombat name them).
func shooter_id() -> String:
	var t := _valid(target) as PlayerTarget
	if t != null and t.target_id != "":
		return t.target_id
	var pp := _valid(puppet) as MechPuppet
	return "player%d" % pp.peer if pp != null else ""


func sync() -> void:
	var h := _current_head()
	if h != _head:
		_head = h
		_looking = false
	var disabled := target != null and is_instance_valid(target) and target.disabled
	var m := _valid(mech) as MechController
	var down := m != null and m.shutdown
	if h != null and ((_was_disabled and not disabled) or (_was_down and not down and not disabled)):
		h.react("revived")
	_was_disabled = disabled
	_was_down = down
	var pp := _valid(puppet) as MechPuppet
	var lost := _part_lost(pp)        # also pools this frame's streamed drops and remembers the fractions
	if h == null:
		_pending = {}
		return
	_stream_hit(h)
	if lost:
		h.react("pain", 1.0)
	var in_ := {"hp": fear_hp(), "disabled": disabled}
	if m != null:
		in_["heat"] = clampf(m.heat / maxf(m.heat_cap, 0.001), 0.0, 1.0)
		in_["shutdown"] = m.shutdown
		in_["effort"] = m.thrusting
	var firing := _since_shot < FIRING_HOLD
	var designating := pp != null and pp.designator
	in_["firing"] = firing
	in_["aiming"] = firing or designating
	h.set_inputs(in_)
	var look := pp != null and pp.shown != null and (firing or designating or _since_shot < LOOK_HOLD) \
		and pp.aim_point.is_finite()
	if look:
		h.look_at_point(pp.aim_point)
		_looking = true
	elif _looking:
		h.clear_look()
		_looking = false


## True when a streamed component fraction that was > 0 last sync is 0 now. Also pools each component's change since the
## last sync into _pending (drops add, rises take back, never below 0; a component first seen is only a baseline), and
## remembers this frame's fractions.
func _part_lost(pp: MechPuppet) -> bool:
	if pp == null:
		_prev_comp = {}
		_pending = {}
		return false
	var lost := false
	for c: String in pp.components:
		var now := float(pp.components[c])
		if not _prev_comp.has(c):
			continue
		var before := float(_prev_comp[c])
		if now <= 0.0 and before > 0.0:
			lost = true
		var p := maxf(float(_pending.get(c, 0.0)) + before - now, 0.0)
		if p > 0.0:
			_pending[c] = p
		else:
			_pending.erase(c)
	_prev_comp = pp.components.duplicate()
	return lost


## The pooled streamed drop as a hit (see the header): pain only if a seen flinch already showed it, held while a stream
## flinch is recent (burn), else react_hit toward the struck component's side.
func _stream_hit(h: PilotHead) -> void:
	var worst := ""
	var amount := 0.0
	for c: String in _pending:
		if float(_pending[c]) > amount:
			amount = float(_pending[c])
			worst = c
	if amount < STREAM_MIN:
		return
	if _since_seen < _dedupe_window():
		_pain_only(h, amount)
		_pending = {}
		return
	if _since_stream < STREAM_GAP:
		return
	_since_stream = 0.0
	_pending = {}
	var m := _valid(mech) as MechController
	var local := _component_side(worst)
	var world_dir := m.global_basis.orthonormalized() * local if m != null and m.is_inside_tree() else Vector3.ZERO
	_react_world(world_dir, amount)


## s after a seen flinch in which a streamed drop is the same hit: HIT_DEDUPE plus how late the owner's snapshot shows
## here (the puppet's interpolation delay, asked of Session, and one send interval).
func _dedupe_window() -> float:
	var delay := NetPuppetBuffer.DELAY
	var sess := Net.session()
	var pp := _valid(puppet) as MechPuppet
	if sess != null and sess.mechs != null and pp != null:
		delay = sess.mechs.delay_of(pp.peer)
	return HIT_DEDUPE + delay + NetMechStream.SEND_INTERVAL


## Toward a component's side in the mech frame (x right, z back): *_l left, *_r right, back behind, torso / head front.
static func _component_side(component: String) -> Vector3:
	if component.begins_with("back"):   # the Strider's back, the Bulwark's back_l / back_r (behind, to that side)
		var s := -1.0 if component.ends_with("_l") else (1.0 if component.ends_with("_r") else 0.0)
		return (Vector3.BACK + Vector3.RIGHT * s).normalized()
	if component.ends_with("_l"):
		return Vector3.LEFT
	if component.ends_with("_r"):
		return Vector3.RIGHT
	return Vector3.FORWARD


# --- Events ------------------------------------------------------------------------------------------------

func _on_world_fired(record: Dictionary) -> void:
	if CombatWorld.life_src(record) < 0:
		return                                            # enemy fire (its peer is the host's)
	var me := shooter_id()
	if me == "" or str(record.get("shooter", "")) != me:
		return
	var age := 0.0
	var w := _valid(world) as CombatWorld
	if w != null:
		age = clampf(w.now - float(record.get("t", w.now)), 0.0, LOOK_HOLD)   # a late record: already that old
	_since_shot = minf(_since_shot, age)


## A shot struck something at `point` (cosmetic impact, every machine that shows the shot).
func _on_impact(point: Vector3, radius: float, explosive: bool, _is_energy: bool) -> void:
	var t := _valid(target) as PlayerTarget
	if t == null or t.disabled or not t.is_inside_tree() or _since_impact < IMPACT_GAP:
		return
	var best := INF
	var centre := Vector3.ZERO
	for s: Dictionary in t.world_spheres():
		var d := maxf(point.distance_to(s["center"]) - float(s["radius"]), 0.0)
		if d < best:
			best = d
			centre = s["center"]
	var reach := DIRECT_MARGIN + (maxf(radius, 0.0) if explosive else 0.0)
	if best > reach:
		return
	var amount := clampf(IMPACT_AMOUNT * maxf(radius, 1.0), IMPACT_AMOUNT, IMPACT_MAX)
	if best > DIRECT_MARGIN:
		amount *= 1.0 - (best - DIRECT_MARGIN) / maxf(reach - DIRECT_MARGIN, 0.001)
	_since_impact = 0.0
	_since_seen = 0.0
	_react_world(point - centre, amount)


## A hit this machine decided on the teammate's target (it owns none, so this only fires if authority rules change).
func _on_remote_hit(target_id: String, hit: Hit) -> void:
	var t := _valid(target) as PlayerTarget
	if t == null or hit == null or target_id != t.target_id:
		return
	var cap := float(t.max_hp.get(hit.component, 0.0))
	var frac := hit.damage / cap if cap > 0.0 else 0.0
	var toward := -hit.impulse
	if toward.length_squared() < 1e-6 and t.is_inside_tree():
		toward = hit.point - (t.global_position + t.up * t.probe_height)
	_hit_or_pain(toward, frac, true)


func _on_damaged(amount: float, component: String, src: String) -> void:
	var h := _current_head()
	if h == null:
		return
	var t := _valid(target) as PlayerTarget
	var cap := float(t.max_hp.get(component, 0.0)) if t != null else 0.0
	var frac := amount / cap if cap > 0.0 else 0.0
	if _since_impact < HIT_DEDUPE:
		_pain_only(h, frac)
		return
	_since_seen = 0.0
	flinches += 1
	h.react_hit(_dir_to(src, h), frac)


## react_hit toward a world direction (zero = unknown), or just the pain part if an impact already flinched for it.
func _hit_or_pain(world_dir: Vector3, frac: float, dedupe: bool) -> void:
	var h := _current_head()
	if h == null:
		return
	if dedupe and _since_impact < HIT_DEDUPE:
		_pain_only(h, frac)
		return
	_since_seen = 0.0
	_react_world(world_dir, frac)


func _react_world(world_dir: Vector3, frac: float) -> void:
	var h := _current_head()
	if h == null:
		return
	var local := Vector3.ZERO
	if world_dir.length_squared() > 1e-8 and h.is_inside_tree():
		local = (h.global_basis.orthonormalized().inverse() * world_dir).normalized()
	flinches += 1
	h.react_hit(local, frac)


func _pain_only(h: PilotHead, frac: float) -> void:
	if frac >= PilotHead.PAIN_AMOUNT:
		h.react("pain", clampf(frac / 0.3, 0.6, 1.0))
