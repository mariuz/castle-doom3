# Chocolate DOOM-3-BFG comparison

The same views in this port and in Chocolate DOOM-3-BFG (github.com/klaussilveira/chocolate-doom3-bfg, the reference for the Doom 3 BFG data, roadmap item 13), on the 47 maps of the BFG edition: Doom 3's 27, Resurrection of Evil's 12 and the Lost Mission's 8. Taken 2026-11-19, before the BFG light scale (below).

How it is made: `tools/tour_maps.ps1 -BasePath "F:\GogGalaxyGames\DOOM 3 BFG" -Route -OutDir playthrough_bfg` plays every map's route (console `route all`) and takes its screenshots; `tools/chocolate_refs.ps1 -Logs playthrough_bfg -OutDir chocolate_ref2` puts Chocolate DOOM-3-BFG's eye at every third of them (`setviewpos`, HUD and weapon hidden, `g_fov 90`) on a fresh load of the map and writes this table, a text file per map and a sheet per map (`<map>_compare.jpg`, ours left). The output folders are not in the repository (screenshots of id Software's data). The columns are those of `docs/DHEWM3_COMPARISON.md`; views where our eye was outside every area (`area -1` in the screenshot line: the route's eye in a wall or a parked monorail car, where Doom 3 draws every area and this port almost nothing) are left out and counted in the last column.

## The playthrough

All 47 maps load and play to their end with no exception and no shader error; every map with a next one loads it (deltax's route stops short of its end, `game/hell` loads after it); 15 stalls over 0.3 s in all (6.5 s). `playthrough_bfg/summary.txt` has each map's numbers.

Played again 2026-11-20 (`playthrough_bfg2`) after BFG brush entities without surfaces were built empty (the script movers' anchors the `.bproc` leaves out, on 41 of the 47 maps): again no exceptions, every map with a next one loads it, deltax's route still stops short. The "Not supported" lines went from 1958 to 591 (mars_city1 27 to 0, mc_underground 35 to 6, erebus3 235 to 17); 392 of the rest are comm1's mover events on `func_mover`s that scripts spawn (`func_mover_spawned_N`: `setModel`, `time`, `move`, `rotateOnce`...), 50 more in commoutside. The run was from a copy with another exe name, so NVIDIA's shader disk cache started empty: 175 stalls over 0.3 s (108 s), against 13; played again with the cache warm, erebus4 had 3 (17 cold) and le_enpro1 0 (17 cold). Frame rates are capped at 60 by vertical sync now, so the medians don't compare with the first run's.

## All maps, default settings

| Map | Views | Luma here | Luma chocolate | Median luma difference | Views within 15% | Median image difference | Views under 5 | Left out (outside areas) |
|---|---|---|---|---|---|---|---|---|
| admin | 14 | 17.8 | 22.9 | 34% | 3 | 7.8 | 2 | 0 |
| alphalabs1 | 16 | 10.2 | 15.2 | 36% | 5 | 6.1 | 7 | 2 |
| alphalabs2 | 12 | 14.2 | 10.9 | 57% | 2 | 5.4 | 5 | 3 |
| alphalabs3 | 9 | 13.7 | 20.3 | 49% | 0 | 7.0 | 2 | 2 |
| alphalabs4 | 22 | 15.9 | 21.3 | 21% | 6 | 5.8 | 9 | 0 |
| caverns1 | 20 | 2.8 | 19.6 | 84% | 0 | 6.7 | 5 | 3 |
| caverns2 | 8 | 2.6 | 11.9 | 85% | 0 | 3.8 | 5 | 2 |
| comm1 | 20 | 15.4 | 16.8 | 35% | 4 | 6.1 | 6 | 0 |
| commoutside | 26 | 15.9 | 16.1 | 46% | 8 | 6.3 | 8 | 4 |
| cpu | 13 | 9.5 | 10.9 | 60% | 3 | 6.5 | 6 | 2 |
| cpuboss | 13 | 23.0 | 27.0 | 52% | 2 | 8.4 | 2 | 3 |
| delta1 | 27 | 18.0 | 14.4 | 52% | 6 | 7.4 | 7 | 1 |
| delta2a | 14 | 12.1 | 20.2 | 46% | 0 | 6.8 | 3 | 2 |
| delta2b | 17 | 10.9 | 16.9 | 43% | 3 | 5.6 | 6 | 3 |
| delta3 | 16 | 16.8 | 25.0 | 39% | 1 | 8.3 | 2 | 1 |
| delta4 | 2 | 8.5 | 14.3 | 21% | 1 | 4.6 | 1 | 1 |
| delta5 | 4 | 15.7 | 14.1 | 44% | 1 | 5.1 | 1 | 3 |
| deltax | 4 | 10.2 | 16.6 | 48% | 1 | 6.0 | 2 | 3 |
| enpro | 17 | 16.6 | 20.9 | 42% | 3 | 5.2 | 7 | 1 |
| erebus1 | 7 | 7.2 | 4.6 | 74% | 0 | 4.9 | 4 | 3 |
| erebus2 | 13 | 6.4 | 5.1 | 56% | 2 | 2.8 | 13 | 0 |
| erebus3 | 12 | 17.2 | 24.8 | 30% | 0 | 7.4 | 1 | 4 |
| erebus4 | 10 | 13.4 | 30.5 | 56% | 1 | 9.1 | 3 | 1 |
| erebus5 | 17 | 30.8 | 24.2 | 41% | 5 | 9.2 | 4 | 2 |
| erebus6 | 12 | 14.1 | 13.6 | 26% | 4 | 4.7 | 7 | 2 |
| hell1 | 31 | 13.9 | 10.8 | 32% | 6 | 3.7 | 23 | 4 |
| hell | 19 | 14.2 | 12.4 | 26% | 6 | 3.5 | 17 | 2 |
| hellhole | 6 | 7.3 | 17.4 | 47% | 1 | 4.9 | 3 | 5 |
| le_enpro1 | 22 | 19.1 | 20.4 | 31% | 5 | 6.7 | 6 | 0 |
| le_enpro2 | 18 | 14.8 | 12.1 | 70% | 3 | 5.2 | 8 | 0 |
| le_exis1 | 11 | 22.8 | 30.5 | 47% | 3 | 10.0 | 0 | 0 |
| le_exis2 | 12 | 15.5 | 22.9 | 45% | 2 | 6.8 | 2 | 1 |
| le_hell | 24 | 14.2 | 16.6 | 37% | 2 | 4.8 | 13 | 7 |
| le_hell_post | 20 | 17.8 | 23.7 | 29% | 4 | 6.7 | 7 | 4 |
| le_underground2 | 19 | 13.9 | 15.7 | 53% | 1 | 5.7 | 7 | 0 |
| le_underground | 10 | 15.3 | 16.0 | 31% | 1 | 5.5 | 3 | 1 |
| mars_city1 | 5 | 19.4 | 26.1 | 26% | 1 | 7.7 | 1 | 2 |
| mars_city2 | 14 | 28.0 | 31.6 | 26% | 4 | 11.3 | 0 | 2 |
| mc_underground | 22 | 14.9 | 18.2 | 40% | 4 | 6.3 | 8 | 1 |
| monorail | 26 | 6.5 | 17.6 | 54% | 3 | 5.6 | 13 | 9 |
| phobos1 | 22 | 10.8 | 14.7 | 47% | 1 | 5.2 | 11 | 1 |
| phobos2 | 19 | 16.2 | 29.1 | 35% | 1 | 7.8 | 5 | 2 |
| phobos3 | 21 | 13.2 | 14.1 | 26% | 7 | 6.0 | 9 | 2 |
| phobos4 | 11 | 10.2 | 3.3 | 65% | 0 | 3.5 | 10 | 0 |
| recycling1 | 20 | 14.8 | 18.4 | 19% | 10 | 5.0 | 10 | 3 |
| recycling2 | 19 | 8.2 | 12.6 | 45% | 2 | 4.1 | 12 | 1 |
| site3 | 15 | 14.7 | 21.0 | 42% | 3 | 8.3 | 6 | 1 |
| **all** | 731 | | | 41% | 131 | 6.0 | 292 | 96 |

## Fresh loads, the Doom 3 BFG look (2026-11-20)

`tools/chocolate_refs.ps1 -Logs playthrough_bfg -Fresh -OutDir chocolate_fresh`: both engines load each map and go to the same views at once (the route's views of the table above are mid-game: doors open, lights switched), both with Doom 3 BFG's look (lights x1.5, `g_fov` 80 across 16:9) and this port's fog lights. Against the route comparison above: views under an image difference of 5 292 of 731 -> 414 of 701, median image difference 6.0 -> 4.3, median luma of the maps 14.2 against Chocolate DOOM-3-BFG's 16.9 -> 18.5 against 17.6 (this port is now darker on 21 maps of 47, was 46).

| Map | Views | Luma here | Luma chocolate | Median luma difference | Views within 15% | Median image difference | Views under 5 | Left out (outside areas) |
|---|---|---|---|---|---|---|---|---|
| admin | 14 | 27.4 | 23.8 | 44% | 3 | 8.1 | 5 | 0 |
| alphalabs1 | 15 | 12.8 | 13.9 | 29% | 4 | 3.7 | 10 | 3 |
| alphalabs2 | 12 | 13.4 | 11.2 | 35% | 3 | 4.3 | 7 | 3 |
| alphalabs3 | 8 | 18.9 | 18.6 | 27% | 3 | 4.7 | 4 | 3 |
| alphalabs4 | 21 | 21.1 | 22.6 | 33% | 3 | 4.4 | 12 | 1 |
| caverns1 | 19 | 12.2 | 21.0 | 39% | 2 | 4.5 | 12 | 4 |
| caverns2 | 8 | 5.0 | 14.5 | 69% | 1 | 3.0 | 5 | 2 |
| comm1 | 19 | 12.9 | 17.2 | 32% | 5 | 3.6 | 12 | 1 |
| commoutside | 26 | 17.0 | 17.0 | 30% | 8 | 3.9 | 16 | 4 |
| cpu | 13 | 13.1 | 10.9 | 47% | 2 | 3.7 | 8 | 2 |
| cpuboss | 13 | 26.7 | 24.6 | 25% | 4 | 7.6 | 5 | 3 |
| delta1 | 26 | 20.3 | 17.9 | 33% | 5 | 4.7 | 15 | 2 |
| delta2a | 14 | 17.2 | 20.4 | 30% | 4 | 4.0 | 9 | 2 |
| delta2b | 17 | 12.5 | 15.1 | 27% | 4 | 3.0 | 11 | 3 |
| delta3 | 16 | 23.1 | 26.0 | 21% | 6 | 5.8 | 7 | 1 |
| delta4 | 2 | 10.5 | 15.6 | 17% | 1 | 2.4 | 2 | 1 |
| delta5 | 4 | 18.1 | 14.3 | 31% | 1 | 3.1 | 3 | 3 |
| deltax | 3 | 16.4 | 14.9 | 10% | 2 | 3.9 | 3 | 4 |
| enpro | 17 | 24.2 | 19.7 | 21% | 8 | 4.2 | 14 | 1 |
| erebus1 | 6 | 10.7 | 4.7 | 33% | 2 | 1.9 | 6 | 4 |
| erebus2 | 13 | 4.6 | 6.6 | 32% | 5 | 1.7 | 12 | 0 |
| erebus3 | 12 | 21.4 | 25.1 | 25% | 4 | 3.9 | 8 | 4 |
| erebus4 | 10 | 22.9 | 30.6 | 37% | 1 | 7.0 | 3 | 1 |
| erebus5 | 18 | 47.0 | 23.5 | 73% | 2 | 11.2 | 4 | 1 |
| erebus6 | 11 | 23.3 | 11.4 | 81% | 0 | 4.2 | 6 | 3 |
| hell1 | 21 | 11.9 | 11.3 | 46% | 6 | 3.6 | 14 | 14 |
| hell | 11 | 14.9 | 13.2 | 19% | 2 | 4.0 | 9 | 10 |
| hellhole | 10 | 20.6 | 15.4 | 51% | 3 | 6.2 | 3 | 1 |
| le_enpro1 | 22 | 30.6 | 18.3 | 39% | 5 | 5.1 | 10 | 0 |
| le_enpro2 | 18 | 12.1 | 12.5 | 32% | 4 | 3.2 | 11 | 0 |
| le_exis1 | 11 | 29.2 | 32.7 | 24% | 3 | 6.5 | 3 | 0 |
| le_exis2 | 12 | 23.3 | 27.7 | 22% | 4 | 5.0 | 6 | 1 |
| le_hell | 24 | 13.9 | 17.6 | 29% | 4 | 3.7 | 17 | 7 |
| le_hell_post | 13 | 19.4 | 22.6 | 30% | 4 | 7.6 | 5 | 11 |
| le_underground2 | 19 | 18.5 | 16.9 | 33% | 2 | 4.1 | 13 | 0 |
| le_underground | 10 | 19.9 | 15.9 | 29% | 1 | 4.4 | 5 | 1 |
| mars_city1 | 5 | 30.0 | 27.1 | 62% | 1 | 7.4 | 2 | 2 |
| mars_city2 | 14 | 29.8 | 33.0 | 28% | 2 | 6.7 | 3 | 2 |
| mc_underground | 22 | 18.5 | 18.8 | 29% | 7 | 4.7 | 12 | 1 |
| monorail | 26 | 12.9 | 18.0 | 48% | 4 | 3.7 | 15 | 9 |
| phobos1 | 22 | 12.2 | 15.3 | 25% | 4 | 3.2 | 17 | 1 |
| phobos2 | 19 | 22.8 | 27.1 | 25% | 4 | 5.1 | 9 | 2 |
| phobos3 | 21 | 22.1 | 15.4 | 22% | 7 | 4.2 | 13 | 2 |
| phobos4 | 11 | 5.6 | 3.6 | 33% | 3 | 1.3 | 11 | 0 |
| recycling1 | 20 | 22.8 | 18.9 | 46% | 2 | 4.6 | 12 | 3 |
| recycling2 | 18 | 14.1 | 13.1 | 25% | 5 | 2.4 | 16 | 2 |
| site3 | 15 | 21.1 | 23.3 | 19% | 7 | 3.7 | 9 | 1 |
| **all** | 701 | | | 32% | 167 | 4.3 | 414 | 126 |

The worst maps are mostly views from inside walls: Chocolate DOOM-3-BFG pushes the player out of a wall after `setviewpos`, this port's noclip stays there (erebus5's views 12 to 16 look at a wall from up close here, at a room there). erebus5's 2 fog lights cover less than half of every area's box, so no area there was fogged.

After the fog lights became Doom 3's fog pass (the depth curve exactly, the fade at the box's top, the box's far faces, every surface a fog light touches; `tools/chocolate_ours.ps1 -OutDir chocolate_fog`, the same Chocolate DOOM-3-BFG views): all maps 413 views under 5 (414 before), median difference 4.3; the fog maps: caverns1 16 of 19 (was 12 in this table), median luma 18.1 against 21.0 (12.2); caverns2 luma 10.1 against 14.5 (5.0); delta1 15 of 26 (15); erebus5 is unchanged (14 areas fogged now: its views are in walls). Other maps differ only by their moving lights and monsters.

With fog on entities too (brush entities, static and md5 models whose box touches a fog light; `chocolate_fog3`): caverns1 17 of 19 views under 5, median difference 1.9, median luma 22.6 against 21.0; caverns2 6 of 8, 2.4, luma 14.8 against 14.5. delta1, erebus5, hell1 and recycling1 are about the same.

## What differs

- **The view's state**: our route takes its screenshots mid-game (doors it opened, lights a trigger switched, a damage tint, monsters), Chocolate DOOM-3-BFG a fresh load seconds after the map starts. Most of the image differences over 5 are views where something else is open, on or alive. Comparing fresh loads (our port at Chocolate DOOM-3-BFG's views, `setviewpos`, eye height minus 68) removes most of it.
- **Light scale** (fixed after the table): Doom 3 BFG's renderer multiplies every light by `r_lightScale` 3, the 2004 renderer (and dhewm3) by 2, and the port matched the 2004 one: views were darker (median luma 10 against 18.5 in alphalabs1, 18.5 against 25.8 in delta3, 18.6 against 35.5 in phobos2). On BFG data lights are now 1.5 times as strong (`TDoom3Map.DataLightScale`, env `CD3_BFG_LIGHTSCALE=1` for the 2004 scale): fresh views 15.1, 27.3 and 26.8.
- **caverns1 and caverns2 stay darker** (median luma 2.8 and 2.6 against 19.6 and 11.9; 4.1 in caverns1 with the light scale): where no light reaches, Chocolate DOOM-3-BFG still shows the surfaces faintly and flat (luma 8 at `setviewpos -2517 -4270 3460 -102`, where `lightsat` finds only `light_5699`, 0.17 at the floor and nothing at the eye). Its source is not found yet (Chocolate DOOM-3-BFG has no ambient setting).
- **Position**: Chocolate DOOM-3-BFG's `setviewpos` drops the player onto a floor up to 16 below and pushes him out of walls, so a few views look at a wall ours sees past (delta3's first view).
- **Views from outside every area**: 96 of the 827 (left out above).

## Taking the references

- Doom 3 BFG's `g_fov` is 80; Doom 3's and this port's 90: the references are taken with `g_fov 90` (with 80 they were zoomed in: alphalabs4's views under an image difference of 5 went from 5 to 9 of 22 with 90).
- Maps that start with a cinematic (delta2a 29.5 s, monorail 18.7 s, recycling1 11.9 s) wait 3000 frames instead of 900: Chocolate DOOM-3-BFG has no console command to skip one, and `setviewpos` doesn't move a cinematic's camera.
- Now and then (about one map in twenty) the view freezes after the first view and every screenshot shows the same picture; the script shoots such a map once more (`dhewm3_compare.py same <dir>` counts the screenshots that look the same as the one before).
