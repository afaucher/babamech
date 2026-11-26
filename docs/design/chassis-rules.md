# Chassis rules: body, joints, intersection, detail

Draft for review (2026-11-23). The rules every chassis is built to: the Strider as it stands, and the two planned
variants, **Bulwark** (heavy biped on long forward-kneed legs, slung tank hull between two hip pods, forward knees, 2 side guns + a belly turret + 2 back mounts) and **Wasp** (two big tilting ducted lift fans since the 2026-11-25 pick: was four ducted
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
   from the side. Bulwark: wider than tall, two back boxes above the hull line. Wasp: two big ear rings either side of the head, small egg pod, a small fin.
5. **Family features every chassis keeps**: white upper / orange band / dark grey mechanics livery, the nose with its
   lamp cluster, the round hatch with the pilot's head and neck, amber running lights, a back plate or fin behind the
   pilot. A chassis changes proportion and locomotion, not the kit of parts that says "babamech".
6. **Camera check**: the body and its back equipment may not hide the crosshair area or the weapons' muzzles from the
   default camera. The Bulwark's two back boxes and the Wasp's fan rings are the risks.

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
   - **Wasp `stub`** (built 2026-11-25): a flat wing root from a pad on each flank under the fan, ending in the Strider
     side mount's block (the weapon's pivot 0.48 out from the pad: shorter and an outward-yawed gun's receiver tail meets the
     hull). Takes the side weapons up to weight 7 with their catalog arcs; the swivel's 120 deg boom is cut to 45 in / 60
     out (`yaw_in_max` / `yaw_out_max`: past them it meets the hull or the fan ring). **Wasp `chin`**: a turntable on a
     block under the nose, the weapon hanging on a pintle 0.4 below it. Light guns only (`max_item_weight` 6: laser,
     gatling, swivel, flamer; the autocannon's and flak's tall receivers would meet the bearing). Its arc is cut in data:
     yaw +-45, pitch -8 / +10 (further down and a long receiver's tail lifts into the belly; landed, every gun at every
     aim stays over the ground). `tests/test_hardpoint_contact_wasp.gd`.
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
   coaming; the two back boxes against each other. Wasp (tested, `test_clearance_wasp` / `test_hardpoint_contact_wasp`):
   the fans tilted against the hull, coaming and every pilot head (the dog's ears set the fans' position); stub guns
   against the fan rings across their tilt; the chin gun
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
   overheat"): two mini chicken legs under the belly that **dangle in flight** (knees bent, a little tucked, toes
   drooping: the A1 pick of 2026-11-25 replaces "folded away") and stand when landed. On heat shutdown the fans wind
   down and it settles onto them (a fall from height is still a hard landing); it stands there, unable to move, until it
   restarts and lifts off. The legs are joints like any other (section 3): a clevis on a belly pad, a hip and a knee pin
   with declared ranges (`WaspMeshes.THIGH_RANGE` / `KNEE_RANGE` / `FOOT_RANGE`), two poses (dangle, stand) and every
   pose between them clear of the hull, the guns and each other, standing with the soles on the ground under the centre
   of mass, the chin gun over the ground (`tests/test_clearance_wasp.gd`). Stand only: no gait.
   **Two main fans, tilting** (user, 2026-11-25: the A1 pick without its two small rear fans): `fan_l` / `fan_r` sit on
   gimbal balls and vector for steering and strafing: 20 deg forward / back, 15 deg sideways (an ellipse,
   `WaspMeshes.FAN_TILT_MAX`; `MechModel.set_fan_tilt` clamps to it, either fan alone), clear of the hull, the coaming,
   every pilot head and the stub guns across all of it.
   **Fan damage: PROPOSAL, awaiting the user** (it replaces "min 3 fans to fly", which the user said must change with
   this pick): the two main fans are the damage components, as legs are on the walkers (each its own HP; its hit volume
   the duct ring, so the two rings are separate, targetable shapes). **One fan out = it cannot hold altitude**: it
   settles onto its legs (a hard landing from height). A dead fan shows it: blades stopped, guard bent, smoke. Nothing of
   this is built. Open questions for the user: **can a grounded Wasp still shoot?** **Does it stay down until the fan is
   repaired** (or limp up on one fan for short hops)?
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
- Bulwark hardpoints and armour (user, 2026-11-25, `docs/design/bulwark-effectiveness.md` options A + C4): **5
  hardpoints**: side_l, side_r, belly (a pintle turret under the keel between the thighs, key 5, side weapons only,
  yaw +-30 / pitch -10 +15), back_l, back_r. **Core HP 900 / 420 / 150** (torso / each leg / head: the earlier
  600 / 280 / 100 x1.5, every core component as the study measured it; hardpoints 80 as on every chassis).
- Wasp: ~~four ducted fans, pod hull (`pick_wasp_four_fans_pod.png`)~~ superseded 2026-11-25 by **A1 "tandem pairs /
  compact"** (`pick_wasp_tandem_compact.png`, user: "the look is the best"), **without its two small rear fans** (user,
  same day): a compact chunky faceted egg pod (orange flank bands, white front and top, dark grey lower hull, dark belly,
  amber window lights), the pilot out of a round hatch ring on top, a small upright fin behind it, **two big ducted lift
  fans** high either side of the cockpit on short stout struts (the ears), three bolted-on guns (a stub each flank, a
  chin turret). Art phase 1 built (`WaspMeshes`, ChassisParts "wasp", `MechCatalog.DRAFT_CHASSIS`: not playable, not
  in CHASSIS / CHASSIS_ORDER; no controller, weapons code, networking or bots yet).
- Wasp mini legs: **two tiny mechanical chicken legs** (reverse knee, three toes and a spur, like the Strider's in
  miniature), ~~folded under the belly~~ **dangling in flight** (the A1 pick). **Coloured as the Strider's legs** (user,
  2026-11-25: "Mirror the color scheme of the other mech with chicken feet", not the concept's orange feet). **Stand
  only** (user): a hip and a knee pin, two poses, no gait.
- Wasp measured (art phase 1, scale 2, `test_mech_parts`): comb landed **7.80 m** (Strider 11.74, Bulwark 9.08), 8.41 m
  across the fans, hull 3.69 m wide x 3.53 m tall (belly to the hatch rim) x 4.41 m long (the chin block included; the
  egg alone 4.13), fans 3.0 m across, belly 1.44 m over the ground landed, legs 1.82 m (thigh + shin + ankle height),
  heaviest loadout 8460 faces (Strider 11522, Bulwark 10828). **Bent: the comb target (5.5-6.5 m) is not reachable**:
  the shared chicken head alone stands 2.8 m over the hatch rim (the heads are not rescaled), the hull is at least 3.2 m
  and the chin gun needs about 1.4 m of belly clearance landed; 7.8 m keeps the head near the Bulwark's deck (6.45 m)
  and well under the Strider's chest. The fans sit a little behind the head (gimbal at z 0.28): the dog's ears
  (3 m across) meet them anywhere further forward once they tilt.
- Wasp art pass 2 (user, 2026-11-26: "Make the hull slightly longer front to back and just a smidge wider"): hull
  4.41 -> **4.94 m** long (chin block included; the egg 4.13 -> 4.67), 3.69 -> **4.01 m** wide (pads included; the egg
  3.94), same height (3.46 m belly to the hatch rim); 8.75 m across the fans (was 8.41: they moved out with the hull and
  carry segment clamps); the fans' gimbals now 0.36 behind the hatch (was 0.44), as far forward as the dog's ears allow
  at full tilt. Hull read as the A1 egg: broad orange flanks and shoulders, a white top and front centre panel, grey only
  low, a dark belly. Chunky segmented guard rings (deeper duct, seven dark clamps over the orange band, lighter blades
  with white tips). Legs 1.35x thicker (drums sized to them, rule 3.3), feet 1.4x, a tidier dangle (both legs alike,
  feet nearly level). A taller, thicker fin, further back. The stub swivel's pitch-up is cut to 45 (the fans now sit over
  the stubs). Heaviest loadout 8508 faces; comb unchanged (7.80 m).

## Bulwark world fit (2026-11-24, Mech session)
The city, the missions and the bots were built around the Strider's 2.2 m capsule that can thrust onto roofs. Measured
with the Bulwark's real capsule (3.6 m, 8 m tall) against the built stack (`scripts/game/bot_fit.gd`,
`tests/test_bulwark_world_fit.gd`, seeds 1-7 and 9, every deck):
- **Fits**: every road line the bot graph walks (streets, lanes, pedestrian streets, open courts, all spine lanes, with
  the avenue carriageways at 5.25 m off the median), every ramp (9 m between the parapets, the capsule passes along the
  whole slope), shaft drops (48 m, 96 m with the landing burn), the four crew spawn slots (10.5 m columns, 8 m rows),
  hold zones, defend relays, sweeps. Alleys (7 m) and roofs above 6 m (the bots' planning margin, below) are out **by design**.
- **Bugs (handed to Environment, side-session note `bulwark-world-fit.md`)**: 3 of 8 seeds have a REQUIRED objective a
  Bulwark cannot reach: seed 4 d1_p and seed 6 d0_p (flag masts snapped deep inside blocks whose way in is 7.6 / 7.0 m),
  seed 9 deck 1 (reached from deck 0 only by an atrium glide; measured: a Bulwark falls through to deck 2 every time).
  `test_bulwark_world_fit` lists them as KNOWN and fails on any new one.
- **Rules built (mission bot)**: the route planner takes the body's capsule (`BotRoutePlanner.body_r`, `fit_body`: every
  walk edge and ramp leg probed at attach, glides left out for a hop-only body; a wide body standing on a ramp first
  follows the lane to an end); a hop-only body never climbs a roof above its hop (`BotNavigator.drop_roofs_above`;
  since 2026-11-25 "hop-only" is `MechCatalog.bot_hop_height(chassis) > 0`, 6 m for the Bulwark: a bot planning
  margin, the mech itself has no ceiling);
  the grid plan's side rays, stand room and floor-cut veto grow by the extra radius; a wide body keeps out of lift wells
  and keeps to a ramp it is halfway down when the goal changes; the stuck window stretches with the slower turn. The
  Strider's values are the old constants (its bot tests unchanged).

## Bulwark thrust: heat, not a ceiling (2026-11-25, user playtest)
"The artificial limit on the Bulwark's jump height doesn't make sense. Let's just have the thrusters accumulate heat a
lot faster, so you're more limited but can still push it." The 6 m `thrust_ceiling` is gone (the controller mechanism,
its net field and lab param removed). The Bulwark's pilot thrust heats **80 /s** (was 30; the Strider 24) against
cooling 12 and a 130 cap, with thrust 30 vs gravity 22 (8 m/s^2 of lift). Measured (`tests/test_chassis_movement.gd`,
flat floor, from cold):

| | Strider | Bulwark before | Bulwark now |
| --- | --- | --- | --- |
| pilot thrust heat /s (net of cooling) | 24 (15) | 30 (18), throttled at 6 m | 80 (68) |
| continuous burn, cold to shutdown | 6.7 s | (hovers at 6 m) | 1.9 s |
| height at shutdown / peak of one burn | 267 / 412 m | 6 / 6.8 m | 15 / 20 m |
| highest jump that still lands safely (auto burn) | ~314 m | 6.8 m | ~19 m (1.85 s burn) |
| 6 m ledge / 12 m roof / 30 m roof (heat at the top) | yes / yes / yes (21) | yes / no / no | yes (85) / yes (112) / no |

The pilot can hop a ledge, push onto a 12 m roof at the cost of most of the heat bar, and nothing much higher: a full
burn shuts the mech down ~15 m up and it falls uncushioned from ~20 m (~30 m/s, leg damage). The **automatic landing
burn** costs its own `auto_burn_heat` (Bulwark 30 /s at full throttle, the old value; Strider 24 = its thrust_heat, so
nothing changed for it): at 80 /s the burn alone would shut a cold Bulwark down on a two-deck (96 m) shaft drop
(touchdown ~31 m/s), so the safety burn is kept as cheap as before. Bots keep their 6 m planning margin
(`MechCatalog.bot_hop_height`). Reboot timer (same day, audit): the reboot countdown runs only while heat is at or
under `reboot_heat`; heat climbing over it during a shutdown restarts the countdown (`tests/test_reboot_rule.gd`).

## Open questions
- `decisions.md` says one chassis for all four pilots: adding chassis is a decision for the user to record.
