# Run from any directory. Use -VivadoBin for a different installation path.
param([string]$VivadoBin = "C:\AMDDesignTools\2025.2\Vivado\bin")
$ErrorActionPreference = "Stop"
$root = (Resolve-Path "$PSScriptRoot/../..").Path
$run = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("fh_router_xsim_" + [guid]::NewGuid()))
Push-Location $run.FullName
try {
    & "$VivadoBin/xvlog.bat" -sv "$root/hardware/rtl/fh_router_dma.v" "$root/hardware/rtl/fh_router.v" `
        "$root/hardware/rtl/fh_router_live.v" "$root/tests/rtl/tb_fh_router.sv" "$root/tests/rtl/tb_fh_router_live.sv"
    if ($LASTEXITCODE) { throw "xvlog failed in $run" }
    foreach ($top in @("tb_fh_router", "tb_fh_router_live")) {
        & "$VivadoBin/xelab.bat" $top -timescale 1ns/1ps -s $top
        if ($LASTEXITCODE) { throw "xelab failed for $top" }
        & "$VivadoBin/xsim.bat" $top -runall -log "$top.log"
        $marker = if ($top -eq "tb_fh_router") { "FH_ROUTER_PASS" } else { "FH_ROUTER_LIVE_PASS" }
        if ($LASTEXITCODE -or !(Select-String -Path "$top.log" -Pattern "^$marker$" -Quiet)) {
            throw "Missing successful completion of $top in $run"
        }
    }
} finally {
    Pop-Location
}
