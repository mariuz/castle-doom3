# Load Doom 3 maps one by one and report what happens: load time, map
# statistics, warnings, exceptions and a screenshot of the start position.
# For people who have Doom 3 data (the full game, or the free demo): the
# data can't be bundled, so this can't run in CI.
#
# Usage (from the repository root, after "castle-engine compile"):
#   .\tools\smoke_maps.ps1 -BasePath "E:\Games\Doom3"
#   .\tools\smoke_maps.ps1 -BasePath "E:\Work\doom3-demo" -Maps game/demo_mars_city1
# Without -Maps, the demo's 3 maps are loaded when <BasePath>\demo\demo00.pk4
# exists, otherwise the full game's single player maps (a map missing from
# the data shows as "(not loaded)").

param(
  [Parameter(Mandatory = $true)] [string] $BasePath,
  [string[]] $Maps = @(),
  [string] $OutDir = "smoke_output",
  [int] $TimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"
$Exe = Join-Path (Get-Location) "castle-doom3.exe"
if (-not (Test-Path $Exe)) { throw "Run from the repository root after compiling (castle-doom3.exe not found)" }
$Log = Join-Path $env:LOCALAPPDATA "castle-doom3\castle-doom3.log"

if ($Maps.Count -eq 0) {
  $Demo = "game/demo_mars_city1", "game/demo_mc_underground", "game/demo_mars_city2"
  $Full = "game/mars_city1", "game/mc_underground", "game/mars_city2", "game/admin",
    "game/alphalabs1", "game/alphalabs2", "game/alphalabs3", "game/alphalabs4",
    "game/enpro", "game/commoutside", "game/comm1", "game/recycling1", "game/recycling2",
    "game/monorail", "game/delta1", "game/delta2a", "game/delta2b", "game/delta3",
    "game/delta4", "game/hell1", "game/delta5", "game/cpu", "game/cpuboss",
    "game/site3", "game/caverns1", "game/caverns2", "game/hellhole"
  if (Test-Path (Join-Path $BasePath "demo\demo00.pk4")) { $Maps = $Demo } else { $Maps = $Full }
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$Results = @()
foreach ($Map in $Maps) {
  $Name = $Map -replace '[/\\]', '_'
  $Watch = [Diagnostics.Stopwatch]::StartNew()
  $Arguments = "--autotest $Map `"$OutDir\$Name`" --demo `"W:3,S,T:180,S,Q`" -basepath `"$BasePath`""
  $Process = Start-Process $Exe -ArgumentList $Arguments -PassThru
  if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process $Process -Force
    $Status = "timeout"
  } else {
    $Status = "exit $($Process.ExitCode)"
  }
  $Seconds = [int]$Watch.Elapsed.TotalSeconds
  $Lines = Get-Content $Log
  Copy-Item $Log (Join-Path $OutDir "$Name.log")
  $Stats = ($Lines | Select-String 'Doom3Level: Map "' | Select-Object -First 1)
  $Warnings = ($Lines | Select-String "Warning").Count
  $Exceptions = ($Lines | Select-String "Exception").Count
  $Results += [PSCustomObject]@{
    Map = $Map; Status = $Status; Seconds = $Seconds;
    Warnings = $Warnings; Exceptions = $Exceptions;
    Stats = if ($Stats) { ($Stats.Line -replace '^.*?Map "[^"]*": ', '') } else { "(not loaded)" }
  }
}
$Results | Format-Table -AutoSize -Wrap
Write-Host "Logs and screenshots: $OutDir"
