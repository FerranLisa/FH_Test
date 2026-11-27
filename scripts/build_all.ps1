# Build FH_Test with Vivado and Vitis 2025.2 and publish the XSA to PetaLinux.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$project = Join-Path $root 'hardware/vivado/FH_Firmware.xpr'
$hardware = Join-Path $PSScriptRoot 'hardware.ps1'

# Refresh the packaged capture core before Vivado opens the main design.
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace -source (Join-Path $root 'hardware/scripts/refresh_capture_package.tcl') -nolog -nojournal
if ($LASTEXITCODE -ne 0) { throw 'Capture IP packaging failed' }

$stages = @('Synthesis', 'Implementation')
if (-not (Test-Path -LiteralPath $project -PathType Leaf)) {
    $stages = @('Create') + $stages
}

foreach ($stage in $stages) {
    Write-Host "Running Vivado stage $stage"
    $LASTEXITCODE = 0
    & $hardware -Stage $stage
    if (-not $? -or $LASTEXITCODE -ne 0) {
        throw "Vivado stage failed: $stage"
    }
}

$LASTEXITCODE = 0
& (Join-Path $PSScriptRoot 'export_build.ps1')
if (-not $? -or $LASTEXITCODE -ne 0) {
    throw 'Hardware export or Vitis build failed.'
}

$source = Join-Path $root 'hardware/exports/FH_Firmware.xsa'
$expectedHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash

$distro = 'Ubuntu-22.04'
$linuxDir = '/home/ferran/FH_Carrier_Linux/HW'
$wslDir = "\\wsl.localhost\$distro\home\ferran\FH_Carrier_Linux\HW"
$tempName = '.FH_Firmware.' + [guid]::NewGuid().ToString('N') + '.xsa'
$tempPath = Join-Path $wslDir $tempName

Write-Host "Copying $source to WSL"
try {
    Copy-Item -LiteralPath $source -Destination $tempPath

    $copiedHash = (Get-FileHash -LiteralPath $tempPath -Algorithm SHA256).Hash
    if ($copiedHash -ne $expectedHash) {
        throw "WSL copy failed verification. Expected $expectedHash, got $copiedHash."
    }

    # Rename within the same Linux directory so readers see a complete XSA.
    & wsl.exe -d $distro --exec mv -fT -- "$linuxDir/$tempName" "$linuxDir/FH_Firmware.xsa"
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to publish FH_Firmware.xsa in WSL.'
    }
}
finally {
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath
    }
}

Write-Host "Published: $linuxDir/FH_Firmware.xsa"
Write-Host "SHA-256:   $expectedHash"