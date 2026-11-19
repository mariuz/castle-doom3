# Take Chocolate DOOM-3-BFG reference screenshots of castle-doom3 screenshot
# views on Doom 3 BFG data (like tools/dhewm3_refs.ps1 for dhewm3):
# for each map, tools/dhewm3_compare.py writes <SavePath>\base\ref_<map>.cfg
# from our log, Chocolate DOOM-3-BFG runs it, its screenshots (24-bit TGA,
# <SavePath>\base\screenshots\shotNNNNN.tga) go to <OutDir>\<map>, then
# dhewm3_compare.py makes <OutDir>\<map>_compare.jpg (ours left).
#   .\tools\chocolate_refs.ps1 -Maps alphalabs1,le_enpro1 -Logs playthrough_bfg
# Without -Maps: every map with a log in -Logs (game_<map>.log). At the end
# <OutDir>\summary.md is the table of all maps compared so far.
# Chocolate DOOM-3-BFG (github.com/klaussilveira/chocolate-doom3-bfg) is
# built with MinGW-w64 (F:\work\chocolate-doom3-bfg\BUILD_NOTES.md); its
# save path must be the exe's folder (base\renderprogs, the cfg).
# -Fresh: this port also loads each map and takes the same views at once
# (dhewm3_compare.py ours), and those are compared instead of the route's
# mid-game screenshots: both engines' views of a fresh load. The look: by
# default Doom 3 BFG's in both (g_fov 80 across 16:9, r_lightScale 3);
# -Classic the 2004 game's (this port's --classic; Chocolate DOOM-3-BFG with
# r_lightScale 2 and g_fov 106.26, which across 16:9 is the 2004 game's 90
# across 4:3). The route playthroughs before 2026-11-20 were taken with the
# 2004 field of view: compare them with -Classic, or use -Fresh.
param(
  [string[]] $Maps = @(),
  [string] $Logs = "playthrough_bfg",
  [string] $OutDir = "chocolate_ref",
  [string] $Exe = "F:\work\chocolate-doom3-bfg\build-mingw\Doom3BFG.exe",
  [string] $BasePath = "F:\GogGalaxyGames\DOOM 3 BFG",
  [int] $Every = 3,
  # frames before the first view; maps that start with a cinematic
  # (Chocolate DOOM-3-BFG has no console skip) get $CinematicWait
  [int] $Wait = 900,
  [int] $CinematicWait = 3000,
  [string[]] $CinematicMaps = @("delta2a", "monorail", "recycling1"),
  [switch] $Fresh,
  [switch] $Classic,
  [string] $OursExe = "castle-doom3.exe"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $OutDir | Out-Null
$SavePath = Split-Path $Exe
$Shots = Join-Path $SavePath "base\screenshots"
$Look = if ($Classic) { "+set g_fov 106.26 +set r_lightScale 2" } else { "+set g_fov 80 +set r_lightScale 3" }
$OursLog = Join-Path $env:LOCALAPPDATA "castle-doom3\castle-doom3.log"
if ($Maps.Count -eq 0) {
  $Maps = Get-ChildItem $Logs -Filter "game_*.log" | ForEach-Object { $_.BaseName.Substring(5) }
}
foreach ($Map in $Maps) {
  $Log = Join-Path $Logs "game_$Map.log"
  python tools/dhewm3_compare.py cfg $Log (Join-Path $SavePath "base\ref_$Map.cfg") --every $Every --wait $(if ($CinematicMaps -contains $Map) { $CinematicWait } else { $Wait })
  $Dest = Join-Path $OutDir $Map
  New-Item -ItemType Directory -Force $Dest | Out-Null
  # now and then (about one map in twenty) every view after the first shows
  # the same picture: the view froze; then the map is shot once more
  for ($Try = 1; $Try -le 2; $Try++) {
    if (Test-Path $Shots) { Remove-Item (Join-Path $Shots "*") -Force }
    $Arguments = "+set fs_basepath `"$BasePath`" +set fs_savepath `"$SavePath`" $Look +set r_fullscreen 0 +set r_windowWidth 1600 +set r_windowHeight 900 +set r_windowX 40 +set r_windowY 40 +set s_volume_dB -40 +map game/$Map +exec ref_$Map.cfg"
    $P = Start-Process $Exe -ArgumentList $Arguments -WorkingDirectory $SavePath -PassThru
    if (-not $P.WaitForExit(600 * 1000)) { Stop-Process $P -Force; Write-Host "$Map : Chocolate DOOM-3-BFG timeout" }
    Remove-Item (Join-Path $Dest "*") -Force -ErrorAction SilentlyContinue
    if (Test-Path $Shots) { Get-ChildItem $Shots -Filter "shot*" | Move-Item -Destination $Dest }
    $Same = [int](python tools/dhewm3_compare.py same $Dest)
    $Count = (Get-ChildItem $Dest).Count
    if ($Same * 2 -le $Count) { break }
    Write-Host "$Map : $Same of $Count views the same as the one before (frozen), try $Try"
  }
  if ($Fresh) {
    # this port at the same views on a fresh load
    $Demo = python tools/dhewm3_compare.py ours (Join-Path $SavePath "base\ref_$Map.cfg")
    $OursDir = Join-Path $OutDir "${Map}_ours"
    New-Item -ItemType Directory -Force $OursDir | Out-Null
    Remove-Item (Join-Path $OursDir "*") -Force -ErrorAction SilentlyContinue
    $OursArgs = @("-basepath", "`"$BasePath`"", "--mute", "--minimized")
    if ($Classic) { $OursArgs += "--classic" }
    $OursArgs += @("--autotest", "game/$Map", (Join-Path (Resolve-Path $OursDir) "s"), "--demo", "`"$Demo`"")
    Start-Process (Resolve-Path $OursExe) -ArgumentList $OursArgs -WorkingDirectory (Get-Location) -Wait
    $Log = Join-Path $OutDir "${Map}_ours.log"
    Copy-Item $OursLog $Log -Force
  }
  python tools/dhewm3_compare.py compare $Log $Dest (Join-Path $OutDir "${Map}_compare.jpg") --every $(if ($Fresh) { 1 } else { $Every }) --ref chocolate | Set-Content -Encoding utf8 (Join-Path $OutDir "${Map}_compare.txt")
  Write-Host "$Map : $((Get-ChildItem $Dest).Count) shots"
}
python tools/dhewm3_compare.py table $OutDir (Join-Path $OutDir "summary.md")
