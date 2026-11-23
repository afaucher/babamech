# Ambient life: civilians and vehicles

A little extra movement in the city: a few people on the sidewalks, a few driverless pods on the roads, a tram on the
spine. They live quietly under occupation, panic when a firefight reaches them, and are the same civilians and vehicles
the crew rescues later. **Approved by the user on 2026-11-22 with the changes in section 0; being built.**

## 0. Decisions (user, 2026-11-22)

The user's words on 1 and 2: "we need a reason for the player to hold their fire, let's let them be killed but no blood,
just knock them over." 3-6 and the vehicle look (section 14) approved as proposed. Where a later section still says
"hurt" or "shots pass through", this table and section 6 win.

| # | Question | Decision |
|---|---|---|
| 1 | Can civilians die? | **Yes.** A civilian who is hit is **killed: knocked over, lying still**. No blood, no gore, no ragdoll. It counts against the mission |
| 2 | Do weapons hit civilians? | **Yes: every shot, blast and flame that touches one kills it**, so the player has to hold fire near people. Shots are not stopped by them. Enemies never target them, but their fire kills the same way |
| 3 | Do cars crash? | **Not by themselves** (they are automated and brake). They get **shoved, tipped and wrecked by mechs and blasts**, exactly like the heavy street props. Occupants always get out first |
| 4 | How many? | **About 24 people and 10 vehicles in a 220 x 240 m district**, roughly 2-4 people and 1 vehicle per visible block. Section deck: 60 and 16, plus one tram |
| 5 | Private cars? | **None.** Every vehicle is shared and driverless: pods, service carts, the tram. Parked "cars" are pods docked at the kerb |
| 6 | How long until calm returns? | People stay indoors until 45 s after the last shot nearby; streets are back to normal about 90 s after |

## 1. The picture

Curfew-quiet. The invaders run the city, so life goes on in a subdued way: someone walks from a doorway to a pod stop, a
pod glides by at the speed limit and stops at a red light with nobody else at the junction, a service cart trundles
along the kerb, the tram hums down the spine every couple of minutes. A checkpoint makes the pods queue. Nobody runs,
nobody gathers.

Then a mech opens fire. The nearest people flinch and look, then run, arms up, for the nearest doorway; the ones who
see them run start running too, so panic visibly ripples down the street ahead of the fight. Pods slam to a stop with
their hazard lights blinking, doors open, passengers scramble out. Pods with a clear road behind them reverse out and
speed away. A minute after the shooting stops, a door opens and one person looks out.

## 2. Who is out there

| Agent | Size | Speed | Count (district / deck) | Where |
|---|---|---|---|---|
| Pedestrian | 1.8 m | walk 1.4 m/s, run 4.5 | 24 / 60 | Sidewalks, zebra crossings, park paths, plazas |
| Pod (shared driverless cab, 4 seats) | 3.4 x 1.8 x 1.9 m | 9 m/s streets, 12 avenue, 14 fleeing | 8 / 12 | Road lanes; docked in parking strips |
| Service cart (delivery / cleaning) | 2.6 x 1.4 x 1.6 m | 4 m/s | 2 / 4 | Kerb side of streets, plazas |
| Tram (3 cars, section mode only) | 3 x 9 m cars | 14 m/s | 0 / 1 | The spine's rail lane, between station hooks |

Hard caps, enforced in code and tested. Agents are simulated and drawn only near players (section 9); a district with
nobody in it costs nothing.

## 3. Normal life

Everything in calm state is a **timetable**: a pure function of the seed, the agent's id and the shared clock. No agent
reacts to another in calm state, which is what makes it free on the network (section 8).

- **Doors and stops.** The plan already has what is needed: every building's front door (the centre of its front face),
  pod stops (one per block face on a parking strip), benches, park paths, and in section mode the section plan's
  `station` and `checkpoint` hooks.
- **Pedestrians** make trips: appear at a door, walk the sidewalk (walkway lane, inside the furnishing band), cross
  only at zebra crossings on green, end at another door, a stop (and vanish into a pod), or a bench (sit 20-60 s, then
  another trip). Doors are where people appear and disappear, so the population breathes without popping in view.
- **Traffic lights** run on the shared clock (the signal poles already stand at every corner): a fixed cycle per
  junction, offset by junction id. Pods stop at red, people cross on green. That one rule removes every pod-pedestrian
  conflict without any agent sensing another.
- **Pods** loop the road grid in the right-hand lane, stop at red lights and stop lines, pull into a pod stop for a
  10 s dwell now and then, and dock in a parking strip when their trip ends. Docked pods are the "parked cars".
- **Service carts** crawl along the kerb, stopping at each bin.
- **Tram**: end to end along the rail lane with a 20 s dwell at each station hook; one tram, so it passes about every two
  minutes.
- **Checkpoints** (section hooks): a barrier across the lanes; every pod stops 6 s, so a short queue forms.
- **Ramps**: pods take them between decks once ramps are built; freight lifts carry vehicles later (rescue convoys).

## 4. Panic

**Threats.** A threat is `{point, radius, strength, time}`. The host raises them from signals that already exist:

| Source | Signal | Radius | Strength |
|---|---|---|---|
| A weapon fires | `CombatWorld.fired` | 60 m | 1 |
| An impact / explosion | `CombatWorld.impact_spawned` | 40 m / 80 m explosive | 2 / 3 |
| A mech moving fast nearby (player or enemy) | mech position + velocity | 15 m | 1 |
| An enemy alerts or telegraphs an attack | `EnemySquad.enemy_event` | 40 m | 1 |
| A prop goes down | `CityProps.prop_moved` | 15 m | 1 |
| A panicking civilian in view | (the ripple) | 8 m, 0.3-0.8 s later | passes on strength - 1 |
| A pod emergency-stops | (vehicles) | 12 m | 1 |

Threats closer than 10 m and 0.25 s apart are merged, so a burst of fire is one event.

**What a person does.** One alarm level per person, driven only by threats:

| State | Trigger | Looks like (low poly: silhouette and speed, no faces needed) |
|---|---|---|
| Calm | - | Upright walk, arms at the sides |
| Wary | Any threat in range | Stops, turns toward it, 0.5-1 s (the flinch) |
| Fleeing | After wary, or strength >= 2 at once | Runs at 4.5 m/s leaning forward, **both arms up in a V**, toward the nearest door or building corner that is away from the threat |
| Sheltered | Reaches a door | Gone (indoors). The door remembers how many are inside |
| Cowering | No refuge within 40 m, or the threat is within 8 m | Crouched to half height, arms over the head, still |
| Hands up | A mech stands within 10 m and nothing has fired for 3 s | Standing still, arms straight up |
| Down (killed) | Hit (section 6) | Tips over in 0.4 s in the direction of the hit, then lies flat and still for the rest of the mission |

People steer away from any mech within 12 m, so a mech walking down a street parts the crowd without touching it.

**Calming down.** Each door, and each person outside, keeps the time of the last threat within 60 m. 45 s after it,
doors start letting people out one at a time (one every 3-6 s); a cowering person stands up after 20 s. Vehicles restart
15 s after the last threat in their range. About 90 s after the last shot the street looks normal again.

**Audio hooks** (signals for the audio system, no sound work here): `civilian_event(kind, world_pos)` with `gasp`
(wary), `scream` (first frame of fleeing, at most one per 1.5 s per 30 m), `run_steps`, `door_slam` (sheltered),
`whimper` (cowering), `hurt`; `vehicle_event(kind, world_pos)` with `brake`, `horn`, `hazard`, `doors`, `tip`, `alarm`
(wrecked), `tram_bell`.

## 5. Vehicles in a firefight

Vehicles are automated, so they behave lawfully and predictably; the drama is in how abruptly.

- **Emergency stop**: a threat within 30 m, or a mech or obstacle in the lane ahead. Brakes hard (10 m/s^2), hazard
  lights blink, doors open, occupants get out and flee as pedestrians (1-2 per occupied pod).
- **Flee**: if the threat is ahead and the lane behind is clear, an empty pod reverses to the last junction and drives
  away from the threat at 14 m/s, out of range, then docks at the first free kerb. This is the "speeding away".
- **Abandoned**: a stopped pod stays where it is, hazards blinking, until calm returns; then it drives on.
- **Wrecked**: a pod or cart that a mech walks into, or that takes a weapon's knockback or a blast, becomes a heavy
  street prop on the spot (mass 900 kg pod, 500 kg cart): shoved, or tipped on its side by a hard enough hit, using the
  same closed-form sim and host arbitration as the trees (`city-props.md`). A wreck never drives again and its alarm
  blinks. Pods do not hit each other and do not run people over: both are ruled out by the timetable and the e-stop.
- **Tram**: stops where it is, doors stay shut. It is a shelter (and a ready-made rescue container later). A mech cannot
  tip it (25 t); shots stop on it.
- Docked pods are props from the start (they can be kicked), and wake into traffic only in calm state.

## 6. Harm, and how weapons treat civilians

The game is about rescue: civilians die easily, so the player has a reason to hold fire (user decision, section 0).

- **Anything that touches a civilian kills it**: a shot's path passing within the shot's radius + 0.4 m of the figure, a
  blast within its radius, a flame stream, a mech's foot within 1 m while the mech moves faster than 2 m/s, a pod or
  prop shoved onto them. The figure tips over (0.4 s, away from the hit) and lies still. No blood, no ragdoll.
- **Shots are not stopped** by civilians (1.8 m next to an 8 m mech): the round carries on and kills whoever is on its path.
- A person **indoors is safe** (buildings are not destructible). A pod wrecked while occupied kills its occupants
  (counted, no figures); the tram protects its passengers.
- **Cost**: mission tallies `killed_by_players` (also per pilot) and `killed_by_enemies`, a signal
  `civilian_killed(id, world_pos, src)` for the HUD bark and audio, and the end-of-mission score. Later the rescue count:
  the dead are subtracted from who can be saved.
- **Enemies** never target civilians (game-design 7), but their fire kills by the same rule and is counted separately:
  a reason to draw a fight away from a crowd.
- **Who decides** (AGENTS.md rule 3): civilians are host-owned, and every machine computes the same positions, so the
  **attacker's machine** tests its own shots and sends a request; the host confirms with `life.down {id, t, dir, src}`.
- **Weapons interface** (group `ambient_life`, one node per scene, world positions):
  `life.sweep(a, b, r, src) -> int` for every shot path (each projectile's movement this step, a hitscan beam, a flame
  stream muzzle to clipped end), and `life.blast(point, radius, src) -> int` from `CombatWorld.splash`. Both return how
  many were killed; neither changes the shot.

## 7. Ties to the rescue game (game-design 8)

- Sheltered civilians are the **rescue pool**: each door knows how many are inside, so "this block has 9 people to get
  out" comes for free.
- The **transport pod** the crew commandeers is this pod; **supply and evac trucks** are bigger vehicles on the same
  lanes. So the lane follower is built to take an order later (`follow`, `hold`, `go to`, `load`) instead of its timetable.
- The tram and the pod stops are where loading happens.

## 8. Networking (AGENTS.md rule 6)

Ambient life is a **host-arbitrated world system built from scheduled effects**:

- **Calm state costs nothing**: every machine computes every agent from `(seed, agent id, shared clock)`. Timetables,
  traffic lights and trips are closed-form.
- **Every change of state is one host event** on the shared clock: `life.threat {point, radius, strength, t}` (at most
  4 per second after merging). Each machine then derives each agent's reaction itself (who is in range, the flinch delay
  from a hash of the id, the refuge chosen by a pure function of the plan), so one small event moves a whole street
  identically everywhere. Also `life.req {id, dir, src}` (attacker to host) answered by `life.down {id, t, dir, src}`, and a vehicle turning into a prop
  (`life.wreck {id, pose, t}`, after which the props system owns it).
- **Only the host raises threats**, from its own combat world, enemy squad and the mech positions it already receives.
  Clients never decide anything about civilians.
- **Late join**: a snapshot of what differs from the timetable: per affected agent `{id, state, pose, t0, target}`, per
  door its occupant count and last-threat time, the hurt tallies. Under 2 KB for a full deck in full panic.
- Transport: `Session.send_event`, as props do. No network code outside `scripts/net/`.
- `net_fields()`: plan and timetables `SPAWN`; agent states, door counts and tallies `OWNER` (the host); drawing `LOCAL`.

Rejected: a host-run crowd sim streamed as snapshots (bandwidth and jitter for something that should be free), and
per-client local crowds (players would see different people in different places, which breaks "rescue that one").

## 9. Performance

- No nodes and no physics bodies per agent. People and vehicles are **MultiMesh** instances; a pose is a choice of mesh
  (walk A / walk B, run A / run B, wary, cower, hands up, down), not a skeleton.
- Agents are evaluated only within 150 m of a player's camera, drawn within 200 m; beyond that they are just a
  timetable nobody asks about.
- Updates at 20 Hz in four staggered groups; transforms interpolated per frame.
- **Budget: 0.5 ms average, 1.0 ms worst per frame** for a full deck (60 people, 16 vehicles, 1 tram) on the host, as its
  own line in `test_perf` so it cannot hide inside the combat budget.

## 10. Look

In the locked city look: chunky low poly, flat colour per face from `CityPalette`, lit only by the light rig.

- **People**: about 40 faces. Box torso, block head, two legs, two arms; clothes in cream, terracotta, sage, sky blue and
  one dark; three body builds and two heights. Readable from a mech's cockpit as a figure, not a face.
- **Pod**: a rounded box with a big teal glass canopy, cream body with one accent stripe, wheels hidden in skirts, a
  light bar front and back (hazards). No driver's seat: seats face each other.
- **Cart**: a low flatbed in sand with a sage hopper.
- **Tram**: three cars, cream over sage, a sky-blue stripe, glazing along the whole side.
- **Concept grid** (the art rule: 3 x 3): pod form (bubble / boxy shuttle / low wedge) x livery (cream-terracotta civic /
  sage municipal / sky-blue transit), rendered on the local renderer once you agree the direction.

## 11. Build plan (after you agree)

Code in `scripts/world/life/`; a lab subject `life`; shown in the test drive. Each phase with tests and renders.

1. **People, calm and panic** in the stand-alone district: plan (doors, sidewalks, crossings, lights), timetable,
   threat events, the seven states, MultiMesh figures, audio signals, lab subject with a "fire a threat here" control.
2. **Pods and carts**: lanes, lights, stops, docking, emergency stop, flee, wreck into props.
3. **Harm and the tally**, the weapons calls, the HUD hook.
4. **Networking**: events, late join, a two-process net test.
5. **Section mode**: tram, checkpoints, ramps.

## 12. Who else is involved

- **Section plan** (transit spine): station and checkpoint hooks, the rail lane, ramps. Read only.
- **Weapons**: the two calls in section 6 and the `fired` / `impact_spawned` signals.
- **Enemies and audio** (antigravity): `EnemySquad.enemy_event` as a threat source, enemies never targeting civilians,
  and the two audio signals in section 4.
- **Main session**: the test drive creates the life node (one line) and the HUD shows the tally.

## 13. Agreed with other sessions

- **Weapons (agreed, 2026-11-22):** every weapon's fire, the enemies' included, emits `CombatWorld.fired(record)`
  (`record.origin` = muzzle, `record.shooter`, `record.weapon`); the flamer emits it 10 times a second and the gatling 12,
  so the threat merge in section 4 must throttle. `impact_spawned(point, radius, explosive, is_energy)` is stable; the
  flamer spawns no impacts. Once this design is approved the weapons session adds `life.blast(point, radius, src)` from
  `CombatWorld.splash` and `life.sweep(a, b, r, src)` once per step per lit flame stream (muzzle to clipped end, radius at
  the end; the flamer is becoming a 45 m, 5 degree cone, so sweeps are long and thin), on the deciding machine only, when
  a node in group `ambient_life` exists.
- **Section plan (answered, 2026-11-22):**
  - **Tram**: the rail lane runs the full arc on every deck, so the tram shuttles between its deck's two end walls and
    passes a wall only through a `portal` gate. A `station` hook is the centre of a transit region beside the spine, not
    on the rail: the tram stops at x = the centre of `lane_x("rail")`, s = the hook's s. Every deck has at least one.
  - **Checkpoints**: a `checkpoint` hook sits where a cross line meets the spine (x = `col_x[spine_line]`, inside the
    avenue lane; j = the cross line nearest its s). `size: "heavy"` closes the avenue there (pods queue, 6 s each);
    `size: "light"` stands beside the road and stops nothing. `cordon` hooks sit in front of sealed blast doors.
  - **Traffic**: right-hand, two-way on every road; no one-way lines. Ramps carry vehicles both ways in one 10 m lane;
    the cross street is closed on that lane's side where a ramp touches down.
  - **Routes**: `road_graph(false)` is the drivable graph over all decks, with `walk` / `path_to`; pods in section mode
    route on it instead of looping a grid.

## 14. Concept grid (rendered)

`docs/design/ambient-life/grid_pods.png`: pod form (bubble / shuttle / wedge) x livery (civic / municipal / transit).
**Approved by the user (2026-11-22):** **bubble** for the 4-seat pod (the only silhouette that does not read as
a present-day car, and the easiest to tell from a mech's height), **shuttle** for the bigger transport pod the crew
commandeers and for the tram's cars, and the **wedge** dropped (it reads as an ordinary minivan). Liveries by role
instead of one for all: civic cream + terracotta for pods, municipal sage for service carts and supply trucks, transit
sky blue for the tram and transport shuttles.

## 15. As built (phase 1: people, 2026-11-22)

Code in `scripts/world/life/`; tests `tests/test_life.gd`, `tests/test_net_life.gd`; lab subject `life`.

- **`LifePlan`** (data from a `CityPlan`, gameplay seed `seed * 15485863 + 7`, `checksum()`): the walk graph is a lane
  3 m in from the curb round every block (the walkway is 1.6..4 m), with every door and street bench as a node on it, and a
  zebra crossing between the facing lane corners of neighbouring blocks (inside the drawn zebra band, 1.8..4.8 m from the
  block corner). Doors: one per building whose lot faces a street, 0.3 m out of the middle of its front facade. Benches:
  the street benches of `CityProps.layout` (park and plaza benches are not used). Lights: a 50 s cycle per junction
  (offset from the seed and junction id). Changed in phase 2 to a 60 s cycle: walk 22 s along x, 8 s turn phase (both
  walk signals red), walk 22 s along s, 8 s turn phase. People: 24 for 220 x 240 m, by area,
  cap 60, or the `people` param; clothes / build / height from `plan.cosmetic_seed()`.
- **Timetable** (`calm_pose(id, t)`, closed form): time is cut into slots of 110-180 s per person; in slot k the person
  leaves a door picked from (seed, id, k), walks the shortest lane route (crossings cost 4 m extra) to another door 25-150 m
  away, waits at a corner until a crossing's whole walk fits in one green, sometimes (35 %) sits on the bench that adds
  the least walking for 20-60 s, and is indoors the rest of the slot. Consecutive trips start at unrelated doors (indoors in
  between), which keeps it closed form. About 50-60 % of people are outdoors at any time.
- **`LifeCrowd`** (no nodes; the shared agent store and threat system, built so vehicles can add their own records later):
  `apply_threat({x, s, r, st, t})` and `kill(id, t, dir, src)` are the only state changes. In range = outdoors and calm
  within r at t. Flinch 0.1-0.4 s (hash of the id), wary 0.5-1 s (0.15 s at strength >= 2), then flee at 4.5 m/s along the
  lane graph (crossings ignored on red) to the cheapest door within 40 m straight / 60 m walking, +30 m for a door closer to
  the threat than the person; no such door, or the threat within 8 m: cower. Ripple: a calm, outdoor person within 8 m of
  someone who starts to flee gets a threat of strength - 1 0.3-0.8 s later (so strength 1 does not ripple, 3 ripples
  twice), derived on every machine. Doors within max(60 m, r) of a threat lock down for 45 s (merged intervals): nobody
  starts a trip from a locked door, sheltered people leave 0-6 s after their door's lock-down ends and resume their
  timetable with the next trip that starts after that. A cowering person stands up 20 s after the last threat within 60 m,
  walks calmly to the nearest door, and is back on the timetable from the next trip.
- **`AmbientLife`** (root node, group `ambient_life`; see the API in the report / file header). Host threats merge within
  10 m and 0.25 s and leave at most every 0.25 s. Kills: `sweep` / `blast` test the displayed (interpolated) positions on
  the calling machine and go through `life.req` on a client; the host kills only people outdoors at its own clock time.
  A down person tips over in 0.4 s (rotation of the standing mesh about the feet) and lies still for the mission.
  `hands_up` is a local look (cowering, a pusher within 10 m, no threat for 3 s), not synced.
- **`LifeFigures`**: 5 clothes colours x 9 pose meshes = 45 MultiMeshes (one instance per person of that colour in each;
  the unused ones scaled to zero). 42 faces a figure (box legs, box torso, head with a hair cap, box arms), 1.8 m, three
  builds and two heights by instance scale. Skin is `terracotta_light`, hair `trunk`, trousers from the palette.
- **Measured** (headless, 60 people, `_process` timed directly): 0.08 ms average, 0.29 ms worst per frame, calm and in
  full panic; applying a threat that alarms 10 people 0.8 ms (once); a sweep that misses everyone 0.5 us; plan build 2 ms.
  Not in `test_perf` (no per-system slot there).

**Not built / deviations (phase 1)**: section mode, tram, checkpoints (later phases); enemy alerts as a threat source
(waiting on antigravity); no 150 m / 200 m evaluation or draw cut-off (the
whole district is evaluated, still well inside budget); "doors let people out one at a time" is a 0-6 s spread per
person, not a queue; a sitter does not notice that their bench was knocked over; on a clock change (a session starts or
ends) every alarm and lock-down is dropped (the dead and the tallies stay); `door_count` is computed, nothing shows it.
Renders: `docs/design/ambient-life/life_calm.png`, `life_street.png` (default 24 people), `life_panic.png`,
`life_killed.png`, `life_panic_close.png` (60 people, to get several states in one frame).

### Phase 2 (pods and service carts, 2026-11-22)

- **Phase 1 fixes.** A mech (any registered pusher) moving faster than 0.5 m/s within 12 m of someone outdoors or 20 m of
  a vehicle is a host threat (12 m, strength 1, at most once a second per pusher): people step away into doors or crouch,
  vehicles in reach e-stop. There is no local-only sidestep. Park benches (round the fountain, reached by the four park
  paths and a paved ring of 5.5 m) and plaza benches (straight in from a street side when that misses the planter) are
  timetable destinations now. Roof props in `CityProps.layout` (field `building` >= 0) are ignored.
- **`LifeTraffic`** (plan, `checksum()`): 8 pods + 2 carts for 220 x 240 m, by area, caps 12 / 4, params `pods` / `carts`.
  Every vehicle drives a loop round one block with the block on its right, in the lane next to that block's curb (street:
  4.45 m out, beyond the parking strip; avenue: the outer lane, 2.93 m out), so it only ever turns right, along a quarter
  ellipse round the block corner. Loops of different blocks never share a lane or a junction quadrant. A turn starts at
  the painted stop line (6 m before the box) and is timed into the junction's turn phase so the vehicle is off both zebras
  before walk returns. Pods pull into the parking strip for a 10 s stop on every other long street side and end each lap
  docked in the strip; the dock pads the lap to a whole number of signal cycles (some pods dock two cycles longer: the
  "parked cars"), so the timetable repeats exactly. Several vehicles on a loop are the same lap shifted by whole
  multiples of K cycles, K > the dock. Carts crawl at 4 m/s and stop 3 s beside each bin. Speeds: 9 m/s streets,
  12 avenue, 5 in turns, 4 pulling over.
- **`LifeFleet`** (state, driven by the same threat events; reworked in the phase 2 fix round). Each event that touches
  a loop (a threat within 30 m of one of its vehicles, a wreck of one of them, a wreck landing in or leaving its lane)
  starts an episode that anchors the loop's vehicles where they are:
  - threat: vehicles in range e-stop (reaction 0.2-0.5 s, 10 m/s^2, hazards); a pod with passengers lets 1-2 out 0.8 s
    after stopping (rider slots, 8 per mission); a pod with nobody aboard, or 1.5 s after its last passenger got out,
    speeds away from the threat along its own lane: forward (5 m/s^2 up to 14 m/s, 8 m/s^2 down) when the threat is
    behind, reversing (4 m/s^2 up to 8 m/s, 6 m/s^2 down) when it is ahead, until 80 m from it, short of the next stop
    line (forward) or the last clear point (reversing), and 6 m short of any vehicle or wreck; with less than 10 m of clear
    lane it stays put with hazards (abandoned). The rest of the loop brakes to a stop. Held until 15 s after the last
    threat in range (merged lock-downs).
  - restart: every vehicle drives on at once from where it stands at its lane's speeds, waits at the next stop line for
    its own timetable and from there is that timetable again, shifted by a whole number of 30 s turn-phase periods (one
    shift per loop, the smallest that keeps every vehicle's timetable behind where it restarts), so spacing and turn
    timing hold. A vehicle stopped inside a turn finishes it in the next turn phase (that one may wait up to 30 s).
  - always: 6 m bumper to bumper behind the vehicle ahead on its loop and behind any wreck in its lane, waiting at the
    stop line instead when that spot is inside a junction. Queued vehicles show `stopped`, hazards off. A wreck shoved
    out of the lane starts an episode that does not hold: the queue drives on at once.
  A wreck never drives again. Its slide is `CityPropSim`'s SHOVE (called read-only) with the vehicle's mass (pod 900 kg,
  cart 500 kg; start speed up to 10 m/s x min(800 / mass, 1), so a blast or a mech can shove it clear of a lane); it tips
  onto its side in 0.7 s on a blast or a push faster than 8 m/s; blasts and pushes shove a wreck again, shots do not.
  Passengers still inside are killed and counted (`occupants_killed`, also in the player / enemy tallies and per src).
- **`LifeCars`**: 6 MultiMeshes (pod and cart, each plain / hazards dark / hazards bright). The pod is a rounded 16-sided
  loft (cream, terracotta stripe, dark-teal glass canopy over the top half, cream roof cap, dark skirt), light bars front
  and back. Hazards (and a wreck's alarm): big amber bars front and back and a band round the roof edge, swapped between
  dark amber (`terracotta_dark`) and bright amber (`marking_yellow`) at 1.5 Hz; no emission (CityPalette's only emissive
  material is the cream ceiling strip). A wreck is the same mesh rolled.
- **Measured** (headless, 60 people + 12 pods + 4 carts, `_process` timed directly): calm 0.14 ms average / 0.38 ms
  worst per frame; held after four big threats 0.13 / 0.41 ms; restarting 0.13 / 0.64 ms; applying four threats 5.8 ms in
  all (with episodes); a sweep that misses 0.6-4 us; plan + traffic build 9 ms.

**Not built / deviations (phase 2, after the fix round)**: vehicles have no collision (shots and mechs pass through);
a wreck blocks a loop when its resting centre is within 2.4 m of that loop's path, so one lying just beyond that, partly
over the lane, is driven through;
a vehicle out of range on a halted loop just stops; vehicles never go straight through a junction or leave their block
loop (so they do not cross the district); a pod speeding away stops at the next stop line rather than turning through the
junction; no pod stops on the avenue (no parking strip); centre-to-centre spacing of 5 m holds within a loop, while
oncoming vehicles in adjacent lanes pass 3.1 m apart (their footprints never touch); a vehicle halted inside a turn waits
for the next turn phase before moving (up to 30 s); the "queue waits before the junction" rule is in the code but has no
test of its own. Renders: `life_traffic.png`, `life_pod_close.png`, `life_panic_traffic.png` (a stopped pod with hazards
and its passengers running), `life_riders.png` (passengers getting out, sidewalk camera), `life_wreck.png`,
`life_crowd_{calm,panic,killed}.png` (24 people) and `life_crowd_{calm,panic,killed}_60.png`; no still of a pod speeding
away (a still cannot show it).

### Phase 3 (section decks, the stack, the tram, checkpoints, 2026-11-22)

New files `life_tram.gd` (`LifeTram`), `life_tram_cars.gd` (`LifeTramCars`), `life_barriers.gd` (`LifeBarriers`); test
`tests/test_life_section.gd`; a stack phase in `tests/test_net_life.gd`. A district on its own is unchanged (same plan and
traffic checksums, same ids, no viewer culling unless a viewer is registered).

- **One `AmbientLife` for a stack.** `setup_stack(stack, people = -1, pods = -1, carts = -1)` makes one child
  `AmbientLife` per deck ("Deck0".., a *unit*: not in the group, not connected to the session), each built with
  `setup(stack.decks[k])` and working in that deck's frame (`global_transform`, so an offset, rotated stack works). The
  stack node routes: `raise_threat`, `blast` and pushers go to the deck `stack.deck_at()` names (a threat or a blast never
  reaches another deck, also not through a floor hole); `sweep` is tested on every deck (each early-outs on its own
  bounds, so a miss is still two AABB tests per deck); every deck's `CityProps` is bound by `setup_stack` itself.
  **Ids**: `deck * AmbientLife.ID_STRIDE (1000) + the id on that deck`, for people and vehicles separately; deck 0's ids are
  the stand-alone ones. `ids()`, `vehicle_ids()`, `unit(k)`, `count()` / `vehicle_count()` (all decks), and every query
  (`state_of`, `pose_of`, `visible_now`, `drawn_now`, `vehicle_state`, `vehicle_pose`, `vehicle_kind`, `tally` summed)
  take stack ids. `civilian_killed` carries the stack id. **Events**: no new names; `life.threat`, `life.req`,
  `life.down`, `life.wreq` and `life.wreck` from a unit carry `"deck": k` (their x / s / id are per deck); no key = deck 0
  or a district on its own. `life.sync` carries the whole stack's snapshot (deck count, then each deck's length-prefixed
  snapshot); a section deck's snapshot adds the fleet length and the tram's halts. **Only one AmbientLife per scene**
  handles `life.*`: a second one in the tree refuses to connect to the session and pushes an error.
- **Near viewers only.** `add_viewer(node)` / `remove_viewer(node)`. In a stack with none registered the current camera
  is the viewer; with no viewer at all nothing is culled. A deck with no viewer on it (by `deck_at`) is not evaluated or
  drawn (its tram's collision bodies still move); on a viewer's deck an agent within 150 m is sampled at 5 Hz, 150-200 m
  from 1 Hz samples (interpolated), beyond 200 m hidden and re-checked once a second. Hidden agents cannot be hit (a shot
  from beyond 200 m of every viewer on that machine misses civilians). Poses are functions of events and the clock, so an
  agent coming back into range is exactly where the events put it (tested against an instance with no viewers).
- **Section-mode people (`LifePlan`).** No walk edge passes through a floor cut (grown by the curb + 0.4 m), and plaza
  bench approaches avoid them. The zebras beside spine junctions are not used (they would cross the ramp-lane cuts and the
  rail lane away from a cross street); instead, at every inner cross line, a crossing along the cross street (on the line,
  or a quarter of the street's width off it if the line hits a cut, a ramp mouth or kept-clear ground; off the line when a
  heavy checkpoint's barrier stands there), split from the cross-street zebras beside the spine, in three pieces:
  ramp_a (no signal), the avenue (the spine junction's walk signal), rail + ramp_b (`rail_edges`: started only when the
  tram's **timetable** keeps every car more than 40 m from the line for the whole piece, `LifeTram.next_clear`).
- **Section-mode vehicles (`LifeTraffic`).** Arterial, cross and perimeter roads are streets (parking strips, pull-overs).
  A block beside the spine has ramp lanes next to it, so **its loop is dropped**; every lap path is checked (inside the
  walls, out of floor cuts and the rail / ramp lanes) and dropped if it fails. **Avenue loops** carry pods on the spine's
  avenue lane: on every other stretch between two cross lines (so no two share a junction; the parity that covers most
  heavy checkpoints), right-hand traffic in the outer lanes, a U-turn (half circle starting 2.5 m before the box) at each
  end timed into the turn phase like every corner, docked against the avenue's -x edge midway; half the pods (up to two
  per loop), the rest on block loops (up to three per loop). Nothing else uses the avenue lane, so the no-overlap argument
  holds. Pods do **not** take ramps between decks in this phase (block and avenue loops only). Closed gates: no loop
  reaches a wall gate (perimeter roads run along the walls), so they are dead ends by construction.
- **Checkpoints (`LifeBarriers`, cosmetic, no collision).** `heavy`: two striped arms (terracotta / marking, 0.8 m
  stripes) meeting mid-road across the avenue lane (or across the road the hook is on) at the cross line, a low booth at
  each end; every loop with a turn at that junction holds 6 s (`CHECK_STOP`) at its stop line, a HOLD mark before the turn
  wait in the timetable (closed form, no-overlap kept). `light`: one booth on the sidewalk corner beside the junction.
  `cordon`: concrete barrier blocks (yellow band) across the sealed gate at the hook.
- **Tram (`LifeTram`, `LifeTramCars`).** One per deck, three shuttle cars 3 x 9 m, 3.2 m (sky blue, cream lower band,
  dark glazing, windscreens at both ends, roof unit), 0.6 m apart, on the rail lane's **-x track** (a quarter of the lane
  off its centre: centred, it straddled the two drawn tracks). Shuttles between end stops 3 m short of each end wall,
  14 m/s, 1.2 m/s^2, 20 s at every station hook's s (middle car's centre; stations within 30 m merged, clamped inside the
  end stops), 10 s at an end before reversing; through a `portal` it turns round 100 m beyond the wall with its centre
  beyond the wall for 40 s. Phase per deck from the seed. Halts: a threat within 60 m of any car brakes it (0.3 s
  reaction, 2.5 m/s^2), hazards, doors shut, held to 15 s after the last threat in range, then it drives from where it
  stands to the stop it was heading for, dwells there and rejoins its timetable at that departure, shifted (episodes in
  `LifeTram`). Not wreckable, not pushable; sweeps / blasts / pushers ignore it. `vehicle_event("tram_bell", pos)` on
  leaving a stop or restarting. Collision: one `AnimatableBody3D` per car (`sync_to_physics` off, layer 1, a 3 x 3.2 x 9
  box), moved to the pose every frame; a car wholly beyond an end wall is hidden and its shape disabled. Queries:
  `tram_state(k)`, unit `tram_car_pose(i)`.
- **Lab.** Option `site` (alone / section / stack), param `deck`, cameras `station`, `tram` (close), `checkpoint`
  (the clock is moved on to a dwell / a pod at the checkpoint); in section / stack a viewer node stands on the focus.
  `--life site=stack,seed=4,camera=station`.
- **Measured** (headless, 3-deck stack seed 1, 60 people + 6 pods + 4 carts + a tram per deck, `_process` of the stack
  node and its units timed directly): viewer on deck 0, calm 0.12 ms average / 0.39 ms worst per frame; after four threats
  0.12 / 0.86 ms; no viewer at all (every deck evaluated) 0.45 / 4.8 ms (the worst is the first frame resampling all three
  decks). `setup_stack` 159 ms; the stack itself 0.9 s. Plan + traffic per deck 45-65 ms.

**Not built / deviations (phase 3)**: pods per deck are 5-9, not 12 (only the blocks away from the spine take block loops,
and every other avenue stretch); pods do not use ramps; people waiting for the tram use its timetable only, so after a
halt (shifted timetable) a calm walker can still be on the rail piece as the late tram passes, and fleeing people route
over the rail piece without waiting; people waiting at the rail piece stand at the avenue's edge, 1.5 m from a passing
car; a deck with no viewer on it is not drawn even when visible through a floor hole; viewer culling is per machine (a
client's shot at a civilian more than 200 m from its own viewers misses); barriers have no collision and walkers on the
light checkpoint corner pass through its booth; the spine zebras are still drawn but unused; the test drive / mission do
not create the stack life yet. Renders: `life_tram.png` (stack seed 4 deck 0, the tram dwelling at a station, the cordon
blocks at the far blast door), `life_tram_close.png`, `life_checkpoint.png` (a pod held at the heavy checkpoint, arm and
booth beyond it), `life_section_street.png` (mech eye on a section deck: one person and a service cart in frame).

**Pod model adopted (user pick: candidate 7, `capsule_a`, 2026-11-22).** `LifeCars.pod()` calls
`LifePodVariants.adopted(geo, lights)` (one source of truth; the gallery still draws the nine candidates unchanged):
the capsule_a body and glass, trimmed to 484 triangles plain / 496 with hazards (one lighter facet on each end glass only,
no dark lower split on the door glass, a straight side stripe, hexagonal wheels with a three-sided pyramid hub cap), closed
and consistently wound (tested: every directed edge has its reverse). Pale light bars sit in the end slots with no housing;
hazards are amber bars in those slots (y 0.80, z +-1.735) at both ends and a 1.1 x 1.0 m amber band on the roof
(`terracotta_dark` / `marking_yellow` at 1.5 Hz). Wheels inboard with 0.28 m clearance (unchanged: they read at the
junction camera's distance). `LifeTraffic.SIZE["pod"]` is now 1.85 x 1.95 x 3.5 m, which moves pod stop lines 0.05 m and
so changes the stand-alone traffic checksums (seed 1/2/3: `742568104e969d8d`, `f95817faffc270f1`, `3daf84e9a4299bca`);
riders already left from the middle of the side. Re-rendered: `life_pod_close.png`, `life_traffic.png`,
`life_panic_traffic.png`, `life_riders.png`, `life_wreck.png`.

### Crowd lab (lab subject `crowd`, 2026-11-22)

`scripts/world/life/crowd_lab.gd` (`CrowdLab`), test `tests/test_crowd_lab.gd`. The civilians on their own, on the real
systems: a small seeded `CityDistrict` (walled, its own daylight rig) with an `AmbientLife` on it, so the timetables,
threats, kills and `LifeFigures` drawing are exactly the game's. Made to judge civilian animations and looks: it talks
only to `AmbientLife`'s public API and the debug hooks below, never to `LifeFigures`, so it keeps working when the
figure drawing is replaced. Run it with `.\lab.ps1 crowd`, or for a shot
`--scene res://scenes/lab.tscn --subject crowd --shot out.png --shot-after 4 --crowd camera=close,people=40,inspect=auto`
(`--crowd k=v,...` presets any param / option; `inspect=auto` picks the visible figure nearest the crowd focus,
`threat_at=focus` puts the threat on it).

- **Params**: seed, people (1..200, default 24), area (district side 90..240 m, default 130: density = people / area),
  life clock speed (the lab's pause / speed scale it too), threat_x / threat_s (arc m), threat_r (alarm radius),
  kill_r (blast kill radius), repeat_s (0 = once), inspect (figure id, -1 none; out of range is reported, not an error).
- **Options**: camera `lab` (the lab's orbit round the crowd focus) / `close` (2-3 figures) / `group` / `street` /
  `mech_eye` (10 m up in the street, figures 30-80 m away) / `top` / `follow` (the inspected figure); state `timetable`
  or any `AmbientLife.DEBUG_STATES` key, on the `crowd` or the `inspected` figure; threat `off` / `gunfire` (three
  seeded sweeps through the point + a strength-2 threat) / `blast` (`blast(kill_r)` + a strength-3 threat) / `mech`
  (a stand-in pusher walking 50 m through the point at 3 m/s: proximity threats and kills on contact); quality
  high / medium / low (`AmbientLife.set_quality` and the rig's); lighting. Buttons: Fire threat, Reset crowd
  (`restore` of an empty snapshot + the clock back to 900 s: everyone alive and calm), Inspect nearest.
- **Shown**: a red post and rings at the threat (alarm radius faint, kill radius for a blast), a yellow ring, cone and
  "#id mode" label on the inspected figure, and a readout (top right): alive / down / outdoors / drawn, the histogram of
  `state_of` and of `mode_of`, the figures' draw calls (visible GeometryInstance3D under `life.figures`) and instances,
  life's own `_process` time (ms per frame, averaged over 1 s, display only), the threat, the forced state, and the
  inspector (`debug_person`: state / mode, timetable activity, speed, heading, trip doors home -> destination, bench,
  alarm record, down, seeded variety cloth / build / tall / period / phase).
- **Real states today** (`DEBUG_STATES`, one list; add a new animation there and the lab lists it): walk, idle (the
  timetable's "wait"), sit, flinch ("wary"), flee ("run"), cower, hands_up, down, and look_around (animation only:
  one of the idle's variations, forced as mode "look_around"; not a crowd state). "Knocked over" is the kill
  ("down"): a non-lethal knock-down does not exist.
- **Shot options** (`--crowd`): `ui=hide` (lab panel and readout hidden), `markers=hide`, `fire_after=s` (first threat
  this long after a build, default 0.5), `frames=<dir>,frame_n=N,frame_dt=s,frame_after=s` (N viewport PNGs every
  frame_dt wall seconds, then quit: GIF strips).
- **Debug hooks on `AmbientLife`** (lab only, `Net.LOCAL`, never sent, never called by the game):
  `debug_force_state(id | -1, key)` / `debug_clear()` / `debug_forced(id)` (a presentation override applied in the
  pose sampling: `state_of`, `mode_of`, `pose_of` and the figures follow it; the crowd's own state, threats, kills,
  `snapshot()` and `tally()` never do; nobody is moved: people indoors stay hidden, the dead stay down; free while
  unused, one empty-dictionary test per sample), `debug_person(id)`, `mode_of(id)` (public: the animation a drawer is
  asked for), `debug_people_cap` (passed to `LifePlan.make(..., cap)`, default `PEOPLE_CAP` 60: the lab raises it to
  200), `debug_profile` / `debug_us`. The test checks a hook-free run is bit-identical (snapshot hash) to the code
  before the hooks.
- Shots: `docs/design/ambient-life/crowd_lab_close.png`, `crowd_lab_street.png`, `crowd_lab_mech_eye.png`,
  `crowd_lab_panic.png`, `crowd_lab_inspect.png`.

## Civilian animation: candidates (prototype, 2026-11-22; the user picked C, built: "Civilian animation: as built")

User: "They are a little too blocky with simple animations. Improve the animations first, then the look for the high
detail setting if still needed." Step 1 is choosing an animation **style** (art rule: show options before building).
Same figure look as today in every candidate (LifeFigures' boxes, palette colours, proportions); only the motion differs.
Nothing in the game changed: the prototype is the lab subject `life_anim` (`scripts/world/life/life_anim_lab.gd`,
`life_anim_rig.gd`, `life_anim_limbs.gdshader`).

**Today, measured.** 9 baked pose meshes x 5 clothes = 45 MultiMeshInstances a deck, ~84 triangles a figure. Walk = two
meshes (walk_a / walk_b) flipped every 0.75 m of route distance, run = two meshes every 1.4 m (always arms up in a V),
flinch = the `wary` mesh, cower / hands-up / sit = one mesh each, killed = the idle mesh tipped over rigidly in 0.4 s.
The mesh only changes at a person's 20 Hz-group sample (every 0.2 s), so the walk reads as a two-frame shuffle. Per frame
the CPU writes one interpolated transform per visible person (plus a hide write when the pose mesh changes).

| | How | Draw calls (deck) | Per figure per frame | Feel |
|---|---|---|---|---|
| **A  more poses** | today's technique, ~60 baked poses (8-frame walk, 8-frame run x 2 arm styles, 4 idles x 4, flinch 3, cower 4, fall 4 + lying, sit, hands up) | ~300 MMIs (60 poses x 5 clothes; ~60 if clothes move to instance colour) | as today + 2 writes at every frame switch (8 a cycle) | stepped, stop-motion; hard cuts between states |
| **B  shader limbs** | ONE jointed mesh (10 rigid boxes: torso, head, upper / lower arms, thighs, shins; part id in UV.x), posed in the vertex shader from MultiMesh custom data `(state + 16*prev, t0, seed, dir/turn)` | 5 MMIs (one per clothes) or 1 with clothes as instance colour | as today (1 transform); custom data only on a state change | smooth swing, bob from leg geometry (feet stay planted), lean, 0.2 s blends |
| **C  limbs + character** | B + secondary motion and acting in the same shader: head leads turns and look-arounds with torso follow, overshoot on starts / stops, hip drop and shoulder counter-twist, idle sub-actions cycling (look around / wrist check / phone / talk with gestures), panic: look back, flailing arms, stumble; cower: anticipation, tremble, peeking; fall: knees buckle, arm fling, whiplash, bounce, settle into a sprawl | same as B | same as B (shader ~2x ALU of B; ~120 tris, ~360 vertices a figure: negligible at 24-60 people a deck) | alive, readable acting |

How the shader is driven: the clock is **one uniform** set once per frame from `AmbientLife.now` (the shared net clock
online, the local clock x `time_scale` offline), so pause, lab speed and net time just work; the full build would make it
a global shader uniform (`life_clock`) so every deck's material shares it. Per-figure variety (stride, speed, posture,
handedness = mirrored poses, phase, idle variant, which way they glance) comes from the seed in the custom data (the
game would pass `LifePlan.h(id, k)`), never the global generator. Flat shading is intact (rigid parts, normals rotated
with the part, same lit vertex-colour material as `CityPalette.surface_material()`: albedo sRGB vertex colour,
roughness 1, specular 0.1); render layers / cull masks are the instance's as usual.

**Sheets** (`docs/design/ambient-life/`): `grid_civilian_anim.png` (the 3x3 to show: A / B / C x walk / panic run /
knocked over, numbered 1-9, today as a reference row), per motion `anim_sheet_<walk|idle|run|cower|flinch|fall|turn>.png`
(one row per style, 8 time-ordered frames), `anim_sheet_sequence.png` (walk > flinch > run > cower > fall, frames around
each transition: popping), `anim_sheet_idle_variety.png` (8 seeds at the same moment), `anim_sheet_exag_<walk|run|fall|idle>.png`
(C subtle x0.6 / natural x1.0 / cartoony x1.5), `anim_mech_eye_40m.png` / `anim_mech_eye_20m.png` (a mixed crowd per style
from 10 m up, 70 deg FOV). GIFs: `anim_today.gif`, `anim_A.gif`, `anim_B.gif`, `anim_C.gif` (walk, run, fall),
`anim_all.gif`, `anim_mech_eye_40m.gif`.
(The prototype lab subject `life_anim` that rendered them was removed when C was built: its "today" and A previews
needed the old pose meshes. The crowd lab shows every motion on the game's own rig.)

**Findings.** Limbs stay attached (child boxes overlap their joint), feet stay on the ground (the body height comes
from the longer leg), flat shading holds. A is visibly B with fewer frames: on a sheet A and B look alike, in motion A
pops (and every state change cuts). Today's figures cast no visible shadow in these shots (the game's own shots agree;
likely the sun's large normal bias on thin boxes); the rig's shadow pass did, so the prototype turns rig shadows off for
a fair comparison (shadows would be a look-step choice). At 40 m from a mech the figures are ~20 px tall at 1080p:
there, only the big shapes read (lean, arms up, crouch, lying, stride width); C's head / hip / hand detail is invisible,
but its stumble, look-back and sprawl still read as "panic" / "dead" rather than "posed mannequin".
Two honest caveats from the sheets: (1) at 40 m today's poses read **as well as or better** than B at natural
amplitude, because they are extreme silhouettes (both arms up in a V for every runner, one arm raised in cower): the
jointed poses are more compact (pumping arms, hands on head). Whatever style is picked should keep wide silhouettes for
the panic states (more hands-up runners, bigger arm swing) and use exaggeration around x1.3. (2) Run -> cower briefly
stands up before crouching (the cower entry starts from a standing pose; B / C blend over it, A cuts): the full build
starts the entry from the previous motion. Everything else blends without popping in B / C (`anim_sheet_sequence.png`).
`anim_mech_eye_40m_crop.png` is the 40 m shot cropped at native pixels.

**Recommendation: C at exaggeration ~x1.3** ("natural-to-cartoony"). It costs the same as B (5 or 1 draw calls a deck
instead of today's 45, nothing extra per frame), the acting is what makes the street read as people at 15-40 m (look-
around, phone / wrist / talk idles, look-back and stumble when fleeing, knees-buckle-and-sprawl when knocked over), and
the bigger amplitude buys back the silhouette at 40-150 m. B is the fallback for LOW. A is not worth it: ~6x today's draw
calls and more CPU writes for a stepped look that is strictly worse than B.

**What the full build would involve** (after a pick; nothing of this is built):
- `LifeFigures`: one MultiMesh per clothes variant (or one per deck with clothes as instance colour), `use_custom_data`,
  the jointed mesh, the shader material; `show_pose(id, pose, xf)` becomes `show(id, xf)` + `set_motion(id, code, t0,
  w)` written only when the motion changes. Instance counts, HIDDEN transform, `render_layer` before `add_child`
  unchanged. 45 MMIs a deck -> 5 (or 1).
- `AmbientLife._sample` returns a motion code and its start time instead of a mesh id: walk / run start at the trip /
  flee start (walk phase from route distance: custom data carries the distance at t0 and the speed, so feet never
  slide), flinch = `t_alarm`, flee = `t_flee`, cower = the record's start, down = `dead.t` with the fall direction
  relative to the heading, turn = a heading change over ~30 deg between samples, sit / idle from the timetable. All of
  it is already a pure function of `LifeCrowd.pose(id, t)`: no new state, no new message; the host still arbitrates
  threats and kills (`life.threat`, `life.down`), clients stay cosmetic-only. Hit tests keep using the figure
  position, not limbs.
- The shader clock as a global uniform set once a frame by the stack root (pauses and time scale follow `now`).
- LOW quality: same shader with `character` 0 (B) and the existing draw radius; MEDIUM / HIGH C. Cheaper than today in
  draw calls at every level.
- Tests: `test_life` (motion codes per state, deterministic per seed), `test_render_layers`, `test_perf` (the 0.5 ms
  life budget), a visual shot per motion; the lab subject `life` shows it in the real district.

## Civilian animation: as built (Build C, 2026-11-22)

User pick from `grid_civilian_anim.png`: **C, shader limbs + character, at ~x1.3**. The look (boxes, proportions, palette,
five clothes sets, builds, heights) is unchanged; only the animation changed. Gameplay and co-op are untouched: the
crowd's states, timetables, host arbitration, `life.*` messages, `snapshot()` / `restore()`, `tally()` and every hit test
(positions and the 1.8 m capsule, never the mesh) are bit-identical (the crowd lab's captured hash still passes).
Animation is cosmetic on every machine, computed locally from the same state and clock.

**Rig** (`LifeAnimRig`, `life_anim_rig.gd`): one jointed figure mesh, 10 rigid parts (torso, head + hair, upper arms,
forearms, thighs, shins), **132 triangles**; UV.x = part id, UV.y = colour slot (0 vertex colour: skin / hair, 1 shirt,
2 trousers), so one mesh serves every clothes set. Child boxes overlap their joint, so bends never open a gap.
`static_figure(geo, v)` gives the same figure standing still as plain geometry (the pod gallery's scale figure).

**Drawing** (`LifeFigures`): **one MultiMeshInstance3D per deck** (was 45: 9 pose meshes x 5 clothes), one instance per
person (index = id), `use_custom_data`, `material_override` = the shader material, `layers` = the deck's render layer set
before `add_child`, the district's bounds as `custom_aabb`. Per frame the CPU writes one transform per visible person
(`place`, as before) and one material uniform (`set_clock`); custom data (`set_motion`) only when that person's motion
changes / starts or a turn starts (measured: 74 writes in 30 s of a calm 60-person street over 817 visible
person-seconds, about 0.1 per person-second, against 30 transforms per person-second).

**Shader** (`life_anim_limbs.gdshader`, spatial, `cull_back`, lit like `CityPalette.surface_material()`: vertex colour
sRGB -> linear, roughness 1, metallic 0, specular 0.1; normals rotate with their part, flat shading intact). Custom data:
- x = motion + 16 x previous motion + 256 x clothes + 2048 x talk + 4096 x (turn / 5 deg + 36)
- y = life-clock time the motion began, minus an epoch (a multiple of 4096 s, so float32 keeps ms precision)
- z = 1024 x walking speed (cm/s) + seed (10 bits, `LifePlan.h(id, 91)`)
- w = metres walked at y (walk / run: the stride runs from distance, feet do not slide) or the fall direction (radians,
  model space) for a kill.
Shirt / trousers palettes are uniform arrays. The pose (root sway / bob / yaw / roll, spine lean / twist / roll, head,
arms with elbows, legs with knees, topple) is evaluated per vertex; the lower foot is kept on the ground from the leg
geometry (the bob comes from the legs). Blends: 0.3 s from the previous motion (0.45 s into cower / hands up, 0.18 s
into a fall), always from the previous motion's pose (fixes the prototype's run -> cower standing-up pop).

**Clock**: `anim_time` = `AmbientLife.now` minus the epoch, set once a frame on the deck's material (one material per
`LifeFigures`; no global shader uniform: two AmbientLife instances in one process, tests and labs, run different
clocks). `now` is the shared net clock online and the local clock x `time_scale` offline, so pause, lab speed and net
time just work.

**Motions** (`LifeAnimRig.MODE_MOTION`: crowd mode -> motion; every `DEBUG_STATES` entry maps to one, tested):
- **walk** (`walk`): stance-linear gait (the planted foot sweeps exactly the stride: A = asin(stride / 4 / leg)),
  seeded stride 1.35-1.65 m, knee lift in the swing, arm swing against the legs, hip drop and shoulder counter-twist,
  now and then a glance aside. Phase = metres walked, so feet do not slide.
- **idle** (`wait`): weight shift, breathing, sub-actions cycling by seed: look around, check the wrist, phone, talk;
  `talk` (another idle person within 3 m when the wait starts) makes it mostly talk gestures.
- **look_around** (lab-forced; in the game an idle variation): head sweeps both ways, torso follows.
- **sit** (`sit`, the existing benches): thighs on the seat, shins to the floor, occasional head turn.
- **flinch** (`wary`): recoil with forearms up and a step back, overshoot, then holds wary with a tremble; starts at the
  alarm record's time.
- **run** (`run`, fleeing): lean, flight phase, pumping and flailing arms; **40 % of runners (by seed) run with both
  arms up**, waving (the wide silhouette reads at 40 m); look-back over the shoulder and an occasional stumble.
- **cower** (`cower`): crouch with hands on the head, entered from the previous motion (anticipation flinch on the way
  down), trembling, peeking out.
- **hands_up** (`cower` + a mech within 10 m and no shot for 3 s, the existing local look): arms straight up, half step
  back, trembling.
- **fall** (`down`, the kill): knees buckle, the body twists to face (or turn its back on) the **hit direction from the
  kill event** (`dead.dx / ds`, so it is the same everywhere), topples along it, arms fling, head whiplash, one bounce,
  then settles into one of four sprawls (by seed) on its front or back and lies still. `pose_of` still returns the old
  tipped transform (`LifeFigures.tip`) for the dead.
- **turning** (all upright motions): the drawn heading eases toward the route's (exponential, tau 0.16 s) instead of
  snapping (`AmbientLife._turned`, rotation only: positions and hits untouched); a gap over ~29 deg at a sample writes a
  turn into the custom data and the head and shoulders lead into it (a standing person shuffles its feet round).
Variety (all from the person's seed, never the global generator): stride, arm swing, posture, head pitch, handedness
(20 % mirrored), phases, idle variant cycle, hands-up runner share, glance / stumble timing, sprawl. Exaggeration
`LifeAnimRig.EXAGGERATION` = 1.3 (one constant; legs follow the stride, not it).

**Quality**: same shader at every level (the character layer is multiplications, not branches: nothing measurable to
save by dropping it). HIGH / MEDIUM: real shadows from the posed figure (the shadow pass runs the same vertex
function); LOW: figure shadows off (`AmbientLife.set_quality` -> `LifeFigures.set_shadows`), plus the existing shorter
draw radius. No contact blob: the real shadows ground the figures in the shots; no acne or peter-panning seen.

**Costs** (crowd lab, seed 1, 130 m, 40 people + 8 riders, close camera, same frame): before 45 MMIs / 432 instances,
life update 0.192 ms a frame; after 1 MMI / 48 instances, 0.194 ms (unchanged within noise). Headless `_step` without
culling: 24 people 0.17 ms, 60 people 0.32 ms, 200 people 0.94 ms a frame. Triangles a figure 84 -> 132; the vertex
shader is the new GPU cost (~400 vertices a figure, 24-60 figures a deck: negligible).

**Not done / known**: the prototype gallery (`life_anim`) was removed rather than ported. (Timetabled people waiting at
the same corner node used to stand on the same point: fixed, see "Crowd spacing".) A falling body's limbs can clip a neighbour or a wall. Forced lab states apply where people stand (a forced
hands-up sitter stands up in place on the bench). Shots: `docs/design/ambient-life/civ_c_*.png`, `civ_c_crowd.gif`.
Test: `tests/test_life_anim.gd`.

## Crowd spacing (2026-11-23)

User, on `civ_c_crowd.gif` (the crowd lab's `group` camera, 160 people on a 90 m district, a blast): "like 10 people
standing in the same spot". It was the timetable: everyone waiting for one green at a corner stood exactly on the corner
node (8-17 people on one point in the lab, 3-4 in the game's districts), sitters on a bench shared one seat point, walkers
on a side all walked its one centre line, and a blast left the bodies where they stood (on that point). Now people never
stand, wait, sit, cower or lie on the same spot. Everything below is a pure function of (plan / seed, person id, the
timetable, host events): no message, no new event, the same on every machine; the timetable's times are unchanged.

- **Standing slots at crossings** (`LifePlan.wait_slots`): per crossing node, slots for each of its crossings laid out
  once (all the node's crossings together, round robin, after the benches and lower-index crossing nodes within 14-16 m,
  so the layout never depends on which was asked first): rows 0.9 m apart ahead of / on / behind the node, columns 0.9 m
  apart along the curb (away from the node's other crossing), at least `SLOT_GAP` 0.9 m from every other slot, on the
  walkway only (1.7-3.95 m from the curb: not in the road, the furnishing band or a building, clear of props by their
  radius + 0.3 m, of benches, park fountains and plaza planters), up to 32 a crossing. Nodes in a road (section mode: the
  spine pieces) never step forward into the lane ahead; nothing waits in the rail lane; at a node beside the rail lane
  the slots are on the lane's edge line only (the rail crossing's own pair at +-0.45 m, the others further along), and on
  a rail piece the step to / from a slot takes the last / first 0.4 m (`RAIL_TURN`), so inside the rail lane a walker is
  never more than 0.45 m off the crossing's line.
- **Who stands where**: the hold index (`LifePlan._groups`, per 60 s window): everyone whose timetable waits for the same
  green at that corner, ranked by arrival then id; rank r takes slot r (rail pieces, whose waits end at different times:
  slots split by window parity). The group then crosses on `CROSS_LANES` by rank (0, +-0.8, +-1.6, +-0.4, +-1.2 m off the
  crossing's line; +-0.45 on section spine pieces) and walks on in lanes that differ for consecutive ranks.
- **Benches**: two seats (+-0.5 m); per window parity, the first to arrive sits on that parity's seat, the next stand by
  the bench at its standing slots of that parity (facing it, 0.9 m apart, on the walkway / in the park or plaza); at most
  `bench_cap` (1 + 6) stop in a window. Who stops is decided from everyone's *wished* trips (`LifePlan.wish`, which do not
  depend on each other); the rest walk on to their door without stopping (same doors, same start).
- **Walking lanes**: an offset to the right of the walking direction, one of five lanes (-0.9 .. 0.9 m, 0.45 m apart) by
  the id (after a green: by rank in the group), mitred at corners, changed within 2.5 m of a leg's start (of its end when
  stepping into a slot), plus a seeded surge / lag of up to 0.8 m mid-leg. Fleeing and the walk home after cowering use
  the same lanes along their routes.
- **Shelter / cowering**: fleeing people still go in at their door (hidden); cowering people take the nearest spot on
  rings of 0.8 m round where they were that is 0.8 m clear of everyone already cowering there (`LifeCrowd._cower_spot`,
  records made in event order), stepping there while they flinch; the spot (`cx`, `cs`) is in the snapshot (version 3).
- **Bodies**: a body that would lie within 0.8 m of another rests at the nearest clear spot on those rings (it slides
  there during the 0.4 s fall; kills apply in the host's event order everywhere). Dead bodies are not hit targets (only
  `_on` people are), so this is cosmetic for gameplay; the dead record keeps the hit point (`x0`, `s0`) besides the rest.
- **Guaranteed (asserted in `tests/test_life_spacing.gd`**, lab district 24 / 60 / 120 people and 160 people on 90 m,
  a 220 x 240 district, two section decks; 240 s sampled every 0.5 s, then 40 s after a strength-3 threat and a 4 m blast
  at the densest spot): standing, waiting and sitting people at least 0.7 m apart (measured: 0.90 m everywhere), at most
  3 standing people in any 1 m disc (measured: 2); after the blast, cowering / wary people and bodies at least 0.6 m apart
  (measured 0.70-1.23 m). **Not guaranteed: walkers.** Each walks its own closed-form route, so two strangers on one lane at
  nearly one speed can overtake slowly; asserted rare instead: within 0.4 m of another walker in at most 5 % of walker
  samples (measured 0.2-0.3 % at game densities, 1.2-4.6 % in the dense lab; 14.5 % at 160 people on 90 m, reported
  only), longest such stretch 0.5-18 s.
- **Costs**: the layouts (slots, bench slots) and the next minutes of the hold index are built in `AmbientLife`'s setup
  (`WARM_PARTS` = 4 extra setup parts, with the door trees below) and then one person a frame ahead of need
  (`LifePlan.warm_ahead`, `AHEAD` = 6 windows of 60 s): no first-use spike. Headless `_step` (crowd lab seed 1, no
  culling, `tests/bench_life.gd`): 24 / 60 / 200 people 0.09-0.10 / 0.18 / 0.48-0.50 ms a frame, worst 0.5 / 0.6 / 1.6 ms
  (before: 0.09 / 0.17 / 0.47 ms, worst 0.48 / 0.66 / 1.38 ms; the shared PC's noise is about +-0.03 ms). Known: a clock
  jump (a session starting, the lab's reset) finds the index for the new time unbuilt and builds it on the next frames
  (one-off, up to ~10-35 ms for 60 people).
- **Per-shot costs (same results)**: `LifeCrowd.apply_threat` computes a pose only for people whose trip box reaches the
  tested area (alarmed people, the dead and anyone a change in the event could affect are computed first, exactly as
  before), `LifeFleet.apply_threat` skips loops whose path cannot reach the threat, `AmbientLife.sweep` / `blast` look up a
  grid of the displayed feet from the second shot test on the same positions, and the walk graph's door trees are built
  at setup instead of on the first shot. Each keeps a `brute_force` reference path; `tests/test_life_threat_grid.gd` runs
  a scripted 120 s stack run both ways and gets the same hits, states, events, tally and snapshot. Stack seed 1:
  `raise_threat` 24 / 60 people a deck: first 891 / 734 us -> ~250 / ~350 us, median 343 / 522 -> 140-200 / 215-265 us;
  `sweep` (~3 m chord, 3 decks) median 7 / 10 -> 7 / 8 us, worst 70-90 -> 20-35 us.
- Checksums: `LifePlan.checksum()` unchanged (slots are derived, not in it); the crowd lab's snapshot hash re-captured
  (3903048191 -> 3798602067); `test_net_life` (both peers agree, stack phase included) passes.
- Shots: `civ_c_crowd.gif` re-shot with the same setup (`camera=group,area=90,people=160,seed=1,threat=blast,kill_r=6,
  threat_at=focus,threat_r=60,fire_after=2.5`), `crowd_spacing_corner.png`, `crowd_spacing_street.png` (mech eye,
  120 people), `crowd_spacing_shelter.png` (after gunfire), `crowd_spacing_blast.png`. Judged: the corner crowd now stands
  in rows, each figure on its own spot (at this 18x game density it still reads as a tight crowd, 0.9 m apart); the
  street is clean; a blast into ~15 people still reads as a pile: the bodies rest 0.8 m apart, but each lies 1.7 m long,
  so limbs overlap. Not done: bodies spread wider than 0.8 m (they would slide further during the fall).

## Road forms (2026-11-23)

City variety (`city-variety.md`) gives segments a form (lane, pedestrian street, superblock court; service alleys inside
blocks). Life follows it, all from plan data, no new messages: a crossing over a pedestrian street or a court has no
signal (junction -1, crossed on arrival, like the spine's ramp_a piece); walkers keep the walkways (no walking down a
pedestrian street's middle in v1) and never enter an alley. `LifeTraffic._make_loop`: no loop round a block beside a
pedestrian street or a court; a lane (one 8 m lane) is driven one way down its middle (no parking strip) by the first
loop that claims it (`lane_claims`), and the block across it gets no loop; when there are not enough loops for the pods,
the pod loops with free slots take more (never reached when blocks suffice). The section's forms are live by default
since 2026-11-23 (f_lane 0.20, f_pedestrian 0.15, f_none 0.08), switched by Missions, so every section deck's life
follows them; with the forms off (explicit zero mix) nothing changes. Stand-alone life / traffic goldens were re-captured (test_life_section). test_life skips the walk-signal check
for junction -1 crossings; test_life_traffic's fleet scenarios run on seed 1 with `road_variety 0` (they look for long
straight laps), its calm checks with the forms on.
