# FH_Test stereo monitor on FH_Carrier

This profile boots two programs concurrently. Vitis on A53 #3 owns UART0, the
GMAX3412 controls, RTC, FULL/ROI scheduler and RAW rolling buffer. Linux on
A53 #0–2 owns GEM0, the two monitor DMAs and the hardware VCU. Start capture
with the existing UART menu. With R=24, U schedules one FULL every 25 accepted
slots. Busy slots can reduce the measured frame rate. The monitor admits up to
10 FULL pairs/s and keeps the frame IDs from the acquisition controller.

## Hardware and Vitis on Windows

Close Vivado and Vitis. In PowerShell at the FH_Test root, select the AMP
workspace for this build session and run the existing hardware/software build:

```powershell
$env:FH_MONITOR_AMP = '1'
.\scripts\build_all.ps1
```

This creates or uses `software/workspace_amp` and builds the capture ELF for
A53 #3 at 0x40000000. Use its FH_TestApp.elf for the AMP boot image.
Removing the environment variable selects the original standalone workspace.
The GUI JTAG action resets the entire MPSoC and launches the standalone A53 #0
application. Use SD boot for simultaneous Linux and Vitis. Sensor diagnostics
and U remain on the existing UART. The standalone lwIP N/E functions use GEM0
in the legacy boot profile. In the AMP profile Linux owns that peripheral.

## Linux image and SD boot

Use the exported FH_Carrier XSA and matching PetaLinux 2025.2 environment on
Linux. The Puzhi KFB image has a different carrier design. For a new ZynqMP
project use the following sequence in the PetaLinux shell, with FH set to the
path of this checkout:

```sh
petalinux-create project --template zynqMP --name fh-monitor
cd fh-monitor
petalinux-config --get-hw-description="$FH/hardware/exports/FH_Firmware.xsa"
python3 "$FH/software/monitor/install_recipe.py" "$PWD"
```

Configure the target root filesystem for systemd and SD/ext4. Include the
ZynqMP VCU encoder kernel modules, firmware, AMD OpenMAX GStreamer plug-ins and
GObject introspection data for Gst, GstRtsp and GstRtspServer. The application
recipe installs the service and media dependencies. Configure Ethernet for the
board's bench subnet (default host setting 192.168.1.123). Keep a Linux shell
available by network for journalctl. UART0 belongs to Vitis after handoff.

After building Linux with `petalinux-build`, make a copy of the generated
DTB configured for concurrent boot. The script uses host dtc tools fdtget and
fdtput. It reserves 8 MiB of low DDR for input to the monitor and 256 MiB
for Vitis, removes Linux control of the legacy acquisition devices, and limits
Linux to three A53 cores. Verify the selected SD interface and Ethernet PHY in
the FH_Carrier device tree.

```sh
python3 "$FH/software/monitor/prepare_dtb.py" images/linux/system.dtb images/linux/fh-amp.dtb
```

Stage the filenames listed in `monitor.bif` together in one directory. Use the
FH bitstream and AMP ELF from Windows and the matching FSBL, PMU firmware,
BL31 and U-Boot from the Linux build. From that directory generate BOOT.BIN:

```sh
bootgen -arch zynqmp -image "$FH/software/monitor/monitor.bif" -o BOOT.BIN
```

Place BOOT.BIN, the kernel Image and fh-amp.dtb on the SD boot partition. Use
the project's ext4 Linux rootfs on the root partition. Boot the Image with the
external fh-amp.dtb. A FIT with its original embedded DTB would omit the AMP
reservations. For U-Boot distro boot, an extlinux.conf entry can select them:

```text
default fh-monitor
label fh-monitor
    kernel /Image
    fdt /fh-amp.dtb
    append root=/dev/mmcblk0p2 rootwait rw console=tty0 maxcpus=3 clk_ignore_unused pd_ignore_unused cma=256M@0x50000000-0x70000000
```

Adjust the root device to the SD slot of the target. Bootloader console traffic
can precede the Vitis UART menu. The service checks the DMA reservation before
accessing physical memory. The kernel needs /dev/mem access to these reserved
and MMIO ranges. Check the media stack on the board with:

```sh
gst-inspect-1.0 omxh264enc
gst-inspect-1.0 omxh265enc
systemctl status fh-monitor
journalctl -u fh-monitor -f
```

## Run

Install the host dependencies with `python -m pip install -r software/host/requirements.txt`.
Boot the AMP image and start the usual UART U capture, with R=24 and duration
0 for continuous operation. Open **Board → Live stereo monitor** in FH_Test.
The live window uses the board IP in the main window. The wheel anchors zoom
to the pointer in the selected eye. Both eyes use the same magnification and
retain independent origins. Drag either image to pan that eye. Full field resets the windows. Resolution and codec
changes reopen the session. Crop changes take effect on a subsequent FULL pair.

The server offers RTSP at `rtsp://192.168.1.123:8554/stereo` with interleaved
RTP over TCP, plus HTTP configuration on port 8555. The MPEG transport stream
contains two video tracks (A then B) with identical PTS for each accepted pair.
FH_Test renders only matching timestamps. Its first frame requires an active U
capture. A player that selects a single video track can display one eye.

## Data path and commissioning

Both live taps accept 16 sensor samples per active clock. They take the upper
eight bits of each 10-bit sample, pack selected pixels across lane boundaries
and cross to the DMA clock through independent FIFOs. The DMA buffers reside
at 0x34000000 and 0x34400000. On matching acquisition IDs, the Linux producer
copies reduced luminance into NV12 buffers with neutral chroma. The VCU encodes
each eye. This implementation uses completed reduced frames as encoder input;
zero-copy and slice synchronization are further latency optimizations.

Start at 1024 × 768 per eye and then test 2048 × 1536. Compare the A/B field and
orientation against a RAW U pair. During zoom and reconnect, inspect UART U
completion counts and the HTTP /monitor frame_id. Measure achieved frame rate
and exposure-to-display latency on the target. FIFO overruns, a mismatched
pair or a missing eye cause a monitor drop; RAW acquisition has its own path.
The wider profile and 1:1 zoom are the most demanding on instantaneous DMA
bandwidth. Functional integration, implementation timing, Linux boot and
throughput require verification on the target.
