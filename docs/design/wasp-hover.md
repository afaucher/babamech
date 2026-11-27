# Wasp hover: movement, damage, networking, AI hooks (DRAFT for the user's approval)

Mech session, 2026-11-26. Nothing here is built. The art is (`docs/design/chassis-rules.md`, "Wasp"); the bot and
enemy anti-air side is antigravity's `docs/design/wasp-ai.md`. Numbers marked **(tune)** are starting points for the lab.

## Decided by the user
- Two big tilting fans, no rear fans. Three light guns (two stubs, one chin), no item over weight 7.
- Mini chicken legs: dangle in flight, stand when landed, no walking.
- **Losing a fan = a walker losing a leg, identical behaviour**: the Wasp is DOWNED under the existing rules
  (`DownedRules`, `PlayerTarget`): no movement, no weapons, takes no damage, dropped as a target; revived in place by a
  crewmate's repair drone, or the pilot holds respawn. It stays down until then.
- Pilot head stays full size.

## 1. Movement (proposal)
One controller class: `MechController` gets a hover branch chosen by the catalog (`move == "hover"`), so the camera,
weapons, damage, net stream and bots keep talking to the same node. The biped path is untouched (Strider golden test).

| | Strider | Bulwark | Wasp (tune) |
|---|---|---|---|
| Forward | 12 walk / 22 run | 8 / 14 | 16 cruise / 24 boost |
| Strafe | 12 | 6.4 | 16 (full speed: its edge) |
| Half turn | 1.75 s | 2.9 s | 1.2 s |
| Vertical | thrusters | hot thrusters | Space climbs, Ctrl descends, 9 m/s |
| Accel | 30 | 14 | 22, with drift (it slides, it does not stop dead) |

- **Altitude**: no gravity while flying. With no climb input it holds height above the ground or roof under it, so it
  rises over buildings on its own. **No artificial ceiling** (user, 2026-11-26: "Why do we want a ceiling. We need to
  be able to fly between decks."): the only limit is the world itself, the underside of the deck above, and it flies
  up or down through ceiling openings and shafts to change deck. What keeps it honest at height is heat (climbing
  costs) and enemy anti-air, not a cap.
- **Landing**: descend to the ground and it settles on its legs (`grounded`). Landed it cannot move, only turn and
  shoot; Space lifts off. Landing is a choice, not a penalty: a landed Wasp cools faster (below).
- **Heat** (so flight is not free): hovering in place costs nothing; moving costs like a walker's walk; boost and
  climbing cost like a run. Heat cap 90 / cooling 9 **(tune)**, cooling x1.5 while landed. **Overheat = shutdown, as on
  every chassis**: the fans stop and it drops onto its legs; from height that is a fall (next point); it lifts off
  again after the normal reboot.
- **Falls**: the Wasp has no fall-damage legs. A hard landing (shutdown at height) damages the **torso** by the same
  share a walker's legs would lose. There is no automatic landing burn: the pilot (or the bot) must come down before
  overheating.
- **Body**: capsule radius 2.2 m (the Strider's), about 5 m tall: it fits everywhere the Strider fits, including alleys;
  the fans (8.75 m across) overhang it, as the Bulwark's hull overhangs its capsule.
- **Between decks**: it may fly through ceiling openings and shafts; ramps work too (it just flies along them).

## 2. Damage
- Components: torso, head, `fan_l`, `fan_r`, the three hardpoints. **The fans take the legs' place in every table**
  (core components, hit volumes = the two duct rings), so losing one downs it by the existing rule with no new state.
- Health **(tune)**: torso 260, each fan 110, head 100, hardpoints 80: about 580 core against the Strider's 900. It
  survives by not being hit: small, fast, above most ground fire.
- A downed Wasp in the air drops onto its legs where it is (downed mechs take no damage, so the drop is free).

## 3. Networking
- Same owned-actor stream as the walkers; position is already 3D. **No new streamed state**: fan tilt, bank, leg pose
  and rotor speed are computed on every machine from the streamed velocity and the grounded / shutdown / downed flags
  the stream already carries.
- **No packet growth**: on the wire the fans use the leg slots (`leg_l` / `leg_r`) and the hardpoints reuse existing
  ids (`side_l`, `side_r`, `belly`), with Wasp labels in the HUD ("Left fan", "Left stub", "Chin"). The catalog draft's
  `stub_l` / `stub_r` / `chin` ids get renamed to match.

## 4. Hooks for the bot and enemy AI (agreed names, from wasp-ai.md 2.1)
- Catalog: `MechCatalog.entry(id)["move"] == "hover"`.
- Inputs: `move_input`, `aim_yaw`, `running` (boost), and new `climb_input: float` in -1..1.
- State: `grounded: bool`, `can_fly() -> bool` (both fans alive and not shut down), `working_fans() -> int`
  (**0..2**, not 0..4), `altitude() -> float` above the ground under it, and `headroom() -> float` (m of free air above
  it, to the slab or the roof of an opening). No `hover_ceiling()`: there is no cap (user).
- With fan loss = downed, the bot's "grounded turret" fallback is not needed: a Wasp with a dead fan is simply downed.

## 5. Other systems
- **Camera**: its own chase framing (closer and lower than the Strider's), and the pitch range must let the pilot look
  well down, since it fights from above. First person from the hatch as usual.
- **Controls**: Space / Ctrl replace thrust; nothing else changes. Keys 1-3 for the three guns.
- **Objectives**: capture and depot zones count a hovering Wasp inside the zone's height; it has to come down into them.
- **Enemies**: anti-air aim, pitch limits and the gunship's altitude matching are built (antigravity, `scripts/enemy/`).
- **Hangar**: it stands on its legs in the bay; the bay clamps need a Wasp fit.

## 6. Build order (each step ends with tests; nothing selectable until the last)
1. Hover controller + lab subject + model hooks driven from motion; movement tests.
2. Damage (fan components, hit volumes, downed, fall), HUD diagram, camera framing, first person.
3. Weapons on the three mounts (ids renamed), keys, fire tests.
4. Net: 2-peer tests with a Wasp against a Strider (movement tracking in 3D, damage, down / revive).
5. Bot piloting (Engine / antigravity) and a bot-played mission as proof; world-fit survey for a flier.
6. Selectable in the hangar; bots may be assigned it.

## Open for the user
- The speed / health numbers above are guesses to tune in the lab.
- Is "hovering costs no heat, moving does" right, or should it be able to fly indefinitely?
