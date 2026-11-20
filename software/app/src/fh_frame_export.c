#include "fh_frame_export.h"
#include <string.h>

/* V31 uses capture-then-export, so publication is not concurrent with reads.
 * The mirror is deliberately independent from the hardware LUT layout.
 */
typedef struct {
    FhFrameRecord rec;
    int valid;
} Entry;
static Entry entries[FH_FRAME_MAX_ENTRIES];
static u64 next_order = 1ULL;
static u32 live_count = 0U;
static int capture_active = 0;
static int ddr_ready = 0;

static int overlaps(u64 a, u32 alen, u64 b, u32 blen)
{
    return a < (b + (u64)blen) && b < (a + (u64)alen);
}

void fh_frame_reset(void)
{
    memset(entries, 0, sizeof(entries));
    live_count = 0U;
    next_order = 1ULL;
    ddr_ready = 0;
}

void fh_frame_set_capture_active(int active) { capture_active = !!active; }
void fh_frame_invalidate_sensor(u32 sensor, u64 address, u32 bytes)
{
    for (u32 i=0; i<FH_FRAME_MAX_ENTRIES; ++i) {
        if (entries[i].valid && overlaps(address,bytes,entries[i].rec.address[sensor],entries[i].rec.bytes)) {
            entries[i].valid=0;
            --live_count;
        }
    }
}
void fh_frame_set_ddr_ready(int ready) { ddr_ready = !!ready; }
int fh_frame_is_ready(void) { return ddr_ready && !capture_active; }
int fh_frame_capture_active(void) { return capture_active; }
u32 fh_frame_count(void) { return live_count; }

int fh_frame_address_valid(u64 address, u32 sensor, u32 bytes)
{
    u64 lo, hi;
    if (sensor > 1U || (bytes != FH_FRAME_FULL_BYTES && bytes != FH_FRAME_ROI_BYTES))
        return 0;
    lo = FH_FRAME_BASE + (u64)sensor * FH_FRAME_SENSOR_BYTES;
    hi = lo + FH_FRAME_SENSOR_BYTES;
    if (address < lo || address >= hi || (address & 1ULL) != 0ULL)
        return 0;
    return (u64)bytes <= hi - address;
}

int fh_frame_publish(u32 frame_id, u32 pulse, u32 type,
                     u64 addr0, u64 addr1, u32 bytes, u32 roi_y)
{
    int candidate = -1;
    u32 i;
    if ((type != FH_FRAME_FULL && type != FH_FRAME_ROI) ||
        bytes != ((type == FH_FRAME_FULL) ? FH_FRAME_FULL_BYTES : FH_FRAME_ROI_BYTES) ||
        (!addr0 && !addr1) || (addr0 && !fh_frame_address_valid(addr0, 0U, bytes)) ||
        (addr1 && !fh_frame_address_valid(addr1, 1U, bytes)) ||
        (type == FH_FRAME_FULL && roi_y != 0U) ||
        (type == FH_FRAME_ROI && roi_y > 2048U))
        return 0;

    /* Invalidate old records whose pixels will be overwritten. This also
     * handles variable-sized FULL/ROI slots, unlike modulo-256 eviction. */
    for (i = 0U; i < FH_FRAME_MAX_ENTRIES; ++i) {
        if (!entries[i].valid) {
            if (candidate < 0) candidate = (int)i;
            continue;
        }
        if (entries[i].rec.frame_id == frame_id ||
            (addr0 && overlaps(entries[i].rec.address[0], entries[i].rec.bytes, addr0, bytes)) ||
            (addr1 && overlaps(entries[i].rec.address[1], entries[i].rec.bytes, addr1, bytes))) {
            entries[i].valid = 0;
            --live_count;
            if (candidate < 0) candidate = (int)i;
        }
    }
    if (candidate < 0) {
        /* A 256-entry mirror is not larger than the V30 hardware LUT.
         * Evict the oldest published record rather than inventing validity. */
        u64 oldest = ~(u64)0;
        for (i = 0U; i < FH_FRAME_MAX_ENTRIES; ++i)
            if (entries[i].rec.order < oldest) {
                oldest = entries[i].rec.order;
                candidate = (int)i;
            }
        entries[candidate].valid = 0;
        --live_count;
    }
    entries[candidate].rec.frame_id = frame_id;
    entries[candidate].rec.timer_pulse = pulse;
    entries[candidate].rec.type = type;
    entries[candidate].rec.roi_y = roi_y;
    entries[candidate].rec.address[0] = addr0;
    entries[candidate].rec.address[1] = addr1;
    entries[candidate].rec.bytes = bytes;
    entries[candidate].rec.order = next_order++;
    entries[candidate].valid = 1;
    ++live_count;
    return 1;
}

int fh_frame_find(u32 frame_id, FhFrameRecord *out)
{
    u32 i;
    if (!out) return 0;
    for (i = 0U; i < FH_FRAME_MAX_ENTRIES; ++i)
        if (entries[i].valid && entries[i].rec.frame_id == frame_id) {
            *out = entries[i].rec;
            return 1;
        }
    return 0;
}

int fh_frame_item_at(u32 chronological_index, FhFrameRecord *out)
{
    u32 i, j;
    u64 after = 0ULL;
    int selected;
    if (!out || chronological_index >= live_count) return 0;
    for (j = 0U; j <= chronological_index; ++j) {
        u64 best = ~(u64)0;
        selected = -1;
        for (i = 0U; i < FH_FRAME_MAX_ENTRIES; ++i)
            if (entries[i].valid && entries[i].rec.order > after &&
                entries[i].rec.order < best) {
                best = entries[i].rec.order;
                selected = (int)i;
            }
        if (selected < 0) return 0;
        after = best;
    }
    *out = entries[selected].rec;
    return 1;
}
