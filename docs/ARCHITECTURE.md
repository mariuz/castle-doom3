# Architecture

Castle Doom 3 reads Doom 3 (id Tech 4) data at runtime and turns it into Castle Game Engine (CGE) scenes. Nothing is converted offline.

```
 PK4 / loose files ──► Doom3Files (d3fs:) ──┬─► Doom3Lexer ─► Doom3Decls (materials, entityDefs, models, skins, sounds)
                                            │                    │
                                            │                    ├─► Doom3Images (d3img:, image programs)
                                            │                    └─► Doom3Materials (X3D appearances)
                                            ├─► Doom3Proc   (.proc areas, brush models, portals, BSP)
                                            ├─► Doom3MapFile (.map entities)
                                            └─► Doom3Md5    (.md5mesh / .md5anim, CPU skinning)
                                                         │
                                       Doom3Level (TDoom3Map component) ─► Doom3World (TD3Game: doors, AI, sounds, player)
                                                         │
                                         GameViewPlay / GameViewMenu, Doom3Hud, Doom3Console
```

## Units

| Unit | Role |
|---|---|
| `Doom3Files` | Virtual file system. Reads each PK4's ZIP central directory once, indexes paths (lowercase, `/`), inflates entries on demand from a `TFileStream`, so 300 MB+ paks are never loaded whole. Loose directories override PK4s. Registers `d3fs:`. |
| `Doom3Lexer` | idLexer subset shared by all text formats: quoted strings, punctuation, `//` and `/* */` comments, paths as single tokens, locale-independent numbers, `SkipBracedSection`. |
| `Doom3Decls` | Scans `materials/*.mtr`, `def/*.def`, `skins/*.skin`, `sound/*.sndshd` and indexes every declaration body by type and name (first definition wins, like Doom 3). Bodies are parsed on demand into `TD3Material`, `TD3ModelDecl`, `TD3Skin`, `TD3SoundShader` and merged entityDef dictionaries (`inherit`). Undeclared materials become implicit ones named after their image. |
| `Doom3Images` | Finds image files (`.tga`, `.png`, `.jpg`, `dds/*.dds`) and evaluates image programs. Normal maps are served as `d3img:/normal/<program>`: plain Doom 3 normal maps get their green channel flipped, `heightmap(img, scale)` becomes a normal map, `addnormals(a, b)` adds slopes. Output is uncompressed TGA. |
| `Doom3Materials` | `TD3Material` → `TAppearanceNode`: Phong material with diffuse, normal and specular textures (shininess 16/128, Doom 3's exponent), alpha test → `amMask`, translucent → `amBlend`; blended stages → unlit material with `TBlendModeNode` (`add` = one/one, `filter` = dst_color/zero). |
| `Doom3Proc` | `mapProcFile003`: models with surfaces (`( x y z s t nx ny nz )` vertexes, indexes), `interAreaPortals`, `nodes` (area BSP, `PointInArea`). Shadow models are skipped. |
| `Doom3MapFile` | `.map` entities (key / value pairs, primitive count; brushes and patches skipped), `origin` / `angle` / `rotation` helpers, coordinate conversion. |
| `Doom3Md5` | md5mesh joints / meshes / weights, md5anim hierarchy / baseframe / frames, absolute poses, frame interpolation (lerp + normalized quaternion lerp), skinning. `TD3Md5Instance` owns a `TCastleScene`, `PlayAnim`, `Update`. `Md5Cache` shares parsed files. |
| `Doom3Level` | `TDoom3Map` (`TCastleTransform`, registered for the editor): builds the area scenes, lights, brush entities and md5 entities of a map. |
| `Doom3World` | `TD3Game`: movers (`func_door`, `func_rotating`), speakers, monsters, player health / armor, pistol, use. |
| `Doom3Hud`, `Doom3Console` | UI components drawn with `DrawRectangle` and `UIFont`. |
| `GameViewPlay`, `GameViewMenu`, `GameInitialize` | Views, input, demo-script harness, data source setup and command line. |

## Coordinates and conventions

- Doom 3 is X forward, Y left, Z up; CGE is Y up. `D3ToCge(v) = (v.x, v.z, -v.y)`, a proper rotation, so triangle winding is preserved. 1 unit = 1 Doom 3 unit (an inch): player eye height 68, radius 16, speeds 140 / 220, gravity on.
- Doom 3 front faces are clockwise (its face plane is `(v2 - v0) × (v1 - v0)`), so geometry sets `Ccw := False`; `twoSided` materials set `Solid := False`.
- Doom 3's `t` texture coordinate goes down the image, CGE images are bottom-to-top: `v = 1 - t`. Because of this flip, the tangent-space bitangent points the other way, hence the green flip of normal maps.
- md5 quaternions store x, y, z; w is `-sqrt(1 - x² - y² - z²)`. Joint poses are made absolute by `parent.q * local.q` and `parent.pos + parent.q.rotate(local.pos)`.
- Entity rotation: idMat3 rows are the rotated local axes (`world = x·row0 + y·row1 + z·row2`). `D3RotateCge` applies it to CGE vectors; transforms use `SetView(direction, up)` built from it.
- A light's CGE radius is twice its Doom 3 light box, with quadratic attenuation `1 / (1 + 8 d² / r²)`: 1/3 at the box, ~3% where CGE cuts the light off (CGE stops a light hard at its radius).
- Sound shader distances are meters (× 39.37 units); volume is dB.

## Rendering notes

- One `TCastleScene` (`World`) holds every area's solid surfaces and all lights; `WorldNonSolid` holds `nonsolid`, translucent and blended surfaces with `Collides := False`. Each area and material is its own shape, so frustum culling and per-shape light lists stay effective (`MaxLightsPerShape` 32).
- Lights are `Global` and the world scene has `CastGlobalLights`, so they also light brush entities and md5 models.
- Brush entity scenes and md5 scenes are children of `TDoom3Map`; md5 scenes don't collide and aren't pickable (shots test monsters as cylinders).
- Textures are referenced by URL (`d3fs:/...`, `d3img:/...`), so CGE's texture cache shares them between shapes and scenes. X3D nodes are never shared between scenes.

## The test level

`tools/make_test_pk4.py` writes every file of `data/base/castle_doom3_test.pk4` in real Doom 3 formats: a `.proc` with two areas, a portal and one BSP node; brush models for a door, two crates and a fan; a `.map` with the player start, 8 lights, the brush entities, two creatures and a speaker; materials exercising `heightmap()`, `addnormals()`, stage-based maps, `_flat`, additive stages, ambient and strobe light shaders and a table; procedural textures; a 7-joint md5 creature with idle and walk animations; a model decl, entityDefs with `inherit`; sound shaders and WAVs. The unit tests check the parsers against it.
