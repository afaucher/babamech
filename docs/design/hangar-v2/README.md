# Hangar v2: the shared bay airlock (built 2026-11-25)

**Pick history.** From `hangar_grid.png` the user first picked concept 5, "alcove airlocks" ("if we expect them to step
out of the alcove it makes more sense. That is where they are stored. Otherwise they are getting shot out the bottom
like Helldivers."). That was built with a door in every alcove's back wall (shots in `build/`); the user then picked
**one shared bay airlock** over per-alcove doors. The alcoves are storage walls again (clamps, lamps, back panel).
After watching it in game: "The animation didn't wait for them to walk, but it wasn't too long." So it now always
plays to the end, with the mission loading behind it.

## Egress logic
The crew's mechs are stored clamped in their alcoves, facing the aisle. The bay's **left end wall** (where the old
breaching door was) holds the airlock (`HangarAirlock`): an inner jaw door across two lanes (upper leaf with a viewing
window, rising into the wall; lower leaf sinking into the floor; hazard teeth on the seam), a chamber, an outer door
(two leaves sliding apart) and a short corridor to the docking collar. Lamp bars: green sealed, amber cycling, red open.
On Launch (`HangarEgress`, per airlock cycle = group):
1. The inner door cycles open. Each mech in turn: clamps release, it steps out of its alcove to its lane, turns toward
   the airlock (a quarter turn) and walks down the aisle into the chamber, to its slot (nose to tail, first one deepest).
2. Every mech parked: the inner door shuts, the chamber cycles (amber light, flashing lamps; visible through the window).
3. The outer door opens (red); the group walks out into the corridor; the outer door shuts.
4. A crew too long for the chamber: the chamber cycles back and the next group goes the same way.
**Groups (same rule for every chassis mix):** queue = nearest the airlock first; a mech joins the current group if one
of the `LANES` (2) lanes still has room for its depth + `SLOT_GAP`, else the group closes. A lane is
`lane_length()` = the deepest chassis + the shallowest one + 3 gaps (from the catalog). So 4 Striders or 2 Bulwarks +
2 Striders go in one cycle; 3 or 4 Bulwarks need two.
**No walking through each other:** a mech starts only once the one before it has turned onto its lane and stands
farther off than both turning radii (wide neighbours never turn at once); in a lane it keeps `SLOT_GAP` behind a parked
mech and `FOLLOW_GAP` (1.6 m: room for both strides) behind a walking one; nobody enters while the inner door is not
fully open (or leaves before the outer one is).

## Sizes (from the catalog, measured)
`HangarBay.chassis_envelope(id)` (every chassis, bare and bulkiest loadout, both leg bends, measured from a real
MechModel): lane width = widest + 2 x 0.25 m (5.14 m; the Bulwark is 4.64 m), lane 0 on the turn line (the fleet's
largest turning circle clears the alcove posts), the doors span both lanes, door height = tallest + 0.35 m. The test also
checks the lanes against the catalog capsules. Walk speed / acceleration / turn rate: the chassis' movement in the bay's
half scale (`GAME_SCALE` = MechRig.mech_scale 2); feet planted by `Gait`, legs by `LegIK`, as `MechRig` does.

## Timing: plays to the end, behind the load, crew-synced
- Launch flows `FrontEnd._play_launch(delay)` -> `MechStage.set_alert(true, delay)`; the 2.5 s launch alert (and
  NetMission's LAUNCH_LEAD) is unchanged. At its end FrontEnd hands its MechStage to `HangarHandoff`, a full-screen layer
  on the tree root above the mission's loading screen, and changes scene as before: the egress keeps playing while the
  mission loads behind it.
- `TestDrive._finish_setup` awaits `HangarHandoff.wait_done()` before it reports its build at the load barrier
  (`report_mission_built`, crew) or uncovers (solo, paused while it waits). So play starts when both the sequence and
  the load are done; the length comes from the crew composition (the same on every machine), so the crew still starts
  together on the host's go. No scripts/net change.
- Pace: 1.5x natural, more for a long sequence so it takes about 16 s (`EGRESS_TARGET`), never past 3x: solo Strider
  14.5 s natural -> 9.7 s, Strider + Bulwark 23.5 -> 15.7 s, 4 Striders 28 -> 16 s, 2B + 2S 32 -> 16 s, 4 Bulwarks
  (two cycles) 51 -> 17 s. Well inside NetMission.LOAD_TIMEOUT (45 s after start_t).
- No handoff headless or in tests (`--run-test`, unless `HangarHandoff.in_tests`), so net tests' barriers never wait.
- The camera eases from the stored framing to an egress view down the aisle from the bay's right side (the airlock
  door faces it, the chamber shows through the open door and the window).

## Look and cost
Flat low-poly, merged MeshKit meshes: the airlock's fixed parts one mesh (lit + glow), each moving leaf one, two lamp
bars, a glass pane, one chamber OmniLight (amber while cycling), two amber strobes (the bay's alert strobes).

## Lab and tests
Lab subject `hangar`: state (prep / alert = play), crew 1-4, crew chassis (strider / bulwark / mixed), egress pace.
`tests/test_hangar_egress.gd`: lane / door sizes from the catalog (boxes and capsules), group vs multi-cycle (1 cycle for
4 Striders and 2B+2S, 2 for 4 Bulwarks), cycles in order, no overlaps, nobody in a door that isn't open, everyone out of
sight at the end, doors shut and green, dry-run duration matches, played length near the target, reset.
Shots: `build2/` (idle; `contact_strider_bulwark.png`, `contact_crew4.png`; `egress_sb.gif/.mp4`,
`egress_crew4.gif/.mp4` (frames every 0.5 / 0.6 s of sequence time, 4 fps); `seq_*`; `hv2b_handoff_fullscreen.png`).
