# Pilot heads: RESUMED and built (2026-11-22)

No longer paused. Current status is at the top of `docs/design/pilot-heads.md`. Remaining: wire combat state (heat, hp,
hits, firing, aim) into `PilotHead.feed` / `react_hit` / `look_at_point`; user decisions on effects and flush. The text
below is the original pause note, kept for history.

---

# Paused: expressive pilot heads + duck

Paused 2026-11-21 (evening) at the user's request: not on the critical path to a playable demo. Nothing is committed.
Session: "pilot heads" side session of the main game-design session. Resume from this file alone.

## Goal
All five pilot heads (chicken, pickle, corn, dog, **duck**) rigged with moods, reactions, neck motion and idles, a lab
subject to preview them, tests green. Design: `docs/design/pilot-heads.md`. Implementation is done by Opus subagents
(Agent tool, model "opus"), one focused piece each; design and review stay in the lead session.

## Done
- Design draft `docs/design/pilot-heads.md` (rig = rigid faceted pieces; channels, 6 moods, 8 reactions; neck spring;
  idle; networking = all `Net.LOCAL`; code shape).
- Duck concept grid `art/renders/head_duck_r1/grid_head_duck_r1.png` (script `art/tools/head_duck_r1.ps1`, `SEEDS.md`).
  **User picked 2: mallard with the crest tuft**, copied to `art/picks/head_duck.png`, recorded in `art/picks/SEEDS.md`.
- Hook agreed with the mech-meshes session (see "Agreed hook").

## In progress when paused
**Subagent A (core + chicken rig)** was told to stop at a safe point with `-TestAll` green and report. Its report had
not arrived when this was written: **check the state of these files before relying on them** (run
`.\test_runner.ps1 -TestName test_pilot_head`, then `-TestAll`).
- `scripts/pilot/pilot_head.gd` (`PilotHead`: `make`, `feed`, `advance`, `set_mood`, `react`, `react_hit`,
  `look_at_point`, `fx` signal)
- `scripts/pilot/pilot_expressions.gd` (channel list, mood and reaction tables)
- `scripts/pilot/pilot_face.gd` (shared channels -> pieces logic; **the head-definition contract is its header**)
- `scripts/pilot/pilot_neck.gd` (two-joint spring chain, flair springs, look / turn lead)
- `scripts/pilot/pilot_idle.gd` (seeded blinks, glances, tics)
- `scripts/pilot/heads/pilot_head_chicken.gd` (the reference rig)
- `tests/test_pilot_head.gd`
Not reviewed by the lead yet: no code review, no screenshots looked at.

## Not started
- B: rigs for pickle, corn, dog (`scripts/pilot/heads/pilot_head_<id>.gd`, one registry line each in `PilotHead`).
- C: duck: rig (`pilot_head_duck.gd`) from `art/picks/head_duck.png`; static duck in `MechHeadMeshes.build` +
  `MechMeshes.HEADS`, rerun `.\tools\models\gen_mech_meshes.ps1`; `"duck"` in `MechCatalog.HEADS` / `HEAD_ORDER`
  (shared file: only add the duck; tell the main session); `tests/test_smoke.gd` asserts exactly four heads; prove
  settings, hangar and the hello handshake accept it.
- D: effects `scripts/pilot/pilot_fx.gd` (stars, steam, sweat, chips, flash; listens to `PilotHead.fx`).
- E: lab subject `pilot` in `LabRegistry.SUBJECTS` (head, mood, reaction triggers, look target, scripted "mech moves"
  loop, five-head line-up); optional `lab_actions()` / `do_lab_action(id)` added to the lab contract for buttons.
- F: the mech hook (below), then `test_layout` / `-Visual` shots and review.

## Exact next step
1. Read subagent A's files, run `test_pilot_head` and `-TestAll`. If A stopped part-way, send one Opus subagent to
   finish the brief (missing pieces = whatever the tests listed in design §8 do not yet cover).
2. Take a hidden-desktop shot of the chicken in each mood (GPU lock: `docs/testing.md`), review, fix.
3. Launch B, C, D+E in parallel (separate files), then F (touches `mech_model.gd` / `mech_rig.gd`) last.

## Agreed hook (mech-meshes session, 2026-11-21)
- The lead's subagent may edit only the head lines: in `mech_model.gd` `_build_lowpoly`, replace the static head with
  `PilotHead.make(head_id, seed)`; keep the node in the Cockpit seat named `Head_<id>`, the scale
  `float(params["head"]) / (s * MechMeshes.BODY_SCALE)` and y = -0.12; leave the placeholder branch untouched;
  `MechModel.pilot` is reassigned on every `rebuild()` (null in placeholder art).
- In `mech_rig.gd` `update_pose`, one guarded `model.pilot.feed(delta, {...})` using `_body.grounded()` and `_air_time`.
- `MechParts.head` (used by the `heads` lab gallery) stays on the static `.res`.
- Re-read both files before editing: that session has uncommitted changes in them.

## Rules that apply
No windows: headless tests, hidden desktop for shots, GPU lock shared with ComfyUI. Look RNG only (never global
`randf`). No network code. Don't edit `docs/design/decisions.md`. `art/` only for the duck round. Don't commit.

## Open questions for the user
Duck: **answered** (2, mallard / tuft). The other five were not answered; work proceeded on these defaults, all cheap
to change:
1. Face budget: rigged heads at ~180-210 faces instead of ~150. Default: yes.
2. Effects (faceted stars, steam, sweat, chips). Default: in, behind `fx_enabled`.
3. Colour flush (red hot, pale afraid, grey disabled). Default: on.
4. Victory is a smirk with one raised brow, not a grin. Default: yes.
5. Pickle's long-range signal is whole-body jelly squash, no added appendage. Default: yes.
Also for the main session later: the `apply_damage` result must be visible on every machine (direction, amount) so
puppets flinch.
