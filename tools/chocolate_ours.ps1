# Shoot this port again at the views of an earlier tools/chocolate_refs.ps1
# -Fresh run and compare with the Chocolate DOOM-3-BFG screenshots already
# taken (after a change of this port: Chocolate DOOM-3-BFG doesn't run again).
#   .\tools\chocolate_ours.ps1 -Maps caverns1,caverns2 -RefDir chocolate_fresh -OutDir chocolate_fog
# Writes <OutDir>\<map>_ours (screenshots), <map>_ours.log, <map>_compare.jpg
# and .txt, and <OutDir>\summary.md. -Extra adds console commands before the
# views (e.g. "O:r_skipFogLights 1").
param(
  [string[]] $Maps = @(),
  [string] $RefDir = "chocolate_fresh",
  [string] $OutDir = "chocolate_ours",
  [string] $Cfgs = "F:\work\chocolate-doom3-bfg\build-mingw\base",
  [string] $BasePath = "F:\GogGalaxyGames\DOOM 3 BFG",
  [string] $Extra = "",
  [switch] $Classic,
  [string] $OursExe = "castle-doom3.exe"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OursLog = Join-Path $env:LOCALAPPDATA "castle-doom3\castle-doom3.log"
foreach ($Map in $Maps) {
  $Demo = python tools/dhewm3_compare.py ours (Join-Path $Cfgs "ref_$Map.cfg")
  if ($Extra -ne "") { $Demo = $Demo -replace "^W:3,", "W:3,$Extra," }
  $OursDir = Join-Path $OutDir "${Map}_ours"
  New-Item -ItemType Directory -Force $OursDir | Out-Null
  Remove-Item (Join-Path $OursDir "*") -Force -ErrorAction SilentlyContinue
  $OursArgs = @("-basepath", "`"$BasePath`"", "--mute", "--minimized")
  if ($Classic) { $OursArgs += "--classic" }
  $OursArgs += @("--autotest", "game/$Map", (Join-Path (Resolve-Path $OursDir) "s"), "--demo", "`"$Demo`"")
  Start-Process (Resolve-Path $OursExe) -ArgumentList $OursArgs -WorkingDirectory (Get-Location) -Wait
  $Log = Join-Path $OutDir "${Map}_ours.log"
  Copy-Item $OursLog $Log -Force
  python tools/dhewm3_compare.py compare $Log (Join-Path $RefDir $Map) (Join-Path $OutDir "${Map}_compare.jpg") --every 1 --ref chocolate | Set-Content -Encoding utf8 (Join-Path $OutDir "${Map}_compare.txt")
  Write-Host "$Map done"
}
python tools/dhewm3_compare.py table $OutDir (Join-Path $OutDir "summary.md")
