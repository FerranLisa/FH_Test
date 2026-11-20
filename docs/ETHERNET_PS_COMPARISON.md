# Ethernet PS configuration comparison — 2026-11-14

No Ethernet-related Vivado configuration correction was identified. No Vivado
sources, XSA, FSBL binaries or bitstreams were modified; no build was run.

## Evidence compared

- Tested commit `2bc7230`: `docs/board_configuration.json`.
- Current source: `hardware/bd/design_1.bd` and configuration manifest.
- Current export: `hardware/exports/FH_Emulator.xsa` (`design_1.hwh`, `psu_init.c`).
- Archived export: `hardware/exports/FH_Emulator_design_PZ.xsa` (same members).
- Current FSBL source: `software/workspace/FH_Emulator_platform/zynqmp_fsbl/psu_init.c`.
- Vendor reference: PZ-ZU7EV-KFB-2025 / 10_PZ_ZCU_NET0 / Vitis /
  design_1_wrapper / zynqmp_fsbl / psu_init.c.

The PZ-named archive is supporting evidence, not proof that its exact binary
was loaded during the successful historical test. The historical committed
configuration manifest provides the versioned configuration baseline.

## Results

76 selected PS properties agree between the tested manifest and current BD.
No differing values were found among the corresponding properties in either
XSA HWH. Selection covers GEM/ENET, IOPLL, PSS reference clock, bank I/O
properties and Ethernet/MDIO MIO electrical settings.

| Configuration | Tested and current |
|---|---|
| MAC | GEM0 enabled; GEM1–3 disabled |
| RGMII | MIO 26–37 |
| MDIO | Enabled, MIO 76–77 |
| GEM0 reference | IOPLL, 125 MHz |
| TSU reference | IOPLL, 250 MHz |
| GEM0 coherency | Disabled |
| GEM0 route through FPD | Disabled |
| Ethernet MIO electrical parameters | Matching drive, slew, pulls and input type |

51 selected PSU_Mask_Write operations across 45 registers match in order
between the current XSA, PZ archive and current FSBL source. Selection covers
GEM, IOPLL, relevant MIO pins, shared bank/tri-state controls, SD controls and
GEM reset. GEM0_REF_CTRL uses mask 0x063F3F07 and value 0x06010C00.
GEM_TSU_REF_CTRL uses mask 0x013F3F07 and value 0x01010600.

The vendor reference has differences in shared SD controls and tri-state bits
for other MIO pins. The RGMII MIO32–37 and MDIO MIO76–77 tri-state bits match.
The current generated file includes GEM reset writes in peripherals_init,
resetout_init and resetin_init helpers; these also exist identically in the
PZ archive. Their textual presence is not evidence that all helpers execute
on a particular boot. The vendor reference has only the peripherals_init
write in this comparison.

## Interpretation and next validation

The checked PS configuration does not support blaming a changed GEM pinout,
reference clock, I/O electrical setting or coherency selection. Keep the
current carrier configuration, including its SATA/USB/I2C requirements.
Do not replace the entire PS preset with the vendor example.

Continue the already prepared KFB software baseline experiment: power-cycle,
program once, run N before capture or optional tests, confirm the KFB BASELINE
2bc7230 banner, and save the full UART log. This comparison does not establish
hardware integrity, live register state, exact loaded ELF provenance, or
identity of all FSBL board hooks and runtime call paths. It compares generated
configuration and source, not execution on the board.
