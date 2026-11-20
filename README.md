# FH_Test — V35 development

Two physical GMAX3412 receivers on FH_Carrier. Startup reports independent initialization and 16-lane training results. UART 8 and 9 open sensor diagnostics. Enter C1 or C2 with an optional exposure in microseconds, followed by Enter (for example C2:2000). The default is 1000 us. U:3000 sets a 3000 us exposure on both sensors for this run and asks for R and duration. Plain U also prompts for exposure (default 1000 us). U arms both receivers and strobes both TEXP1 lines together. R selects how many central 4096 × 1024 crops to retain between full frames. Both sensors read full frames. Busy 4 ms timer slots are skipped. N exports retained images; Ethernet sensor indices are 0 and 1.

## Build V35

Close Vivado and Vitis, then run the following command from the FH_Test project root.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_all.ps1
```

The script creates the Vivado project if needed, runs synthesis and implementation through bitstream generation, validates and exports the XSA, and builds the Vitis platform and application. Vivado logs are under `hardware/results` and Vitis logs are under `software/logs`.

## Previous revision and build instructions

# FH_Emulator V34 — FH_Carrier

19 November 2026. The physical FH_Sen4K / GMAX3412-A single-frame capture workflow has been verified on FH_Carrier.

## Changes in V34

- Capture a normal 4096 × 3072, 10-bit image with **C** in the main UART menu or **Capture GMAX-A** in FH_Test. On first use, the firmware powers and configures the sensor, calibrates its PHY and trains all 16 sub-LVDS lanes. Later captures reuse the initialized receiver. The physical exposure pulse is 1 ms.
- The receiver detects the start-of-frame marker on each lane and compensates up to one RX word clock of skew per frame. The ramp checker and DMA consume the same aligned words. The receiver ILA exposes all 16 lanes before alignment.
- In sensor submenu **8**, **V** checks a full test ramp through EOF, **W** stores a new test frame and **C** stores a normal image. The simulation covers changing lane delays, rejection beyond the configured margin and recovery on a subsequent frame.
- DMA stores each full frame as 24 MiB in the PL DDR4 rolling buffer. Main-menu **C** publishes its FrameID and opens Ethernet export. FH_Test refreshes the catalog and can download and display the selected Sensor 0 image. Bench verification covered the full test ramp, DDR storage, Gigabit Ethernet transfer and display.

## Release status

- SATA port 0 has established a Gen3 6 Gb/s link and completed read-only ATA
  IDENTIFY with a valid checksum, reporting model, serial, firmware and capacity.
  The recorded test had zero idle-observation and IDENTIFY transfer errors.
- After replacement of the carrier Ethernet connector, physical link stability
  has been confirmed by repeated power-cycle tests. Direct FH_Carrier-to-PC
  Ethernet image transfer is reported working.
- **Known limitation:** image transfers through the router with the PC on Wi-Fi
  can pause for many seconds or reach the PC receive timeout. A captured transfer
  recovered and completed after TCP retransmission. The cause is not yet isolated;
  direct-cable success does not establish reliability on every network path.
  The next comparison is both devices wired to the same router, with PC Wi-Fi off.
- These are bench observations, not full production qualification or timing signoff
  for every source revision.

## Projects to open

- Vivado 2025.2: `hardware/vivado/FH_Emulator.xpr`.
- Vitis 2025.2 workspace: `software/workspace`.
- Platform: `FH_Emulator_platform`.
- Application: `FH_Emulator_App`, standalone A53 #0, 64-bit.
- BSP domain: `standalone` (short name avoids Windows object-path limits).
- Desktop application: `python FH_Test.py` from the repository root.
  Its V34 title, saved settings and default programming paths are carrier-specific.
  Dependencies remain in `software/host/requirements.txt`.

The Vivado top retains the name `FH_Carrier_Bringup_top` because the validated
carrier XDC and receiver ILA hook reference its hierarchy. This is not the old
project: all source/IP paths resolve inside FH_Emulator.

## Included features

| Area | FH_Carrier V34 behavior |
| --- | --- |
| PS clocks | FH_Bringup PS DDR/MIO/GTR configuration; SATA 150 MHz RefClk0, USB3 100 MHz RefClk1 |
| PCIe clock | External 100 MHz reference monitor, divided clock/Gray CDC and corrected constraints; no new PCIe endpoint or storage driver |
| Board diagnostics | Power-good/reset GPIO, EEPROM dump/EUI-48, PAC1944 identification and rail measurements |
| SATA | CEVA host setup, COMRESET, stable-link and idle-error checks, read-only ATA IDENTIFY; no disk-sector reads or writes |
| I2C | PS I2C0 on MIO 74–75, PS I2C1 over EMIO to PAC1944, AXI IIC for GMAX_A |
| Sensor control | FH_Sen4K/GMAX3412-A power/reset/clock control, I2C/SPI access, configuration table, PHY calibration, training and receiver diagnostics |
| Receiver | 16-lane GMAX-A sub-LVDS receiver with per-frame word alignment and raw RX ILA |
| Acquisition | Two emulators, 250 Hz slots, FULL + R ROI, discarded busy slots, ordered stereo storage in 4 GiB PL DDR4 |
| Metadata | Hardware Frame_Addr_LUT, FrameID/TimerPulse, overwrite invalidation and retained-pixel verification |
| Router | FULL subsampling and ROI rectangle extraction; control at 0xA00C0000, export DMA at 0xA00D0000 |
| Ethernet | GEM0 MIO 26-37, MDIO 76-77, EEPROM EUI-48 with explicit bench fallback; gigabit-only autonegotiation, TCP 5001, raw/routed downloads and TCP/DMA stall diagnostics |
| Console | UART0 MIO 42–43, 115200 8N1 |

Router control uses `axi_smc/M13_AXI` and `M14_AXI`; its PL DDR read uses
`pl_ddr_smc/S03_AXI`. Its write channel shares `gmax_ddr_smc` through the new
`S01_AXI` input and writes PS DDR through the existing HP0 path. Both run at
120 MHz. Existing capture/legacy-owner paths and register addresses are retained.

Vitis generates drivers/FSBL from the carrier XSA. An application-local PHY
override supplies the current RTL8211F initialization (see below), without
patching the installed BSP sources. Default IP is 192.168.1.123/24, gateway
192.168.1.1. Use a unique IP and MAC for each board on the LAN.

## Compile in the GUIs

1. Open the carrier XPR. Open `design_1`, **Validate Design**, then **Generate
   Output Products**. Use global synthesis (already selected).
2. **Run Synthesis**, **Run Implementation**, then **Generate Bitstream**.
   Implementation uses Performance_Explore and the local receiver ILA hook.
3. Inspect timing/DRC/methodology. In the Vivado Tcl Console run:

   ```tcl
   source C:/Projects/FH_Emulator/hardware/scripts/export_gui.tcl
   ```

   This checks completed, current runs and timing (including pulse width and bus
   skew), then exports `hardware/exports/FH_Emulator.bit`, `.ltx` and `.xsa`.
   It does not compile. It refuses an incomplete/stale or failing implementation.
4. Open Vitis with `C:\Projects\FH_Emulator\software\workspace`.
   Update **FH_Emulator_platform → Hardware Specification** to the final
   `hardware/exports/FH_Emulator.xsa`, replacing any design-only handoff.
5. **Build Platform**, including its freshly generated FSBL, then **Build
   Application**. Do not use a KFB or old FH_Bringup FSBL/ELF.
6. Create a hardware debug launch for A53 #0 using the matching BIT, carrier FSBL
   and application ELF, or use the carrier FH_Test **Program & Run** after builds.
   It checks artifact presence, embedded BIT equality and platform XSA consistency.

Initial platform settings: standalone stdin/stdout `psu_uart_0`; lwip220 RAW_API;
`no_sys_no_timers=true`, IPv6/DHCP disabled; TCP send/window 32768/16384;
512 TCP segments; memory 262144. Application heap/stack are 1 MiB/64 KiB.

Edit the native Vitis `software/workspace/FH_Emulator_App/src` after creation.
The tracked `software/app/src` is the creation snapshot; maintain it alongside
native edits for reproducibility. Build commands never silently reimport sources.

## Automated export and software build

After Generate Bitstream succeeds, save and close Vivado and Vitis, then run from
the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\export_build.ps1
```

This exports and validates the existing implementation, updates the platform
from the final XSA, builds its BSP/FSBL, then builds the native application.
Missing Vitis components are created; existing application sources are preserved.
It stops on any failed stage and never launches synthesis, implementation or board
programming. Logs are in `hardware/results` and `software/logs`. Close the Vitis
workspace before running; the script never deletes workspace locks.

## Console and board checks

Expect the **FH_Emulator / FH_Carrier / V34** banner and startup board/clock
diagnostics. The main commands are:

| Command | Action |
| --- | --- |
| 1-7 | Power, EEPROM, PAC1944 and complete reference-clock diagnostics |
| 8 | GMAX_A sensor diagnostics submenu |
| S | SATA detection and read-only IDENTIFY; leaves output visible until another command |
| C | Capture one physical GMAX-A frame and open Ethernet export |
| U | Capture and verify stereo emulator frames with 250 Hz trigger slots |
| L | List valid rolling-buffer LUT entries |
| E | Observe PHY for 60 seconds before and 120 seconds after one initialization |
| N | Start/resume Ethernet export on TCP port 5001 |
| D during N | Show GEM, PHY and active TCP-transfer diagnostics |
| R | External reset test |
| H | Show menu on request |
| ESC | Stop the active U/N operation, or exit from the main console |

Submenu 8 also provides manual control of sensor power and streaming.
Run E from a fresh application session, before N; initialization changes PHY
configuration, while its before/after observation phases only read registers.

For stereo emulator export, run U, inspect L, then start N and connect with FH_Test.
N can start before capture: STATUS works, but image retrieval requires valid
retained frames. Commands are STATUS, LIST, GET, PAIR and RANGE. FH_Test retries
its read-only attachment STATUS probe for up to 45 seconds; image downloads
are not automatically retried and retain a 30-second socket receive timeout.

For each candidate build, run U/L/N and Router downloads. Check DDR calibration,
matching stereo counts, zero exposure extensions, retained pixels and CRCs.
Physical capture uses GMAX-A. Stereo capture uses the two emulators.

## Recreate from a clean checkout without compiling

Run Vivado batch with `hardware/scripts/create_project.tcl`, then
`hardware/scripts/design_handoff.tcl`. These create the project, output products
and design-only XSA without synthesis/implementation. Then run:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/software.ps1 -Stage CreatePlatform
powershell -ExecutionPolicy Bypass -File scripts/software.ps1 -Stage CreateApp
```

The source manifest records the original import. Recreated projects still require
the builds, timing review and board checks above. [Initial preparation notes](docs/VALIDATION_V33.md)
describe the 13 November import state, not the later bench results summarized here.

## RTL8211F initialization and transfer diagnostics

The FH_Carrier PHY reports ID 001C:C916. The application-local
`fh_xemacpsif_physpeed.c` overrides the complete AMD Vitis 2025.2 lwIP
physpeed archive object and survives BSP regeneration. The current Realtek path:

- Advertises **1000 Mb/s full duplex only**; 10/100-only link partners are unsupported
  by this configuration. Autonegotiation remains enabled.
- Enables RTL8211F TX delay at page 0xD08, register 0x11, preserving other bits,
  checking readback and restoring the previous page.
- Decodes PHYSR register 0x1A and requires gigabit/full-duplex/link-up status.
- Polls BMSR twice per sample for up to 15 seconds, checks the final sample and
  rejects invalid MDIO status. The E diagnostic additionally bounds MDIO operations
  and reset waiting; normal initialization does not have that reset deadline.

N uses the EEPROM EUI-48 when valid. Otherwise it explicitly logs a **BENCH fallback**
MAC of `02:46:48:00:00:01`. Only one board using that fallback may be on the LAN.
This permits comparison-board testing; it is not automatic carrier identification.

N reports Ethernet READY/WAITING separately from frame availability. After five
seconds without ACK progress while bytes are outstanding, automatic TCP diagnostics
report frame/offset, queued/acknowledged bytes, windows, retransmission state,
application output errors and DMA descriptor state. Reports are limited to three
per stall; D provides an on-demand snapshot. These diagnostics do not reset the
PHY or DMA, or change TCP retry policy.

For network troubleshooting, save UART output and a matching Wireshark capture.
Compare direct cable, both endpoints wired through the router, and PC over Wi-Fi
with the same firmware and frame selection. Do not interpret DMA completion alone
as evidence that a packet reached the PC.

See [PHY observation and TCP stall diagnostics](docs/ETHERNET_PHY_OBSERVATION.md)
and [FH_Test usage](docs/FH_TEST.md). Application-only diagnostic changes require
an application rebuild and ELF reload; changes to hardware or platform settings
require the corresponding matching exports/builds.
