param([ValidateSet('Create','DesignHandoff','Simulate','Synthesis','Implementation','ReviewTiming','Export')][string]$Stage='Create')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vivado='C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat'
$hw=Join-Path $root 'hardware'
New-Item -ItemType Directory -Force "$hw\results" | Out-Null
function Invoke-Vivado([string]$script,[string]$label,[string[]]$extra=@()) {
    & $vivado -mode batch -notrace -source "$hw/scripts/$script.tcl" -log "$hw/results/$label.log" -journal "$hw/results/$label.jou" @extra
    if ($LASTEXITCODE -ne 0) {throw "Vivado $label failed; inspect hardware/results/$label.log"}
}
Push-Location $root
try {
    switch ($Stage) {
        Create {Invoke-Vivado 'create_project' 'create'}
        DesignHandoff {
            Invoke-Vivado 'export_design' 'design_handoff'
            & 'C:\AMDDesignTools\2025.2\tps\win64\python-3.13.0\python.exe' "$root/scripts/verify_design_handoff.py"
            if ($LASTEXITCODE -ne 0) {throw 'Design-only XSA validation failed'}
        }
        Simulate {
            foreach ($test in @('test_gmax3412_tables','test_gmax3412_dual_live','test_gmax3412_capture','test_pl_ddr_dci_sequence')) {
                Invoke-Vivado $test $test
            }
        }
        Synthesis {Invoke-Vivado 'build' 'synthesis' @('-tclargs','synth')}
        Implementation {Invoke-Vivado 'build' 'implementation' @('-tclargs','implement')}
        ReviewTiming {Invoke-Vivado 'review_routed_timing' 'timing_review'}
        Export {
            Invoke-Vivado 'build' 'export' @('-tclargs','export')
            & 'C:\AMDDesignTools\2025.2\tps\win64\python-3.13.0\python.exe' "$root/scripts/verify_export.py"
            if ($LASTEXITCODE -ne 0) {throw 'XSA identity check failed; do not use this export'}
        }
    }
} finally {Pop-Location}
