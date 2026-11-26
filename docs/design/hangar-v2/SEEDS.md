# Hangar v2: how the mechs leave the bay (2026-11-25, proposal)

User: "higher detail and a more logical thought process about how the mechs get out". Fiction used: our assault boat is
docked to the habitat; the crew enters a section along the transit rail line through the top deck's bulkhead
(mission-section.md §2). Today's bay (HangarBay): four wall alcoves and a plain two-leaf "breaching door" on the left end
wall, with no visible way from the alcoves to the station.

local-render, flux3_klein_t2i, 1024x576, seeds 11 and 22 (both in renders/), prompts in prompts/ (shared style block +
one mechanism each). Regenerate: `render_hangar_v2.ps1`. Grid: `hangar_grid.png` (the seed shown per tile).

| # | Egress | Grid seed | Prompt |
|---|---|---|---|
| 1 | Breach + walk: the end wall is a ram that bored through the hull; mechs unclamp and walk a striped aisle into the boarding tube | 22 | prompts/1_breach_walk.txt |
| 2 | Rail-launch sleds: each cradle is a wheeled sled on floor rails converging on a hatch mated to the station's rail tunnel | 11 | prompts/2_rail_sleds.txt |
| 3 | Floor hatch / spoke lift: docked at the hub, each alcove's floor is a lift that lowers its mech down a lit shaft | 11 | prompts/3_floor_drop.txt |
| 4 | Overhead crane: mechs hang from ceiling crane carriages, carried in line to an airlock | 22 | prompts/4_overhead_crane.txt |
| 5 | Alcove airlocks: each alcove is its own lock; the back wall opens onto a station corridor | 22 | prompts/5_alcove_airlocks.txt |
| 6 | Revolver carousel: cradles on a turntable index one mech at a time to one breach gate | 11 | prompts/6_carousel.txt |
| 7 | Two-level cutaway: scissor-lift cradles lower mechs onto a flatbed rail car in the station tunnel below | 11 | prompts/7_cutaway_lift.txt |
| 8 | Belly ramp: the bay floor's far end hinges down into a station docking hangar; mechs walk down | 11 | prompts/8_belly_ramp.txt |
| 9 | Mass driver: a magnetic launch trench down the bay fires each mech through an iris into the transit tunnel | 11 | prompts/9_mass_driver.txt |

Notes: the renders came out detailed and semi-realistic rather than the locked flat low-poly look, and the left third is
not darker as asked: they are references for the egress logic and the detail density, not for shading. 2 and 7 tie the
bay directly to the rail-line entry the mission already uses.
