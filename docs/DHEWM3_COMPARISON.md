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

## Again after the light fixes (2026-11-16)

The same 27 maps toured again (`tour_output6`) against the same dhewm3 views, after lights moved to their `light_origin`, took their projection image's hue and their `sound` amplitude (see the changelog): 199 of 270 views have an image difference under 5 (192 before), the median stays 3.9. The maps with the most moved and sound driven lights changed most: `delta2a` median image difference 7.8 -> 5.8 (its yellow lamp room, view 5: luma 10.5 -> 28.8, dhewm3 31.9), `comm1` 4.8 -> 4.1, `commoutside` 5.5 -> 5.2, `mc_underground` view 6 (a flickering sound driven light 6 units from a box) 10 -> 26, dhewm3 96.

What still differs most, by view:

- Views from outside every area (the eye in a wall or in a parked monorail car: `caverns2`, `delta4`, `monorail`): Doom 3 draws all areas there, this port the last area the view was in (drawing all of them compiles shaders for every light at once).
- Sealed item closets: dhewm3 draws them black, here the sky shows through (`alphalabs2`, `delta5`, `site3`).
- Doors open here and stay shut in dhewm3: the tour flies with noclip, and Doom 3 doesn't touch triggers in noclip (this port does, for the routes).
- The global ambient gray and the lights' soft outer parts (analytic shapes, roadmap item 10), as before.

## Measured light images (2026-11-17)

The 27 maps toured again (minimized and muted, `tour_output9`) after the lights took their projection and falloff images' measured profiles instead of analytic shapes, Doom 3's 512 sample window for sound driven lights and the portal flow of lights with a precomputed shadow (see the changelog), against the same dhewm3 views:

| | Before (`tour_output7`) | After (`tour_output9`) |
|---|---|---|
| Views with an image difference under 5 | 201 | 213 |
| Views within 15% of dhewm3's luma | 32 | 40 |
| Median image difference | 3.9 | 3.9 |

The five maps without the global ambient light (`CD3_GLOBAL_AMBIENT=0`, before the portal flow):

| Map | Views | Luma here | Luma dhewm3 | Median luma difference | Views within 15% | Median image difference | Views under 5 |
|---|---|---|---|---|---|---|---|
| admin | 10 | 8.5 | 12.8 | 36% | 1 | 3.8 | 8 |
| alphalabs1 | 10 | 2.8 | 3.5 | 7% | 6 | 0.8 | 10 |
| delta1 | 10 | 7.9 | 9.8 | 22% | 3 | 1.6 | 9 |
| hell1 | 10 | 6.4 | 8.2 | 15% | 5 | 1.1 | 10 |
| mars_city2 | 10 | 18.2 | 21.0 | 27% | 3 | 2.5 | 7 |
| **all** | 50 | | | 27% (39% before) | 18 (11) | 1.9 (2.9) | 44 (41) |

- Lit places are now near dhewm3's brightness (`mars_city2`'s median luma 8.9 -> 18.2, dhewm3 21.0; `delta3`'s first corridor 25.4 -> 45.5, dhewm3 57.4): the soft outer parts of the lights were what the analytic shapes missed.
- With the default global ambient the median luma difference grows (63% -> 75%): places dhewm3 draws black still get the gray, and lights now reach further into them.
- Where it is brighter than dhewm3 now: big lights that Doom 3's shadows keep out of rooms behind walls (`game/comm1`'s airlock is lit by the outdoor light `light_outdoor_area2_1`, whose image `lights/asstemp2a` is an even noise, not a disc): here only one light casts shadows. Flickering lights make some views differ from run to run (`mc_underground` view 4: luma 35.6, 18.3, 31.5 in three tours).
