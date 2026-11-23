# Chassis rules: body, joints, intersection, detail

Draft for review (2026-11-23). The rules every chassis is built to: the Strider as it stands, and the two planned
variants, **Bulwark** (squat heavy biped, barrel torso, forward knees, 2 side guns + 2 back mounts) and **Wasp** (four ducted
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
   **(new)**. The Bulwark's hips and knees are visibly bigger than the Strider's; a thin pin under a heavy barrel reads
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
   - **Bulwark side guns** (user, 2026-11-23: "shoulder/arm guns, like the existing mech"): no articulated arms. Two
     mounts built like the Strider's side mounts (flat hull pad, round mount, weapon pivots on it), set at shoulder
     height on the barrel's widest point. They take every side and shoulder weapon, including the railgun, so the mount
     kind is `side` with the shoulder weapons' attach faces tested on it too.
   - **Bulwark `back` x2**: two saddles side by side, each the Strider's back saddle; items may not overlap each other
     or rise into the pilot's head (check every pair).
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
6. **Chassis-specific risks to test first**: Bulwark: side guns against the barrel's widest point and against the
   thighs when aiming down; the two back boxes against each other. Wasp: stub guns against the fan ducts; the chin gun
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
   acceleration, fans tilt and spin up with thrust. On heat shutdown the fans stop and it falls (hard landing applies).
   Landed pose: it rests on skids or the fan ducts, which therefore need a flat underside.
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
- Bulwark: barrel torso (`pick_bulwark_torso_barrel.png`) on **sumo legs** (`pick_bulwark_legs_sumo.png`): very thick short
  thighs set wide, knees bent deeply forward with large square orange knee pads, short thick shins, heavy boot feet with
  a split toe clamp in front and a heel spur behind.
- Bulwark weapons: two shoulder-height side guns mounted like the Strider's, two back mounts (`pick_bulwark_concept.png`).
- Wasp: four ducted fans, pod hull (`pick_wasp_four_fans_pod.png`).

## Open questions
- Wasp: does it land (skids, a landed pose) or always hover? What happens at zero HP on a fan?
- Does damage by component (legs today) map to fans on the Wasp?
- `decisions.md` says one chassis for all four pilots: adding chassis is a decision for the user to record.
