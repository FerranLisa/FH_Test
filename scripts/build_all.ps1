# Build FH_Test with Vivado and Vitis 2025.2.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$project = Join-Path $root 'hardware/vivado/FH_Firmware.xpr'
$hardware = Join-Path $PSScriptRoot 'hardware.ps1'

if (-not (Test-Path -LiteralPath $project -PathType Leaf)) {
    Write-Host 'Creating Vivado project'
    & $hardware -Stage Create
}

Write-Host 'Running synthesis'
& $hardware -Stage Synthesis
Write-Host 'Running implementation and generating bitstream'
& $hardware -Stage Implementation

& (Join-Path $PSScriptRoot 'export_build.ps1')
if (-not $?) { exit 1 }
