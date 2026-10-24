# Measure the frame cost of shadows from several lights (console
# r_shadowLights N, roadmap item 2) on real Doom 3 maps, to pick the default.
# For people who have Doom 3 data (the full game, or the free demo): the
# data can't be bundled, so this can't run in CI.
#
# Each map is loaded once and, in that run, every setting is measured in
# turn (frame rates on one machine vary a lot between runs when other
# programs use the GPU: compare within a run, never across runs):
# for each N of -Lights, r_shadowLights N with the depth bounds test on and
# off (r_useDepthBounds, GL_EXT_depth_bounds_test: NVIDIA has it) and, with
# -Scissor, the light scissors off too (r_useScissor 0). Frame rates are
# read from the screenshot log lines ("Screenshot ... (N FPS, ...").
# Mars City 1 starts with a cinematic, so the measurement starts after
# "skipcinematic"; -ViewPos "x y z yaw" measures another spot instead of
# the start (setviewpos; e.g. "3848 -1216 299 0" in Mars City Underground).
#
# Usage (from the repository root, after "castle-engine compile"):
#   .\tools\measure_shadowlights.ps1 -BasePath "E:\Work\doom3-demo"
#   .\tools\measure_shadowlights.ps1 -BasePath "E:\Games\Doom3" -Maps game/alphalabs1 -Lights 1,2,4,8
#   .\tools\measure_shadowlights.ps1 -BasePath "E:\Work\doom3-demo" -Maps game/demo_mc_underground -ViewPos "3848 -1216 299 0"
# Without -Maps, the demo's 3 maps are measured when <BasePath>\demo\demo00.pk4
# exists, otherwise a few of the full game's maps.

param(
  [Parameter(Mandatory = $true)] [string] $BasePath,
  [string[]] $Maps = @(),
  [int[]] $Lights = @(1, 2, 3, 4, 8),
  [string] $ViewPos = "",
  [switch] $Scissor,
  [double] $Settle = 2.5,
  [string] $OutDir = "measure_output",
  [int] $TimeoutSeconds = 900
)

$ErrorActionPreference = "Stop"
$Exe = Join-Path (Get-Location) "castle-doom3.exe"
if (-not (Test-Path $Exe)) { throw "Run from the repository root after compiling (castle-doom3.exe not found)" }
$Log = Join-Path $env:LOCALAPPDATA "castle-doom3\castle-doom3.log"

if ($Maps.Count -eq 0) {
  if (Test-Path (Join-Path $BasePath "demo\demo00.pk4")) {
    $Maps = "game/demo_mars_city1", "game/demo_mc_underground", "game/demo_mars_city2"
  } else {
    $Maps = "game/mars_city1", "game/mc_underground", "game/alphalabs1", "game/hell1"
  }
}

# The demo script: settle, skip the intro, freeze the game (creatures and
# animated materials don't change the measurement), then one screenshot
# per setting after $Settle seconds. "notarget" keeps monsters idle.
$Steps = @("W:3", "O:skipcinematic", "W:1", "O:notarget", "O:g_stopTime 1")
if ($ViewPos -ne "") { $Steps += "O:setviewpos $ViewPos" }
$Steps += "W:1"
$Settings = @()
foreach ($N in $Lights) {
  $Steps += "O:r_shadowLights $N"
  $Steps += "O:r_useDepthBounds 1"; $Steps += "W:$Settle"; $Steps += "S"
  $Settings += "r_shadowLights $N, depth bounds on"
  $Steps += "O:r_useDepthBounds 0"; $Steps += "W:$Settle"; $Steps += "S"
  $Settings += "r_shadowLights $N, depth bounds off"
  if ($Scissor) {
    $Steps += "O:r_useScissor 0"; $Steps += "W:$Settle"; $Steps += "S"
    $Settings += "r_shadowLights $N, depth bounds off, scissor off"
    $Steps += "O:r_useScissor 1"
  }
  $Steps += "O:r_useDepthBounds 1"
}
$Steps += "O:r_shadows 0"; $Steps += "W:$Settle"; $Steps += "S"
$Settings += "r_shadows 0"
$Steps += "Q"
$Demo = $Steps -join ","

New-Item -ItemType Directory -Force $OutDir | Out-Null
$Results = @()
foreach ($Map in $Maps) {
  $Name = $Map -replace '[/\\]', '_'
  $Arguments = "--autotest $Map `"$OutDir\$Name`" --demo `"$Demo`" -basepath `"$BasePath`""
  $Process = Start-Process $Exe -ArgumentList $Arguments -PassThru
  if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process $Process -Force
    Write-Warning "$Map`: timeout"
  }
  $Lines = Get-Content $Log
  Copy-Item $Log (Join-Path $OutDir "$Name.log")
  $Shots = @($Lines | Select-String 'Screenshot "' )
  $Support = ($Lines | Select-String 'GL_EXT_depth_bounds_test (supported|not supported)' | Select-Object -First 1)
  for ($I = 0; $I -lt $Settings.Count; $I++) {
    $Fps = ""
    if ($I -lt $Shots.Count -and $Shots[$I].Line -match '\(([0-9.]+) FPS') { $Fps = [double]$Matches[1] }
    $Results += [PSCustomObject]@{ Map = $Map; Setting = $Settings[$I]; FPS = $Fps }
  }
  if ($Support) { Write-Host "$Map`: $($Support.Line -replace '^.*?Depth bounds', 'Depth bounds')" }
}
$Results | Format-Table -AutoSize
Write-Host "Logs and screenshots: $OutDir"
Write-Host "Pick the default r_shadowLights from the frame rates above; CLAUDE.md says the test machine's rates vary between runs, so compare only within a map's run."
