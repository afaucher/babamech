# Weapon builds: nothing paused

Updated 2026-11-22 by the weapons session. **Nothing is paused any more.** The four weapons paused on 2026-11-21
(`missiles`, `railgun`, `swivel`, `flamer`) are all built, so all nine weapons fire in the `weapon_range` lab and through
`WeaponRack` in the test drive. The fixed-weapon fire arc is built too, off by default (`Combat.FIXED_ARC_ENABLED`).
Design, numbers and a code map: [../design/weapons.md](../design/weapons.md).

## Known gaps
- Network wiring of hits: `CombatWorld.remote_hit` is only a signal; sending hits is slice milestone S7.
- Damaged-weapon penalties and ammo cook-off (design §4.6): after the slice.
- Friendly fire (design §4.6): not built.
- Remote machines posing the swivel boom from the streamed `aim_yaw` / `aim_pitch` (`WeaponMount`, `OWNER`): not wired;
  only the owner's machine poses it today.

## Open design questions for the user
Kept in sync with [weapons.md §7](../design/weapons.md#7-open-questions).
1. Fixed-weapon arcs (±25°, built but off): turn them on, or let every weapon reach any aim point?
2. Knockback stagger and wall-slam damage (both built): in or out?
3. Friendly fire: no damage and no heat to teammates, 25% knockback?
4. Blocked line of sight: fire into the obstacle (built) or refuse to fire?
5. Railgun limited to one per mech?
6. Flamer ground-fire patches: later, or never?
7. Projectile speeds (100 m in 1.2–2.2 s for most guns): the right "slow"?
8. Does missile guidance need line of sight from the launcher to the aim point?
9. Should the missiles' laser line cost heat (it costs none)?
10. Flamer shooter heat: 6 /s active + 1.0 passive ≈ the 6 /s cooling, so it barely heats the shooter. Raise it?
11. Light targets slide very far under gatling / autocannon bursts: keep, or cap the hit-slide?
