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
param(
  [string[]] $Maps = @(),
  [string] $Logs = "playthrough_bfg",
  [string] $OutDir = "chocolate_ref",
  [string] $Exe = "F:\work\chocolate-doom3-bfg\build-mingw\Doom3BFG.exe",
  [string] $BasePath = "F:\GogGalaxyGames\DOOM 3 BFG",
  [int] $Every = 3
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $OutDir | Out-Null
$SavePath = Split-Path $Exe
$Shots = Join-Path $SavePath "base\screenshots"
if ($Maps.Count -eq 0) {
  $Maps = Get-ChildItem $Logs -Filter "game_*.log" | ForEach-Object { $_.BaseName.Substring(5) }
}
foreach ($Map in $Maps) {
  $Log = Join-Path $Logs "game_$Map.log"
  python tools/dhewm3_compare.py cfg $Log (Join-Path $SavePath "base\ref_$Map.cfg") --every $Every --wait 900
  if (Test-Path $Shots) { Remove-Item (Join-Path $Shots "*") -Force }
  $Arguments = "+set fs_basepath `"$BasePath`" +set fs_savepath `"$SavePath`" +set r_fullscreen 0 +set r_windowWidth 1600 +set r_windowHeight 900 +set r_windowX 40 +set r_windowY 40 +set s_volume_dB -40 +map game/$Map +exec ref_$Map.cfg"
  $P = Start-Process $Exe -ArgumentList $Arguments -WorkingDirectory $SavePath -PassThru
  if (-not $P.WaitForExit(600 * 1000)) { Stop-Process $P -Force; Write-Host "$Map : Chocolate DOOM-3-BFG timeout" }
  $Dest = Join-Path $OutDir $Map
  New-Item -ItemType Directory -Force $Dest | Out-Null
  Remove-Item (Join-Path $Dest "*") -Force -ErrorAction SilentlyContinue
  if (Test-Path $Shots) { Get-ChildItem $Shots -Filter "shot*" | Move-Item -Destination $Dest }
  python tools/dhewm3_compare.py compare $Log $Dest (Join-Path $OutDir "${Map}_compare.jpg") --every $Every | Set-Content -Encoding utf8 (Join-Path $OutDir "${Map}_compare.txt")
  Write-Host "$Map : $((Get-ChildItem $Dest).Count) shots"
}
python tools/dhewm3_compare.py table $OutDir (Join-Path $OutDir "summary.md")
