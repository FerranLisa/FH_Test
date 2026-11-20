# V33 preparation and validation

13 November 2026. This records project preparation, not a compiled release.

- Vivado 2025.2 created `FH_Emulator.xpr` and validated the expanded block
  design. `hardware/results/root_create.log` ends with `FH_CARRIER_PROJECT_READY`.
- Output products and `FH_Emulator_design.xsa` were generated successfully.
  The XSA contains the carrier peripherals, both emulators, PL DDR and Router;
  it contains no bitstream.
- Vitis created `FH_Emulator_platform` with the `standalone` A53 domain,
  configured lwIP and generated the FSBL/BSP sources. It created
  `FH_Emulator_App` and imported the V33 sources. Native sources match
  the maintained snapshot. The final creation run has no object-path warning.
- Static checks compare the PS configuration, baseline nets and address map with
  FH_Bringup. Existing connections and mapped/excluded segments are preserved.
  The only tolerated PS parameter normalization is four timing defaults for the
  disabled SD1 peripheral. The enabled carrier configuration is unchanged.
- Router master/control connections and packaged-IP source dependencies are
  checked. Generated capture ports are 256 bits; Router DMA addresses are 64 bits.
- The host-only suite passes 29 tests, including four tests of the actual carrier main-menu text, fragmented
  UART input, capture failure, blocked DMA ownership and export refusal. All pass.
  Run `python tests/test_console.py` for the carrier-specific UART cases.
- `python scripts/verify_sources.py` checks source integration, the
  design-only XSA, Python syntax, release labels and native/application snapshot
  equality. The baseline comparison requires the local FH_Bringup source tree.

Vivado reported AXI USER-width metadata differences at the PS HP0/DDR interfaces
and initial capture TDATA metadata propagation warnings. Generated capture width
is verified as 256 bits. These checks do not replace synthesis or timing signoff.
The tool installation also emitted a Tcl Store catalog warning and used its
installation fallback. No installed tool files were modified.

Vitis uses a project-local Java socket temporary directory to avoid the observed
Java 21 failure with the default Windows temporary path. The wrapper restores the
calling environment on exit. The BSP domain is named `standalone` to keep generated
object paths below the limit flagged by CMake for the longer default domain name.

No synthesis, implementation, bitstream generation, application/FSBL build,
programming or board test has been performed. Follow the GUI build and board-check
sequence in README.md before using this release.
