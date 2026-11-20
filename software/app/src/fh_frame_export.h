#ifndef FH_FRAME_EXPORT_H
#define FH_FRAME_EXPORT_H

/* FH_Bringup V31: software mirror of the valid stereo Frame_Addr_LUT.
 * This file does not change the FPGA LUT. V31.1 imports valid hardware slots
 * only after U stops and verifies the retained frames. Reset the mirror before
 * any capture/reset that can overwrite storage; never publish live DMA data.
 */
#include "xil_types.h"

#define FH_FRAME_MAX_ENTRIES 256U
#define FH_FRAME_FULL 1U
#define FH_FRAME_ROI  2U
#define FH_FRAME_BASE 0x1000000000ULL
#define FH_FRAME_SENSOR_BYTES 0x80000000ULL
#define FH_FRAME_FULL_BYTES 25165824U
#define FH_FRAME_ROI_BYTES   8388608U

typedef struct {
    u32 frame_id;
    u32 timer_pulse;
    u32 type;          /* FH_FRAME_FULL or FH_FRAME_ROI */
    u32 roi_y;         /* 1024 for V30 ROI, 0 for full */
    u64 address[2];    /* FIRST PIXEL address, not slot/guard start */
    u32 bytes;         /* payload bytes per sensor */
    u64 order;         /* insertion order in this runtime */
} FhFrameRecord;

void fh_frame_reset(void);
void fh_frame_invalidate_sensor(u32 sensor, u64 address, u32 bytes);
void fh_frame_set_capture_active(int active);
void fh_frame_set_ddr_ready(int ready);
int fh_frame_is_ready(void);
int fh_frame_capture_active(void);
u32 fh_frame_count(void);
int fh_frame_publish(u32 frame_id, u32 pulse, u32 type,
                     u64 addr0, u64 addr1, u32 bytes, u32 roi_y);
int fh_frame_find(u32 frame_id, FhFrameRecord *out);
int fh_frame_item_at(u32 chronological_index, FhFrameRecord *out);
int fh_frame_address_valid(u64 address, u32 sensor, u32 bytes);

#endif
