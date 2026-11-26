# Menu: where the player's mech stands (2026-11-25, proposal)

User: "I like the backdrop, but putting the player on a rotating pedestal doesn't make sense in that scene."
Each option: an in-engine blockout (`engine_*.png`: MenuBackdrop + MechStage, menu camera unless noted, crude boxes for
new hardware, the round plinth still baked in the hall mesh) and two img2img renders from it (`renders/<id>_s11/_s22.png`,
flux3_klein_refs, 1024x848, prompts in `prompts/`, `render_placement.ps1`). Contact sheet: `placement_grid.png`.
`engine_current_pedestal.png` is today's menu.

- **A Service cradle** (`engine_A_cradle.png`): the mech stays where it is but stands still in a maintenance cradle
  (gantry towers, yoke, hip-height catwalk, umbilicals, striped floor plate), turned three-quarters to look out at the
  habitat. Smallest change; the mech stays big and well lit. Best render: s22.
- **B Outside on a gantry** (`engine_B_outside.png`): seen through the glass, the mech stands on an external boarding arm
  under hull floodlights, the habitat behind it; the room is empty foreground. Strong story (about to go), but the mech is
  small (~1/4 of the preview height) and the accent picker would read poorly. Best render: s22.
- **C Holo on the tactical table** (`engine_C_holo.png`; `engine_C_holo_menu_cam.png` at the menu camera, where it is too
  small): the mech as an orange hologram over the table, camera moved in. Fits the room perfectly, but loses the real
  mech's colours and detail (bad for accents and hangar continuity). Best render: s11.
