# dhewm3 comparison

The same views in this port and in dhewm3 1.5.5 (the reference Doom 3 source port), on the 27 single player maps of Doom 3, taken 2026-11-12.

How it is made: `tools/tour_maps.ps1` visits 10 spots per map (the player start, then items and weapons) in god mode, noclip and notarget; `tools/dhewm3_refs.ps1 -Logs tour_output3 -OutDir dhewm3_ref3 -Every 2` puts dhewm3's eye at the same places (`setviewpos`, HUD and weapon hidden) and writes this table (`summary.md`), a text file per map with every view's numbers and a sheet per map with the pairs side by side (`<map>_compare.jpg`). The output folders are not in the repository (they are screenshots of id Software's data).

- **Luma**: the mean brightness of a view (0 to 255); the columns are the medians of a map's 10 views.
- **Luma difference**: how far a view's luma is from dhewm3's, in percent of dhewm3's; a view that is black in dhewm3 counts as a very large difference.
- **Image difference**: the mean absolute difference of the two views in gray, shrunk to 160 x 90 and slightly blurred, in percent of white. Under 5 is the same view with small differences.
- The bottom 18% of both views (this port's HUD and weapon) is left out.

## All maps, default settings

| Map | Views | Luma here | Luma dhewm3 | Median luma difference | Views within 15% | Median image difference | Views under 5 |
|---|---|---|---|---|---|---|---|
| admin | 10 | 16.4 | 12.8 | 20% | 4 | 4.8 | 6 |
| alphalabs1 | 10 | 11.6 | 3.5 | 282% | 0 | 3.9 | 9 |
| alphalabs2 | 10 | 12.6 | 5.6 | 224% | 0 | 4.2 | 6 |
| alphalabs3 | 10 | 12.9 | 5.2 | 81% | 0 | 3.8 | 8 |
| alphalabs4 | 10 | 13.2 | 6.2 | 61% | 1 | 3.0 | 9 |
| caverns1 | 10 | 12.2 | 9.7 | 31% | 4 | 2.3 | 9 |
| caverns2 | 10 | 10.0 | 6.3 | 84% | 1 | 2.8 | 9 |
| comm1 | 10 | 14.8 | 10.7 | 51% | 0 | 4.8 | 5 |
| commoutside | 10 | 17.2 | 7.5 | 175% | 0 | 5.5 | 5 |
| cpu | 10 | 15.8 | 10.7 | 75% | 1 | 4.1 | 8 |
| cpuboss | 10 | 13.7 | 13.6 | 30% | 2 | 3.8 | 8 |
| delta1 | 10 | 16.0 | 9.8 | 78% | 0 | 3.8 | 8 |
| delta2a | 10 | 19.0 | 31.9 | 45% | 1 | 7.8 | 2 |
| delta2b | 10 | 10.0 | 1.8 | 223% | 0 | 3.9 | 9 |
| delta3 | 10 | 14.5 | 15.2 | 40% | 3 | 3.9 | 8 |
| delta4 | 10 | 0.9 | 10.9 | 91% | 1 | 4.2 | 7 |
| delta5 | 10 | 19.1 | 9.8 | 95% | 1 | 5.0 | 5 |
| enpro | 10 | 14.3 | 7.8 | 128% | 3 | 4.1 | 7 |
| hell1 | 10 | 15.4 | 8.2 | 87% | 1 | 3.6 | 8 |
| hellhole | 10 | 15.4 | 6.1 | 160% | 0 | 4.2 | 6 |
| mars_city1 | 10 | 16.9 | 12.8 | 41% | 0 | 3.7 | 7 |
| mars_city2 | 10 | 18.7 | 21.0 | 25% | 2 | 4.0 | 7 |
| mc_underground | 10 | 11.6 | 9.9 | 69% | 2 | 3.9 | 7 |
| monorail | 10 | 0.1 | 3.4 | 100% | 2 | 4.1 | 7 |
| recycling1 | 10 | 13.1 | 8.9 | 48% | 1 | 2.6 | 8 |
| recycling2 | 10 | 12.0 | 10.3 | 35% | 1 | 2.6 | 9 |
| site3 | 10 | 16.4 | 4.3 | 1001% | 0 | 4.8 | 5 |
| **all** | 270 | | | 66% | 31 | 3.9 | 192 |

What it says:

- The views are the same places and shapes: 192 of 270 views have an image difference under 5.
- The brightness is not the same. Where dhewm3 is black (inside lockers, unlit corners), this port shows a flat gray of 10: Castle Game Engine's default global ambient light (0.2) times the materials' ambient (0.2). Items are often in dark places, so the medians differ a lot (`alphalabs1`: 11.6 here, 3.5 in dhewm3).
- `delta4` and `monorail` have several views that are fully black here (0, not the gray) and lit in dhewm3 (`delta4` at eye 100 68 165): not looked into yet.

## Five maps without the global ambient light

The same five maps toured with `CD3_GLOBAL_AMBIENT=0` (console `r_globalAmbient 0`), against the same dhewm3 views:

| Map | Views | Luma here | Luma dhewm3 | Median luma difference | Views within 15% | Median image difference | Views under 5 |
|---|---|---|---|---|---|---|---|
| admin | 10 | 6.7 | 12.8 | 59% | 0 | 4.5 | 6 |
| alphalabs1 | 10 | 1.6 | 3.5 | 29% | 4 | 1.0 | 10 |
| delta1 | 10 | 5.9 | 9.8 | 38% | 2 | 2.3 | 8 |
| hell1 | 10 | 5.2 | 8.2 | 24% | 2 | 1.8 | 10 |
| mars_city2 | 10 | 8.9 | 21.0 | 52% | 3 | 3.8 | 7 |
| **all** | 50 | | | 39% | 11 | 2.9 | 41 |

- Black is black, and the image difference gets smaller in all five maps (median 2.9 instead of 3.9).
- Lit places are then darker than dhewm3's (about 55 to 65% of its luma): the lights' middles match, their soft outer parts don't. The port draws the lights' projection and falloff images as analytic shapes (roadmap item 10, exact light images); the gray had hidden that.
- The default is unchanged for now (CGE's 0.2).
