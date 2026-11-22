class_name FlamerFx
extends CombatEffect
## The flamer's look (weapons.md §3.9): ONE LowPolyFlame.Stream per firing mount ("shooter/hardpoint"), the game's one
## flame style. Cosmetic and local: every machine builds it from the chunk fire records it gets (FlameChunk), so it needs
## nothing the records don't carry. The flamer behaviour calls `FlamerFx.note(world, record)` for every chunk; the first
## one creates the Stream, later ones keep it lit and re-aim it.
##
## The Stream sits at the live muzzle (CombatWorld.muzzle_of, when the firer registered one) or else the latest record's
## origin, its -Y along the latest record's aim, sized to the weapon: length = range, speed = chunk speed (so tongues
## travel with the chunks), sideways spread = tan(stats.spread) (the 5° cone). It is stepped on the CombatWorld clock
## (manual), so the lab's time scale and pause apply. Each step the Stream's `max_length` is set from one query along the
## aim (`cap_at`), so the flame splats against a wall or the target it meets instead of flying through.
## `emitting` stays on while chunks keep coming (no gap longer than
## GAP_SHOTS chunk intervals), then the tongues in flight finish and the effect frees itself.

const GAP_SHOTS := 1.6         ## chunk intervals without a new chunk before the flame stops
const WIDTH := 1.5             ## a tongue's peak width (m): chunky, but a jet, not a puff
const COUNT := 64              ## tongues in flight at once: ~0.7 m apart over 45 m, one continuous jet
const TUMBLE := 0.55           ## rad a tongue tips off the axis
const ROOT := 0.35             ## a steady jet() cone at the nozzle, × WIDTH

var mount_key := ""            ## "shooter/hardpoint"
var stream: LowPolyFlame.Stream
var last_t := -INF             ## clock time of the latest chunk
var aim := Vector3.FORWARD     ## the latest chunk's aim (unspread)
var at := Vector3.ZERO         ## the latest chunk's origin
var chunks := 0                ## chunks noted
var _prev := NAN               ## clock time of the last advance


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"mount_key": Net.LOCAL, "stream": Net.LOCAL, "last_t": Net.LOCAL, "aim": Net.LOCAL, "at": Net.LOCAL,
		"chunks": Net.LOCAL, "_prev": Net.LOCAL})
	return f


static func key_of(record: Dictionary) -> String:
	return "%s/%s" % [record.get("shooter", ""), record.get("hardpoint", "")]


## The live FlamerFx for a record's mount, or null.
static func find(w: CombatWorld, record: Dictionary) -> FlamerFx:
	var k := key_of(record)
	for e in w.effects:
		if e is FlamerFx and (e as FlamerFx).mount_key == k and is_instance_valid(e):
			return e
	return null


## A chunk left this mount: keep (or start) its Stream.
static func note(w: CombatWorld, record: Dictionary, st: Dictionary) -> FlamerFx:
	var fx := find(w, record)
	if fx == null:
		fx = FlamerFx.new()
		fx.name = "FlamerFx"
		var rec := {"shooter": record.get("shooter", ""), "hardpoint": record.get("hardpoint", ""),
			"weapon": record.get("weapon", ""), "t": record.get("t", w.now)}   # no shot_index: remove_shot never drops it
		fx.start(w, rec, st)
		w._add_effect(fx)
	fx._take(record)
	return fx


func start(w: CombatWorld, rec: Dictionary, st: Dictionary) -> void:
	super.start(w, rec, st)
	mount_key = key_of(rec)
	stream = LowPolyFlame.Stream.new()
	stream.name = "Stream"
	stream.manual = true
	stream.length = float(st.get("range", 45.0))
	stream.speed = float(st.get("speed", 32.0))
	stream.width = WIDTH
	stream.count = COUNT
	stream.spread = tan(deg_to_rad(float(st.get("spread", 5.0))))
	stream.tumble = TUMBLE
	stream.root = ROOT
	stream.jitter_seed = hash(mount_key) & 0xFFFF
	stream.top_level = true
	add_child(stream)


func _take(record: Dictionary) -> void:
	chunks += 1
	var t := float(record.get("t", world.now))
	if t >= last_t:
		last_t = t
		aim = (record["dir"] as Vector3).normalized()
		at = record["origin"]


func emitting() -> bool:
	return stream != null and stream.emitting


func gap() -> float:
	return GAP_SHOTS / maxf(float(stats.get("rate", 10.0)), 0.001)


func advance_to(now: float) -> void:
	var dt := 0.0 if is_nan(_prev) else maxf(now - _prev, 0.0)
	_prev = now
	stream.emitting = now - last_t <= gap()
	var m := world.muzzle_of(record)
	var p: Vector3 = m.call() if m.is_valid() else at
	var b := Combat.look_basis(aim)     # -Z along the aim; the Stream wants -Y along it
	var x := b.x
	var y := -aim
	stream.transform = Transform3D(Basis(x, y, x.cross(y)).orthonormalized(), p)
	if stream.emitting or stream.active():
		stream.max_length = cap_at(p)
	if dt > 0.0:
		stream.advance(dt)


## Where the flame meets something along its axis from `p`: the nearest of world geometry, a city prop and a target's hit
## spheres (CombatWorld.first_hit: one physics ray), as a distance; INF when nothing is within the weapon's reach. The
## Stream's tongues splat there instead of flying through walls (cosmetic: the chunks resolve their own hits).
func cap_at(p: Vector3) -> float:
	var reach := float(stats.get("range", 45.0))
	var h := world.first_hit(p, p + aim * reach, 0.0, str(record.get("shooter", "")))
	return float(h["frac"]) * reach if not h.is_empty() else INF


func finished() -> bool:
	return stream != null and not stream.emitting and not stream.active() and world.now - last_t > gap()
