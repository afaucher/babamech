# Back-mount equipment

Status: **built** 2026-11-22 (weapons session; design the same day, user picked these three). Weapons design:
[weapons.md](weapons.md). As built: see the last section. Hangar entry, cooling stat and HUD rows are in (Engine, same day).
Meshes in (Mech, 2026-11-22) and wired (weapons session, same day): flying drone, cradle swap, radiator glow.
Playtest pass (weapons session, 2026-11-22): the drone is a selectable slot launched by the trigger, circles its
launcher, flies home to its dock, and shows green only while it repairs.

Equipment goes in the **back** slot only, so it competes with the mortar. One back item per mech. Equipment is not a
weapon: it makes no fire records and has no aim, no pivot and no muzzle. The repair drone is launched with the trigger
when its slot is selected (Controls); passives are always on.

| id | Name | Type | Weight | What it does | Limit |
| --- | --- | --- | ---: | --- | --- |
| `repair_drone` | Repair Drone | active | 6 t | Launches a drone that circles the launcher for 60 s, repairs every mech within 15 m of the launcher, then flies home to its dock | 2 drones per mission, one out at a time, 15 heat per launch |
| `radiator` | Radiator Fins | passive | 5 t | Cooling +3 heat/s (9 -> 12 in play: a spawned mech cools at 9 /s) | none |
| `ammo_bin` | Ammo Bin | passive | 6 t | +50% ammo on every limited-ammo weapon mounted (rockets 36 -> 54, missiles 18 -> 27) | none |

## Controls and HUD
- The repair drone slot is a normal selectable slot: key 5 toggles it, a double tap solos it, soloing another slot
  deselects it. It starts **deselected**. With it selected, a fresh press of the trigger (LMB, the same input that fires
  the selected weapons) launches one drone (one per press, holding does not repeat), costs 15 heat, and deselects the
  slot again, so a later pull never spends the second drone by accident: reselect to launch again. No charges left or
  a destroyed back hardpoint: the slot is unusable (deselected, can't be selected), like a dry weapon.
- Passives (radiator, ammo bin) are always on and ignore the key.
- `WeaponRack.slots()` reports the back slot as usual, plus `equipment: true`, `passive: bool`, `active_left` (seconds of
  repair the drone has left, 0 when none), `hint` (see As built), with `ammo` / `ammo_max` = drones left / 2. `ready` is
  0 while a drone is out (until it has docked).

## Repair drone
- Launch: rises from its dock on the back mount out onto its orbit over 0.5 s, then circles the launcher 5 m out, 6 m
  above its back mount, one turn per 6 s, bobbing a little and facing along its travel. The orbit centre follows the
  launcher (smoothed, about 0.4 s lag).
- After 60 s it stops repairing and flies home to its dock on the launcher's back (1.5 s, homing on the moving mech,
  shrinking to the docked size), then the docked drone shows again. No early return when everyone is full: it circles
  idle until its time is up. It dies at once (no return) when the launcher is downed or gone.
- Repair: while circling, each second every mech within 15 m (horizontal) of the **launcher** gets 1% of its max HP
  back, spent on its most damaged component first. About a minute in range restores 60%. Destroyed components and
  destroyed mechs are not restored (that is `revive`, later). It repairs the launcher too.
- Look: a small low-poly quad drone in the launcher's accent colour. Green only while it works: a green beam (thin,
  unshaded, like the laser line) to each mech it is repairing right now, and a faint green ring on the ground at 15 m
  around the launcher while at least one beam shows. Nothing green on the rise, while idle or on the way home.
  Beam look since 2026-11-23 (the user's pick, cell C3 of the render probe `tools/scanner_beam/`): instead of the thin
  line, a "moving scan line" on each repaired target: one bright green ring around the body, level in the target's own
  up frame, travelling up and down it (15-95 % of its height, one trip up and back per 3 s, eased at the turns) with
  three fainter trail rings and a soft band fading behind it, joined to the drone's lens by a faint thin wedge (a fan
  onto the ring's drone-facing arc with two faint edge lines). Ring radius and height fit the target (its MechModel's
  mesh bounds, so every chassis; hit spheres for dummies / assets). The scan height is a pure function of the clock
  since launch, so every machine shows the same scan. Unshaded, alpha-blended, no shadows (`RepairDrone._place_scan`).
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
  `heal_rate` 0.01, `follow` 0.4, `rise` 0.5, `orbit` 5, `orbit_period` 6, `dock` 1.5, `active_heat` 15; radiator
  `cooling_bonus` 3; ammo bin `ammo_bonus` 0.5.
- **Hover height**: 6 m above the launcher's **back mount** (5.8 m on the 8 m strider), so about 11.8 m above its feet:
  "6 m above the launcher" measured from its feet would put the drone inside the mech.
- **Rack** (`WeaponRack`): the drone slot is selectable like a weapon (`press_slot` toggles / solos, `set_enabled`
  works, the unusable rule applies: no charges or a destroyed hardpoint). Built deselected (`rebuild`; weapons keep
  their default). Each `step`, `_step_equipment(pull)` (pull = the trigger went down this step) launches a selected,
  launchable drone (`can_launch`: a charge left, none of this rack's drones out, hardpoint intact, mech not shut down)
  and deselects the slot (one `slot_changed`). `activate(n)` still launches directly regardless of selection (tests /
  bots). Passives: always enabled, the key does nothing and breaks a pending double tap, `set_enabled` ignores them.
  `slots()` adds `equipment`, `passive`, `active_left`, `hint` to EVERY slot (false / false / 0 / "" for weapons and
  empty slots); for equipment `built` true, `enabled` = selected (passives true), `ammo` / `ammo_max` = drones left / 2
  (-1 for passives), `ready` 1 / 0, `hold` "DESTROYED" / "DRONE OUT" (rising, circling or flying home) / "EMPTY" /
  "PASSIVE" / "", `in_range` false, `usable`. **`hint`** (for the HUD): the drone slot says `"PRESS <n>"` (its own key)
  when usable, deselected and none out, `"CLICK TO LAUNCH"` when selected and it can launch now, `""` otherwise; always
  `""` on weapons and passives. A destroyed back hardpoint stops the radiator and the launch. Ammo bin:
  `WeaponRack.bonus_ammo` (rockets 54, missiles 27, mortar 3 -> 5), `ammo_max` reports the bigger load.
- **Drone** (`RepairDrone`, a `CombatEffect`; `CombatWorld.launch_drone(record)`, `drone_of(shooter)`,
  `set_anchor(shooter, () -> Node3D)` / `anchor_of`): follows its launcher's node on this machine (the rack registers
  its mech; CombatNet registers each puppet's). Orbit: centre = the launcher's hover point (`hover` above the back
  mount) with the `follow` smoothing, radius `orbit` across the launcher's up axis, angle `orbit_angle(now)` =
  TAU x (now - t0) / `orbit_period` in the drone's level frame: a pure function of the record and the shared clock, so
  every machine draws the same orbit (no new messages, no RNG). Rise: dock -> orbit point over `rise`. Repair only while
  circling (`repairing()`: after the rise, before `life`): heals every target this machine OWNS that is not on the
  enemy team within 15 m of the LAUNCHER across its up axis (`reach_to`; so the host also repairs host-owned non-enemy
  targets such as dummies). Home (`returning()`, `home_fraction()`): from the orbit point of angle(t0 + life) around
  the current centre to the live dock (`EquipmentLook.dock`, re-read each step), smoothstep over `dock` s, scale
  FLY_SCALE -> the mount's, turning into the dock's orientation, bob faded out; `finished()` at life + dock, so it is
  removed on the step it lands. Dies (no return) when the launcher's PlayerTarget is `disabled` (own, or a puppet's
  streamed mirror) or its node is gone for 1 s. A newer launch by the same shooter replaces a live drone. A record
  older than `life` is still dropped (a late joiner doesn't see a drone already on its way home).
- **Green**: `RepairDrone.repairable(t)` (hittable, not destroyed, a component with 0 < hp < max): the one test for the
  owner's own target (exactly when `heal` restores something) and for puppets (their streamed mirror HP). Beams go to
  repairable non-enemy targets in range while `repairing()`; the ring (centred on the launcher) shows only while a beam
  does (`ring_shown()`).
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
    scale, grows to full size over the 0.5 s rise, turns toward its travel (yaw only, 0.25 s smoothing) and bobs
    0.15 m. Rotors don't spin. Fallback when the part is missing (`RepairDrone.flying_id` not in `MechMeshes.EQUIPMENT`):
    the old MeshKit quad with spinning rotors.
  - Cradle swap, no MechModel edit: the MeshInstance3D under `HP_<hp>/Weapon_repair_drone` gets its mesh swapped
    (accent re-applied). **Rule**: a drone of that shooter is alive on this machine (`CombatWorld.drone_of`: launched,
    repairing or flying home) -> `weapon_repair_drone_cradle`; otherwise `weapon_repair_drone` (docked), even with no
    charges left (it came home; the HUD reports EMPTY from the rack). The same rule on every machine, from the drone
    effect alone (no charge counting). A MechModel rebuild (loadout change) makes a new node: the swap re-applies on
    the next step; no node / mesh (placeholder art) is skipped.
  - Radiator glow: the radiator mesh's surface named `"heat"` gets ONE emissive StandardMaterial3D per mech
    (`set_surface_override_material`); emission black -> `MechMeshes.ORANGE` (from 5 % to 60 % heat) -> red-hot
    (1.0, 0.24, 0.10) near overheat, energy 0 -> 1.8, the fins' albedo darkening to 0.3 so the glow colour reads.
    Rewritten only when the heat fraction moved 0.02 or more. Heat: the owner's rack (MechController gauge), the lab's
    Heat, else the anchor's MechController heat / heat_cap (a puppet's mech carries the streamed heat).
- **Lab**: `weapon_range` lists the three in Weapon (back hardpoint only); the drone launches per fire mode (the next
  one once the last has docked) and repairs a PlayerTarget on the lab mech and `repair_dummy`; option "Repair demo"
  damaged / full. The lab mech shows the cradle swap (unlimited charges); the readout says "returning" on the way home. Radiator: a demo heat load (14 /s in "hold", 25 per
  tap in "single") makes the lab gauge climb so the fins glow; the camera focus is the back mount.
- **Tests**: `test_back_equipment` (selection: deselected by default, key toggles, no launch from the key, trigger edge
  launches one and deselects, solo / double tap, `hint` values, unusable at 0 charges, `activate` direct; orbit 5 m
  and one turn per 6 s, identical on two worlds; repair radius from the launcher; green only while repairing; home to
  the dock in `dock` s; flying mesh + accent, cradle on launch / return / last charge, rebuild, remote cradle,
  placeholder fallback, radiator emission), `test_weapon_rack` (`hint` on every slot), `test_net_drone` (2 peers, life
  shortened to 8 s: positions agree, A's puppet on B docked / cradle / docked again, beams on B to its own mech only
  while damaged, on A to B's puppet only while its mirror is below full), `test_visual_weapon_repair_drone` (shots
  `weapon_repair_drone`, `weapon_repair_drone_close`, `weapon_repair_drone_return`, `weapon_radiator_hot`).
- Not covered yet: enemies targeting the drone (out of scope), the cosmetic launch pop on remote machines uses the
  puppet, revive. Bots (`scripts/ai/player_bot.gd`) never launch the drone: they deselect any slot that is not
  `in_range` (equipment never is) and never call `activate`.

## Later candidates
Point defence, coolant flush, jump jets, deployable barrier, smoke, ammo carrier, heat sink bank, gyro, armour pack,
sensor mast.
