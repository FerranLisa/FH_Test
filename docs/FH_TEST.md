# FH_Test desktop application

From the repository root, using a Python environment with pip:

```powershell
python -m pip install -r software/host/requirements.txt
python FH_Test.py
```

The application uses Qt SerialPort, included with PyQt6; pyserial is not needed.
The existing PyQt5 viewer fallback is also supported when QtSerialPort is installed.
No Vivado/Vitis build or firmware change is required. Program and run the matching
FH_Firmware firmware separately before connecting.

## Normal workflow

1. Close any other terminal owning the board COM port. Select that port and Connect
   at 115200 baud (8N1, no flow control). Connection itself sends no commands.
2. At the board's main UART menu, click **Help / sync (H)**. The detected menu
   enables capture controls. If already in Ethernet export, use **Attach / refresh
   export** instead. Default address is 192.168.1.123, TCP port 5001.
3. Set R (0–24), exposure in microseconds, and duration. Duration 0 is continuous.
   Click **Start capture**. Numeric values are sent only after their prompts.
4. Use **Stop capture** for a continuous run. The application sends one ESC,
   then waits for firmware verification and successful LUT import. Verification
   scans retained pixels and can take time; do not reset the board during this phase.
5. With **Export after verification** checked, export mode starts automatically
   and the retained-frame catalog is fetched. Otherwise click **Enter export**.
6. Select or double-click a frame to download both sensors and display the pair.
   Previous/Next also loads the selected pair. Choose MSB/LSB grayscale and hover
   over an image to see its metadata. Cancel interrupts a transfer or background load.
7. Starting another capture first exits export and waits for the UART return message.

UART is controlled asynchronously by Qt. TCP transfers and RAW validation run in
a worker thread. Only one network operation runs at a time, matching the firmware's
single-client server. A full pair contains 48 MiB; an ROI pair contains 16 MiB.
Only the displayed pair is retained as NumPy arrays.

## Files and offline viewing

Downloads go into unique session subdirectories under `images/sessions` by default.
Choose another root with **Choose download root**. Refreshing the remote catalog
starts a new local session to avoid mixing acquisitions or board restarts.
Both sensors are staged and CRC-checked against the selected catalog identity
before the pair is offered to the viewer. RAW files remain uint16 little-endian,
with 10 meaningful bits; JSON sidecars retain the existing downloader format.

**Open downloaded folder** opens a directory of existing pairs without a board.
Incomplete pairs are skipped. Image sizes, pixel range, metadata and stereo timer
pulses are checked before display. The standalone `images/view_stereo.py` and
`software/host/fh_fetch.py` commands remain available.

The console retains its latest 10,000 text blocks; **Save UART log** saves that
visible history. It is not an unlimited automatic log recorder.
Manual **Send text** / **Send + Enter** controls are available outside automatic
capture sequencing. Use text without Enter for menu commands and Send + Enter
for numeric answers. Manual commands discard the remote catalog and return the
controller to unknown state until recognizable firmware output arrives.

## States and recovery

- Capture and Ethernet export are mutually exclusive in current firmware. This
  application does not provide live streaming during capture.
- A successful TCP status query can attach to an already-running export server
  without UART. Capture controls still require the corresponding board's UART.
- Use matching UART and IP endpoints; the existing protocols have no unique board
  identity handshake to verify that they refer to the same physical board.
- Prompt/server-start timeouts leave state unknown, without sending ESC. Inspect
  the UART log, and resynchronize at the main menu or attach to export. A connection
  made midway through capture or a numeric prompt cannot automatically discover
  the firmware state; complete numeric answers manually or finish/recover that
  session in a terminal if needed.
- Firmware DMA ownership failures require the board reset/relaunch described by
  firmware. The host does not try to recover by issuing more capture commands.
- Disconnecting UART or closing the window does not stop capture, exit export,
  reset the board, or terminate its firmware. Stop/Return to menu are explicit.
- The PHY TX-delay toggle is intentionally not a normal application control.

## Host checks

```powershell
python -m unittest discover -s tests -p "test_fh_test*.py" -v
```

Tests cover fragmented UART prompts, capture/verification sequencing, blocked
ownership, catalog gaps/errors, image CRC, cancellation and incomplete-pair cleanup.
With Qt installed, offscreen tests also exercise startup, remote catalog handling,
stale-result rejection, background image loading and both grayscale modes.
Hardware acceptance still requires connecting the actual UART and Ethernet,
running a timed and continuous capture, and displaying FULL and ROI pairs.
# Router extension

The Router bar supports FULL-only subsampling and rectangle downloads from the
4096 x 1024 band for both FULL and ROI records. It requires updated hardware and
firmware. See [Router build and usage](ROUTER.md) for the GUI build procedure,
coordinate conventions, and validation status.

## JTAG Program & Run

Restart FH_Test to see **Program & Run (JTAG)** and **JTAG files...**.
Connect the board's USB JTAG and UART, end active Vitis debug sessions, and connect
UART in FH_Test to capture startup messages. Vitis does not need to be open.

Use **JTAG files...** to review the XSDB, exported XSA/BIT, application ELF,
FSBL ELF and imported platform XSA paths. Defaults use this repository and
`C:/AMDDesignTools/2025.2/Vitis/bin/xsdb.bat`. Saved selections persist.

Clicking **Program & Run (JTAG)** resets the board and clears retained captures.
It checks artifacts first, connects to localhost hw_server port 3121 (starting an
owned server if needed), programs PL, runs FSBL to XFsbl_Exit, then downloads and
resumes the A53 application. Progress/errors appear as `[JTAG]` lines in the console.
The host sends H after successful launch if UART is connected; require a responding
application menu before starting capture. No Ethernet export connection is needed.

The operation uses existing compiled artifacts and does not compile or write flash.
Before reset it rejects missing files, mismatched BIT/XSA, a different imported
platform XSA, non-AArch64 ELFs, missing FSBL exit symbol, and ELFs older than the
imported XSA. These checks detect common stale-build mistakes, but timestamps do
not prove ELF build provenance. Build matching platform and application artifacts
in Vitis before using the launcher. It refuses ambiguous multiple A53#0 targets.

Cancel stops the owned launch processes; it cannot undo programming/reset already
performed. Treat board state as unknown after failure/cancellation and rerun the
full launch. Existing hardware-server processes are left running. First board
validation of this JTAG flow is still required; automated launch tests use mocks
and do not program hardware.

## SATA detection and read-only IDENTIFY (S)

Rebuild/reload the application, return to the main UART menu and send `S`
using FH_Test's manual text field. Startup and clock test `7` remain passive.

The test checks controller clock/reset and lane configuration, configures the
CEVA port-0 host fields, and validates PHY timing **after** setup against the
generated FSBL values. It never writes PI or PHY timing registers. If PI does
not expose port 0, it stops without accessing that port. Existing active
command/FIS engines or commands also block the test.

COMRESET is asserted for 2 ms, then the test waits up to 5 seconds for a link
stable for 100 ms. Reset errors are printed and cleared. A separate 1-second
idle observation checks whether link changes or errors recur. With a stable
link, one ATA `IDENTIFY DEVICE` (0xEC) command transfers 512 bytes to dedicated,
aligned PS DDR buffers. It reports model, serial, firmware, logical sector size
and capacity. No disk sectors are read or written, and no filesystem is mounted.

The transfer has a 5-second timeout. Cache maintenance surrounds DMA. Completion
requires the expected byte count and valid ATA data (including checksum when
provided). Engine stop waits are bounded. On successful cleanup the original
command-list/FIS pointers are restored. On unresolved DMA ownership, buffers
remain allocated, port interrupts remain masked and further `S` attempts are
blocked until reset/reload. The port remains awake after the test.

The final summary separates IDENTIFY success from idle/transfer SError flags.
A successful IDENTIFY is not a storage throughput or disk-sector integrity test.
Hardware validation of this revision is pending. Clock test `7` checks clock,
reset and PI before accessing port status; unavailable ports are SKIPPED.

References:
- Generated FSBL `psu_init.c` for PHY timing and clock/reset configuration.
- [CEVA driver](https://github.com/torvalds/linux/blob/master/drivers/ata/ahci_ceva.c).
- [AHCI 1.3.1](https://www.intel.com/content/dam/www/public/us/en/documents/technical-specifications/serial-ata-ahci-spec-rev1-3-1.pdf).


### Ethernet PHY recovery diagnostics (V33, pending hardware validation)

The first initialization logs BMCR, current BMSR (double read), and partner
registers before/after PHY reset and after negotiation or timeout. RTL8211F
speed acceptance requires three matching link/speed/duplex samples 100 ms
apart, with autonegotiation complete and full duplex. The KFB TX-delay
initialization and readback remain enabled; RX delay is preserved.

The application now polls link recovery locally instead of using the BSP
recovery path: it reads the negotiated state without another PHY reset,
rejects every speed except 10/100/1000, and keeps the netif down on failure.
The TCP listener can remain allocated while the banner reports WAITING.
D and ESC remain serviced between bounded recovery attempts. Initial
autonegotiation can still block for up to 15 seconds.

Validation: connect UART before programming, power-cycle and program once,
then run N without capture. Save the full startup/PHY log; retry the PC
connection after link-up. Disconnect/reconnect Ethernet while N is active
and confirm recovery reports no reset. Repeat with U followed by N. These
changes address recovery and diagnostic gaps; the initial physical link
failure is not yet proven fixed. No firmware compilation was performed.


### Active experiment: KFB Ethernet baseline 2bc7230

This supersedes the custom recovery/watchdog experiment above. The application
PHY override now contains generated AMD 2025.2 code with the exact Realtek
status/TX-delay patch from commit 2bc7230. Its application-local linkage is
retained so only an application rebuild is required. The original BSP
eth_link_detect polling is restored. Custom GEM clock writes, custom stable
status checks, no-reset recovery, TX watchdog and automatic PHY scans are
disabled. Manual D diagnostics remain available. Carrier hardware/FSBL,
capture, Router and TCP command functionality are retained. This is an
Ethernet behavior comparison, not a complete historical firmware rollback.

Previous experimental sources are checkpointed as .c.txt files under
software/experiments/ethernet_pre_kfb_baseline (outside the application build).

Rebuild the application; connect UART before programming; power-cycle the
board and load once through JTAG. Run N before capture or optional tests.
Confirm the KFB BASELINE 2bc7230 banner and retry Attach. Save the complete
log before using D, then test U followed by N if connection succeeds. The
original PHY timeout/reset and BSP recovery behavior is intentionally
restored for comparison; this is not a validated production fix. No build
or hardware test has been run by the assistant.
