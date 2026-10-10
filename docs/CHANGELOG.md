# Changelog

## 0.7.0

Shadows.

- **Stencil shadows** with CGE's shadow volumes: every frame the strongest light at the player (lights in the player's area first, ambient lights never) casts shadows of brush entities (doors, crates, movers), static models and md5 models (up to 1500 triangles). Area geometry receives shadows.
- Console `r_shadows [0|1]`; screenshot log lines name the shadow casting light.
- 213 checks; CI checks the shadow light is chosen.

Known limitation: one shadow casting light at a time (CGE's shadow volumes), and walls don't cast shadows.

## 0.6.0

Light volumes.

- **Doom 3 light volumes**: lights don't fade with distance any more; like Doom 3 each lights a box (point lights, `light_radius`, `rotation`) or a frustum (projected lights, `light_target` / `light_right` / `light_up`, `light_start` / `light_end`), mapped to the light's texture space like `lightProject`, shaped by projection and falloff curves. Implemented as a per-light CGE shader effect (`PLUG_light_scale`) reading the fragment's world position.
- Lights without a `texture` use Doom 3's `lights/defaultPointLight` / `lights/defaultProjectedLight` when the game data declares them.
- `shaderParm4` is the light shader's time offset, like Doom 3.
- Console `r_lightVolumes [0|1]` reloads the map with plain spherical lights for comparison.
- **Fixed**: a shut door was hidden by portal visibility when seen from the room on its other side (it now belongs to the areas on both sides of its portal).
- Test level: a projected window light, Doom 3-style default light shaders and light images.
- 210 checks (light texture space, projected lights, shapes).

Known limitation: projection and falloff images are approximated by analytic shapes chosen from the image name (CGE doesn't bind textures referenced only by light effects).

## 0.5.0

Light shaders.

- **Material expressions and tables** (`Doom3Expressions`): `time`, `parm0-11`, `global0-7`, `table[...]` lookups (`snap`, `clamp`, wrapping and interpolation like Doom 3), arithmetic, comparisons, `&&` / `||`, with Doom 3's operator priorities.
- **Animated lights**: light shaders' color registers (`red`, `green`, `blue`, `rgb`, `rgba`, `color`, `colored`) are evaluated every frame with the light's `_color` and `shaderParm`s, so strobes, flickers and pulses work. A declared shader without color registers is white, an undeclared one uses `_color`, like Doom 3.
- Console `lights` lists every light's current color.
- Test level: a flickering (snap table), a pulsing (sine table) and a strobing light.
- 193 checks (expressions, tables, light shaders); CI checks that the pulsing light changes.

## 0.4.0

Portal visibility.

- **Portal visibility** like Doom 3's renderer: from the camera's area through the inter-area portals, each portal clipped by the view volume and narrowing it. Areas (now one scene each), brush entities, static and md5 models of hidden areas aren't drawn.
- **Doors close portals** while they are shut, so nothing behind a closed door is drawn.
- **Lights** are switched off while none of the areas they reach is visible (a flood through the portals within the light's radius).
- Console: `r_usePortals [0|1]`, `portals`; screenshot log lines show the visible areas. `TDoom3Map.PortalCulling`.
- Fixed: `notarget` didn't stop a monster that was already attacking.
- 162 parser and visibility checks; CI checks the visible areas through the door.

## 0.3.0

Static models and collision models.

- **Collision models (`.cm`)**: maps collide with Doom 3's collision geometry, including its invisible `playerclip` brushes, instead of the render geometry. Material contents follow Doom 3's surface parameters (`playerclip`, `monsterclip`, `nonsolid`, `water`, `trigger`...). `TDoom3Map.UseCollisionModel` (default on).
- **Static models**: LightWave `.lwo` (LWO2) and 3ds Max `.ase` loaders for `func_static`, props, light fixtures, items and LWO doors, with skins; `func_*` models collide unless `noclipmodel`.
- **Fixed**: every rotated entity (brush entities, static models, creatures) faced backwards. CGE's default `TCastleTransform` orientation points along local +Z; `SetD3Rotation` now orients them.
- Test level: LWO barrels, ASE terminals with glowing screens, a `.cm` with an invisible clip wall and a monster clip strip.
- 147 parser checks (from 102); CI checks that static and collision models load.

## 0.1.0

First version: PK4 file system, declarations, materials with diffuse / normal / specular maps and image programs, `.proc` / `.map` levels, lights, md5 models, doors, speakers, simple monsters, pistol, flashlight, HUD, console, menu, the `TDoom3Map` editor component, autotest harness, unit tests and CI.
