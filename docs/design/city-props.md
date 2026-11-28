# Destructible street props

Trees, lamps, signs, signal poles, benches and bins get knocked over by mechs and weapons, then lie loose on the ground:
heavy, they slide a little when hit again or walked into, and never fly around. **Design for `scripts/world/city/city_props.gd`
(+ `city_prop_sim.gd`); the user's request, 2026-11-21.**

## 1. Choices

| Question | Choice | Why |
|---|---|---|
| Physics bodies or our own sim? | **Our own closed-form topple and slide** (no RigidBody3D) | A prop's fall must be the same on every machine from one broadcast (a scheduled effect, AGENTS.md rule 6). Godot's rigid bodies are not deterministic across machines, and 300 sleeping bodies cost more than 300 MultiMesh instances |
| Do props block mechs? | **No, never.** A mech walks through a standing prop and it goes down; a fallen prop is pushed aside | The mech stays kinematic and its controller is untouched; an 8 m mech should not stop for a lamp post |
| Do props block shots? | Yes: a prop has a hit capsule; a shot that meets it stops there and pushes the prop | Trees are soft cover until they fall. Needs the weapons side to ask (section 5) |
| Gameplay or cosmetic? | **Gameplay**: host-arbitrated world objects with stable ids | They move and are synced, so their positions can no longer come from the mesher's cosmetic stream |

## 2. Prop types

`CityProps.TYPES`. Mass decides how hard a hit must be and how far a shove goes.

| Type | Mass (kg) | Contact radius | Height | Falls in | Rests at | Topples from a weapon at |
|---|---|---|---|---|---|---|
| tree | 1200 | 0.6 m | 5.6 m (x its scale) | 0.9 s | 78 deg (on its canopy) | dv >= 3 |
| lamp | 400 | 0.3 | 6.5 | 0.8 | 90 | dv >= 2 |
| signal | 300 | 0.3 | 5.3 | 0.7 | 90 | dv >= 2 |
| sign (new: street sign post) | 150 | 0.25 | 3.6 | 0.6 | 90 | dv >= 1.5 |
| bench | 250 | 0.9 | 0.9 | 0.4 | 90 (tips on its back) | dv >= 1.5 |
| bin | 80 | 0.35 | 0.9 | 0.3 | 90 | dv >= 1 |

`dv` is the weapon's knockback (m/s, as in `CombatTarget.apply_impulse`). Any moving mech topples anything it touches.

## 3. Layout

`CityPropLayout.layout(plan) -> Array` is pure data: `[{id, type, x, s, h, yaw, scale, variant}]`, ids = array index, generated
from the plan with its own generator (`plan.props_seed() + 1`, roof units `+ 2`; the same value as `cosmetic_seed()`,
named apart 2026-11-25 because props are gameplay), so it is the same on every machine and no longer depends on the order
the meshers draw in. `layout_checksum()` covers it, and **the load barrier compares it**: `CityStack.checksum()` joins
every deck's `layout_checksum(props.items)` (code audit 2026-11-25; until then it was only called from tests, so two
machines with different prop layouts would desync by index). A district on its own (test drive district mode) reports
`plan.checksum()` alone: that hook is TestDrive's. Placement rules are the ones the furniture pass
already uses (street trees about every 9 m with a lamp every third slot, benches and bins beside them, a signal pole per
block corner, median trees, park and garden trees), plus a sign post per block edge.

The static furniture mesh keeps only what cannot move: tree pits, planters, the fountain, the median.

## 4. Behaviour

States: `STANDING -> FALLING -> DOWN` (and `DOWN -> SLIDING -> DOWN`). Everything is a function of one event and the time
since it; nothing integrates frame by frame.

**Topple** `{id, kind: TOPPLE, dir, t0}`: the prop rotates about its base, away from the push (`dir`, a unit vector in the
deck's (x, s) plane). Tilt at age `a`: `rest * (a / T)^2` up to `T` (it accelerates like a falling pole), then one small
bounce of 4 deg over 0.25 s. Its base ends 0.3 m along `dir`. After `T + 0.25` it is `DOWN`, lying along `dir`.

**Shove** `{id, kind: SHOVE, dir, v0, from: {x, s, lie}, t0}`: a fallen prop slides along `dir` from speed `v0` under a
friction of 6 m/s^2: distance `v0 a - 3 a^2`, stopping after `v0 / 6` s at `v0^2 / 12` m. It turns up to 20 deg toward
the push as it goes. `v0` is capped at 4 m/s (1.3 m of slide) and scaled by 400 / mass (at most 1): a tree barely moves, a
bin skitters. The slide stops early at a building wall or the map edge (2D test against the plan's building footprints).
The event carries the pose it starts from, so machines never have to agree on a half-finished motion.

Props do not collide with each other. On a curved deck a prop's pose is built from its arc position each time, so it
always lies on the floor facet under it (sidewalk 0.2 m or road 0 m by where it is).

**Mech contact.** Each physics step, for every pusher this machine owns: any prop within `pusher radius + prop radius` in
the deck plane, and within 6 m of the pusher's height, is touched. Standing and the pusher is moving (> 0.5 m/s): topple
along the pusher's velocity. Down and at rest: shove with `v0 = 0.5 x speed` along the velocity (at most one shove per
prop per 0.25 s). At the new 12 m/s walk a mech flattens a row of street trees without slowing; each kick then moves a
fallen lamp or bin about 1.3 m and a fallen tree about 0.15 m (measured).

## 5. Interfaces

**Weapons** (`scripts/combat/`, proposal to that session). `CityProps` is a node; a scene has at most one (`CityDistrict.props`).

- `props.first_hit(a, b, r) -> {id, frac, point, normal}` or `{}`: the first prop on a swept segment (capsule test), so
  `CombatWorld.first_hit` can stop a shot on a tree.
- `props.apply_impulse(id, dv: Vector3, src: String)`: the verb. Topples a standing prop if `|dv|` reaches its threshold,
  shoves a fallen one.
- `props.blast(point, radius, dv, src)`: splash. Every prop within `radius` gets `dv x (1 - d / radius)` radially.

Props have no HP: they fall, they do not break (banners are the destructible-for-score objects).

**Mech** (`MechController`, proposal to the main session, no edit made). `props.add_pusher(body, radius)` registers a
mover; it reads `global_position` and `velocity`. Until the test drive calls it, `CityProps` finds `CharacterBody3D`s in
the scene itself (re-scanned once a second) and takes the radius from their capsule. For co-op it also needs to know
whether this machine owns the mover: a `MechController.owner_peer` (or `is_local()`).

## 6. Networking (host-arbitrated world object)

- A touch or a weapon hit on any machine is a **request**: `props.request(id, kind, dir, v0)`.
- The **host decides**: is the prop still standing (topple) or at rest (shove)? If so it stamps the event with the shared
  clock and the start pose and broadcasts it; every machine, the host included, then runs the same closed-form motion
  from `t0` (a late arrival fast-forwards). Offline the request is decided on the spot.
- Transport: `Session.send_event` (reliable): client -> host `prop.req`, host -> crew `prop.ev`. No network code in the
  city folder: only calls on `Session`.
- **Late join**: `props.snapshot() -> PackedByteArray` (every prop that is not standing: id, x, s, lie; anything still
  moving is written at its rest pose) and `props.restore(bytes)`. The host sends it as `prop.sync` when a peer joins.
  The bytes are checked first (`CityProps.valid_snapshot`, 2026-11-25): a count no larger than this layout's props, the
  buffer exactly that many records long, every id in the layout, every float finite; a malformed buffer is ignored with a
  warning (every prop stands) instead of looping on the peer's count.
- Declared in `net_fields()`: layout `SPAWN`; prop states `OWNER` (the host); render caches `LOCAL`.
- Hooks still needed in `scripts/net/`: none for the events above. A "world state for late joiners" registry (so each
  system does not hand-roll its own `*.sync`) would be the tidy home for the snapshot once more systems need it.

## 7. Tests and lab

- `tests/test_city_props.gd`: layout is deterministic and checksummed; a topple ends `DOWN` at the predicted pose; the
  same events on two managers give identical snapshots; a shove is short, heavier props go less far, and it stops at a
  wall; snapshot / restore round-trips; a pusher driven through a row topples it; a pusher on a roof does not.
- `tests/test_net_props.gd` (2 processes): a client's request topples the prop on both machines, and a snapshot taken on
  the host restores the same state on the client.
- Lab `city`: option `props demo` drives a pusher down a sidewalk so the falls can be watched and tuned.

## 8. As built (2026-11-21)

Built to this spec in `scripts/world/city/city_prop_sim.gd` and `city_props.gd`; tests `test_city_props`, `test_net_props`.
Additions the build needed: a prop pose also carries `spin` (how far shoves have turned it), a shove event carries `len`
(the slide length after the host's wall check, so clients never test collision), layout items carry `pit` (street trees
get a tree pit), the sign post stands 5.6 m along each block edge. Fallen props rest at the height of what is under
them (sidewalk, median, garden bed, planter, road). Not done: `scripts/combat/` does not call the three verbs yet, and
`MechController` has no `owner_peer`, so online every mech found by scanning counts as the host's.

## 9. Station (R2.11, 2026-11-27)
The top deck's tram stop (`scripts/world/city/city_station.gd`, `CityStation`; spec `city-spine.md` section 5, user pick
cell 7 of `city-spine/grid_station.png`: "just some basic lights and benches ... arranged with a small wall"). Real
fittings only: no game indicators.
- **Where** (`CityStation.of(plan)`, a pure function of the plan; {} on every other deck and on a district on its own):
  a 32 x 3.5 m platform against the rail lane's east edge, inside the `ramp_b` lane (the promenade side: no ramp there on
  the top deck), centred in the spine segment nearest the deck's middle that keeps 8 m (`BOX_CLEAR`) from both junction
  boxes, slid in 2 m steps if a floor cut, ramp or kept-clear ground is in the way. Its centre is the tram's stop. Seeds
  1-12 all have one (tests/test_city_props.gd). Seed 1: s -61..-29 (stop -45), x -30..-26.5.
- **What**: the platform 0.35 m high (paved top, kerb sides, a yellow tactile strip 0.15-0.6 m in from the track edge), a
  low back wall 0.3 m thick along its far edge, 0.8 m over the platform (1.15 m over the street, with a cream coping),
  the station's name board standing on the wall at the centre (4.4 m wide, top 2.6 m over the platform: the deck signs'
  dark panel and sky-blue stripe, the name in CitySigns' cream stencil letters on the track face; letters A H L N O R S T
  added to the face). The name: one of `CityStation.NAMES` from the plan's cosmetic seed through its own generator.
- **Props**: 4 street lamps against the wall (arms over the platform) and 4 benches facing the track (two flank the
  board), the ordinary `lamp` / `bench` items: knockable and shoved as any other, host-arbitrated by id. Appended after
  every other item (roof units included) by `CityPropLayout.layout`, so no other id moves and they are in
  `CityPropLayout.checksum` (the top deck's props checksum moves; stand-alone layouts are unchanged:
  `GOLDEN_LAYOUT` f321076ebd6e98f1 still holds). The platform is a raised floor for fallen props
  (`CityPropSim.floor_rects`).
- **Collision** (`CityStation.collision`, StaticBody3D "StationBody" in node "Station" under `CityProps`, layer 1): a
  platform box and a wall box per 4 m floor facet (both below the pin band: a mech steps onto them), a
  `CityGeo.rounded_box` for the board (its top is in the band); meta `col_kind` "station" (collision survey). Not in the
  district's "Collision" body, `tri_count`, stats or geometry digest (those pins stay).
- **Keep-outs**: no other street prop, tree or sign stands on the platform (+0.5 m) or in the tram's swept path
  (+0.5 m) (tested on seeds 1-12).
- **Shots**: `docs/design/city-spine/station.png` (the tram at the platform, life lab) and `station_wide.png` (city lab
  camera `station`).
