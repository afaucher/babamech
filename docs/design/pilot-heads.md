# Pilot heads: expression, motion, idle

> **Status 2026-11-22: built.** All five heads are rigged (`scripts/pilot/`), effects and the lab subject `pilot` exist,
> and the mech seats a `PilotHead` (`MechModel.pilot`) fed by `MechRig` (movement, turning, landing, effort, footfall).
> In the test drive `PilotCombatLink` (`scripts/pilot/pilot_combat_link.gd`) adds heat, shutdown, hull / head HP,
> disabled, hits (direction + amount), component loss, reboot / respawn, firing, aim look and kill smirks, for the local
> mech only. Teammates' puppets have `PilotPuppetLink` (`scripts/pilot/pilot_puppet_link.gd`, section 7): streamed heat,
> shutdown, thrust, designator, their fire records (aim look), shots seen striking them, reboot, and (since the snapshot
> carries component HP and `disabled`) hull / head HP (afraid), a part lost (pain), downed (dazed), revived, and hits
> from the streamed HP drops (flinch with the real amount toward the struck part's side, even for shots this machine
> never draws; deduped against a seen impact). Not wired yet: the attacker's true direction for a hit not drawn here,
> enemy shots drawn on machines other than the host's, teammate down / alert, objective smirks.
> Open with the user: keep effects? keep / soften the colour flush? smirk for victory; pickle flair. Known weak spots:
> smirk is subtle, pale flush is subtle, chips are white-on-white on the chicken.

Status: **draft for review** (2026-11-21). Covers the five pilots (chicken, pickle, corn, dog, **duck**). The locked
look stays: true low poly, flat colour per face, no texture, **stern** by default. This page adds what moves, when, and
how it reads. Open questions for the user are at the end.

## 1. Who sees the head, and from where

| Viewer | Distance | What is visible | What has to carry the read |
| --- | --- | --- | --- |
| You, over the shoulder | 6-10 m | the **back** of your own head, profile when it turns | neck pose, head turns, flair (comb / ears / husk / crest), effects |
| Teammate nearby (revive, regroup) | 5-30 m | face, three-quarter | brows, lids, pupils, mouth |
| Teammate across a street or deck | 30-100 m | a few pixels of head | silhouette pose, flair, colour flush, effects |
| Menu, hangar, lab | close-up | everything | the full face |

So every expression is built in **three layers that say the same thing**: (a) the face, (b) the silhouette (neck, tilt,
flair), (c) one effect or colour cue. An expression that only exists in the eyebrows is not finished.

## 2. Rig: rigid faceted pieces, not blend shapes

Each head is a small tree of rigid low-poly pieces that rotate, slide and scale. No skeleton skinning, no blend shapes.

Why: with one flat colour and one normal per face, a blend shape bends facets and makes the shading swim; a rigid piece
keeps every facet exactly as modelled, like a paper-craft puppet, which is the look. It is also the cheapest thing to
build from `MeshKit` in GDScript (no Blender on this PC), costs a handful of transforms per head per frame, and a pose is
plain data that blends linearly.

Common pieces (every head):

| Piece | Moves | Used for |
| --- | --- | --- |
| `NeckLow`, `NeckHigh` | two joints, pitch / yaw / roll | all body motion (section 4), nods, recoil, slump |
| `Skull` | carried by `NeckHigh`; scale Y for squash | landing, wobble |
| `BrowL`, `BrowR` | roll (angry in / worried out), slide up / down | the main face signal; stern = low and angled in |
| `LidL`, `LidR` (new plates, skin colour) | slide down over the eye | blink, squint, wide eyes, dazed half-lids |
| `PupilL`, `PupilR` | slide in the eye plane, scale | gaze, pin-prick fear, big dazed |
| `Jaw` (lower beak / bill / muzzle / mouth plate) | hinge open, dark mouth interior behind it | pant, gasp, shout, grit |
| `MouthL`, `MouthR` (pickle, corn: two half bars) | corners up / down | frown, grimace, smirk |

Per-character flair (the long-range signal, each a damped spring so it also trails every head movement):

| Head | Flair pieces | Raised (alarm / effort) | Dropped (dazed / hurt) |
| --- | --- | --- | --- |
| Chicken | comb (4 spikes on one hinge), 2 wattles (pendulums) | comb snaps upright and forward | comb flops to one side |
| Dog | 2 ears (two hinges each), tongue plate (hidden in the jaw) | ears prick up and back | ears hang, tongue out |
| Corn | 5 husk leaves (hinge at the base) | husks flare out like hackles | husks droop and close in |
| Pickle | no appendages: the whole body is the flair (jelly spring: squash / stretch / shear), 4 warts on tiny springs | stretches tall and rigid | sags short and wide, slow wobble |
| Duck | bill (upper + lower), crest tuft or tail-of-neck feathers (per the picked concept), longer two-bend neck | crest up, neck tall | neck S-bend collapses, bill hangs open |

Face budget: the static heads are 142-182 faces. Lids, mouth interior and the split mouth add about 25-40, so rigged
heads land at **about 180-210 faces** (question 1).

**Neck seal (2026-11-22, user bug "you can see up the head's neck in some poses, it separates from the mech").** The
neck's base sits in the hatch below its dark floor; the lean, the push and the squash used to lift its open bottom ring
up to the floor or rim (0.14 above the floor on the chicken) and slide it across the opening (up to 0.08). Now:
(1) every `NeckLow` closes with a collar plug (`PilotFace.add_neck_plug`: a dark `COLLAR` frustum `PLUG_DEPTH` 0.18
below the base, capped, 14 faces on top of the head's budget), so there is no open edge to look into and the neck runs
down past the floor in every pose; standalone (lab, crew panel) it reads as a dark collar under the neck; (2) the push
(focused, effort, peck...) no longer slides `NeckLow`: it leans it about its base and `NeckHigh` turns back by the same
angle (`PilotFace.pose_neck_joints`); `NeckLow` tilt is capped at 24 degrees, the rest bends higher. The sink still slides
it (down into the hatch). Guarded by `tests/test_pilot_neck_seal.gd` (every head on a real mech, worst poses: the plug's
bottom stays 0.02 below the hatch floor and inside the hull); shots `tests/test_pilot_neck_visual.gd`.

## 3. Expressions

### 3.1 Model: channels, moods, reactions

The face is driven by about a dozen **channels** in -1..1 or 0..1, the same for every head:
`brow_raise`, `brow_anger` (angle in), `brow_skew` (one up, one down), `lid` (0 open .. 1 shut), `pupil_size`,
`gaze_x`, `gaze_y`, `jaw`, `mouth_curve`, `flair` (-1 dropped .. 1 raised), `flush` (-1 pale .. 1 red), `tremble`.
Each head maps channels to its own pieces (a chicken has no mouth corners: `mouth_curve` tilts the beak a little and
moves the wattles). An expression is one row of channel values, so **every head has every expression by construction**,
and a head can override a row where its anatomy needs it.

Two kinds, blended every frame:
- **Mood**: the standing state, picked from the mech's state by priority (dazed > afraid > overheated > strained >
  focused > stern). Cross-fades over 0.25 s.
- **Reaction**: a one-shot on top, with attack / hold / release times and a strength. Reactions add to the mood and
  always decay back to it. A stronger reaction replaces a weaker one of the same kind; different kinds stack (flinch +
  landing).

Stern is the floor: the brows only leave "low and angled" for dazed, afraid, revived and the top of a flinch. Positive
moments are a **smirk and one raised brow**, never a grin.

### 3.2 The set

| Expression | Kind | Trigger | Face | Silhouette + flair | Effect / colour |
| --- | --- | --- | --- | --- | --- |
| **Stern** | mood | default | brows low and angled in, lids 35 % down, mouth shut | neck upright, flair at rest | none |
| **Focused** | mood | aiming at a target / firing | brows lower, lids 55 %, pupils small and locked on the aim point | head pushed forward and down a little, flair slicked back | none |
| **Strained** | mood | heat above ~70 % | brows angled, one twitching, jaw cracked open | slight sway, flair drooping a little | flush +0.4 (reddening), one sweat drop now and then |
| **Overheated** | mood | heat above ~90 % until shutdown | lids heavy, jaw open, panting (jaw cycles 3 Hz; dog: tongue out) | neck sags forward, head bobs with the panting, flair limp | flush +1 (red), steam puffs off the crown, sweat drops |
| **Afraid** | mood | hull or head HP below ~25 % | brows up and angled **out**, eyes wide, pupils pin-prick, darting glances, jaw tight | neck pulled down into the hatch (head rides lower), flair raised and trembling | flush -0.6 (pale), tremble |
| **Dazed** | mood | shutdown, or disabled | brows slack and uneven, lids half and unequal, pupils big and drifting in slow opposite circles | neck slumped to one side, slow sway, flair dropped | 3 small faceted stars orbiting the crown (disabled: stars replaced by a slow smoke wisp; the head keeps its normal colours: the grey tint was dropped by the user on 2026-11-22) |
| **Flinch** | reaction 0.08 / 0.1 / 0.35 s | any damage, scaled by amount | eyes shut hard, brows slam down, jaw clenched | head snaps **away** from the hit direction, then (section 4) looks toward it | white flash on the facets for 1 frame at high strength |
| **Pain** | reaction 0.1 / 0.5 / 0.6 s | a big hit (> ~15 % HP) or a component destroyed | one eye shut, the other wide, jaw open in a shout, brows skewed | head thrown back, neck whips, flair flung | 2-3 feather / leaf / brine chips fly off |
| **Effort** | reaction, held while active | thrusters, sprint start, step-up climb | lids 70 %, jaw gritted (shut, mouth curve down), brows down | head ducks forward into the push, flair streaming back | none (thruster heat shows through Strained) |
| **Impact** | reaction 0.05 / 0.08 / 0.4 s | landing, scaled by fall speed | blink, jaw bounces open then shut | neck compresses, skull squashes (Y 0.85), flair overshoots forward then back | hard landing adds Flinch |
| **Smirk** | reaction 0.15 / 0.9 / 0.4 s | kill, banner destroyed, objective done | one brow up, one down, lid squint, mouth corner / beak tilt up | sharp upward nod, flair pops up once | none |
| **Revived** | reaction 1.2 s total | revived or rebooted | eyes snap wide, two fast blinks, then settle to stern | head shakes side to side twice (dog-shake), flair whips, neck back upright | stars / smoke scatter |
| **Alert** | reaction 0.1 / 0.4 / 0.3 s | a teammate goes down, or first enemy seen after quiet | brows up for an instant then stern, pupils to the source | head snaps toward the source, flair pricks up | none |

Idle blinks and tics (section 5) are reactions too, at the lowest priority.

## 4. Motion with the mech

All of it derives from what a puppet already has: velocity, facing, grounded, aim point. Computed in the mech's local
frame, so it works on the ring.

- **Neck lag**: the two neck joints are a damped spring chain (about 3.5 Hz, damping 0.5, the upper joint softer). Mech
  acceleration tips the head the other way (start: head back; stop: head forward, then overshoot), sideways
  acceleration rolls it. Flair springs run looser (2 Hz) so comb / ears / husks trail and settle after the head.
- **Looks into turns**: head yaw leads the body by turn rate x 0.25 s (up to 35 degrees), pupils lead the head by
  another 10 degrees, and a small roll banks into the turn.
- **Aim**: the head tracks the aim point within +-70 degrees yaw and +-35 degrees pitch of the hull; beyond that it holds at the limit
  and the pupils go to their limit. Eyes move first (0.08 s), head follows (0.25 s). This is what gives the player
  profile views of their own pilot.
- **Bob and landing**: the head rides the body bob one beat late and half as deep. Footfalls give a small nod (heavier
  on the dog and duck). Landing drives Impact; airborne, the neck stretches a little and flair lifts.
- **Damage direction**: Flinch snaps away from the hit; 0.15 s later the head turns **toward** the source for 0.6 s
  (overriding aim), then returns. Teammates can read where you are being shot from.
- **Threat glances**: when not firing, quick eye-then-head glances at the nearest known enemy outside the view cone.
  Needs the shared last-known enemy list; stubbed until enemies exist.
- Priority for where the head points: damage look > aim (while firing or focused) > threat glance > turn lead > idle
  glance.

## 5. Idle

Idle runs whenever no reaction is playing, scaled down in combat (blinks always; tics only after 4 s of calm; menu and
hangar always).

- **Blinks**: every 2.5-6 s, 0.12 s; 15 % are double blinks. Birds (chicken, duck) blink faster (0.08 s).
- **Glances**: every 4-9 s, eyes then head to a random point in the front cone, hold 0.5-1.5 s.
- **Tics**, one every 6-14 s, per character:

| Head | Tics |
| --- | --- |
| Chicken | sharp head jerks in steps (bird saccades: the head moves in snaps, never smoothly); a peck forward at nothing; comb shake |
| Dog | ear flick (one ear); pant for 2 s with tongue; sniff (nose up, 3 quick lifts); head tilt at something |
| Pickle | slow wobble that settles; a wart twitch; one long suspicious squint to the side |
| Corn | husk rustle (leaves shiver in sequence around the ring); a kernel-pop twitch; looks up at the ceiling lights |
| Duck | silent quack (bill opens twice, head bobs); neck stretch up then settle with a tail-of-neck waggle; a bill preen at the shoulder |

Each head also has a **movement style** that tints everything in section 4: chicken = snappy, stepped; dog = loose,
overshooting, ears always late; pickle = heavy and jelly-slow; corn = stiff and upright, husks do the moving; duck =
smooth glide with a firm nod on each footfall.

Variety comes from the head's own `RandomNumberGenerator`, seeded from the head id and the player's roster slot (a look
generator, never the mission generator and never global `randf`). Same seed + same inputs = same motion, which the
tests use.

## 6. Duck

Same style as the other four: ~150 faces before rig pieces, flat facets, heavy angled brow, narrowed eye, bill closed.
Concept grid: `art/renders/head_duck_r1/grid_head_duck_r1.png` (3 plumages x 3 head / bill shapes, prompts in
`art/tools/head_duck_r1.ps1`). **Picked: 2, mallard with the crest tuft** (`art/picks/head_duck.png`): dark green head, white neck ring, brown chest, yellow bill, a tuft of angular feather shards at the back of the crown (the duck's flair). The bill is the duck's expression tool: wide and flat, so jaw motion
reads from far away; the brow sits on the bill root like the chicken's.

Adding it: `MechCatalog.HEADS` / `HEAD_ORDER` gain `"duck"`; settings, hangar and the hello handshake iterate
`HEAD_ORDER` or validate against `HEADS`, so they accept it (a test will prove each).

## 7. Networking

Everything here is **cosmetic, `Net.LOCAL`**: every machine runs each head from that mech's already-synced state. Nothing
new on the wire for expressions, and no head state is ever read by gameplay.

| Head input | Source | Exists? |
| --- | --- | --- |
| velocity, facing, grounded | owner's mech stream | built (mech snapshots) |
| aim point, firing | owner's mech stream, replicated fire records | built (snapshot aim, CombatNet) |
| heat fraction, shutdown | owner's mech stream | built |
| HP fractions, disabled | owner's mech stream (`NetMechState.comp`, `disabled`, `disable_cause`) | built |
| hit (direction, amount, part) | result of the `apply_damage` verb | amount and part: built, read from the streamed HP drops on every machine; direction: from the impact when drawn here, else only the struck part's side (the attacker never crosses) |
| kill / objective credit, revived, teammate down | events | to exist with combat; all are edges of synced state or existing broadcasts |

Until those exist, the lab's scripted driver and the menu feed the head directly.

**Today (2026-11-22)** `PilotCombatLink` runs on the owner's machine only: it reads `MechController` (heat, shutdown,
thrusting, `rebooted`), `PlayerTarget` (`component_fractions`, `disabled`, `damaged(amount, component, src)`, component
destroyed), `WeaponRack` (`trigger`, `fired`, `aim_point`, camera zoom) and `CombatWorld.hit_landed` (kills), and the hit
direction comes from looking `src` up in `CombatWorld.targets`.

**Puppets (2026-11-22, integration plan W7)**: `PilotPuppetLink` (a `PilotCombatLink` subclass, all `Net.LOCAL`), child
"PilotLink" of every remote crew mech, made by `CrewSync.setup` next to its `MechPuppet` (a 5-line additive hook). It runs
at physics priority 7 (after `MechPuppet` writes the snapshot at 5, before `MechRig` feeds the head at 10). `MechRig`
poses the puppet like any mech, so velocity, turning, landings, footfalls, running effort and idle already reach the head.

| Head input on a teammate's puppet | Read from | State |
| --- | --- | --- |
| heat, shutdown (strained / overheated / dazed, red flush), effort | puppet `MechController` (`MechPuppet.apply` from the snapshot) | works |
| firing, aim look | `CombatWorld.fired` records with shooter `player<peer>` (CombatNet replays remote records through `world.fire`); look at `MechPuppet.aim_point` while firing and 1.5 s after | works |
| aiming | streamed `designator` flag | works |
| hit (flinch + look toward, pain when large) | `CombatWorld.impact_spawned` within 0.6 m of the puppet's hit spheres (blasts: within their radius, falling off): the shot as this machine shows it; direction = outward from the struck sphere | works for every shot shown here; amount is a guess from the impact radius |
| hit with the real amount (the hit signal) | streamed HP drops: `PilotPuppetLink` pools each `MechPuppet.components` fraction's drop since the previous frame (rises / repairs take back, never below 0; a component first seen, the first frame after bind, is a baseline). When the largest pooled component drop reaches `STREAM_MIN` 0.01 (2.5 x the 1/255 step): a seen flinch (impact / damage event) within `HIT_DEDUPE` 0.3 s + the puppet's interpolation delay (`Session.mechs.delay_of`) + one send interval -> pain part only, with the real amount; else, if a stream flinch was less than `STREAM_GAP` 0.5 s ago, keep pooling (burn / rapid fire: at most 2 flinches per s, with the pooled amount); else `react_hit(side, largest pooled drop)`. Side = the struck part's side of the mech (`*_l` left, `*_r` right, `back` behind, torso / head front) | works (2026-11-22, tested offline and over 2 peers), also for hits this machine never draws (host-only enemy shots). Direction is the struck part's side, not the attacker's; two parts struck in one frame flinch toward the worse one |
| hit events on the puppet target | `PlayerTarget.damaged` on the puppet target, `CombatWorld.remote_hit` naming it (deduped against the impact flinch) | wired, never fires: the victim alone decides and applies hits on its mech, nothing crosses |
| hp (afraid), disabled (dazed) | the puppet `PlayerTarget`, which `MechPuppet` mirrors every frame from the owner's streamed component fractions and downed flag (`fear_hp` = min torso / head) | works (2026-11-22, tested offline and over 2 peers) |
| component destroyed (pain) | `PilotPuppetLink` compares `MechPuppet.components` with the previous frame: a fraction going from > 0 to 0 -> `react("pain", 1)`. The puppet target's hp is written directly, so `player_component_destroyed` never fires on it; a part first seen at 0 (first snapshot, rebind, late join) does not hurt | works |
| revived | shutdown true -> false; streamed disabled true -> false | works |
| kill smirk | `CombatWorld.hit_landed` with the teammate as shooter (host: hits from clients on host-owned enemies) | host only |
| head id, accent | roster profile via `MechSpawn.make(..., peer, accent)` in `TestDrive._spawn_crew` | works (tested) |

Still needed from the net side: (optional) an "owner applied damage" event carrying the source, so a teammate's flinch
for a hit this machine doesn't draw looks toward the attacker (today: the size is real from the HP drop, the direction
is the struck part's side; a heal and a hit in the same frame on one part cancel out). Enemy fire records are
not broadcast (CombatNet sends only the local player's records; enemies run on the host), so on a client the host's
enemies' shots striking a teammate are not seen (W4).

## 8. Code shape

- `scripts/pilot/pilot_head.gd` (`PilotHead`, a Node3D): owns the piece tree and the layers. API:
  `PilotHead.make(id, seed)`, `feed(delta, state)` (velocity, yaw rate, grounded, heat, hp, flags: the normal path,
  picks the mood itself), `set_mood(id)` (override), `react(id, strength)`, `react_hit(local_dir, amount)`,
  `look_at_point(global_pos)` / `clear_look()`, `expressions()`, `time_scale`.
- `pilot_expressions.gd` (the channel tables, section 3), `pilot_face.gd` (channels -> pieces per head),
  `pilot_neck.gd` (spring chain), `pilot_idle.gd` (seeded blinks, glances, tics), `pilot_fx.gd` (stars, steam, sweat,
  chips: tiny flat-shaded meshes, no textures), `pilot_head_parts.gd` (the per-piece meshes for all five heads, built
  with `MeshKit`).
- `MechModel` builds a `PilotHead` in the cockpit seat instead of the static head mesh, and `MechRig` feeds it once per
  frame. Hook agreed with the mech-meshes session; the static `head_<id>.res` files stay as the neutral-pose export.
- Lab subject `pilot` ("Pilot expressions"): head, mood, reaction trigger, look target, a scripted **mech moves** loop
  (walk, run, stop, turn, jump, land, hit from each side, overheat, shutdown, revive) and a five-head line-up. Needs
  buttons in the lab: an optional `lab_actions()` / `do_lab_action(id)` added to the lab contract.
- Tests: every head has every expression and every channel mapping; each reaction returns to the mood within its
  duration; same seed gives the same pose stream; neck spring stays bounded under extreme acceleration; face count per
  head under budget; duck accepted by settings / hangar / handshake; layout checks for the new lab subject; a visual
  test shooting each mood per head.

## 9. Questions for the user

1. ~~Face budget~~: ~180-210 faces is fine (user, 2026-11-21).
2. ~~Effects~~: kept as built, "looks good for now" (user, 2026-11-22).
3. ~~Colour flush~~: red when hot and pale when afraid kept as built, "looks good for now" (user, 2026-11-22). Grey
   when disabled was dropped by the user the same day: "lose the grey look".
7. ~~Chase camera hides the pilot head~~ (only the comb tip shows behind the back plate and pods in the test drive):
   leave it for now (user, 2026-11-22). Head scale on the chassis stays open in `decisions.md`.
4. **Victory is a smirk**, not a grin or cheer, to stay stern. Agree?
5. ~~Duck~~: picked, mallard / tuft.
6. **Pickle** has no appendages, so its flair is whole-body jelly squash. Or give it something (a stem sprig, a helmet)?
