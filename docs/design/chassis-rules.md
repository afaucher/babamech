# Chassis rules: body, joints, intersection, detail

Draft for review (2026-11-23). The rules every chassis is built to: the Strider as it stands, and the two planned
variants, **Bulwark** (heavy biped on long forward-kneed legs, slung tank hull between two hip pods, forward knees, 2 side guns + 2 back mounts) and **Wasp** (four ducted
fans, pod hull, 3 light mounts). Rules marked **(have)** are already enforced by a test on the Strider; **(new)** are
proposed here and need a test before the first new chassis mesh is accepted. Concepts: `docs/design/chassis-concepts/`.

Units: model units, as in `MechMeshes` (the game draws the model at scale 2, body parts at `BODY_SCALE` 1.2).

## 0. Concept images are mood, not geometry
A render decides silhouette, proportion and character. It never decides where a mount, joint or panel goes: the renders
float guns off the hull, fuse joints and change part counts between seeds. Everything below is decided by these rules
and checked by tests, then compared with the concept by eye.

## 1. One chassis = data + parts + a movement system
1. **Catalog entry** (`MechCatalog.CHASSIS`): name, blurb, weights, heat, hardpoint list (`id`, `label`, `mount` kind),
   default loadout. New per-chassis fields **(new)**: `move` (`"biped"` / `"hover"`), `max_item_weight` (the Wasp's
   "no heavy weapons": no single item over 7), armour multiplier, speeds, and the body's collision size.
2. **Parts table** **(new)**: `MechMeshes` constants become per-chassis (`LAYOUT`, `MOUNTS`, `REST_LENGTH`, part lists).
   A chassis shares a part with another only by naming it; nothing reads the Strider's constants implicitly.
3. **Every part is a discrete mesh** built by `MeshKit`, flat shaded, origin at its own pivot or attach point **(have)**.
   Parts are never merged into the torso to hide a seam; the seam is designed (rule 4).
4. **Left and right are one builder mirrored** **(have)**: the torso mirrors its left half from its right (the open-edge
   bug came from building both sides independently).

## 2. Body
1. **Closed and outward-facing**: no open edges, no inward faces, every overhang has an underside **(have,
   `test_geometry_audit`)**. The body is seen from below (Strider belly, the whole Wasp) and from behind (the camera).
2. **The hull is a loft with named stations**, and anything that attaches reads its position from the same stations
   (`_torso_at`), never from a hand-copied number **(have)**.
3. **Flat seats for everything bolted on** **(have for arm pads; new as a general rule)**: where a mount, pylon, plinth
   or socket meets a curved hull, the hull grows a pad with a flat face at least as large as the part's footprint. No
   part sits on bare curvature.
4. **Silhouette first**: the chassis must be recognisable in black from the third-person camera (behind and above) and
   from the side. Bulwark: wider than tall, two back boxes above the hull line. Wasp: four rings, small pod, tail fin.
5. **Family features every chassis keeps**: white upper / orange band / dark grey mechanics livery, the nose with its
   lamp cluster, the round hatch with the pilot's head and neck, amber running lights, a back plate or fin behind the
   pilot. A chassis changes proportion and locomotion, not the kit of parts that says "babamech".
6. **Camera check**: the body and its back equipment may not hide the crosshair area or the weapons' muzzles from the
   default camera. The Bulwark's two back boxes and the Wasp's rear fans are the risks.

## 3. Joints
1. **A joint is three things**: a socket fixed to the parent, a ball or pin at the pivot, and a cap on the child.
   The pivot point is the mesh origin of the child **(have: hip socket / hip cap / knee cap / ankle cap)**.
2. **The pivot stays on the parent** under every pose: worst error under 0.001 while leaning, swaying and twisting
   **(have, `test_ring_step`)**.
3. **Joint size is proportional to load**: ball radius at least 0.55 x the thicker of the two segments it joins
   **(new)**. The Bulwark's hips and knees are visibly bigger than the Strider's; a thin pin under a heavy hull reads
   as broken.
4. **Range of motion is declared and the geometry clears it**: every joint lists its min / max angle, and the child
   clears the parent and the socket across the whole range, including the worst gameplay poses (full stride, crouch,
   shutdown sag, step-up, landing) **(have for hips and thighs, `test_torso_clearance`: 0.02 skin margin, 0.01 cup
   margin; new for knees, ankles, arms and fan arms)**.
5. **Sockets may move to make room** (the hip socket tilts 30 deg and follows the thigh at 0.6) but never detach: the
   socket's base stays inside its pad **(have)**.
6. **Bulwark knees bend forward.** The leg solver already takes the bend sign (`leg_bend` +1). A forward knee needs a
   knee cap on the front, the actuator behind the thigh, and a foot long enough ahead of the ankle to look stable
   (foot length at least 0.8 x shin length) **(new)**.
7. **Actuators are real linkages** **(new)**: a piston has a cylinder pinned to one segment and a rod pinned to the
   other, and it is re-aimed each frame between its two pins (a `look_at` between two markers), so it lengthens and
   shortens as the joint moves. No piston is baked into a segment where it would have to stretch or clip.
8. **Rotors are joints**: a fan has a fixed duct ring, a hub on a strut, and blades that spin about the hub's axis. The
   duct may tilt (pitch with acceleration) about the arm's axis and must clear the hull and the wing-stub weapons at
   full tilt **(new)**.

## 4. Weapon and equipment mounts
1. **Mount point = a frame, not a position** **(have)**: an origin on the mount's flat face, an outward normal, and an up
   axis, in `MOUNTS`. The weapon's own origin is the centre of its attach face.
2. **Contact is measured** **(have, `test_hardpoint_contact`)**: every allowed weapon on every hardpoint touches its
   mount (gap at most 0.01) and its attach face sits on it (seat at most 0.02 off). Back items sit on their saddle.
3. **The chain to the hull is unbroken** **(have)**: weapon -> mount part -> pad -> hull, each link passing rule 2.
   This is the rule the concept renders break most.
4. **A mount is a visible structure sized for the weapon** **(new)**: a turntable or yoke at least 0.6 x the weapon's
   attach face across, with a bolt ring. A gun never meets the hull edge-on or through a strut thinner than its barrel.
5. **One mount kind accepts one family of attach faces** (`side`, `shoulder`, `back`; new: `stub` and `chin` for the
   Wasp). A new kind lists which existing weapons it takes and each of those is tested on it.
   - **Bulwark side guns** (user, 2026-11-23: "shoulder/arm guns, like the existing mech"): no articulated arms. Since
     the slung hull (B1, polish pass): a flat pad on each hip pod's front face, a bolted flange on it and a short wide yoke
     straight forward to the block the weapon pivots on, so the gun sits beside the wedge nose with its pivot just under
     the deck line, on the pod's upper front (the yoke is long enough that every weapon pitched fully up or down keeps its
     tail off the pad; any lower and, since the long legs of 2026-11-24, a gun aimed fully down and in meets its own knee
     pad in the heat shutdown slump). They take every side and
     shoulder weapon, including the railgun, so the mount kind is `side` with the shoulder weapons' attach faces tested on
     it too. Every weapon keeps its full catalog arc (30 deg either way, -50 / +45 pitch; the swivel -40 / +60) except
     the swivel's inward yaw, cut to `yaw_in_max` 55 deg: past it its boom meets the nose.
   - **Bulwark `back` x2**: two saddles on plinths on the rear wings behind the pods, each the Strider's back saddle; items may
     not overlap each other or rise into the pilot's head (check every pair). Outboard, so the mortar does not stand
     right behind the head in the chase view.
   - **Wasp `stub`**: a short wing root from a hull pad, between the front and rear fan arms, ending in a side-kind
     face. **Wasp `chin`**: a turntable under the nose, weapon hangs below; it must clear the ground when landed.
6. **Pivot clearance** **(have)**: a weapon swept through its full aim range keeps at least 0.005 off pads and hull, and
   **(new)** off other weapons, fan ducts, arms and the pilot's head. Where it cannot, the aim range is cut down in data
   rather than the weapon allowed to clip.
7. **Muzzles and their positions come from the mesh** (the catalog's muzzle offset equals the barrel tip, tested), and a
   muzzle has a clear line forward: no part of its own chassis within its fire cone **(new)**.
8. **Empty hardpoints look finished**: the bare mount shows a capped face with its bolt ring **(have)**.

## 5. Intersection
1. **Three allowed relations between two parts**: *seated* (flat face on flat face, rule 4.2), *nested by design*
   (ball in socket, pin in clevis, with the hidden part capped), or *clear* (at least the margin apart in every pose).
   Anything else, a part poking through another, is a bug.
2. **Static pairs are tested at rest; moving pairs are tested across their range** at the poses in rule 3.4.
3. **No z-fighting**: coplanar faces of different parts are offset by at least 0.004, or one is inset.
4. **Chassis against the world**: the collision shape contains the body and the legs' rest pose; weapons may extend
   past it by no more than 0.5 m in the game so barrels do not pass through walls **(new)**.
5. **Pilot head**: the hatch ring clears every catalog head (the neck-seal test), and no weapon, back item or fan
   passes through the head's bounding sphere in any aim pose **(have for the seal; new for the sweep)**.
6. **Chassis-specific risks to test first**: Bulwark: side guns against the nose and the legs (standing and slumped) when
   aiming in, up and down, the thighs against the hip pods' undersides when stepping up, every pilot head against the
   coaming; the two back boxes against each other. Wasp: stub guns against the fan ducts; the chin gun
   against the ground and the front fans' downwash cone; tilting ducts against the hull.

## 6. Detail
1. **Three sizes of form**, in this order: primary (the silhouette masses), secondary (panels, pads, housings, joint
   caps: 10 to 30 % of the part's size), tertiary (bolt rings, vents, hinges, lamps, hazard stripes: under 10 %).
   Tertiary detail only goes where secondary structure explains it (bolts on a flange, a vent on a housing).
2. **Detail is geometry and vertex colour** **(have)**: no textures. Four surfaces only: `matte`, `glow`, `accent`
   (player colour), `heat` (radiator fins).
3. **Detail follows function**: every moving part shows how it moves (pin, piston, bearing ring); every mount shows how
   it is fastened; panels have a 0.01 to 0.02 step or groove, not a colour change alone.
4. **Density is uneven on purpose**: busy at joints, mounts and the nose; calm on the big armour faces. About 70 % of
   the hull's area stays plain.
5. **Colour by role**: white and orange armour, grey structure, dark joints and mechanisms, gun-metal weapons, amber
   lights, the accent on the same parts on every chassis (shoulder pods on the Strider; shoulder balls on the Bulwark;
   fan rings on the Wasp) so a teammate's colour reads at a glance.
6. **Budgets** (triangles; the Strider's numbers are the guide, checked by `test_mech_parts`): torso up to about 1600,
   other body parts up to about 400 each, leg segments up to about 300, weapons up to about 650, equipment up to about
   600. A whole chassis with a full loadout stays within 1.25 x the Strider's total **(new)**; four of them are on
   screen in co-op (`test_perf_coop`).
7. **Detail must survive distance**: nothing thinner than 0.02 (about 5 cm in the game); thinner parts flicker. The
   Wasp's fan blades and guards are the risk: blades are a few broad paddles, guards are thick rings.

## 7. Movement systems
1. **Biped** (Strider, Bulwark): `Gait` + `LegIK` + `MechRig` as built. Per chassis: segment lengths, bend sign,
   stance width, step length and rate, max step-up from the leg geometry (`rig.max_step()`), sag numbers.
2. **Hover** (Wasp, new): no gait. Space / Ctrl climb and descend, full-speed strafe, a ceiling, body banks into
   acceleration, fans tilt and spin up with thrust. **It has mini legs** (user, 2026-11-23: "mini legs so it can land in
   overheat"): short landing legs folded under the hull in flight. On heat shutdown the fans wind down, the legs
   unfold and it settles onto them (a fall from height is still a hard landing); it stands there, unable to move, until
   it restarts and lifts off. The legs are joints like any other (section 3): a socket on a hull pad, a declared fold
   range, clear of the chin gun, the stub guns and the fans both folded and down, and long enough that the chin gun
   clears the ground when landed.
   **Fans are damage components** (user, 2026-11-23: "min 3 required to fly"): each of the four fans has its own HP,
   as legs do on the walkers. With one fan out it still flies, with reduced lift and speed and a visible list toward the
   dead corner. With two out it cannot fly: it comes down onto the mini legs (a hard landing from height) and stays
   there, still able to aim and fire, until a fan is repaired. A dead fan shows it: blades stopped, guard bent, smoke.
   The fan's hit volume is its duct ring, so the four rings must be separate, targetable shapes.
   **It needs its own AI** (user): the mission bot and route planner assume a walker on decks and ramps. A hover pilot
   needs 3D routes (over obstacles, between decks through ceiling openings), altitude choice, landing before overheat,
   and enemy AI needs to aim at and react to a flying target. Design that with the bot's owners before building.
3. **The model exposes the same hooks whatever the system**: mount frames, muzzle points, the hatch, `twist_override`,
   the shutdown pose, a `lab_params` list. Weapons, HUD, pilot heads and puppets never ask which chassis they are on.

## 8. Networking (AGENTS.md rules still apply)
1. The chassis id travels in the hello handshake (it already does); every machine builds the same parts from it.
2. A new movement controller is an owned actor: its vars are classified in `net_fields()`, its pose goes through
   `NetMechCodec`, and remote copies are puppets. Hover adds altitude rate and bank only if the puppet cannot derive
   them from position and velocity.
3. Per-chassis collision size and armour are `SPAWN` data from the catalog, never synced per frame.

## 9. Acceptance: what a new chassis must pass before it ships
1. `test_mech_parts` (parts exist, budgets), `test_geometry_audit` (closed, facing).
2. `test_hardpoint_contact` on its own hardpoints with every allowed item, including back-pair overlap.
3. `test_torso_clearance` generalised to its joints and poses (rule 3.4), plus the weapon sweep (rule 4.6).
4. A lab subject with its tunable numbers (covered by `test_lab` and `test_layout`), and shots in `-Visual`.
5. Third-person camera shots from behind, side and below, compared with the concept, with the weak spots written down.
6. `test_net_contract`, and a two-machine run with one of each chassis.

## Picked so far (user, 2026-11-23)
- Bulwark: **slung hull, layout B1** (`pick_bulwark_layout_slung_hull.png`; supersedes the barrel torso,
  `pick_bulwark_torso_barrel.png`, which squashed the Strider's layout into a short egg): a low, deep armoured hull slung
  between the legs (narrow chamfered wedge nose, sloped glacis with a grille, flat top deck, wings behind the pods, engine
  block at the rear, a keel between the thighs hanging below the hip line with skids, ribs and a belly hatch), and over
  each hip a big round armoured pod standing out of the flank like a pauldron (white drum, orange cap, dark hub), so the
  legs hang from the flanks. The pilot sits in a well behind the glacis inside a raised armoured coaming: only the head
  above the eyes' line shows (every head clears it, eyes at least 0.23 over it; the shared heads are not rescaled). The
  detail is on the deck and pods where the chase camera looks (coaming, hatch lid, radiator grille, deck caps, ammo boxes
  on the pods feeding belts to the side guns, a rear handrail, amber running lights, orange hazard plates). On
  **sumo legs** (`pick_bulwark_legs_sumo.png`): very thick thighs set wide, knees bent deeply forward with large
  square orange knee pads, thick shins, heavy boot feet with a split toe clamp in front and a heel spur behind.
  **Taller on longer legs** (user, 2026-11-24: "increase it about 50%; the head should be about at the chest of the
  other mech. We need longer legs"): the legs grew (thigh 0.78 -> 1.34, shin 0.72 -> 1.23, ankle 0.24 -> 0.34 model
  units; sections, hip ball, knee and ankle drums, cup and knee pads 1.25x thicker; boot 1.2x), the hull did not. The
  chest landmark wins over "50 %": the pilot's eye line is at the Strider's chest (two thirds up its torso), tested
  within 0.5 m; that is +27 % to the comb (7.17 -> 9.08 m), not +50 % (10.8 m would put the head up by the Strider's
  head). The stance widened with the legs (2.9 -> 3.4, the hull between the pods 0.86 -> 0.98, wings 1.18 -> 1.3) so
  it stays wider than tall to the comb; the keel hangs deeper between the thighs (-0.28 -> -0.38), the hip pods are
  bigger (radius 0.48 -> 0.54) and sit lower over the hips.
  Measured (scale 2, test_mech_parts): comb 9.08 m (Strider 11.74, 77 %), pilot's eye line 7.71 m (Strider chest
  7.69 m), deck 6.45 m, body 9.27 m wide across the pods (Strider 4.79; the guns stay inside that width), 7.52 m deep,
  3.52 m tall, hip 4.80 m, stance 3.4 (the hips 1.7 model units either side of the centre line), step-up 1.63 m (the
  Strider's 1.25), deck 2.7x the chicken head's footprint (the well and the pods cut into it), heaviest loadout 9824
  faces (Strider 11522). Joints at 0.56x the thickest section (rule 3.3).
  **No hip twist** (ChassisParts `twist_max` 0): the hips hang under pods fixed to the hull, so the legs cannot turn
  about the body's centre the way the Strider's do (MechRig's 90 deg would swing a hip out from under its pod and the
  thighs into the nose); it strafes by stepping sideways (tested). MechRig does not read `twist_max` yet: phase 2.
  Clearance tests now walk it with 2.4 m strides and a 0.7 m foot lift, slump it by MechRig's own 0.42 (no longer scaled
  down for short legs) and dip it 0.38 on landing.
- Bulwark weapons: two side guns on short yokes bolted to the hip pods' fronts, two back mounts on the rear wings
  (`pick_bulwark_concept.png` for the loadout, B1 for the placement).
- Wasp: four ducted fans, pod hull (`pick_wasp_four_fans_pod.png`).
- Wasp mini legs: **two tiny mechanical chicken legs** (reverse knee, three toes and a spur, like the Strider's in
  miniature), folded under the belly in flight (`pick_wasp_landed_chicken_legs.png`). Two legs under a wide hull: the
  landed pose must balance (feet under the centre of mass, wide enough apart) and lift the chin gun clear of the ground,
  so the real legs are longer and set wider than drawn. **Stand only** (user): no walking on them, so they need a
  fold / unfold motion and a landing bounce, no gait.

## Bulwark world fit (2026-11-24, Mech session)
The city, the missions and the bots were built around the Strider's 2.2 m capsule that can thrust onto roofs. Measured
with the Bulwark's real capsule (3.6 m, 8 m tall) against the built stack (`scripts/game/bot_fit.gd`,
`tests/test_bulwark_world_fit.gd`, seeds 1-7 and 9, every deck):
- **Fits**: every road line the bot graph walks (streets, lanes, pedestrian streets, open courts, all spine lanes, with
  the avenue carriageways at 5.25 m off the median), every ramp (9 m between the parapets, the capsule passes along the
  whole slope), shaft drops (48 m, 96 m with the landing burn), the four crew spawn slots (10.5 m columns, 8 m rows),
  hold zones, defend relays, sweeps. Alleys (7 m) and roofs above the hop are out **by design**.
- **Bugs (handed to Environment, side-session note `bulwark-world-fit.md`)**: 3 of 8 seeds have a REQUIRED objective a
  Bulwark cannot reach: seed 4 d1_p and seed 6 d0_p (flag masts snapped deep inside blocks whose way in is 7.6 / 7.0 m),
  seed 9 deck 1 (reached from deck 0 only by an atrium glide; measured: a Bulwark falls through to deck 2 every time).
  `test_bulwark_world_fit` lists them as KNOWN and fails on any new one.
- **Rules built (mission bot)**: the route planner takes the body's capsule (`BotRoutePlanner.body_r`, `fit_body`: every
  walk edge and ramp leg probed at attach, glides left out for a hop-only body; a wide body standing on a ramp first
  follows the lane to an end); a hop-only body never climbs a roof above its hop (`BotNavigator.drop_roofs_above`);
  the grid plan's side rays, stand room and floor-cut veto grow by the extra radius; a wide body keeps out of lift wells
  and keeps to a ramp it is halfway down when the goal changes; the stuck window stretches with the slower turn. The
  Strider's values are the old constants (its bot tests unchanged).

## Open questions
- `decisions.md` says one chassis for all four pilots: adding chassis is a decision for the user to record.
