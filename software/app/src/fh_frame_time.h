/* RTC seconds are Unix UTC in this application. PL register reads never toggle
 * the command bit, so the scheduler retains ownership during a U acquisition. */
#include "xrtcpsu.h"
#define FH_RTC_BASE ((UINTPTR)0xFFA60000U)
#define FH_TIME_HISTORY 1024U
#define FH_FIRST_UTC 1577836800U /* Reject unprovisioned RTCs (before 2020). */

typedef struct {
    u64 ticks;
    u32 seconds;
} FhRtcAnchor;
static FhRtcAnchor time_history[FH_TIME_HISTORY];
static unsigned time_count, time_head;
static u32 time_sequence, time_last_set;
static u64 observed_edge, edge_interval;
static u32 late_edges, accepted_edges;

/* Restore the diagnostic selector because other capture code shares this port. */
static u32 time_register(unsigned reg)
{
    u32 saved=DualControl;
    cap_write(DUAL_GPIO,(saved & ~255U)|reg);
    u32 value=cap_read(DUAL_GPIO+8U);
    cap_write(DUAL_GPIO,saved);
    return value;
}

static u64 time_read64(unsigned reg)
{
    u32 hi,lo;
    do {
        hi=time_register(reg+1);
        lo=time_register(reg);
    } while (time_register(reg+1)!=hi);
    return ((u64)hi<<32)|lo;
}

static u32 rtc_read(unsigned reg) {return Xil_In32(FH_RTC_BASE+reg);}
static void rtc_write(unsigned reg,u32 value) {Xil_Out32(FH_RTC_BASE+reg,value);}

/* Keep a plausible per-unit crystal trim across warm starts. */
static int rtc_prepare_calibration(int setting_time)
{
    const u32 nominal=XRTC_TYPICAL_OSC_FREQ-1U;
    u32 previous=rtc_read(XRTC_CALIB_RD_OFFSET);
    u32 divider=previous & XRTC_CALIB_RD_MAX_TCK_MASK;
    u32 wanted=previous;
    if (divider<nominal-32U || divider>nominal+32U)
        wanted=nominal;
    if (wanted==previous && !setting_time) return 1;
    /* Writing calibration restarts the subtick counter before SET_TIME. */
    rtc_write(XRTC_CALIB_WR_OFFSET,wanted);
    for (unsigned i=0;i<100;++i) {
        if (rtc_read(XRTC_CALIB_RD_OFFSET)==wanted) {
            if (wanted!=previous)
                xil_printf("ZU7EV RTC calibration corrected: 0x%08x -> 0x%08x. Use T to refresh UTC.\r\n",
                           previous,wanted);
            return 1;
        }
        usleep(1000);
    }
    xil_printf("ZU7EV RTC calibration readback failed: expected 0x%08x, read 0x%08x.\r\n",
               wanted,rtc_read(XRTC_CALIB_RD_OFFSET));
    return 0;
}

static int time_init(void)
{
    DualControl=cap_read(DUAL_GPIO);
    if (time_register(0x10)!=0x46545431U) {
        xil_printf("Load the FH_Test frame timestamp bitstream.\r\n");
        return 0;
    }
    rtc_write(XRTC_CTL_OFFSET,rtc_read(XRTC_CTL_OFFSET)|XRTCPSU_CRYSTAL_OSC_EN|XRTC_CTL_BATTERY_EN_MASK);
    rtc_prepare_calibration(0);
    rtc_write(XRTC_INT_STS_OFFSET,XRTC_INT_STS_SECS_MASK);
    time_sequence=time_register(0x11);
    time_last_set=rtc_read(XRTC_SET_TIME_RD_OFFSET);
    rtc_write(XRTC_INT_EN_OFFSET,XRTC_INT_EN_SECS_MASK);
    return 1;
}

void time_service(void)
{
    if (!(rtc_read(XRTC_INT_STS_OFFSET)&XRTC_INT_STS_SECS_MASK)) return;
    u32 seq=time_register(0x11);
    if (seq==time_sequence) return; /* Wait for IRQ propagation to PL. */
    u64 ticks=time_read64(0x12);
    u32 sec=rtc_read(XRTC_CUR_TIME_OFFSET);
    __asm__ volatile("dsb sy" ::: "memory");
    if (sec!=rtc_read(XRTC_CUR_TIME_OFFSET) || seq!=time_register(0x11)) return;
    u64 now=time_read64(0x14);
    rtc_write(XRTC_INT_STS_OFFSET,XRTC_INT_STS_SECS_MASK);
    edge_interval=(observed_edge && seq-time_sequence==1U) ? ticks-observed_edge : 0;
    observed_edge=ticks;
    time_sequence=seq;
    /* A pending level may have remained asserted while firmware was busy. */
    if (now-ticks>6000000ULL) {++late_edges; return;}
    if (sec<FH_FIRST_UTC) return;
    ++accepted_edges;
    time_history[time_head]=(FhRtcAnchor){ticks,sec};
    time_head=(time_head+1U)%FH_TIME_HISTORY;
    if (time_count<FH_TIME_HISTORY) ++time_count;
}

static u64 time_utc_us(u64 ticks)
{
    /* Between observed edges interpolate. Just beyond the latest edge use
     * the last measured second for at most one second. Never bridge a step. */
    for (unsigned n=1;n<time_count;++n) {
        FhRtcAnchor b=time_history[(time_head+FH_TIME_HISTORY-n)%FH_TIME_HISTORY];
        FhRtcAnchor a=time_history[(time_head+FH_TIME_HISTORY-n-1)%FH_TIME_HISTORY];
        if (ticks<a.ticks) continue;
        u64 period=b.ticks-a.ticks;
        if (b.seconds!=a.seconds+1U || period<119000000ULL || period>121000000ULL ||
            (ticks>b.ticks && (n!=1 || ticks-b.ticks>period))) return 0;
        return (u64)a.seconds*1000000ULL+(ticks-a.ticks)*1000000ULL/period;
    }
    return 0;
}

void fh_rtc_status(char *buf, size_t size)
{
    u32 seconds=rtc_read(XRTC_CUR_TIME_OFFSET);
    snprintf(buf,size,"rtc_seconds=%lu rtc_subticks=%lu rtc_pl_edges=%lu rtc_period_ticks=%llu "
             "rtc_accepted=%lu rtc_late=%lu rtc_irq=%lu rtc_irq_mask=%lu rtc_calib=%lu rtc_utc=%s",
             (unsigned long)seconds,(unsigned long)rtc_read(XRTC_CUR_TCK_OFFSET),
             (unsigned long)time_register(0x11),(unsigned long long)edge_interval,
             (unsigned long)accepted_edges,(unsigned long)late_edges,
             (unsigned long)(rtc_read(XRTC_INT_STS_OFFSET)&1U),
             (unsigned long)(rtc_read(XRTC_INT_MSK_OFFSET)&1U),
             (unsigned long)rtc_read(XRTC_CALIB_RD_OFFSET),
             seconds<FH_FIRST_UTC ? "calendar_unset" :
             time_utc_us(time_read64(0x14)) ? "locked" : "waiting_for_anchors");
}

static void fh_rtc_diagnostic(void)
{
    char sample[320];
    for (unsigned i=0;i<3;++i) {
        if (i) {
            u64 start=capture_us();
            while (capture_us()-start<1100000ULL) {time_service(); usleep(1000);}
        }
        time_service();
        fh_rtc_status(sample,sizeof sample);
        xil_printf("ZU7EV RTC sample %u: %s\r\n",i+1,sample);
    }
}

static void fh_rtc_set_command(void)
{
    u64 seconds=0;
    unsigned digits=0;
    int c=inbyte();
    int valid=(c==':');
    while (c!='\r' && c!='\n') {
        c=inbyte();
        if (c=='\r' || c=='\n') break;
        if (c<'0' || c>'9' || digits==10U) {
            valid=0;
            continue;
        }
        seconds=seconds*10U+(unsigned)(c-'0');
        ++digits;
    }
    if (!valid || seconds<FH_FIRST_UTC || seconds>=0xffffffffULL) {
        xil_printf("Invalid RTC time. Use T:<Unix UTC seconds> followed by Enter.\r\n");
        return;
    }

    /* The BSP compensates for the one-second transfer to CURRENT_TIME. */
    u32 target=(u32)seconds+1U;
    if (!rtc_prepare_calibration(1)) return;
    time_count=time_head=0;
    accepted_edges=late_edges=0;
    observed_edge=edge_interval=0;
    rtc_write(XRTC_INT_STS_OFFSET,XRTC_INT_STS_SECS_MASK);
    rtc_write(XRTC_SET_TIME_WR_OFFSET,target);
    time_last_set=rtc_read(XRTC_SET_TIME_RD_OFFSET);
    u64 start=capture_us();
    while (capture_us()-start<3000000ULL) {
        if ((rtc_read(XRTC_INT_STS_OFFSET)&XRTC_INT_STS_SECS_MASK) &&
            rtc_read(XRTC_CUR_TIME_OFFSET)==target && time_last_set==target) {
            xil_printf("ZU7EV RTC set and verified: %u Unix UTC seconds.\r\n",target);
            time_service();
            return;
        }
        usleep(1000);
    }
    xil_printf("ZU7EV RTC write unconfirmed: expected %u, current %u.\r\n",
               target,rtc_read(XRTC_CUR_TIME_OFFSET));
}

static void time_prepare(void)
{
    time_service();
    if (rtc_read(XRTC_CUR_TIME_OFFSET)<FH_FIRST_UTC) return;
    u64 start=capture_us();
    while (!time_utc_us(time_read64(0x14)) && capture_us()-start<2300000ULL) {
        time_service();
        usleep(1000U);
    }
}
