# Export the existing implemented design, then update/build Vitis components.
# Close Vivado and Vitis first. Does not synthesize, implement, or program the board.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$transcribing = $false
try {
    foreach ($file in @(
        'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat',
        'C:\AMDDesignTools\2025.2\Vitis\bin\vitis.bat',
        'C:\AMDDesignTools\2025.2\tps\win64\python-3.13.0\python.exe',
        (Join-Path $root 'hardware/vivado/FH_Emulator.xpr'),
        (Join-Path $root 'hardware/vivado/FH_Emulator.runs/impl_1/FH_Carrier_Bringup_top.bit')
    )) {
        if (!(Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required file missing: $file" }
    }
    $logDir = Join-Path $root 'software/logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $log = Join-Path $logDir ('ExportBuild-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    Start-Transcript -Path $log | Out-Null
    $transcribing = $true
    Write-Host '1/3 Exporting implemented hardware and validating XSA/BIT identity'
    & "$PSScriptRoot/hardware.ps1" -Stage Export
    Write-Host '2/3 Updating and building platform (BSP and FSBL)'
    if (!(Test-Path -LiteralPath "$root/software/workspace/FH_Emulator_platform")) {
        & "$PSScriptRoot/software.ps1" -Stage CreatePlatform
    }
    & "$PSScriptRoot/software.ps1" -Stage BuildPlatform
    Write-Host '3/3 Building application from native workspace sources'
    if (!(Test-Path -LiteralPath "$root/software/workspace/FH_Emulator_App")) {
        & "$PSScriptRoot/software.ps1" -Stage CreateApp
    }
    & "$PSScriptRoot/software.ps1" -Stage BuildApp
    Write-Host 'SUCCESS: hardware exported; platform and application built.'
    Write-Host "XSA: $root/hardware/exports/FH_Emulator.xsa"
    Write-Host "Application: $root/software/workspace/FH_Emulator_App/build"
    Write-Host "Logs: $logDir (Vivado: hardware/results/export.log)"
} catch {
    Write-Error -Message $_ -ErrorAction Continue
    exit 1
} finally {
    if ($transcribing) { Stop-Transcript | Out-Null }
}
