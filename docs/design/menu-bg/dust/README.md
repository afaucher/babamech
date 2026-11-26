# Menu dust over the walls (2026-11-25)

Faint dots over the dark wall and window frame in the menu were the additive dust motes (`MenuBackdrop._dust`), not the
stars: same frame, same camera, `before_dust_on.png` vs `dust_off.png` differ by ~970 px of specks, most over the frame
and wall; turning the stars off removes dots only over the black glass (stars are depth-tested correctly).
Fix (menu_backdrop.gd `_dust_over_glass`): a mote is kept only if, seen from the menu camera (CAM_POS), it lies over open
glass (inside the window opening, clear of the ribs and transom, with a margin for its drift). The generator still draws
every mote, so the motes over the glass are identical. `after_dust_on.png`, `crop_right_frame_compare.png` (right frame,
before / after / off), `dust_marks_before_after.png` (motes circled: magenta before, green after). 32 of 120 motes remain
at HIGH (about 15 visible beside the mech): sparser; raising DUST would restore the density over the glass (a look change).

**Superseded (2026-11-25, user: "Just drop the motes entirely."):** the dust is gone from MenuBackdrop (mesh, quality
counts, the window filter, the rebuild hooks). These shots stay as the record of the investigation.
