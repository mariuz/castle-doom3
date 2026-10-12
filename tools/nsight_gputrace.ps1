# GPU Trace (NVIDIA Nsight Graphics) of castle-doom3: per-frame GPU metrics.
#
# Needs access to the GPU performance counters: NVIDIA Control Panel ->
# Desktop -> Enable Developer Settings, then Developer -> Manage GPU
# Performance Counters -> allow all users (or run this elevated).
# Don't pass ngfx's --platform: Qt takes it as its own option and aborts.
#
# Example (Mars City Underground, tracing 1 s from 70 s after the start):
#   .\tools\nsight_gputrace.ps1 -BasePath E:\Work\doom3-demo -Map game/demo_mc_underground -StartMs 70000 -Demo 'W:90,Q'
# The trace (.ngfx-gputrace, open it in Nsight Graphics for per-draw data)
# and exported metrics (BASE\*.xls, tab separated) go to -Out.
param(
  [string]$Ngfx = 'E:\Program Files\NVIDIA Corporation\Nsight Graphics 2026.3.1\host\windows-desktop-nomad-x64\ngfx.exe',
  [string]$BasePath = '',
  [string]$Map = 'testmap',
  [int]$StartMs = 20000,
  [int]$DurationMs = 1000,
  [string]$Demo = 'W:40,Q',
  [string]$Out = (Join-Path $env:TEMP 'castle-doom3-gputrace')
)
$Root = Split-Path $PSScriptRoot -Parent
New-Item -ItemType Directory -Force $Out | Out-Null
$GameArgs = "--autotest $Map $(Join-Path $Out 's') --demo $Demo"
if ($BasePath -ne '') { $GameArgs = "-basepath $BasePath $GameArgs" }
& $Ngfx --activity 'GPU Trace Profiler' `
  --exe (Join-Path $Root 'castle-doom3.exe') --dir $Root `
  --args $GameArgs --start-after-ms $StartMs --max-duration-ms $DurationMs `
  --auto-export --output-dir $Out
Write-Host "ngfx exit code: $LASTEXITCODE"
$Frame = Join-Path $Out 'BASE\FRAME.xls'
if (Test-Path $Frame) { Get-Content $Frame }
