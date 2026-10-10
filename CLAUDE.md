# CLAUDE.md

Working notes for developers and AI agents on Castle Doom 3: a Doom 3 (id Tech 4) port to Castle Game Engine (CGE) in Object Pascal (FPC). Sibling of `castle-quake1`, `castle-quake2` and `castle-doom`. Read `docs/ARCHITECTURE.md` for how the code works.

## What this is

- Doom 3 data (`.proc`, `.map`, `.mtr`, `.def`, `.skin`, `.sndshd`, `.md5mesh`, `.md5anim`, TGA / DDS images, WAV / OGG sounds) is read at runtime from PK4 archives and served to CGE through the `d3fs:` and `d3img:` URL protocols.
- Bundled data is only the generated test level `data/base/castle_doom3_test.pk4` (map `testmap`), written by `tools/make_test_pk4.py`. **Never commit id Software data**; a Doom 3 install is loaded with `-basepath` or a `base/` directory next to the exe (gitignored).
- Units: `Doom3Files`, `Doom3Lexer`, `Doom3Decls`, `Doom3Images`, `Doom3Materials`, `Doom3Proc`, `Doom3MapFile`, `Doom3Md5`, `Doom3Level` (`TDoom3Map`), `Doom3World` (`TD3Game`), `Doom3Hud`, `Doom3Console`, `Game*` views.

## Build and run (Windows)

CGE 7.0-alpha.3 snapshot with bundled FPC 3.2.2 is installed at `C:\castle-engine` (not on PATH):

```powershell
$env:PATH = "C:\castle-engine\bin;C:\castle-engine\tools\contrib\fpc\bin;" + $env:PATH
castle-engine compile --mode=release      # or --mode=debug
.\castle-doom3.exe
```

Keep the project at a short path (`E:\Work\castle-doom3`): long paths break FPC builds. Audio needs `OpenAL32.dll` next to the exe (gitignored). The log goes to `%LOCALAPPDATA%\castle-doom3\castle-doom3.log`.

## Testing without watching the window

```powershell
.\castle-doom3.exe --autotest testmap C:\TMP\cd3\s --demo "W:2,S,G:200 0 0,A:0,W:2,S,G:420 -250 0,A:20,F,W:0.4,S,N:0,Y,X,W:0.4,X,S,Q"
.\castle-doom3.exe --autotest MENU C:\TMP\cd3\s
```

Pass the whole `--demo` value as one argument (from PowerShell `Start-Process`, quote it inside `-ArgumentList`, or the spaces in `G:x y z` split it). Script commands are listed in the README; grep the log for `Warning|Exception|Screenshot|Message|Shot:`. Screenshot log lines show the FPS, eye position (Doom 3 coordinates), yaw and area. Useful test map spots: start (-160, -160) yaw 45; in front of the door (200, 0) yaw 0 (it opens within ~1 s); room B (420, -250); creatures are monsters 0 and 1 (`N:0`). `blob_1` has 80 health, the pistol does 14 per shot every 0.35 s (6 hits kill it).

Unit tests: `cd tests; castle-engine compile; .\castle-doom3-tests.exe` (102 checks; run from `tests/`). When the generator changes, update the expected counts there.

## CGE editor integration

- `editor_units="Doom3Level, Doom3Hud, Doom3Console"`; these call `RegisterSerializableComponent`. Children created by a component must call `SetTransient`.
- `TDoom3Map` builds the map in the editor (`Loaded` + `CastleDesignMode`); in the game `TViewPlay` calls `LoadMap`. Keep it at identity transform: gameplay uses its local space as world space. `TDoom3Map.EnsureData` adds the test PK4 and loads decls when the editor runs without `GameInitialize`.
- Call `TD3Game.Clear` before `TDoom3Map.LoadMap` (movers and speakers reference the map's scenes).

## Conventions and pitfalls

- 2-space indent, `begin` / `end` on their own lines, PascalCase, no `with`.
- Coordinates: `D3ToCge(v) = (v.x, v.z, -v.y)`; Doom 3 front faces are clockwise → `Ccw := False`; `v = 1 - t`; normal maps get their green flipped (see ARCHITECTURE.md).
- Pascal `{ }` comments end at the first `}`: don't write braces inside them (use words or `//`).
- Locals named like `TCastleTransform` properties (`Center`, `Up`, `Direction`...) clash inside `TDoom3Map` methods.
- `TCastleSoundSource` lives in `CastleBehaviors`; `Container.Pressed.KeyUp` has an `out` key string.
- CGE cuts a light off hard at its `Radius`; keep attenuation low there (see `BuildLights`).
- One X3D node must not be in two scenes: `MaterialAppearance` creates fresh nodes each call, textures are shared by URL.
- Doom 3 decls: the first definition wins; names are lowercase with `/`. `ReadImageProgram` normalizes programs without spaces (they are also the `d3img:` URL paths).
