# Invader banners: the destructible occupation prop

Status: **built** (2026-11-23), not yet wired into the test drive. Engine adds that (see "Wiring" below). Everything in
this doc is a default the user can change.

Sources: `decisions.md` (occupation is control, not war damage; alien banners are destructible), `game-design.md` §2 / §6
("tearing down the invaders' symbols is part of liberating an area"), `mission-section.md` §10 (`banner` hooks at
transit regions), `city-props.md` (banners are the destructible-for-score objects), `enemies.md` §7 (the approved
banner).

## 1. Look (approved, not redesigned)

Design **"Descent"**, colouring **F2c3**: dark slate field `#3e3c3e`, a brick `#a2453a` arrowhead pointing diagonally
down-left (~47°) with a thin field-coloured slit, three long cream `#e8dcc0` bars trailing up-right **behind** the
arrowhead, cream border, swallowtail bottom. 4.0 m wide x 6.4 m to the swallowtail points, emblem at 0.85 scale, centred;
three cloth panels (the outer two folded back 0.22 m), an iron cross-bar with two wall brackets. Pole variant: a free-
standing 11.2 m iron pole with an arm at 10.7 m, cloth 4.0 x 5.6 m.

Ported from the probe placeholder (`tools/enemy_style/enemy_style_probe.gd`, not used at runtime) into
`BannerMeshes` (flat-shaded MeshKit vertex colours, the shared MeshKit materials). A facade banner on a lower ground tier
gets a shorter cloth (4.8-6.4 m: bar at min(tier top - 0.8, 10.4) m, at least 1.6 m of wall under the cloth). The notch
scales with the length. Reference shot: `art/renders/enemy_colour_r3/F2c3_banner_close.png`; ours:
`docs/design/banners/`.

Torn state: ragged field strips (fixed lengths) and the torn top border stay on the bar (`fringe`), the cloth lies as a
crumpled heap (four flattened lumps with brick, cream and border folds showing) at the foot of the facade, 1 m out on
the sidewalk (`heap`). Five small shreds flutter down during the tear (`shred`).

## 2. Placement (deterministic, `BannerPlan`)

Plain data per deck from the deck's `CityPlan` (gameplay geometry, already proven equal on every machine by the load
barrier's `CityStack.checksum`) and the **mission seed**, through one `RandomNumberGenerator` seeded from both
(`seed * 7919 + (deck + 1) * 104729 + 0xBA22`, AGENTS rule 4). So every machine places the same banners with the same ids
without sending anything. The list is not added to the barrier checksum: it is a pure function of two inputs the
barrier already checks (plan checksum, and the mission seed every machine launched with). `BannerPlan.checksum(list)` /
`OccupationBanners.checksum()` exist for tests, or for Engine to join the barrier string if it ever wants to.

**Facade spots**: ground tiers (`y0 <= 1.5 m`) at least 7 m tall, every 7 m along each side with 1 m to spare at each end
(the probe's facade finder). Kept only where:
- the ground 7 m out (sidewalk + 3 m) is a road strip or an open lot (plaza, park, garden, court), and nothing is built
  6 m out;
- not on the building's front side within 3.6 m of the face's middle (the door: apartments, civic hall and similar put
  it in the middle bay);
- not within 4 m (+ half the banner) of a floor cut (ramp mouths, shafts, holes) or a ramp, and not on ground the site
  keeps clear;
- not within 12 m of a `checkpoint` or `cordon` hook (checkpoint gates, sealed blast doors), not within 8 m of the deck's
  edge (boundary gates, portals);
- no pillar towers.

**Picks**, in order:
1. At every `banner` hook of the deck (transit region centres, `mission-section.md` §10): the 2-3 facade spots nearest
   it within 45 m (a seeded jitter breaks ties), a new building first.
2. A seeded scatter (Fisher-Yates with the same generator), preferring civic buildings and facades on the spine,
   arterials and plazas, up to 6-9 facades in all.
3. 1-2 **pole banners** on plaza lots (transit and civic plazas), the ones nearest a banner hook first, clear 2.6 m round
   the pole and the cloth, never on a road; the cloth faces the deck's middle across s.

Always: at least 9 m apart, at most 2 on one building (a new building first), at most 10 a deck. Measured on seeds 1-6
(three decks each): 7-10 a deck, 1-2 of them poles; placement 3-19 ms a deck.

**Graphics quality** never changes the banners (they are gameplay targets: a banner one machine doesn't have could still
be shot by another). LOW turns the cloth's shadows off; each deck's banners follow that deck's visibility (CityStack hides
far decks at LOW / MEDIUM). This replaces the brief's "fewer banners at LOW".

**Clear of the facade** (2026-11-23, user playtest: a banner hung through an apartment's balconies). A facade spot is
kept only where the banner's envelope (cloth, the cross-bar with its end caps, the brackets, + `MARGIN` 0.3 m; out to
the bar + 0.3 m) meets none of its face's relief boxes and no other box. `CityFacade.relief(plan, building, tier)`
lists, per side, everything standing out at least `RELIEF_MIN` 0.4 m (deeper than the cloth's back at 0.48 m):
balconies (every bay of a balconied face: which bays get them is a cosmetic roll), door canopies, shop awnings (every
shape), recessed entrances, corner blade signs, downtown awnings and lobby canopies, alley hoods and pipes, lane wall
lamps and hanging signs (anywhere the roll can put them). The meshers draw with the same constants, so the two agree
(geometry digests unchanged). Other boxes: every other tier of every building (setbacks, neighbours at a corner), plan
solids (portico columns, steps), park columns, pillar cores. A blocked step slides along its face up to `SLIDE` 3.5 m
(0.5 m steps) and tries the shortest cloth (4.8 m) before it is dropped. Shallow relief (bands, sills, piers,
cornices, up to 0.35 m) passes behind the cloth. Street props (lamps, trees) are not checked: they stand at the curb,
beyond the banner's 0.8 m reach. Seeds 1, 4, 7, 403112 (all decks): 113 banners before and after; 20 of them clipped
before (15 balconies, 5 lane lamps / signs), none after (`tests/test_banner_placement.gd`). Placement 5-33 ms a deck. Shot: `city-variety/banner_clear_1.png`
(test_visual_banners `banners_apartment`).

## 3. Destruction (host-arbitrated world object, AGENTS rule 6 shape 3)

`BannerTarget` (a `CombatTarget`, pattern `AssetTarget`): `target_id "banner_<deck>_<id>"`, `owner_peer 0`,
`mass_class "static"`, **team `"enemy"`**, 60 HP on one component `cloth` (3 autocannon shells at 22, a rocket salvo,
one railgun slug). Hit spheres: two columns x 2-3 rows of 1.15 m spheres covering the cloth.

Team `"enemy"` because of how the team rules already work:
- `CombatWorld.spares`: same team and not `"player"` is always spared, so **enemy fire passes through** banners and never
  tears its own symbol; player fire (a different team) always hits, friendly-fire setting or not.
- `EnemyBase._acquire_target` / `EnemyDrone` skip their own team, and `_on_damaged_alert` only alerts on other teams:
  **enemy AI never acquires or alerts on a banner**. Every other scan (`EnemySquad`, troopers, drop drones, spotlights)
  looks only at team `"player"`. `PlayerBot` tracks only `EnemyBase`; the repair drone skips team `"enemy"`.
- Side effects to know: the player's flak proximity fuse bursts near banners (they are targets), the crosshair's aim
  query sees them, and the dev `--dev-fast-clear` multiplier applies to them.

Flow:
1. A shot from any machine: `CombatWorld.decides` makes the **shooter's** machine decide (owner_peer 0). On a client the
   hit becomes `remote_hit` and CombatNet's `"combat.hit"` carries it to the host (sender-checked, de-duplicated), which
   applies it. Only the host writes the banner's HP; **HP is never synced**.
2. At 0 HP the host's target emits `cloth_down`; `OccupationBanners` decides the tear once, plays it, and sends **one**
   reliable event: `Session.send_event(0, "banner.torn", {deck, id, t})`, t = `Session.host_time()`.
3. Every machine plays the tear from t on the shared clock (1.1 s: the cloth drops, tips out and crumples, shreds fall,
   then the heap; a tear older than 1.4 s arrives settled). The cross-bar stays. A torn banner is not hittable: shots
   pass, nothing is counted.
4. A member that sets up after a tear (the only late case: mid-mission joins are refused; a member reaching the barrier
   after play started) gets `"banner.sync" {torn: [[deck, id, t], ...]}` from the host on `Session.peer_joined`, and the
   host re-sends it once to the crew at `Session.mission_go`. Events that arrive before setup finishes are queued.

All wire use is through the Session API (rule 5), like `CityProps`' `prop.req / prop.ev / prop.sync`; nothing in
`scripts/net/` changed.

## 4. Score and feedback

On every machine: `torn_count(deck)` / `banner_count(deck)` (deck -1 = all), `is_torn(deck, id)`, the signal
`banner_torn(deck, id)`, and a `[Flow] banner torn  deck k banner i (n of m torn)` line. No HUD yet: the mission HUD /
end summary can read the counts (follow-up). No audio cue yet (follow-up: a cloth rip + the heap landing, keyed off
`banner_torn`). Today, on the host / solo only, CombatAudio already plays its generic "break" and "kill" cues when a
banner's HP reaches 0 (it watches every registered target); clients hear nothing. TestDrive's `[Flow] first enemy
contact` line also fires on the first banner hit (it counts any team-"enemy" target): Engine may want to skip
`BannerTarget` there.

## 5. Wiring (Engine)

```gdscript
var banners := OccupationBanners.new()
add_child(banners)
banners.setup(stack, combat.world)          # ~30 ms for three decks on this PC
# or, in the stepped load: banners.setup_begin(stack, combat.world); while not banners.setup_step(8.0): await frame
```
Needs the built `CityStack` in the tree (not moved afterwards) and the `CombatWorld` (targets register there; its
`mission_seed` seeds the placement). Meshes go on `CityStack.deck_layer(k)`, set before they enter the tree. One deck per
`setup_step`. Optionally `banners.set_quality(q)` from `_on_graphics_quality` (shadows only).

## 6. Code map

| File | What |
|---|---|
| `scripts/world/occupation/banner_meshes.gd` | `BannerMeshes`: cloth (per length), bar, pole, fringe, heap, shred; cached |
| `scripts/world/occupation/banner_plan.gd` | `BannerPlan`: placement as data, rules above, checksum |
| `scripts/world/occupation/banner_target.gd` | `BannerTarget`: the cloth as a host-owned CombatTarget |
| `scripts/world/occupation/occupation_banners.gd` | `OccupationBanners`: nodes per deck, tear decision / events / animation, counts |
| `scripts/world/occupation/banner_lab.gd` | lab subject `banners` (wall + pole close up, cloth length, tear scrub, play / reset) |
| `tests/test_banners.gd` | placement rules over seeds 1-6, field on a real stack, tear by player fire, torn takes no hits, enemy fire / AI |
| `tests/test_net_banners.gd` | 2 peers: client fire tears on the host, one event, both torn, late field synced |
| `tests/test_visual_banners.gd` | shots (lab close / torn, stack chase / close / mid-tear / torn) |
