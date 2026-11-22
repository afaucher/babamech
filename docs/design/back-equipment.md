# Back-mount equipment

Status: **built** 2026-11-22 (weapons session; design the same day, user picked these three). Weapons design:
[weapons.md](weapons.md). As built: see the last section. Hangar entry, cooling stat and HUD rows are in (Engine, same day).
Meshes in (Mech, 2026-11-22) and wired (weapons session, same day): flying drone, cradle swap, radiator glow.

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

## As built (2026-11-22)
- **Catalog**: entries in `MechCatalog.WEAPONS` with `equipment: "active" | "passive"` and `kind: "equipment"`, so
  loadouts, the hello profile, `sanitize_loadout` and `loadout_stats` (weight) carry them unchanged. They are NOT in
  `WEAPON_ORDER` (tests and code that iterate weapons skip them); `MechCatalog.EQUIPMENT_ORDER`, `is_equipment(id)` and
  `equipment_for(mount)` list them. `WeaponRegistry.playable_loadout` keeps them (no "offline" swap). Fire records
  naming equipment are refused by `CombatNet.decode`. Stats: drone `charges` 2, `life` 60, `hover` 6, `radius` 15,
  `heal_rate` 0.01, `follow` 0.4, `rise` 0.5, `active_heat` 15; radiator `cooling_bonus` 3; ammo bin `ammo_bonus` 0.5.
- **Hover height**: 6 m above the launcher's **back mount** (5.8 m on the 8 m strider), so about 11.8 m above its feet:
  "6 m above the launcher" measured from its feet would put the drone inside the mech.
- **Rack** (`WeaponRack`): key 5 calls `activate(5)` (equipment never toggles; `set_enabled` ignores it; a press of an
  equipment key breaks a pending double tap; soloing another slot leaves it enabled). `slots()` adds `equipment`,
  `passive`, `active_left` to EVERY slot (false / false / 0 for weapons); for equipment `built` true, `enabled` true,
  `ammo` / `ammo_max` = drones left / 2 (-1 for passives), `ready` 1 / 0, `hold` "DRONE OUT" / "EMPTY" / "PASSIVE" / "",
  `in_range` false. A destroyed back hardpoint stops the radiator and the launch. Ammo bin: `WeaponRack.bonus_ammo`
  (rockets 54, missiles 27, mortar 3 -> 5), `ammo_max` reports the bigger load.
- **Drone** (`RepairDrone`, a `CombatEffect`; `CombatWorld.launch_drone(record)`, `drone_of(shooter)`,
  `set_anchor(shooter, () -> Node3D)` / `anchor_of`): follows its launcher's node on this machine (the rack registers
  its mech; CombatNet registers each puppet's), heals every target this machine OWNS that is not on the enemy team
  within 15 m across the launcher's up axis (so the host also repairs host-owned non-enemy targets such as dummies),
  dies when the launcher's PlayerTarget is `disabled` (own, or a puppet's streamed mirror) or its node is gone for 1 s.
  A newer launch by the same shooter replaces a live drone. After 60 s it climbs away for 1.5 s with no repair.
- **Heal verb**: `CombatTarget.heal(amount, src) -> float` (signal `healed(amount, component, src)`): lowest HP fraction
  first, spills over, never a destroyed component, nothing on a destroyed or not-hittable target. `PlayerTarget` needs
  no override (its HP is in `hp` / `max_hp`; `is_hittable()` is false while `disabled`).
- **Net**: `combat.drone {t, hp}` through CombatNet's existing relay (host forwards with `o`), duplicates dropped by
  (origin, t), a launch older than 60 s dropped, one stamped > 5 s ahead refused. No heal message.
- **Look** (cosmetic, every machine, no messages; `scripts/combat/equipment_look.gd` = `CombatWorld.equipment_look`,
  stepped at the end of `CombatWorld.advance`, plus `RepairDrone`):
  - Flying drone: the Mech mesh `weapon_repair_drone_flying` (MechMeshes part, `MechMeshes.apply_accent` with the
    launcher's MechModel accent, as MechModel tints its parts), x `RepairDrone.FLY_SCALE` 2.1 (about 1.6 m). It leaves
    from the docked drone's spot (`HP_<hardpoint>` x `MechMeshes.DRONE_DOCK`, `EquipmentLook.dock`) at the mount's
    scale, grows to full size over the 0.5 s rise, turns slowly toward its travel (yaw only, 0.8 s smoothing) and bobs
    0.15 m. Rotors don't spin. Fallback when the part is missing (`RepairDrone.flying_id` not in `MechMeshes.EQUIPMENT`):
    the old MeshKit quad with spinning rotors. Beams and ring unchanged.
  - Cradle swap, no MechModel edit: the MeshInstance3D under `HP_<hp>/Weapon_repair_drone` gets its mesh swapped
    (accent re-applied). **Rule**: a drone of that shooter is alive on this machine (`CombatWorld.drone_of`: launched,
    repairing or flying off) -> `weapon_repair_drone_cradle`; none and charges left -> `weapon_repair_drone` (docked);
    none and no charges -> empty cradle. Charges left: the owner's `WeaponRack` count (`watch`), the lab: unlimited;
    other machines (puppets): catalog charges (2) minus the launches this world saw for that shooter (each
    `combat.drone` arrives once). A machine that joined after a launch shows one more drone docked than the owner has:
    cosmetic, accepted. A MechModel rebuild (loadout change) makes a new node: the swap re-applies on the next step;
    no node / mesh (placeholder art) is skipped.
  - Radiator glow: the radiator mesh's surface named `"heat"` gets ONE emissive StandardMaterial3D per mech
    (`set_surface_override_material`); emission black -> `MechMeshes.ORANGE` (from 5 % to 60 % heat) -> red-hot
    (1.0, 0.24, 0.10) near overheat, energy 0 -> 1.8, the fins' albedo darkening to 0.3 so the glow colour reads.
    Rewritten only when the heat fraction moved 0.02 or more. Heat: the owner's rack (MechController gauge), the lab's
    Heat, else the anchor's MechController heat / heat_cap (a puppet's mech carries the streamed heat).
- **Lab**: `weapon_range` lists the three in Weapon (back hardpoint only); the drone launches per fire mode and repairs
  a PlayerTarget on the lab mech and `repair_dummy`; option "Repair demo" damaged / full. The lab mech shows the cradle
  swap (unlimited charges: docked again whenever no drone is out). Radiator: a demo heat load (14 /s in "hold", 25 per
  tap in "single") makes the lab gauge climb so the fins glow; the camera focus is the back mount.
- **Tests**: `test_back_equipment` (flying mesh + accent, dock launch, cradle on launch / return / last charge, rebuild,
  remote launch counting, placeholder fallback, radiator emission), `test_net_drone` (A's puppet on B: docked before,
  cradle while out), `test_visual_weapon_repair_drone` (shots `weapon_repair_drone`, `weapon_repair_drone_close`,
  `weapon_radiator_hot`).
- Not covered yet: enemies targeting the drone (out of scope), the cosmetic launch pop on remote machines uses the
  puppet, revive.

## Later candidates
Point defence, coolant flush, jump jets, deployable barrier, smoke, ammo carrier, heat sink bank, gyro, armour pack,
sensor mast.
