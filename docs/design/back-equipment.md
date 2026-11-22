# Back-mount equipment

Status: design, 2026-11-22, weapons session. User picked the first three: repair drone, radiator, ammo bin. Not built yet
(waits for co-op step 3, which edits the same combat files). Weapons design: [weapons.md](weapons.md).

Equipment goes in the **back** slot only, so it competes with the mortar. One back item per mech. Equipment is not a
weapon: it never fires on the trigger (LMB), has no aim, no pivot and no muzzle.

| id | Name | Type | Weight | What it does | Limit |
| --- | --- | --- | ---: | --- | --- |
| `repair_drone` | Repair Drone | active | 6 t | Launches a drone that follows the launcher for 60 s and repairs every mech within 15 m of it | 2 drones per mission, one in the air at a time, 15 heat per launch |
| `radiator` | Radiator Fins | passive | 5 t | Cooling 6 -> 9 heat/s | none |
| `ammo_bin` | Ammo Bin | passive | 6 t | +50% ammo on every limited-ammo weapon mounted (rockets 36 -> 54, missiles 18 -> 27) | none |

## Controls and HUD
- The back slot key (5) **activates** active equipment directly (launches the drone). It does not toggle, and LMB never
  triggers equipment. Passives ignore the key.
- `WeaponRack.slots()` reports the back slot as usual, plus `equipment: true`, `passive: bool`, `active_left` (seconds the
  drone has left, 0 when none), with `ammo` / `ammo_max` = drones left / 2. `ready` is false while a drone is out.

## Repair drone
- Launch: pops up from the back mount over 0.5 s, then hovers 6 m above the launcher and follows it (smoothed, about
  0.4 s lag). After 60 s it flies off and is removed. Dies with the launcher.
- Repair: each second, every mech within 15 m (horizontal) of the drone gets 1% of its max HP back, spent on its most
  damaged component first. A full minute in range restores 60%. Destroyed components and destroyed mechs are not
  restored (that is `revive`, later). It repairs the launcher too.
- Look: a small low-poly quad drone in the launcher's accent colour, with a green beam (thin, unshaded, like the laser
  line) to each mech it is repairing, and a faint green ring on the ground at 15 m.
- First version: enemies cannot target the drone.

## Radiator and ammo bin
- Radiator: adds 3 /s to the chassis cooling while mounted. Fins glow with heat (cosmetic, from the heat fraction).
- Ammo bin: applied when the loadout is built; rounds up to a whole salvo.

## Networking
- Radiator, ammo bin: part of the loadout (already in the hello profile); each machine derives the effect. No messages.
- Repair drone: a **scheduled effect**. One broadcast `{launcher peer, start time}`. Every machine draws the drone from
  that and the launcher's (puppet) position. **Each machine repairs only its own mech** when it is inside the radius, via
  a new `heal(amount, src)` verb on `CombatTarget`, so nobody writes another mech's HP and no heal messages are sent.

## Needed from other sessions
- Mech: meshes for the three back items (drone docked + flying, radiator fins, ammo bin) and mounting them on the model.
- Engine: hangar offers equipment in the back slot; HUD shows the drone count / time left and marks passives.
- Antigravity: `PlayerTarget` (player HP) must honour `heal`.

## Later candidates
Point defence, coolant flush, jump jets, deployable barrier, smoke, ammo carrier, heat sink bank, gyro, armour pack,
sensor mast.
