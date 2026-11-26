# Chassis concept picks (local-render, seed 11, 768x768; prompts beside each render as `*_prompt.txt`)

| Pick | Source render | Workflow | Reference |
|---|---|---|---|
| `pick_bulwark_torso_barrel.png` | `bulwark_a1_s11.png` | flux3_klein_refs | `art/picks/mech_base.png` |
| `pick_bulwark_legs_sumo.png` | `bulwark_legstudy_8_sumo_s11.png` | flux3_klein_t2i | none |
| `pick_wasp_four_fans_pod.png` | `wasp_a1_s11.png` | flux3_klein_refs | `art/picks/mech_base.png` |

User picks (2026-11-23): Bulwark = barrel torso + sumo legs (forward knees); Wasp = four fans, pod hull.
| `pick_bulwark_concept.png` | `bulwark_full_s22.png` | flux3_klein_refs | `pick_bulwark_torso_barrel.png` + `pick_bulwark_legs_sumo.png` |
| `pick_wasp_landed_chicken_legs.png` | `wasp_legs_a_chicken_s22.png` | flux3_klein_refs | `pick_wasp_four_fans_pod.png` |

## Bulwark layout pick (2026-11-23)
- `pick_bulwark_layout_slung_hull.png` = `bulwark2_b1_s11.png`: flux3_klein_t2i, text only, seed 11, 768x768, prompt in `bulwark2_b1_prompt.txt`. Grid: `bulwark_layout_grid.png` (cells `bulwark2_<a|b|c><1|2|3>_s11.png`). User picked B1: slung hull, outboard legs, top-deck detail. Supersedes the barrel torso pick.

## Wasp look pick (2026-11-25)
- `pick_wasp_tandem_compact.png` = `wasp5_a1_s11.png`: flux3_klein_refs, reference `art/picks/mech_base.png`, seed 11, 768x768, prompt in `wasp5_a1_prompt.txt`. Grid: `wasp_orig_grid.png` (cells `wasp5_<a|b|c><1|2|3>_s11.png`). User picked A1: two big ducted fans beside the cockpit, two small rear fans, compact egg pod, dangling chicken legs. Supersedes `pick_wasp_four_fans_pod.png` (four equal corner fans); the "min 3 fans to fly" rule has to change. Earlier grids kept for the record: `wasp_look_grid.png` (wasp2_*), `wasp_b1_grid.png` (wasp3_*).
