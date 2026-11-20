# Passive PHY observation (UART E)

Build the Vitis application from the updated sources and program through JTAG.
No Vivado or BSP rebuild is required for this application-only change.

1. Keep the Ethernet cable, switch port, USB and power connections unchanged throughout a run.
2. Start from a fresh power cycle and JTAG launch. Record the power-off duration.
3. Connect UART and enable/save logging. Do not start capture, Ethernet export or Attach.
4. Send `E` through the UART command field (or a serial terminal). No new GUI button is required.
5. Observe the link LED for the approximately three-minute test:
   - BEFORE: 60 seconds of standard PHY register reads, once per second.
   - INIT: the same Realtek PHY initialization routine used by N, once, with timestamped writes/results.
   - AFTER: 120 seconds of standard reads, even if initialization times out.
6. Save uart.log after PHY OBS COMPLETE. Press H only when you want the menu.
7. Use a fresh power/JTAG run for a normal N comparison. Repeat E across several cold starts if intermittent.

ESC aborts either observation phase. Initialization is short but does not poll ESC;
individual diagnostic MDIO operations have 100 ms deadlines and reset waiting has a
2-second deadline. No TCP server, link recovery, vendor-page polling or DMA is started.
The test is blocked after N or a prior E in the same application session.

The test enables GEM management with MDC divider 224, without resetting GEM, and
restores its original management settings afterward. It leaves PHY state as produced
by initialization; aborting does not undo PHY writes. BEFORE means before application
Ethernet initialization, not before FSBL, JTAG or power-on configuration.

## Reading the output

Every sample has elapsed milliseconds, phase, r0 (BMCR), r1 twice (BMSR),
r4/r5 (advertisement/partner), r9/r10 (gigabit control/status).
The second BMSR supplies the displayed current link/autonegotiation state. Keep the
first reading too: it can reveal a latched link loss between samples. r10 idle-error
counters may be read-clear; these reads do not reconfigure the PHY.
ERR(-1) means MDIO busy before transaction; ERR(-2) means transaction timeout.
Zero/all-ones BMSR is reported UNKNOWN rather than asserted to be link down.
Phase summaries count valid up/down samples, observed transitions and read errors;
one-second sampling can miss short transitions. This is evidence, not an automatic
hardware PASS/FAIL verdict. Note LED transitions against the elapsed timestamps.

- Flapping BEFORE: N initialization is not required to trigger the fault.
- Stable BEFORE, flapping AFTER: focus on initialization and resulting configuration.
- Stable E, flapping N: isolate normal recovery writes and then traffic/GEM activity.
- Flapping with no ongoing PHY writes: correlate PHY supply/reset measurements and
  link-partner logs; retained configuration and hardware both remain candidates.

The E path deliberately omits normal GEM initialization and uses conservative MDIO
timing, so a stable result narrows the investigation but does not prove hardware good.
Normal N initialization/recovery behavior is unchanged. No compilation or hardware
execution was performed when adding this test.

## KFB comparison with N

N uses a valid carrier EEPROM EUI-48 when available. If unavailable or invalid,
it logs BENCH fallback and uses locally administered unicast MAC
02:46:48:00:00:01. Use only one fallback board on the LAN and only one board
with static IP 192.168.1.123. This is a bench aid, not automatic carrier detection.
Build the application, JTAG launch, then N; capture is not required for STATUS.
E itself never needs an EEPROM MAC. Use a fresh run for each E/N comparison.


## Startup timeout correction (2026-11-16)

Realtek initialization now polls BMSR twice per sample for up to 15 seconds,
checks the final sample before declaring timeout, and rejects failed/invalid
MDIO reads. The advertisement/reset sequence remains the same. Both E and N
use this corrected routine. N reports Ethernet WAITING or Ethernet READY as
its link state changes. READY indicates link/listener state, not proof that
TCP traffic has reached the PC.

FH_Test retries its read-only STATUS probe for up to 45 seconds when attaching,
with short socket timeouts and cancellation support. Image downloads are not
retried automatically. Frame readiness remains separate from Ethernet readiness.

Validation: startup worker retry/deadline/cancellation tests and host protocol
tests pass. Qt GUI tests require dependencies unavailable in the test runtime.
Firmware was not compiled or tested on hardware. Rebuild the application,
restart FH_Test, and test the first U/N after a fresh power/JTAG start using
the same short cable. Save uart.log; expect negotiation complete, Ethernet
READY and a fully acknowledged PAIR transfer without a second N invocation.


## Image transfer stall diagnostics (2026-11-17)

N now prints TCP DIAG ACK STALL after five seconds with outstanding response
bytes and no acknowledgement progress. It prints at most three snapshots per
stall, at least five seconds apart; a new acknowledgement rearms reporting.
UART D also prints the TCP snapshot (or no active connection).

Snapshots include FrameID/sensor/source address, transmit phase/offset, queued
and acknowledged bytes, send buffer/queue length, remote window/congestion
window, sequence numbers, retransmission timer/count, bounded unsent/unacked
segment counts and bytes, application tcp_output call/error counts, tcp_write
ERR_MEM count, driver submission/rejection counters and TX DMA descriptor state.
The output counters cover explicit application calls, not internal lwIP calls.
No packet memory is dereferenced for frame diagnostics. Automatic dumps do not
scan MDIO or read clear-on-read packet/error counters. Existing UART D hardware
counter behavior is unchanged. Diagnostics do not reset/reclaim DMA or modify
PHY settings, retry policy, or the PC receive timeout.

Rebuild the application and program it, then U -> N and download successive
pairs until the stall occurs. Leave N running for at least 15 seconds, optionally
send D, and save uart.log before ESC. Look for TCP output error and TCP DIAG ACK
STALL. Firmware compilation/hardware validation was not performed here.
