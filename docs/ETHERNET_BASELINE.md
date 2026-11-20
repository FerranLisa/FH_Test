# FH Bringup V31.1 Ethernet integration

V31.1 adds capture-then-export image transfer to the existing V30 application.
UART `U` retains its fixed-exposure stereo acquisition and pixel verification;
only a verified, stopped capture can populate the Ethernet catalog. UART `N`
serves the catalog over PS GEM0 TCP port 5001. UART ESC leaves the server and
returns to the existing menu. All original bring-up commands remain present.

This integration has received file review only. No application or BSP build,
compiler syntax check, synthesis, client execution, or hardware test was run.
Existing ELF, BIT, XSA, generated BSP headers and exported libraries remain the
previous artifacts and do not validate these source changes.

## Source reconciliation

The local application was V30. Its `dual_stream.h` already matched the uploaded
integrated header, including the V31.1 hardware-LUT importer. The server and
frame-export `.c` files were present, but their `.h` files were absent and the
main application did not call them.

The downloaded `BringupTest.c` was compared against the project main: its
changes were confined to V31.1 integration. That integration was applied and
then tightened for MAC validation and capture ownership. The downloaded
`dual_stream.h` was compared against the current header rather than replacing
the capture implementation. Missing headers came from the downloaded
`FH_Bringup_Ethernet_V31 (4).zip`; the client came from downloaded `fh_fetch.py`.
The exact `FH_Bringup_Ethernet_V31_Integrated.zip` named in the earlier chat was
not available in the inspected Downloads/project trees. The earlier chat's
V31.1 description and the integrated downloaded source files supplied its LUT
integration reference; the original ZIP itself was not inspected.

## Changed files

Paths below are relative to the project root.

| File | Integration change |
| --- | --- |
| `software/FH_Carrier_Test/src/BringupTest.c` | V31.1 menu/version, N server entry, board EUI-48 with valid local fallback, reset/import around U, invalidate catalog before menu 8 or external reset |
| `software/FH_Carrier_Test/src/dual_stream.h` | Clear the export mirror even when LUT import preconditions fail; existing V30 capture and LUT reader retained |
| `software/FH_Carrier_Test/src/fh_eth_server.c` | Raw-lwIP server; strict decimal command parsing, TCP close/half-close fixes, polling TCP/ARP/reassembly timers and PHY link detection |
| `software/FH_Carrier_Test/src/fh_eth_server.h` | Added public server interface and port |
| `software/FH_Carrier_Test/src/fh_frame_export.c` | Existing catalog retained; ROI bound check avoids unsigned-add overflow |
| `software/FH_Carrier_Test/src/fh_frame_export.h` | Added catalog interface, sizes and 64-bit address constants; documents stopped LUT import |
| `software/host/fh_fetch.py` | Added Python client; RAW and JSON output, CRC32, image identity, geometry and truncated-response checks |
| `software/FH_Carrier_Test/src/UserConfig.cmake` | Link lwip220 |
| `software/FH_Carrier_Test/src/CMakeLists.txt` | Documents automatic collection of all three application C files |
| `software/FH_Carrier_Test/src/lscript.ld` | Default C heap 1 MiB and main stack 64 KiB for GEM allocation and call depth |
| `software/FH_Carrier_platform/psu_cortexa53_0/standalone_psu_cortexa53_0/bsp/bsp.yaml` | Add installed lwip220 v1.3 library and raw IPv4 static-IP settings |
| `software/FH_Carrier_platform/psu_cortexa53_0/standalone_psu_cortexa53_0/bsp/CMakeLists.txt` | Register lwip220 BSP subdirectory for later generation |
| `software/FH_Carrier_platform/vitis-comp.json` | Mark only the application domain as requiring BSP regeneration |
| `hardware/scripts/build_bringup_v24.ps1` | Include both new C modules, link lwip220, check exported library presence, archive all transfer sources/client |
| `README.md`, `docs/ETHERNET_V31_1.md` | Current integration status and later validation requirements |

The historical v24 output filenames in the command-line script remain because
existing launch/debug scripts consume them. Its maintained source input is now
the same V31.1 application used by Vitis. `scripts/build-software.ps1` already
calls this script and needs no change. Neither script was executed.

## Frame ownership and wire format

The authoritative hardware table has 256 stereo slots. Import reads every
valid slot with `fh_frame_read_slot`, checks type/size and both sensor bounds,
sorts by nonwrapping FrameID, rejects duplicates and inconsistent overlaps,
and checks controller ownership again before marking the mirror ready.

Sensor 0 pixels are within `0x1000000000..0x107fffffff`; sensor 1 uses the
same offset plus 2 GiB, within `0x1080000000..0x10ffffffff`. LUT addresses
point to the first pixel, excluding allocation guards. Addresses remain
64-bit throughout. FULL is 4096 x 3072 x 2 bytes; ROI is 4096 x 1024 x 2
bytes with vertical origin 1024. No FPGA registers or memory maps were added.

The mirror is cleared before each U attempt, before entering the sensor/capture
submenu, and before external reset. Failed/cancelled U attempts cannot export
a prior capture. An unresolved ownership failure retains the existing
reset/relaunch requirement. Server mode is serialized with the UART menu;
no acquisition command runs during export. Cache invalidation and lwIP COPY
writes separate PL-DDR reads from Ethernet DMA buffers allocated in PS DDR.
This is stopped-image export, not concurrent 250 Hz network streaming.

Commands are one ASCII line per connection: `STATUS`, `LIST`, `GET id sensor`,
`PAIR id`, `RANGE first count sensor`. Sensor is 0 or 1. RANGE accepts 1..8
consecutive FrameIDs and rejects the request if any are no longer retained.
Each binary image has a 32-byte little-endian header, raw uint16 little-endian
pixels, and a 4-byte payload CRC32 trailer. Header layout:
`<4sBBBBIIIIII` = FHIM, version 1, sensor, type (1 FULL/2 ROI), flags 0,
FrameID, TimerPulse, width, height, byte count, ROI origin. PAIR returns two
packets, sensor 0 then sensor 1. RANGE returns exactly the requested count.
The server allows one active client; UART ESC aborts an active transfer.

## BSP and hardware configuration for later validation

The current block design already enables GEM0 on MIO 26..37 with MDIO on
MIO 76..77. The current SDT BSP identifies GEM0 at `0xff0b0000`, with
`rgmii-id` PHY mode. No Vivado RTL, block design, XSA or BIT changes were made.
Confirm that the loaded BIT/XSA is the existing V30 fixed-exposure variant,
including dual controller ID `0x3412D030` and emulator LUT signature
`0x44530030`; filenames alone are not evidence of that revision.

The application domain settings now request:

| Setting | Value |
| --- | --- |
| Library | Installed `ThirdParty/sw_services/lwip220_v1_3` |
| `lwip220_api_mode` | `RAW_API` / NO_SYS=1 |
| `lwip220_no_sys_no_timers` | true; application polls TCP at 250/500 ms and ARP at 5 s |
| `lwip220_ipv6_enable`, `lwip220_dhcp` | false |
| `lwip220_tcp` | true |
| `lwip220_tcp_snd_buf`, `lwip220_tcp_wnd` | 32768 / 16384 bytes |
| `lwip220_memp_n_tcp_seg` | 512; at least the derived send queue length of 359 |
| `lwip220_mem_size` | 262144 bytes, separate from C heap |

Later, regenerate the existing `standalone_psu_cortexa53_0` BSP in Vitis and
confirm that these settings survived regeneration. Generate/export the
platform so that both the native application and script see `lwipopts.h`,
`xlwipconfig.h`, `xtopology_g.c` and `liblwip220.a`. These generated files are
not fabricated or substituted here. The currently exported BSP still lacks
lwIP. No FSBL-domain settings were changed.

The server uses AMD's SDT GEM interrupt setup via `xemac_add`, then enables
A53 IRQ delivery; TCP/ARP timers, IPv4 reassembly expiry and link checks are polled without adding
another timer ISR. Check interrupt delivery and PHY negotiation/reset/RGMII
delays on the actual SOM/carrier. Its current generated PHY handle is zero;
verify that AMD PHY discovery selects the fitted device/address. Confirm
GEM descriptors and pbuf allocation fit the configured C heap and that the
later linker map remains inside the reserved 256 MiB PS DDR application region.
No runtime throughput is claimed; the reference CRC implementation is bitwise
and the existing debug configuration uses O0.

## Host workflow after firmware validation

Use Python 3.9 or later; the client needs only the standard library. Connect the board PS Ethernet port to the router and the laptop to its Wi-Fi
on the same `192.168.1.0/24` LAN; the firmware serves
`192.168.1.123:5001`. IP/mask/gateway constants are in `fh_eth_server.c`, and
the TCP port is in `fh_eth_server.h`. The firmware uses the EEPROM EUI-48
when valid, otherwise prints a fallback notice and uses `02:46:48:30:00:31`.
Use unique MAC addresses when operating more than one board.

1. UART U: capture, stop and verify; confirm the imported valid-entry count.
2. UART L: inspect the original hardware table and select a retained FrameID.
3. UART N: start the server.
4. Run the client from the project root, using IDs from the current LIST.
5. UART ESC: stop the server and return to diagnostics.

```
python software/host/fh_fetch.py --host 192.168.1.123 status
python software/host/fh_fetch.py --host 192.168.1.123 list
python software/host/fh_fetch.py --host 192.168.1.123 pair 2325 -o images
python software/host/fh_fetch.py --host 192.168.1.123 get 2325 0 -o images
python software/host/fh_fetch.py --host 192.168.1.123 range 2325 4 1 -o images
```

2325 is an example only. The client writes `.partial` data while receiving,
renames it to `.raw` after CRC success, and writes a JSON sidecar. A failed
pair/range can leave earlier, individually completed images on disk.

Later validation should cover BSP generation/linking, heap and linker layout,
PHY and IRQ operation, all five commands and CRCs against V30 pixel patterns,
U failures and submenu invalidation, ESC during transfer, disconnect/reconnect,
and repeated N sessions. Old bring-up and capture behavior also needs board
regression checks. None of those executable checks was performed here.


## Platform build failure from TCP segment pool

The supplied platform log stops in lwIP `src/core/init.c` because
`MEMP_NUM_TCP_SEG` was 256 while AMD's template computes
`TCP_SND_QUEUELEN = 16 * TCP_SND_BUF / TCP_MSS = 359` for a 32768-byte
send buffer and MSS 1460. The application BSP setting
`lwip220_memp_n_tcp_seg` is now 512, and the application domain is marked for
regeneration. TCP sanity checks remain enabled.

Reload the platform settings in Vitis before regenerating/building the
platform. Confirm the regenerated `lwipopts.h` contains
`#define MEMP_NUM_TCP_SEG 512`. Existing generated headers and build caches
still contain 256 until regeneration; they were not edited. No build was
run to verify the correction. The supplied deprecation and driver initializer
warnings were not the fatal error.
