# Tour Doom 3 maps: load each one, skip its intro, and visit spots spread
# over the level (console "tour i n": the player start, then the items),
# with two screenshots at each (along the spot's angle, then turned around).
# The player is in god mode, noclip and notarget. Then each map's log is
# summed up: load time, frame rates of the screenshots, long frames, and the
# warnings, exceptions, missing sounds / images / materials and unsupported
# features, as text, plus a contact sheet of the screenshots (needs Python
# with PIL: python tools/tour_sheet.py <OutDir>).
# For people who have Doom 3 data: it can't be bundled, so this can't run in CI.
#
# Usage (from the repository root, after "castle-engine compile"):
#   .\tools\tour_maps.ps1 -BasePath "F:\GogGalaxyGames\DOOM 3"
#   .\tools\tour_maps.ps1 -BasePath "F:\GogGalaxyGames\DOOM 3" -Maps game/hell1 -Spots 20
#   .\tools\tour_maps.ps1 -BasePath "F:\work\doom3-demo"
#   .\tools\tour_maps.ps1 -BasePath "F:\GogGalaxyGames\DOOM 3" -Route -OutDir playthrough
# -Route plays each map through instead (console "route all"): from the
# start through every touch trigger and item, the nearest next, to the
# trigger of its target_endlevel, in noclip and god mode (monsters see the
# player), at -Speed units a second with a screenshot every -ShotEvery units.
# Without -Maps: the demo's 3 maps when <BasePath>\demo\demo00.pk4 exists,
# otherwise the full game's 27 single player maps (about 1 minute each).

param(
  [Parameter(Mandatory = $true)] [string] $BasePath,
  [string[]] $Maps = @(),
  [int] $Spots = 10,
  [string] $OutDir = "tour_output",
  [int] $TimeoutSeconds = 400,
  # more demo script steps after the setup, e.g. "O:r_shadows 0"
  [string[]] $Setup = @(),
  [switch] $Route,
  [int] $Speed = 500,
  [int] $ShotEvery = 1500
)

$ErrorActionPreference = "Stop"
$Exe = Join-Path (Get-Location) "castle-doom3.exe"
if (-not (Test-Path $Exe)) { throw "Run from the repository root after compiling (castle-doom3.exe not found)" }
$Log = Join-Path $env:LOCALAPPDATA "castle-doom3\castle-doom3.log"

if ($Maps.Count -eq 0) {
  if (Test-Path (Join-Path $BasePath "demo\demo00.pk4")) {
    $Maps = "game/demo_mars_city1", "game/demo_mc_underground", "game/demo_mars_city2"
  } else {
    $Maps = "game/mars_city1", "game/mc_underground", "game/mars_city2", "game/admin",
      "game/alphalabs1", "game/alphalabs2", "game/alphalabs3", "game/alphalabs4",
      "game/enpro", "game/commoutside", "game/comm1", "game/recycling1", "game/recycling2",
      "game/monorail", "game/delta1", "game/delta2a", "game/delta2b", "game/delta3",
      "game/delta4", "game/hell1", "game/delta5", "game/cpu", "game/cpuboss",
      "game/site3", "game/caverns1", "game/caverns2", "game/hellhole"
  }
}

$Steps = @("W:3", "O:skipcinematic", "W:2", "O:god", "O:noclip", "O:notarget") + $Setup
for ($I = 0; $I -lt $Spots; $I++) {
  $Steps += "O:tour $I $Spots"; $Steps += "W:2"; $Steps += "S"
  $Steps += "T:180"; $Steps += "W:0.7"; $Steps += "S"
}
$Steps += "Q"
if ($Route) {
  $Steps = @("W:3", "O:skipcinematic", "W:2", "O:god", "O:noclip") + $Setup + @("O:route all", "R:$Speed $ShotEvery", "W:3", "O:endlevel", "W:25", "S", "Q")
  if ($TimeoutSeconds -eq 400) { $TimeoutSeconds = 1200 }
}
$Demo = $Steps -join ","

New-Item -ItemType Directory -Force $OutDir | Out-Null
$Summary = @()
foreach ($Map in $Maps) {
  $Name = $Map -replace '[/\\]', '_'
  $Arguments = "--autotest $Map `"$OutDir\$Name`" --demo `"$Demo`" -basepath `"$BasePath`""
  $Process = Start-Process $Exe -ArgumentList $Arguments -PassThru
  if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process $Process -Force
    $Status = "timeout"
  } else {
    $Status = "exit $($Process.ExitCode)"
  }
  Copy-Item $Log (Join-Path $OutDir "$Name.log")
  $Lines = Get-Content $Log
  $Load = ($Lines | Select-String 'Profile: Map "' | Select-Object -First 1)
  $Fps = @($Lines | Select-String 'Screenshot .*\((\d+\.\d) FPS' | ForEach-Object { [double]$_.Matches[0].Groups[1].Value })
  $Long = @($Lines | Select-String 'Profile: Long frame: (\d+\.\d+)' | ForEach-Object { [double]$_.Matches[0].Groups[1].Value })
  $Text = @()
  $Text += "== $Map ($Status)"
  if ($Load) { $Text += ($Load.Line -replace '^Profile: ', '') }
  if ($Fps.Count -gt 0) {
    $Sorted = $Fps | Sort-Object
    $Text += "FPS: min $($Sorted[0]), median $($Sorted[[int]($Sorted.Count / 2)]), max $($Sorted[-1]) over $($Fps.Count) shots: $($Fps -join ' ')"
  }
  $Text += "Long frames: $($Long.Count), $(($Long | Measure-Object -Sum).Sum) s in all, the longest $(($Long | Measure-Object -Maximum).Maximum) s"
  # GLSL programs linked (screenshot lines): by the first screenshot and during the tour
  $Programs = @($Lines | Select-String 'Screenshot .*programs (\d+)' | ForEach-Object { [int]$_.Matches[0].Groups[1].Value })
  if ($Programs.Count -gt 0) { $Text += "Shader programs: $($Programs[0]) at the first screenshot, $($Programs[-1] - $Programs[0]) more during the tour" }
  $Stalls = @($Long | Where-Object { $_ -gt 0.3 })
  $Text += "Stalls over 0.3 s: $($Stalls.Count), $([Math]::Round(($Stalls | Measure-Object -Sum).Sum, 1)) s"
  $Tours = $Lines | Select-String 'Tour \d+/|Route to|Route: done|Route: the map|Route: skipping|Loading map' | ForEach-Object { $_.Line -replace '^GameViewPlay: ', '' }
  $Text += $Tours
  foreach ($Kind in @(
      @('Exceptions', 'Exception'),
      @('Shader errors', 'shader not compiled|not linked|GLSL.*error'),
      @('Warnings', 'Warning'),
      @('Sounds not found', 'Sound shader .* not found|Sound file .* not found'),
      @('Images not found', 'Image not found|Cannot load'),
      @('Normal maps only as DDS', 'normal map only as DDS'),
      @('Not supported', 'Not supported yet'))) {
    $Found = @($Lines | Select-String $Kind[1] | ForEach-Object { ($_.Line -replace '\d+(\.\d+)?', '#') } | Group-Object | Sort-Object Count -Descending)
    $Total = ($Found | Measure-Object -Property Count -Sum).Sum
    $Text += "$($Kind[0]): $([int]$Total) ($($Found.Count) kinds)"
    foreach ($F in ($Found | Select-Object -First 12)) { $Text += "  $($F.Count) x $($F.Name)" }
  }
  $Text | Set-Content -Encoding utf8 (Join-Path $OutDir "$Name.txt")
  $Summary += $Text
  $Summary += ""
  Write-Host "$Map : $Status, $($Fps.Count) shots"
}
$Summary | Set-Content -Encoding utf8 (Join-Path $OutDir "summary.txt")
Write-Host "Summary: $OutDir\summary.txt"
