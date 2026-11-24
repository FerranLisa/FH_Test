# Reproducing FH_Firmware V33 for FH_Carrier

Use Vivado/Vitis 2025.2. The current project uses the original root layout:
`hardware/vivado/FH_Firmware.xpr`, `software/workspace/FH_TestPlatform`,
and `software/workspace/FH_TestApp`. See [GUI build instructions](../README.md).

For a fresh checkout, run these preparation stages from the root. They create
projects and a design-only XSA without synthesis, implementation or C builds:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/hardware.ps1 -Stage Create
powershell -ExecutionPolicy Bypass -File scripts/hardware.ps1 -Stage DesignHandoff
powershell -ExecutionPolicy Bypass -File scripts/software.ps1 -Stage CreatePlatform
powershell -ExecutionPolicy Bypass -File scripts/software.ps1 -Stage CreateApp
```

Compile hardware in Vivado, source `hardware/scripts/export_gui.tcl`, update the
existing Vitis platform to `hardware/exports/FH_Firmware.xsa`, and build platform
and application in Vitis. Use the matching newly generated FSBL, BIT and ELF.
The KFB-specific PHY patch is no longer part of this project.

The native application's `src` directory contains an initial copy of
`software/app/src`. Keep intentional GUI source changes synchronized back to that
tracked snapshot. No FH_Bringup source tree is needed for builds; only the optional
baseline-comparison checker uses that original tree.

Generated project/BSP files and binaries are ignored by Git. Build scripts are
available for explicit future use; no compilation was run during this migration.
