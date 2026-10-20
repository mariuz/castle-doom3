# Changelog

## Unreleased

- **Shadow maps** (CGE changes B and R, [mariuz/castle-engine#12](https://github.com/mariuz/castle-engine/pull/12)): console `r_shadowMaps 1` makes the shadow lights (the strongest at the player, `r_shadowLights N` of them) cast shadow maps instead of stencil shadow volumes: each light (all lights are point lights here) renders 6 views around it into CGE's shared shadow map atlas, soft-edged (PCF), and the shadows fall on all the map's scenes (the lights are global, in their own scene). No closed casters needed (the `.cm` brushes and precomputed volumes are for shadow volumes only). `r_shadowMapSize N` (512) sets the size of each view for the next map. Set by name of a field, so older CGE versions just say it is not supported. Off by default: the brightness and the static shadows match the shadow volumes in the test level.
- **Temporal anti-aliasing** (CGE change Q, [mariuz/castle-engine#11](https://github.com/mariuz/castle-engine/pull/11)): console `r_taa [0|1]` sets CGE's `TCastleViewport.TemporalAntiAliasing`: every frame is shifted by a sub-pixel jitter and blended with the previous ones, found by motion vectors from the depth buffer and the camera movement, clamped to the colors around each pixel so moving monsters don't leave trails. The weapon (`rlFront`) is assumed to move with the camera. Off by default; set by name, so older CGE versions just say it is not supported. Smooths the edges of walls and doors in the test level, same brightness.
- **Environment probes** (CGE change P, [mariuz/castle-engine#10](https://github.com/mariuz/castle-engine/pull/10); unit `Doom3EnvProbes`): console `r_envProbes 1` bakes one probe per map area and lights the map with them (indirect light: Doom 3's black corners get some of the light around them). Each probe renders 6 views (32 x 32) from its area's center with all areas visible and only the map (no weapon, creatures or items), projects them into order 2 spherical harmonics for the diffuse light (an 8 x 8 irradiance cube map) and blurs them with a glossy lobe for the reflections (16 x 16), into an `EnvironmentLight` whose influence box is the area's bounds. Off by default, so the classic look is unchanged. `r_envProbeBake` bakes again (after lights changed), `r_envProbeScale` sets their strength (default 0.5; 1 roughly doubles the brightness of the test level). With a CGE without change P the console and the log say it is not supported. About 2 s for the test level's 2 areas.
- **Shadows from several lights** (CGE change A, `TCastleViewport.ShadowVolumesMaxLights`): console `r_shadowLights N` makes the N strongest lights that are on cast shadow volumes, each in its own pass (default 1: the strongest light at the player, as before). The precomputed shadow volumes are off with several lights. Each shadow light's passes cover only its screen rectangle (Doom 3's `r_useScissor`, CGE follow-up [mariuz/castle-engine#9](https://github.com/mariuz/castle-engine/pull/9)). `g_stopTime` also stops the map's time now (light shaders, animated surfaces), to compare screenshots.
- Console `r_highDynamicRange [0|1]`: CGE's `TCastleViewport.HighDynamicRange` (change I, [mariuz/castle-engine#7](https://github.com/mariuz/castle-engine/pull/7)), set by name so older CGE versions just say it is not supported. Off by default: blended stages (glass, additive overlays) come out darker with it.
- **Shared light effects** (CGE change K, [mariuz/castle-engine#8](https://github.com/mariuz/castle-engine/pull/8)): with a CGE that supports per-light custom fields, lights of the same kind share one light-volume `Effect` and pass their matrices as per-light uniforms, so shapes share shader programs (fewer compiles when areas come into view). Falls back to an effect per light with older CGE. Console `r_sharedLightEffects [0|1]`; env `CD3_SHARED_LIGHT_EFFECTS=0` turns it off, `CD3_LOGSHADERS=1` logs every shader program CGE compiles.
- **Articulated figures** (`af/*.af`, `articulatedFigure` decls; unit `Doom3AF`): bodies (joint, origin, collision model, `containedJoints`) and constraints (fixed, ball and socket, universal, hinge, slider, spring; anchors, cones, pyramids, hinge limits), vectors as points, `joint()`, `bonecenter()`, `bonedir()`. The log's decl index counts them.
- **AF ragdolls** (unit `Doom3Ragdoll`): with an articulated figure, each body is a rigid frame of its center and its constraints' anchors; bodies share their anchors (ball joints), cones and hinge limits bound how far they bend, the world stops them by each body's size, and each body's turn moves its contained joints (others follow their parent). Without one the skeleton ragdoll as before. Doom 3's rigid body solver (masses, friction, contacts) isn't reproduced.
- **Monster deaths**: monsters with a `ragdoll` key fall as their ragdoll when killed (idAI::Killed: StartRagdoll) and stay as corpses (no sinking away), not pickable; the ragdoll owns the pose (scripts' anims and head looks no longer move it). The player's body uses its def's `ragdoll` figure the same way.
- Test assets: `af/test_creatures.af` with `test_blob` and `test_player` (torso, head on a ball and socket, arms on universal joints, legs on hinges); the blob monster defs have `"ragdoll" "test_blob"`.
- **Brass** (idWeapon::Event_EjectBrass, idDebris): weapons' `def_ejectBrass` casings fly after each launch (`ejectBrassDelay`) or the `ejectBrass` script event, from the view model's `eject` joint, or in third person from the world model's, at 40 units a second along the view's forward + left + up, spinning; they bounce (`bouncyness`, `snd_bounce`), lie on the floor and go after their `fuse`. Console `g_showBrass`.
- **The death ragdoll**: with the player def's `ragdoll` key the dead body falls as a ragdoll from its last pose: every joint is a particle (60 Hz verlet, Doom 3's gravity) linked rigidly to its parent, loosely to its siblings and grandparent; it is pushed by the last hit and tips backwards, stops where it hits the world and settles. Doom 3's articulated figure (`.af` bodies and constraints) isn't read. Console `ragdoll 0` plays the `death` anim instead.
- Test assets: an `eject` joint on the test guns' view and world models, a brass casing model (`models/weapons/test/brass.lwo`, `debris_test_brass`, the `test_brass` bounce sound), `"ragdoll"` on `player_test`.
- **Crouch transitions**: the player's body plays `crouch_down` once when crouching starts and `crouch_up` when it stands up (Doom 3's player script Legs_Crouch / Legs_Uncrouch), then its crouch or stand loops.
- **Third person muzzle flash**: the gun in the body's hand shows its flash surfaces (stage `if` with parm4, like the view model), and in third person the flash light comes from its `flash` joint (idWeapon's world muzzle flash), backed off walls along the gun. The test guns' world models have a `flash` joint and flash quads; the test body has `crouch_down` / `crouch_up` anims.
- **Crouching** (idPhysics_Player::CheckDuck, idPlayer::Think): the crouch key (C) lowers the eye to 32 (pm_crouchviewheight) easing by pm_crouchrate 0.87 a frame, the player's box to 38 high (items, triggers, melee, splash damage and projectiles use it), the speed to 80 (pm_crouchspeed; no running, no stamina used, no jumping). Standing up waits until there is room up to 74. The test level has a crawl bar in room A (`crawl_bar_1`, its bottom at 52) to crouch under. Console `crouch [0|1]`, demo scripts `GO:x y seconds crouch`.
- **Death view and the body's death animation**: dead, the eye goes down to 10 (pm_deadviewheight) and the box to 20; the player's body plays its `death` anim once and holds it (Doom 3 has a ragdoll); `pm_thirdPersonDeath 1` backs the view away from the body (20 to 140 units in 3 s, idPlayer::CalculateRenderView). The body plays `crouch` / `crouch_walk` crouched.
- **The gun in the body's hand**: weapons' `model_world` is bound to the body's `joint_attach` joint in third person, shown while the weapon is raised and gone when dead.
- Test assets for what the demo doesn't have: the test player body's `crouch`, `crouch_walk` and `death` anims, world models for the test pistol and shotgun (`worldmodel_test_*`), the crawl bar.
- **Stamina** (idPlayer::AdjustSpeed): running (the run key held while moving) uses a second of stamina a second (pm_stamina 24) and slows from running (220) towards walking (140) by stamina / 45 (pm_staminathreshold); not running it comes back at 0.75 a second (pm_staminarate), 25% faster standing still. Adrenaline sets it to 100 and running uses none while it lasts; `give stamina`, worldspawn's `no_stamina`, console `stamina`, `pm_stamina`, `pm_staminarate`, `pm_staminathreshold`. The HUD shows a stamina bar while it isn't full.
- **The player's body and its skins**: the player def's `model` (an md5 model decl) is the player's body, shown in third person (console `pm_thirdPerson 1`; `pm_thirdPersonRange`, `pm_thirdPersonHeight`, `pm_thirdPersonAngle`, `pm_thirdPersonClip`, the camera of idPlayer::OffsetThirdPersonView), walking, running and idling by speed. It wears the def's `skin`, the same skin with `_berserk` under berserk and `skin_invisibility` while invisible (idPlayer's powerUpSkin); md5 models can change skins (`TD3Md5Instance.SetSkin`). The view weapon hides in third person. The test player has a generated body (the creature's skeleton and anims) with green armor, red berserk and a translucent invisibility skin.
- **Vertical knockback**: a knockback with an upward part (more than 10 units a second) throws the player off the ground (idPhysics_Player::CheckGround), with no friction and Doom 3's gravity (1066) until the player is back down where it started, or lands on something; a ceiling stops the rise. Downward knockback on the ground only pushes sideways. Console `hurt <def> [amount] up` hits from below.
- **Powerups** (idPlayer::GivePowerUp, idItemPowerup): berserk, invisibility, megahealth and adrenaline, from `idItemPowerup` items (`type`, `time`), the inventory's `berserk` / `mega` stats or `powerup_<name>` defs' `time`; they end on time, on death and on a new map. Berserk: 1.7 times the speed, the fists, melee 30 times the damage and twice the reach, projectiles twice the damage, all the player's damage 1.7 times (Doom 3's DamageFeedback), monsters can't hurt the player, `snd_berserk_third`, and `textures/decals/berserk` over the screen fading in its last 10 s (a generated red tint without it). Invisibility: the view weapon turns see-through with a cold glow, the screen's edges shimmer, weapon scripts' `isInvisible` is 1, `snd_invisibility`. Megahealth: 200 health (`powerup_megahealth`'s `inv_health`).
- Test level: `item_berserk_1` and `item_invisibility_1` in room A (spinning boxes), generated growl and sweep sounds; 828 checks; CI checks both pickups and berserk's fists.
- **Double vision, the armor's screen effect and knockback** (idPlayerView, idPlayer::Damage): a damage def's `dv_time` (ms, adding up to 5 s) makes the view double: a screen effect draws the frame twice, shifted by Doom 3's wobbling amount (g_dvAmplitude 0.001, g_dvFrequency 0.5, half the screen at most), only while it lasts. Armor taking a hit flashes `armorViewEffect` over the screen for 250 ms (a generated blue glow when the game has no such material). A hit pushes the player along the force by the def's `knockback` (20 by default): 1000 * knockback / 200 units a second, slowed by Doom 3's ground friction (pm_friction 6, pm_stopspeed 100) in 60 Hz steps, moving the camera with collisions. Console `hurt <damage def> [amount]` hits the player from the front.
- Test level: `damage_test_projectile` has `dv_time` and `knockback`; 805 checks; CI checks the armor's sound and the knockback.
- **Doom 3's falling speed, pain sounds and damage feedback**: the player falls at Doom 3's speed (gravity 1066, linear; CGE's walk navigation grew it exponentially), at least 120 units a second so stepping down stays quick. Hurt, the player cries out by the health left (`snd_pain_small` above 75, `_medium` above 50, `_large` above 25, `_huge`; `pain_delay` apart), `snd_death` on death, `snd_hitArmor` when armor absorbs, `snd_land_hard` on a damaging landing (no cry, like Doom 3). Damage defs give the view a kick (`kick_time`, `kick_amplitude`, from the attack's direction) and screen blobs (`blob_time`, `mtr_blob`, `blob_x` / `_y` / `_width` / `_height`), 0.15 s apart at most (a shotgun's pellets make one); a tunnel vision vignette darkens the screen's edges as health goes down and pulses red at each hit, instead of the flat red flash. The death screen's two lines no longer show a box for the line break.
- Test level: `player_test`'s pain, death and landing sounds (generated grunts and a thud), a blood blob material and texture, kick and blob keys on the test damage defs; 795 checks; CI checks a pain cry and the landing sound.
- **Stair steps and falling damage**: stepping up is Doom 3's: the body is up at once (CGE's walk navigation grows instantly) and the view follows within 200 ms, steps in a row adding up to 32 units (idPlayer's stepUpDelta). Falls are measured from where the descent starts (a jump's top) to where it stops, and land like idPlayer::CrashLand with Doom 3's gravity (1066): delta = 2 * 1066 * height / 10000; above 7 the view dips, above 30 / 45 / 65 the player takes `damage_softfall` / `damage_hardfall` / `damage_fatalfall` (the game's defs, else 10 / 25 / 1000): from about 141, 211 and 305 units. Not when flying (noclip) or in god mode. CGE's falling camera effect is off. 773 checks; CI checks a soft fall.
- **Weapon depth hack and view bob**: the view weapon is drawn in front of the world (CGE's `RenderLayer` rlFront, depth range 0..0.1, like Doom 3's `weaponDepthHack`), so it no longer pokes into walls. The camera bobs like Doom 3's (idPlayer::BobCycle, GetViewPos) instead of CGE's head bobbing: pitch and roll from the velocity and the steps, up to 6 units up, a dip on landing (8 to 32 units by the falling speed); dead, the view tilts (roll 40, pitch -15). The bob is applied only while rendering, so walk navigation and collisions use the plain eye. Console `pm_bob [0|1]`. 758 checks.
- **Weapon bob, kick and muzzle flashes** (roadmap 5e): the view weapon bobs and sways while walking, drifts when idle and lags behind turns and moves (idPlayer::CalculateViewWeaponPos: the bob cycle, `weaponAngleOffset*`, `weaponOffset*`); shots kick it up and back (`muzzle_kick_time`, `muzzle_kick_maxtime`, `muzzle_kick_angles`, `muzzle_kick_offset`, adding up for fast fire). A shot lights the muzzle flash (`flashColor`, `flashRadius`, `flashTime`) at the view model's `flash` joint, backed up from walls. Materials' stage `if` conditions are read: a view model's flash surfaces (`if ( time + parm4 ) ...`) show only right after a shot.
- Test level: the test weapons' view models have a `flash` joint and a muzzle flash mesh (`models/weapons/test/muzzleflash`, its texture generated), gunshot sounds (`test_shot`, `test_shotgun`), kick and flash keys; 751 checks.
- **Weapons** (roadmap 5e): the player's weapons are the player def's `def_weaponN` entityDefs running their `weapon_*.script` objects (idWeapon): state functions (`weaponState`) with the `WEAPON_ATTACK` / `WEAPON_RELOAD` / `WEAPON_LOWERWEAPON` / `WEAPON_RAISEWEAPON` flags, clips and ammo (`ammoInClip`, `ammoAvailable`, `useAmmo`, `addToClip`), `launchProjectiles` (spread, the player's projectiles hurt monsters, their splash too), `melee`, raising, lowering and switching, view models (`model_view` md5s following the view, their anims and sounds). Weapons without a script keep the built-in pistol. Keys 1 to 0 and the mouse wheel select, R reloads; the HUD shows the weapon's clip and ammo. Console `weapon <slot>`, `weapnext`, `weapprev`, `reload`.
- Test level: fists, a pistol and a shotgun with view models and scripts (`weapon_test_gun`, `weapon_test_fists` in `script/doom_main.script`); 721 checks; CI checks firing, reloading and switching.
- **Items and the player's inventory** (roadmap 5e): items (`item_*`, `ammo_*`, weapons' pickups; idItem, idMoveableItem, PDAs) are picked up by touching them and give their `inv_*` keys like idPlayer::Give: health and armor up to the player's limits, ammo up to `max_ammo_*`, weapons by their `def_weaponN` slot, clips (`inv_inclip_*`), carried items (`inv_carry`: keys); full stats leave the item. `triggersize`, `triggerFirst`, `spin`, `snd_acquire` and targets work. The inventory starts from `player_doommarine` (weapons, ammo, armor). Console `inventory`; `give all`, `give weapons`, `give <weapon>`, `give <stat> <amount>`.
- Test level: `player_test` and items in room A (medkit, armor, clip, a spinning shotgun, a key whose targets let the second armor be picked up); 690 checks; CI checks the pickups.
- **Characters move by their animations** (roadmap 5d): like monsters, characters that aren't walking move with their anims' origin (their `path_anim`s), colliding with the world by their `size`; an anim's first update no longer loses its first step.
- Test level: `test_stepper_1` sidesteps by its anim when activated; 650 checks; CI checks it.
- **Flying routes and thrown objects** (roadmap 5d): flyers follow their AAS route around walls (idAASLocal::FlyPathToGoal: the furthest route point they can fly straight to). Moveables (idMoveable) fall, bounce, rest and hurt the player when thrown; the vagary's `chooseObjectToThrow` / `throwObjectAtEnemy` throw them on an arc that reaches the player, `throwMoveable` lets go of a carried one; `setLinearVelocity`, `enableDamage`, `isAtRest`.
- Test level: `moveable_barrel_1` and `blob_thrower_1` (throws it once activated); `blob_flyer_1` flies around the wall into room A; 641 checks; CI checks both.
- **Dodges and combat nodes** (roadmap 5d): monsters standing still move by their animation's origin (evade anims sidestep, like idAI's AnimMove); `testAnimMove` / `testAnimMoveTowardEnemy` check the anim's move has room. Combat nodes (`ai_attackcone`, idCombatNode): `getCombatNode`, `findEnemyInCombatNodes`, `enemyInCombatCone`, `markUsed` (`use_once`), activation toggles them.
- Test level: `blob_dodger_1` goes to `combat_node_1` and sidesteps (`evade_left`); 622 checks; CI checks both.
- **Flying monsters and bosses** (roadmap 5d): monsters whose script says `setMoveType( MOVETYPE_FLY )` fly like idAI::FlyMove (seek, bob, keep to the enemy's eyes plus `fly_offset`, damping, `fly_speed`, leaning into turns), charge straight at the player (`chargeAttack`, the lost soul), and fall when killed in the air. The cacodemon, lost soul and the bosses (cyberdemon, guardian and its seekers, sabaoth, vagary) run their AI scripts, unchecked (not in the demo). More idAI events: `setFlySpeed`, `setFlyOffset`, `moveToEnemyHeight`, `waitMove`, `moveOutOfRange`, `getEnemyEyePos`, `getRandomTarget`, `findActorsInBounds`, `travelDistance*`, `setHealth`, `kill`...
- Test level: `blob_flyer_1` flies and charges once activated; 605 checks; CI checks the charge.
- **More monster attacks** (roadmap 5d, the full game's monsters): projectiles held in the hand until thrown (`create_missile`, `createMissile`), aimed at entities (`fire_missile_at_target`, `fireMissileAtTarget`), thrown along angles (`launchMissile`), `attackMissile`; Doom 3's aim wobble (`attack_accuracy`) and attack cone; homing projectiles (`idGuidedProjectile`, the revenant's rockets) and bouncing ones (`detonate_on_world 0`, grenades); charges and multiframe melee (`attack_begin`, `chargeAttack`), `attackMelee`, `directDamage`, `meleeAttackToJoint`, `radiusDamageFromJoint`. The full game's walking monsters (hell knight, mancubus, revenant, maggot, pinky, trite, tick, cherub, wraith, arch-vile, commandos) run their AI scripts, unchecked (not in the demo).
- Test level: `blob_ranged_1` throws homing balls once activated (its anim's `create_missile` / `launch_missile`, then `attackMissile`); a grenade def; 590 checks; CI checks the homing balls hit.
- **Reverb** (dhewm3's EAX-like map reverb, roadmap CGE change L): maps' `efxs/<map>.efx` files are read (`Doom3Efx`, like dhewm3's idEFXFile) and the effect for the listener is chosen like dhewm3, by its portal area number, its location or `"default"`, and played with CGE's new `SoundEngine.Reverb` (OpenAL EFX). Locations: `info_location` entities spread through portals, not through closed doors or `info_locationSeparator`s. Console `reverb`, `s_useEAXReverb [0|1]`. The demo has no `.efx` files.
- Test level: `efxs/testmap.efx` (room B by area number, room A by location, a default) and two `info_location`s; 563 checks; CI checks the reverb switches between the rooms.
- **LWO models were inside out**: LightWave polygons are clockwise from the front in Doom 3 space too (the `(x, z, y)` swap only relabels the axes), so the port drew the back faces of every LWO model. One-sided panels vanished: the back wall of Mars City Underground's starting elevator was a black hole (mean luma 1.3, dhewm3 25; now 27.6). The test level's generator writes LWO polygons in LightWave's order. Console `pick`: what the view's center ray hits.
- Lights that aren't light volumes (`r_lightVolumes 0`, the flashlight, the muzzle flash) fade smoothly to zero at their radius with CGE's new `RadiusFalloff` (roadmap CGE change H), instead of a radius twice the light box and a hard edge.
- Shadows: the level's precomputed shadow volumes (`.proc` `shadowModel "_prelight_<light>"`, from dmap) cast for their light, as invisible shadow-only casters; console `r_prelightShadows`. The `.cm` brush casters and md5 joint boxes are invisible too, instead of black geometry inside walls and bodies (roadmap CGE change G). Test level: a precomputed volume for `light_1`; 522 checks.
- md5 models whose meshes are closed cast shadow volumes with their own triangles whatever their size, instead of joint boxes (console `r_md5ShadowClosed`): CGE now moves the same shadow caster triangles when only an animated mesh's coordinates change (roadmap CGE change F). Most of the demo's monsters aren't closed and keep the joint boxes.
- **Glass with heat haze and reflections** (roadmap item 3, CGE change E): glass whose stage runs Doom 3's `heatHaze*` programs shows the screen behind it distorted by the stage's normal map (scrolling, masked, weaker with the distance, like the programs), through CGE's new `ScreenTexture`; `cubeMap` stages with `texgen reflect` reflect their cube map, on glass and as an overlay on lit and plain surfaces (12 to 33 per demo map). Other glass (mirrors, videos) keeps the faint tint.
- Material stages are drawn on the same triangles as their surface, with CGE's new `DepthMode` "lequal" depth test, instead of copies 0.25 units in front.
- CI builds with the `doom3-port` branch of mariuz/castle-engine: CGE master with this port's CGE pull requests merged in.
- Test level: a heat haze pane in room B, the glass pane reflects a cube map (`env/testenv`), room A's pillar is shiny metal; 511 checks; CI checks them.
- Console `soundinfo`: the OpenAL device, and whether EFX reverb works (an EAX reverb effect in an auxiliary effect slot).
- **AAS navigation** (roadmap 5d, seventh part): maps' `.aas48` files route monsters around walls and through doorways to the player and their path corners (a Dijkstra search over the AAS areas' walk reachabilities); monsters open doors. Console `aas [entity]`.
- Test level: `maps/testmap.aas48` (generated); `blob_scripted_1` chases the player from the balcony into room A; 499 checks; CI checks the route.
- **Faster loading and playing**: the demo maps load in 22-26 s instead of 36-46 s (start to first frames), and Mars City Underground plays at the vsync rate instead of ~40 FPS. Scenes that don't cast shadows no longer compute shadow volume edges (quadratic in CGE), open models don't cast; GUIs are painted at 512 x 512 with integer blending and cached background images; PK4 entries are inflated from memory mapped files with the C zlib; md5 models are skinned only when visible, with joint matrices, straight into their coordinate lists; faster image programs.
- Profiling: every map load logs its phases and first frames (`Profile:` lines); a sampling profiler (`CD3_SAMPLE=1`, console `sample start` / `sample stop`, `tools/resolve_samples.py`, `tools/sample_callers.py`).
- **Heads look at things** (roadmap 5d, sixth part): characters look at whoever they talk to and monsters at their enemy (`lookAt`, `lookAtEnemy`): the `look_joint` joints turn by their share of the look angles, within `look_min` / `look_max`; heads that are separate models follow the body's neck (`copy_joint`). Console `actors` shows yaw and look angles.
- Test level: `test_walker_1` looks at the player while it talks; 470 checks.
- **Splash damage** (roadmap 5d, fifth part): projectiles with a `def_splash_damage` hurt the player near their explosion (less further away, not through walls); `detonate_on_fuse`. Bernie zombies run their script (all the demo's scripted monsters now do).
- Fixed: monsters could not see the player through playerclip brushes or nonsolid surfaces (Bernie stood behind a heat haze sprite); sight is now a trace on opaque geometry. Brush entities of only nonsolid surfaces no longer collide.
- Test level: `projectile_test` has splash damage; 457 checks.
- **Talking to characters** (roadmap 5d, fourth part): the use key in front of a character ready to talk sets its `AI_TALK`; its script plays the head's lip sync anims, whose `sound_voice` frame commands speak. `$player1`, `getHead`, `setTalkState`, `setTalkTarget`, `getTalkTarget`; `turnToEntity` and `distanceTo` work on the player.
- Test level: `test_walker_1` has a head and talks once it reached its path corner; 448 checks; CI checks a talk.
- **Imps' and security zombies' AI scripts, projectiles** (roadmap 5d, third part): imps throw fireballs (on an arc) and claw, pistol / shotgun / machine gun zombies shoot, all through their own scripts; projectiles come from the animations' `launch_missile` frame commands and the monsters' `def_projectile`. Frame commands `call` and `trigger`. Console `near <entity> [distance]`, `activate <entity>`.
- Fixed: a sound started by a script on channel 0 raised an exception (FreeOnStop set during playback).
- Test level: `blob_scripted_1` throws glowing balls from afar; 444 checks; CI checks a hit.
- **Zombies' AI scripts** (roadmap 5d, second part): zombies run `monster_zombie` (with `monster_base`): they wait for triggers or the player, chase with collisions, swing when in reach (damage from the melee frame commands of their animations), feel pain and die through their scripts. Model decls keep frame commands; anim names resolve to their numbered variants.
- Test level: `blob_scripted_1` on the balcony runs a monster script; 440 checks; CI checks its hits.
- **Characters' AI scripts** (roadmap 5d, first part): Mars City's people (33 in Mars City 1) run their `character` script objects: state functions, animation states per channel, path commands (`path_corner`, `path_anim`, `path_cycleanim`...), walking and turning; they sit, work at computers, drink, read PDAs and walk their rounds. Console `actors`.
- Script VM: persistent threads restarted with another function, `callFunction` / `hasFunction`, `sys.warning` / `sys.error`.
- Test level: `test_walker_1` walks to its `path_corner` when the trigger's script activates it; 431 checks; CI checks it.
- Scripts: `setGuiParm` redraws the entity's GUI screens with the new parameter (Mars City Underground's airlock, crane and bridge panels); `startSpline` moves a mover along a `func_splinemover` curve (Mars City's mouse). Roadmap 5c is done.
- Test level: `bar_1` follows `spline_1`, the trigger's script writes on room A's panel; 420 checks.
- **Animated models** (roadmap 5c): `idAnimated` entities (Mars City's ships and hangar, props) hold the first frame of their `anim`, play it when activated (`cycle`, `num_anims`, `auto_advance`, `wait`, `remove`) and fire their targets at the end; cinematic characters appear and play their `anim`; md5 characters and monsters get their heads (`def_head` at `head_joint`; 52 in Mars City 1).
- Test level: the cinematic shows an idAnimated blob with a head, which walks twice, switches `light_5` and goes; 413 checks.
- **Cinematics** (roadmap 5c): camera anims (`.md5camera`, `Doom3Camera`) with cuts and the `old_origin` offset take over the view and fire their targets at the end; `func_cameraview`; `trigger_fade` and the scripts' screen fades; `info_player_teleport`; _Escape_ / `skipcinematic` skips a cinematic and the shots it chains to. Mars City 1's intro plays its cameras (checked against dhewm3: the first one looks at the console screen).
- Scripts: lights fade in and out over time, `startSoundShader` / `startSound` / `stopSound` play sounds on entities.
- Test level: `trigger_once_cin` fades out, plays a two-shot camera and teleports the player; the lift plays a sound, `light_trig` fades out; 404 checks; CI runs the cinematic.
- **Scripts** (roadmap 5c): a compiler and virtual machine for Doom 3's script language (`Doom3Script`). The demo's whole program (`script/doom_main.script`, 80 files, 1713 functions) compiles in about 0.2 s; the map's `main`, worldspawn's and triggers' `call` keys run as script threads that wait for time, frames, movers and other threads. Events: triggering, lights on / off and colors, doors (open, close, lock), hide / show / remove, entity keys and targets, `bind` / `unbind`, and idMover's moves and rotations with acceleration, so Mars City Underground's machines (cranes, arms, howitzers, pistons) move. Unsupported events are logged once.
- Console: `scripts` (threads, moving entities), `g_stopTime` (freeze them).
- Test level: `maps/testmap.script` moves `lift_1` up and down, turns `bar_1`, and `trigger_once_1` calls a script function; 376 checks.
- **Movers** (roadmap 5b): entities get their entityDef's keys as defaults; doors travel the size of their rotated bounds (most retail doors are rotated) with Doom 3's defaults (speed 100, `triggersize` 60); door `team`s open, close and lock together; `target_lock`; `func_rotating` honors `start_on` and is toggled by activation; `bind` makes brush entities and models follow their parent.
- Test level: `door_2` in `door_1`'s team, `door_light_1` bound to `door_1`; 330 checks.
- **Triggers and entity activation** (roadmap 5a): `trigger_once` / `trigger_multiple` / `trigger_hurt` volumes (from the `.cm`) touched by the player, `trigger_relay` and `trigger_count`, `target` chains with `delay` / `wait` / `triggerFirst` / `noTouch`: lights switch on / off, speakers start / stop, hidden entities and monsters appear, dormant monsters wake, doors unlock or open, `func_remove` removes. Unsupported activations are logged once.
- Test level: `trigger_once_1` in room B fires `trigger_relay_1`, which switches the red `light_trig` on 0.5 s later; 311 checks (a `TD3Game` stepped on the test map), CI walks into it.
- **Doom 3 demo data**: a `demo/` directory (`demo00.pk4` of the free 2004 demo) is loaded like `base/`, next to the exe or under `-basepath`. Its three maps (`game/demo_mars_city1`, `game/demo_mc_underground`, `game/demo_mars_city2`) load and spawn everything, without exceptions; they are dark and slow so far.
- Lights and entities belong to all areas their bounds touch, through the `.proc` BSP (`TD3ProcFile.BoxAreas`), not only the area of their origin: retail lights sit inside their fixtures.
- Monsters honor `hide` (hidden until triggered), `trigger` (dormant until triggered or hurt) and the skill flags `not_easy` / `not_medium` / `not_hard` (medium, Doom 3's default): no more invisible monsters attacking at the start of `demo_mc_underground`.
- `textures/common/entitygui` / `entitygui2` / `entitygui3` without a material (the demo data) are the entity's GUI screens.
- Console commands `lightsat`, `ent <name>`, `guidump <file.gui>` for debugging retail maps.
- `tools/smoke_maps.ps1`: loads maps one by one from a Doom 3 install or the demo and reports load time, map statistics, warnings and exceptions, with logs and screenshots.

## 0.12.0

Shadows from big md5 models.

- **md5 shadow hulls**: md5 meshes over 1500 triangles (retail monsters) used not to cast at all, because CGE searches silhouette edges quadratically and again on every animation frame. They now cast with one closed box per joint, around the vertexes the joint moves, shrunk to stay inside the body and moved by a per-joint matrix transform, so their edges never change.
- Console `r_md5ShadowTris <n>`: the triangle limit (reloads the map; 0 makes every md5 model cast with boxes).
- Shots log which monster they hit.
- 296 checks (joint matrices match skinning, boxes are closed and face out, box counts); CI checks the boxes are built.

Still one shadow casting light: more need shadow volume or cube shadow map support for several point lights in CGE (roadmap item 2).

## 0.11.0

More material stages.

- **Every plain stage is drawn**: stages after the first one (and the first plain stage of lit materials) are overlays, copies of the surface a little in front of it with their own unlit, blended appearance, texture matrix and animated color. Glowing strips on lit walls and doors now show.
- **`deform sprite`**: each quad becomes a camera facing billboard of the same size.
- **Glass**: materials whose only stages are reflections, heat haze, mirrors or videos are drawn as a faint additive tint instead of disappearing.
- A `cubeMap` is a sky only with `texgen skybox` / `wobblesky` (glass reflects cube maps too).
- Test level: the door has pulsing glow strips over its lit metal, a glass pane and a flare in room A.
- 289 checks (extra stages, overlays, glass, sprites); CI checks the stage counts in the log.

## 0.10.0

More shadows.

- **Walls and pillars cast shadows**: the level's `.cm` brushes (solid / opaque contents) are rebuilt as closed convex shadow casters 1 unit inside the walls (the render geometry of areas is open and can't cast). They also stop the shadow light from shining through walls. Grouped per area, enabled for visible areas and the areas the shadow light reaches.
- **`noshadows`**: materials with it don't cast (X3D `shadowCaster`), lights or light shaders with it are never the shadow casting light.
- Test level: solid brushes for walls, floors, ceilings, pillars and the balcony in its `.cm`.
- 269 checks (brush polyhedra are closed, insets, casters of the test level, `noshadows`); CI checks the casters are built.

Still one shadow casting light at a time (CGE's shadow volumes).

## 0.9.0

GUIs.

- **Doom 3 GUIs** (`.gui`) on `guisurf` surfaces: windowDef trees with `rect`, `backcolor`, `matcolor`, `background`, borders, `text` (also `gui::` state from the entity's `gui_*` keys, `\n` line breaks), `textscale`, `textalign`, `forecolor`, `visible`, drawn in software into a 640 x 480 image with CGE's built-in font and shown on the surface. `guisurf entity` / `entity2` / `entity3` use the entity's `gui` / `gui2` / `gui3` keys, `guisurf <path>` names the GUI.
- Brush entities and static models (LWO / ASE screens) pass their entity to their GUI surfaces.
- Test level: a door panel GUI with the entity's text and a status screen.
- 257 checks (parsing, rendered pixels, state, caching); CI checks both GUIs are rendered.

Not yet: GUI events and scripts, the cursor, Doom 3's own fonts.

## 0.8.0

Material stages.

- **Texture matrices**: `scroll` / `translate`, `scale`, `centerScale`, `shear` and `rotate` with expressions, composed like Doom 3's `MultiplyTextureMatrix`, as CGE `TextureTransformMatrix3D` nodes: scrolling screens, moving fluids, rotating fans.
- **Animated surface colors**: `rgb` / `red` / ... / `alpha` registers on glow and blend stages (pulsing panels, fading decals), updated every frame.
- **Skies**: `cameraCubeMap` / `cubeMap` sky materials become a CGE skybox (`TCastleBackground`); the sky surfaces themselves aren't drawn.
- Test level: scrolling terminal screens, pulsing ceiling panels, a skylight in room B.
- 231 checks (texture matrices, stage parsing, skies); CI checks the sky is set up.

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
