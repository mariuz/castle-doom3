# Take dhewm3 reference screenshots of castle-doom3 screenshot views:
# for each map, tools/dhewm3_compare.py writes <SavePath>\base\ref_<map>.cfg
# from our log, dhewm3 runs it, its screenshots go to <OutDir>\<map>, then
# dhewm3_compare.py makes <OutDir>\<map>_compare.jpg (ours left).
#   .\tools\dhewm3_refs.ps1 -Maps mars_city2,hell1 -Logs playthrough
param(
  [Parameter(Mandatory = $true)] [string[]] $Maps,
  [string] $Logs = "playthrough",
  [string] $OutDir = "dhewm3_ref",
  [string] $Dhewm3 = "F:\work\dhewm3\dhewm3\dhewm3.exe",
  [string] $BasePath = "F:\GogGalaxyGames\DOOM 3",
  [string] $SavePath = "F:\work\dhewm3_shots",
  [int] $Every = 3
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $OutDir | Out-Null
$Shots = Join-Path $SavePath "base\screenshots"
foreach ($Map in $Maps) {
  $Log = Join-Path $Logs "game_$Map.log"
  python tools/dhewm3_compare.py cfg $Log (Join-Path $SavePath "base\ref_$Map.cfg") --every $Every --wait 900
  if (Test-Path $Shots) { Remove-Item (Join-Path $Shots "*") -Force }
  $Arguments = "+set fs_basepath `"$BasePath`" +set fs_savepath $SavePath +set r_fullscreen 0 +set r_mode -1 +set r_customWidth 1600 +set r_customHeight 900 +set r_screenshotFormat 2 +map game/$Map +exec ref_$Map.cfg"
  $P = Start-Process $Dhewm3 -ArgumentList $Arguments -WorkingDirectory (Split-Path $Dhewm3) -PassThru
  if (-not $P.WaitForExit(600 * 1000)) { Stop-Process $P -Force; Write-Host "$Map : dhewm3 timeout" }
  $Dest = Join-Path $OutDir $Map
  New-Item -ItemType Directory -Force $Dest | Out-Null
  Remove-Item (Join-Path $Dest "*") -Force -ErrorAction SilentlyContinue
  Get-ChildItem $Shots -Filter "shot*" | Move-Item -Destination $Dest
  python tools/dhewm3_compare.py compare $Log $Dest (Join-Path $OutDir "${Map}_compare.jpg") --every $Every | Set-Content -Encoding utf8 (Join-Path $OutDir "${Map}_compare.txt")
  Write-Host "$Map : $((Get-ChildItem $Dest).Count) shots"
}
