# Rolling-buffer export Router

Source implementation, 11 November 2026. Vivado/Vitis builds and board validation
have not been run for this change. The existing BIT/XSA/ELF do not contain the Router.

## Build from the GUI

1. Open `hardware/vivado/FH_Firmware.xpr` in Vivado 2025.2. In its Tcl Console run:

   ```tcl
   source C:/Projects/FH_Test/hardware/scripts/prepare_router_gui.tcl
   ```

   This adds the RTL and export DMA, connects the block design, validates/saves it,
   and registers `tb_fh_router` as the simulation top. It does not launch any build.
   Stop if validation reports an error. Fresh project creation also includes the
   Router through `subsystem.tcl`; the preparation script adds the testbench.

2. Use **Run Simulation > Run Behavioral Simulation**, then **Run All**. Require
   `FH_ROUTER_PASS`. The bench checks pixel selection, two source geometries,
   production-size full frames, output stalls, unaligned rectangles, source-tail
   draining and AXI-Lite address/data arriving separately. It does not model DMA,
   DDR, the PS or Ethernet; those require integration/board validation.

3. Generate the block design's output products. Reset stale synthesis and
   implementation runs, then use **Run Synthesis**, **Run Implementation**, and
   **Generate Bitstream**. Check timing and DRC, including the existing DDR PHY
   pulse-width/min-skew requirements documented in README.md. Do not reuse the
   pre-Router hardware results.

4. Export the updated hardware with the bitstream included, using
   `hardware/exports/FH_Firmware.xsa` as the handoff filename. Keep the matching BIT.

5. Open `software/workspace` in Vitis. Update the existing
   `FH_TestPlatform` hardware specification to that XSA. Confirm the refreshed
   BSP has `XPAR_FH_EXPORT_DMA_BASEADDR` at `0xA00D0000`. Preserve the existing
   standalone/lwIP settings and Realtek PHY patch described in REPRODUCING.md;
   hardware replacement can regenerate BSP files.

6. Build the platform and `FH_TestApp` from the Vitis GUI. The current generated
   app workspace has been synchronized with the changed canonical files:
   `fh_eth_server.c`, `fh_router.c`, `fh_router.h`, and `UserConfig.cmake`.
   Refresh/reload externally changed files if Vitis was open. For a newly imported
   application, use `software/app/src` as the source of truth.

7. Program the new bitstream and launch the application with the matching updated
   platform initialization/FSBL. Do not mix a new application/platform with an old
   bitstream. Refresh FH_Test's Ethernet catalog after entering export mode.

## FH_Test use

Capture and stop/verify as before, then enter Ethernet export. The Router bar offers:

| Mode | Eligible source | Controls | Output |
| --- | --- | --- | --- |
| Disabled | FULL and ROI | None | Original image, protocol 1 |
| Full-frame subsampling | FULL only | n = 1, 2, 4, 8, 16 | 4096/n by 3072/n |
| ROI rectangle | FULL and ROI | Xi, Yi, Xj, Yj | Xj-Xi by Yj-Yi |

Rectangle coordinates are relative to the 4096 by 1024 band, with exclusive Xj/Yj.
The current fixed band is full-sensor Y=1024..2047. Bounds are
`0 <= Xi < Xj <= 4096`, `0 <= Yi < Yj <= 1024`. A FULL source reads from
`(Xi,1024+Yi)`; a stored ROI source reads from `(Xi,Yi)`. No interpolation is used.
Subsampling starts at `(0,0)` and selects every nth row and column.

The same immutable request configuration applies to both sensors. The browser
filters out ROI records in subsampling mode; the server independently rejects a
subsampling request for an ROI record. Changing settings clears the active local
cache and displayed pixels. Routed variants are stored in `subN` or
`crop_Xi_Yi_Xj_Yj` subfolders of the capture session. Open that subfolder for later
offline viewing. Disabled downloads retain the existing session layout.

The UI reports output size and stereo payload size. Older firmware remains usable
with Router disabled; routed requests require the updated hardware and firmware.

## Hardware and firmware

PL DDR4 -> dedicated AXI DMA MM2S -> fh_router -> dedicated AXI DMA S2MM -> PS DDR.
The CPU transmits the PS DDR output through the existing TCP/lwIP path.
The two sensors run sequentially through one shared Router and staging buffer.
Capture storage, the LUT and capture DMAs are unchanged. Export remains stopped-only.

The Router uses 16-bit streams (one pixel per clock) at the existing 120 MHz clock.
DMA uses 64-bit memory ports and 64-bit addresses; source memory begins above 4 GiB.
Every source pixel is read, including discarded pixels. This initial implementation
reduces Ethernet payload, not source DDR reads. The DMA packs selected pixels into
contiguous uint16 little-endian output, including partial final memory beats.

One aligned 24 MiB static BSS buffer reserves staging storage through the linker,
within the existing PS DDR application memory region. Firmware manages cache
ownership around DMA writes. It waits for both DMA channels and source draining,
checks the emitted count, and uses a ten-second job timeout. A failed job terminates
the connection; the receiver rejects incomplete pairs. The buffer is reused only
after the previous payload has been copied into lwIP via `TCP_WRITE_FLAG_COPY`.

| Router address / offset | Meaning |
| --- | --- |
| Base 0xA00C0000, +0x00 | Signature 0x46525231 |
| +0x04 write | bit 0 start, bit 1 abort |
| +0x04 read | bit 0 busy, bit 1 source drained, bit 2 error |
| +0x08 | Source height (width fixed at 4096) |
| +0x0C / +0x10 | Source-local x0 / y0 |
| +0x14 / +0x18 | Source-local x1 / y1, exclusive |
| +0x1C | Sampling step for both axes |
| +0x20 write / read | Expected output count / emitted count |
| DMA base 0xA00D0000 | Standard AXI DMA simple-mode registers |

## Protocol extension

`STATUS` retains `protocol=1` for existing clients and adds `router=0|1` and
`routed_protocol=2`. Original LIST/GET/PAIR/RANGE requests remain unchanged.
LIST describes stored frames; it never modifies the source geometry to describe a crop.

New request, all numbers unsigned decimal:

```text
ROUTEPAIR frame_id mode n Xi Yi Xj Yj
```

Mode 1 is FULL subsampling; mode 2 is rectangle selection. Bounds are applied in
mode 2 and n in mode 1. The server returns sensor 0 then sensor 1 for the same record.
Each routed FHIM packet has a 48-byte little-endian header:

| Offset | Field |
| --- | --- |
| 0..7 | FHIM, version=2, sensor, original source type, mode |
| 8 / 12 | FrameID / TimerPulse, u32 |
| 16 / 20 / 24 | Output width / height / payload bytes, u32 |
| 28 | Original source roi_y (FULL=0, ROI=1024), u32 |
| 32 / 36 | Full-sensor output origin x / y, u32 |
| 40 / 44 | Sampling step x / y, u32 |

Payload and CRC32 trailer follow. Output pixel `(x,y)` maps to full-sensor
`(origin_x + step_x*x, origin_y + step_y*y)`. JSON sidecars preserve these fields.

## Validation status and board acceptance

All 22 Python host/GUI tests passed in the SMP_gpu environment. No HDL simulation,
Vivado build, Vitis build, or board test was run for this extension.
Host tests cover legacy transfers, routed stereo metadata, rectangle bounds,
subsampling factors, CRC failures and mismatched transforms. GUI checks require
Qt and NumPy. Neither these tests nor source inspection establishes FPGA timing
closure or DMA correctness on the board.

After your builds, download a raw pair and routed versions of that same FrameID.
Compare every output pixel against NumPy slices of the raw image: `[::n,::n]` for
subsampling; `[1024+Yi:1024+Yj,Xi:Xj]` for FULL crops and `[Yi:Yj,Xi:Xj]` for ROI.
Test 1x1 and odd-width rectangles, n=1 and n=16, both sensors, switching settings,
cancellation/retry, and a fresh capture after export. Verify stereo FrameID and
TimerPulse match and that all received payloads pass CRC.
