# Changelog

## 0.3.0

Static models and collision models.

- **Collision models (`.cm`)**: maps collide with Doom 3's collision geometry, including its invisible `playerclip` brushes, instead of the render geometry. Material contents follow Doom 3's surface parameters (`playerclip`, `monsterclip`, `nonsolid`, `water`, `trigger`...). `TDoom3Map.UseCollisionModel` (default on).
- **Static models**: LightWave `.lwo` (LWO2) and 3ds Max `.ase` loaders for `func_static`, props, light fixtures, items and LWO doors, with skins; `func_*` models collide unless `noclipmodel`.
- **Fixed**: every rotated entity (brush entities, static models, creatures) faced backwards. CGE's default `TCastleTransform` orientation points along local +Z; `SetD3Rotation` now orients them.
- Test level: LWO barrels, ASE terminals with glowing screens, a `.cm` with an invisible clip wall and a monster clip strip.
- 147 parser checks (from 102); CI checks that static and collision models load.

## 0.1.0

First version: PK4 file system, declarations, materials with diffuse / normal / specular maps and image programs, `.proc` / `.map` levels, lights, md5 models, doors, speakers, simple monsters, pistol, flashlight, HUD, console, menu, the `TDoom3Map` editor component, autotest harness, unit tests and CI.
