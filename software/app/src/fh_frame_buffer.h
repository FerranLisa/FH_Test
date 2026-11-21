#ifndef FH_FRAME_BUFFER_H
#define FH_FRAME_BUFFER_H
#include "xil_types.h"
/* V30 Frame_Addr_LUT API. Master=0, Slave=1. Addresses point to pixels,
 * not allocation padding. Frames are 16-bit row-major pixels, 4096 wide.
 * Zero return means expired/incomplete/not found. Entries are valid only
 * until overwritten or acquisition restarts. Serialize GPIO access, and
 * revalidate FrameID/address after copying during active acquisition.
 * FrameID is unique until PL reset; acquisition stops at 32-bit exhaustion.
 */
typedef struct {
    /* TimerPulse: 1-based per acquisition, counts skipped ticks, wraps at 2^32. */
    u32 FrameID, Bytes, ROI, Seed, Valid, TimerPulse;
    u64 trigger_ticks, end_ticks;
    UINTPTR Addr;
} FhFrameAddress;
int fh_frame_lookup(u32 FrameID, u32 sensor, FhFrameAddress *entry);
/* Read physical LUT slot 0..255 for sensor 0 or 1. Returns 1 only if valid.
 * Same serialization and live-copy revalidation rules as lookup apply. */
int fh_frame_read_slot(u32 slot, u32 sensor, FhFrameAddress *entry);
#endif
