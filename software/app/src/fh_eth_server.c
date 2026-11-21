/* FH_Bringup V31: bench-only, capture-then-export TCP server.
 * lwIP 2.2 RAW_API, NO_SYS, Cortex-A53 standalone (Vitis 2025.2).
 * Timers are polled using the A53 counter; no timer ISR is installed.
 * UART ESC exits this dedicated service mode.
 */
#include "fh_eth_server.h"
#include "fh_frame_export.h"
#include "fh_router.h"
#include "fh_version.h"

#include "xparameters.h"
#include "xil_types.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xemacps_hw.h"
#include "xuartps_hw.h"
#include "sleep.h"

#include "lwip/init.h"
#include "lwip/tcp.h"
#include "lwip/priv/tcp_priv.h" /* tcp_fasttmr/tcp_slowtmr declarations */
#include "lwip/etharp.h"
#include "lwip/ip_addr.h"
#include "lwip/ip4_frag.h"
#include "netif/xadapter.h"
#include "netif/xemacpsif.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#if LWIP_IPV6
#error "FH V31 Ethernet protocol requires IPv4 (disable IPv6 in lwip220 BSP)"
#endif
#if LWIP_TIMERS
#error "Enable lwip220_no_sys_no_timers: this server polls TCP/ARP timers"
#endif
#if NO_SYS != 1
#error "FH V31 Ethernet server requires lwip220 RAW_API / NO_SYS=1"
#endif

/* Select the PS GEM actually routed to the SOM PHY. Current FH carrier
 * design is expected to use PS Ethernet 0; verify xparameters.h and XSA. */
#if defined(XPAR_XEMACPS_0_BASEADDR)
#define FH_GEM_BASE XPAR_XEMACPS_0_BASEADDR
#elif defined(XPAR_PSU_ETHERNET_0_BASEADDR)
#define FH_GEM_BASE XPAR_PSU_ETHERNET_0_BASEADDR
#else
#error "PS Ethernet0 is not enabled in xparameters.h; update Vivado PS configuration/XSA"
#endif

#define FH_ETH_CHUNK 1024U
#define FH_ETH_MAX_BATCH 8U
#define FH_ETH_TEXT_CAP 49152U
#define FH_ETH_PROTO_VERSION 1U

/* Binary FHIM header, exactly 32 bytes, LITTLE ENDIAN:
 * magic[4], version:u8, sensor:u8, type:u8 (1 FULL/2 ROI), flags:u8,
 * FrameID:u32, timer_pulse:u32, width:u32, height:u32,
 * payload_bytes:u32, roi_y:u32, then payload, then CRC32 LE trailer.
 * Reply to text commands closes the TCP connection after completion.
 */
typedef struct { FhFrameRecord rec; u8 sensor; } TxFrame;

typedef enum { TX_IDLE=0, TX_TEXT, TX_ROUTE_WAIT, TX_BIN_HEADER, TX_BIN_PIXELS, TX_BIN_TRAILER, TX_FINISHED } TxState;

typedef struct {
    struct tcp_pcb *pcb;
    char command[128];
    u32 command_used;
    TxState tx_state;
    char text[FH_ETH_TEXT_CAP];
    u32 text_len, text_pos;
    TxFrame frames[FH_ETH_MAX_BATCH];
    u8 frame_count, frame_index;
    u8 header[80];
    int with_time;
    u32 header_len, payload_bytes;
    FhRoute route;
    FhRouteGeometry geometry;
    u64 route_started;
    u8 trailer[4];
    u32 phase_pos, crc;
    u64 bytes_queued, bytes_acked;
    u64 last_ack_us, last_stall_us;
    u32 output_calls, output_errors, write_mem_errors;
    err_t last_output_error;
    unsigned stall_reports;
} FhConnection;

static struct netif Netif;
static struct tcp_pcb *Listener;
static FhConnection Conn;
static void tcp_transfer_diagnostics(const char *reason);
static int StackInitialized;
static int Stopping;
static int CloseWasAbort;
static u8 NetMac[6];

/* Match AMD standalone RAW_API: NO_SYS_NO_TIMERS=1. GEM interrupts only
 * enqueue packets; all protocol timers and callbacks run in this menu loop. */
static u64 LastFastUs, LastSlowUs, LastArpUs, LastLinkUs;
static u64 monotonic_us(void)
{
    u64 count, hz;
    __asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(count));
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(hz));
    return (count/hz)*1000000ULL + (count%hz)*1000000ULL/hz;
}

/* Dedicated experiment: no lwIP, DMA, recovery or vendor-page polling. */
extern u32 fh_phy_observe_initialize(XEmacPs *gem, u32 address);
static u64 PhyObserveStart;
static int PhyObserveUsed;

unsigned long fh_phy_observe_ms(void)
{
    return (unsigned long)((monotonic_us()-PhyObserveStart)/1000ULL);
}

static int phy_observe_escape(void)
{
    return XUartPs_IsReceiveData(STDIN_BASEADDRESS) &&
           XUartPs_ReadReg(STDIN_BASEADDRESS, XUARTPS_FIFO_OFFSET)==27U;
}

/* Bound each management transaction; a stalled MDIO must not hang this test. */
int fh_phy_observe_mdio(XEmacPs *gem, unsigned address, unsigned reg, u16 *value, int write)
{
    u64 start = monotonic_us();
    UINTPTR base = gem->Config.BaseAddress;
    if (!(XEmacPs_ReadReg(base, XEMACPS_NWSR_OFFSET) & XEMACPS_NWSR_MDIOIDLE_MASK))
        return -1;
    XEmacPs_WriteReg(base, XEMACPS_PHYMNTNC_OFFSET,
        XEMACPS_PHYMNTNC_OP_MASK |
        (write ? XEMACPS_PHYMNTNC_OP_W_MASK : XEMACPS_PHYMNTNC_OP_R_MASK) |
        (write ? (u32)*value : 0U) |
        (address << XEMACPS_PHYMNTNC_PHAD_SHFT_MSK) |
        (reg << XEMACPS_PHYMNTNC_PREG_SHFT_MSK));
    while (!(XEmacPs_ReadReg(base, XEMACPS_NWSR_OFFSET) & XEMACPS_NWSR_MDIOIDLE_MASK)) {
        if (monotonic_us()-start > 100000ULL) return -2;
    }
    if(!write) *value=(u16)XEmacPs_ReadReg(base, XEMACPS_PHYMNTNC_OFFSET);
    return 0;
}

static int phy_observe_read(XEmacPs *gem, unsigned reg, u16 *value)
{
    return fh_phy_observe_mdio(gem,1U,reg,value,0);
}

static int phy_observe_phase(XEmacPs *gem, const char *name, unsigned seconds)
{
    static const unsigned regs[]={0,1,1,4,5,9,10};
    unsigned sample,i,up=0,down=0,errors=0,changes=0;
    int previous=-1;
    u64 start=monotonic_us();
    xil_printf("PHY OBS %s: %u seconds; reads only; ESC aborts.\r\n",name,seconds);
    for(sample=0;sample<=seconds;++sample) {
        u16 values[7]={0};
        int rc[7];
        while(monotonic_us()-start < (u64)sample*1000000ULL) {
            if(phy_observe_escape()) return 0;
            usleep(1000);
        }
        if(phy_observe_escape()) return 0;
        xil_printf("PHY OBS t=%lu ms %s",fh_phy_observe_ms(),name);
        for(i=0;i<7;++i) {
            rc[i]=phy_observe_read(gem,regs[i],&values[i]);
            if(rc[i]) { ++errors; xil_printf(" r%u=ERR(%d)",regs[i],rc[i]); }
            else xil_printf(" r%u=%04x",regs[i],(unsigned)values[i]);
        }
        if(!rc[2] && values[2]!=0xffffU && values[2]!=0U) {
            int link=(values[2]&4U)!=0;
            if(link) ++up; else ++down;
            if(previous>=0 && previous!=link) ++changes;
            previous=link;
            xil_printf(" link=%u an=%u",link,(values[2]&0x20U)!=0);
        } else { previous=-1; xil_printf(" link=UNKNOWN"); }
        xil_printf("\r\n");
    }
    xil_printf("PHY OBS %s SUMMARY: up=%u down=%u transitions=%u read_errors=%u\r\n",
               name,up,down,changes,errors);
    return 1;
}

void fh_eth_phy_observe(void)
{
    XEmacPs gem;
    u32 saved_ctrl,saved_cfg,result;
    u16 id1=0,id2=0;
    if(StackInitialized || PhyObserveUsed || fh_frame_capture_active()) {
        xil_printf("PHY OBS blocked: restart application and run E before N/capture.\r\n");
        return;
    }
    PhyObserveUsed=1;
    memset(&gem,0,sizeof gem);
    gem.Config.BaseAddress=FH_GEM_BASE;
#ifdef SDT
    gem.Config.MdioProducerBaseAddr=FH_GEM_BASE;
#endif
    gem.IsReady=XIL_COMPONENT_IS_READY;
    PhyObserveStart=monotonic_us();
    saved_ctrl=XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_NWCTRL_OFFSET);
    saved_cfg=XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_NWCFG_OFFSET);
    xil_printf("\r\nPASSIVE PHY OBSERVATION v1: PHY[1], 60s BEFORE + init once + 120s AFTER\r\n");
    xil_printf("No TCP server, GEM reset, DMA startup or recovery. H for menu after test.\r\n");
    if(saved_ctrl & (XEMACPS_NWCTRL_RXEN_MASK|XEMACPS_NWCTRL_TXEN_MASK)) {
        xil_printf("PHY OBS blocked: GEM already running; use fresh JTAG launch.\r\n");
        return;
    }
    /* Management interface only: no CfgInitialize (which resets GEM). */
    XEmacPs_WriteReg(FH_GEM_BASE,XEMACPS_NWCFG_OFFSET,
        (saved_cfg & ~XEMACPS_NWCFG_MDCCLKDIV_MASK) | (7U<<XEMACPS_NWCFG_MDC_SHIFT_MASK));
    XEmacPs_WriteReg(FH_GEM_BASE,XEMACPS_NWCTRL_OFFSET,saved_ctrl|XEMACPS_NWCTRL_MDEN_MASK);
    xil_printf("PHY OBS t=%lu ms: GEM MDIO enabled, divider=224; no PHY writes yet.\r\n",fh_phy_observe_ms());
    if(phy_observe_read(&gem,2,&id1) || phy_observe_read(&gem,3,&id2) ||
       id1!=0x001cU || (id2&0xfff0U)!=0xc910U) {
        xil_printf("PHY OBS invalid RTL8211F identity: %04x/%04x; initialization skipped.\r\n",id1,id2);
        goto done;
    }
    if(!phy_observe_phase(&gem,"BEFORE",60)) goto done;
    xil_printf("PHY OBS t=%lu ms INIT BEGIN: same Realtek routine as N\r\n",fh_phy_observe_ms());
    result=fh_phy_observe_initialize(&gem,1);
    xil_printf("PHY OBS t=%lu ms INIT END: result=%lu (1000=success); observing even on failure\r\n",
               fh_phy_observe_ms(),(unsigned long)result);
    if(!phy_observe_phase(&gem,"AFTER",120)) goto done;
    xil_printf("PHY OBS COMPLETE\r\n");
done:
    XEmacPs_WriteReg(FH_GEM_BASE,XEMACPS_NWCTRL_OFFSET,saved_ctrl);
    XEmacPs_WriteReg(FH_GEM_BASE,XEMACPS_NWCFG_OFFSET,saved_cfg);
    xil_printf("PHY OBS ended; GEM management settings restored, PHY state retained.\r\n");
    xil_printf("Save log. Fresh power/JTAG run before comparative N test. H shows menu.\r\n");
}

extern u32_t phyaddrforemac;
/* Read resolved state without restarting the PHY or blocking TCP timers. */
static int kfb_read_gigabit(XEmacPs *gem, u16 *physr)
{
    u16 page, status;
    int ok, restored;
    if (XEmacPs_PhyRead(gem, phyaddrforemac, 1, &status) != XST_SUCCESS ||
        XEmacPs_PhyRead(gem, phyaddrforemac, 1, &status) != XST_SUCCESS ||
        (status & 0x0024U) != 0x0024U ||
        XEmacPs_PhyRead(gem, phyaddrforemac, 31, &page) != XST_SUCCESS) return 0;
    ok = XEmacPs_PhyWrite(gem, phyaddrforemac, 31, 0x0a43U) == XST_SUCCESS &&
         XEmacPs_PhyRead(gem, phyaddrforemac, 26, physr) == XST_SUCCESS;
    restored = XEmacPs_PhyWrite(gem, phyaddrforemac, 31, page);
    return ok && restored == XST_SUCCESS && (*physr & 0x003cU) == 0x002cU;
}

static void kfb_gigabit_link_poll(void)
{
    static unsigned stable_samples;
    struct xemac_s *adapter = (struct xemac_s *)Netif.state;
    xemacpsif_s *driver = (xemacpsif_s *)adapter->state;
    XEmacPs *gem = &driver->emacps;
    u16 physr = 0, page, tx, verify;
    int ok, restored;
    if (!kfb_read_gigabit(gem, &physr)) {
        if (driver->eth_link_status == ETH_LINK_UP)
            xil_printf("Ethernet Link down/unresolved: PHYSR=%04x; polling without reset\r\n", (unsigned)physr);
        stable_samples = 0;
        netif_set_link_down(&Netif);
        driver->eth_link_status = ETH_LINK_DOWN;
        return;
    }
    if (driver->eth_link_status == ETH_LINK_UP) return;
    if (++stable_samples < 2) return;
    /* Initial setup may have timed out before applying the KFB TX delay. */
    if (XEmacPs_PhyRead(gem, phyaddrforemac, 31, &page) != XST_SUCCESS) return;
    ok = XEmacPs_PhyWrite(gem, phyaddrforemac, 31, 0x0d08U) == XST_SUCCESS &&
         XEmacPs_PhyRead(gem, phyaddrforemac, 17, &tx) == XST_SUCCESS &&
         XEmacPs_PhyWrite(gem, phyaddrforemac, 17, tx | 0x0100U) == XST_SUCCESS &&
         XEmacPs_PhyRead(gem, phyaddrforemac, 17, &verify) == XST_SUCCESS &&
         verify == (u16)(tx | 0x0100U);
    restored = XEmacPs_PhyWrite(gem, phyaddrforemac, 31, page);
    if (!ok || restored != XST_SUCCESS) {
        stable_samples = 0;
        xil_printf("Ethernet recovery: TX delay verification failed\r\n");
        return;
    }
    XEmacPs_SetOperatingSpeed(gem, 1000);
    driver->eth_link_status = ETH_LINK_UP;
    netif_set_link_up(&Netif);
    xil_printf("Ethernet Link up: 1000 Mb/s; recovery without PHY reset\r\n");
}

static void service_timers(void)
{
    u64 now=monotonic_us();
    if (now-LastFastUs>=250000ULL) { tcp_fasttmr();LastFastUs=now; }
    if (now-LastSlowUs>=500000ULL) { tcp_slowtmr();LastSlowUs=now; }
    if (now-LastArpUs>=5000000ULL) { etharp_tmr();LastArpUs=now; }
    if (now-LastLinkUs>=1000000ULL) {
#if IP_REASSEMBLY
        ip_reass_tmr();
#endif
        kfb_gigabit_link_poll();LastLinkUs=now;
    }
}

/* Decimal-only, bounded protocol integers; strtoul/sscanf accept signs and
 * trailing junk, which must not silently select a different image. */
static int parse_number(const char *s, unsigned long *out)
{
    unsigned long n=0UL;
    if (!s || !*s) return 0;
    for (;*s;++s) {
        unsigned long digit;
        if (*s<'0' || *s>'9') return 0;
        digit=(unsigned long)(*s-'0');
        if (n>(0xFFFFFFFFUL-digit)/10UL) return 0;
        n=n*10UL+digit;
    }
    *out=n;
    return 1;
}

static void put_u32le(u8 *p, u32 x)
{
    p[0]=(u8)x; p[1]=(u8)(x>>8); p[2]=(u8)(x>>16); p[3]=(u8)(x>>24);
}

static u32 crc_update(u32 crc, const u8 *data, u32 length)
{
    u32 i, k;
    for (i=0U; i<length; ++i) {
        crc ^= data[i];
        for (k=0U; k<8U; ++k)
            crc = (crc>>1) ^ ((crc & 1U) ? 0xEDB88320U : 0U);
    }
    return crc;
}

static void discard_client(int abort_now, const char *reason)
{
    struct tcp_pcb *p = Conn.pcb;
    if (Conn.tx_state==TX_ROUTE_WAIT) fh_router_abort();
    if (!p) return;
    xil_printf("TCP %s: reason=%s state=%u queued=%lu acked=%lu\r\n",
        abort_now ? "abort" : "close", reason, (unsigned)Conn.tx_state,
        (unsigned long)Conn.bytes_queued, (unsigned long)Conn.bytes_acked);
    Conn.pcb = NULL;
    tcp_arg(p, NULL);
    tcp_recv(p, NULL);
    tcp_sent(p, NULL);
    tcp_poll(p, NULL, 0);
    tcp_err(p, NULL);
    if (abort_now) { CloseWasAbort=1;tcp_abort(p); }
    else if (tcp_close(p) != ERR_OK) { xil_printf("TCP abort: tcp_close failed\r\n"); CloseWasAbort=1;tcp_abort(p); }
    else CloseWasAbort=0;
}

static void set_reply(const char *line)
{
    size_t n = strlen(line);
    if (n >= FH_ETH_TEXT_CAP) n = FH_ETH_TEXT_CAP-1U;
    memcpy(Conn.text,line,n);
    Conn.text[n] = 0;
    Conn.text_len = (u32)n;
    Conn.text_pos = 0U;
    Conn.tx_state = TX_TEXT;
}

static int append_line(const char *line)
{
    size_t n = strlen(line);
    if ((size_t)Conn.text_len + n >= FH_ETH_TEXT_CAP) return 0;
    memcpy(Conn.text + Conn.text_len,line,n);
    Conn.text_len += (u32)n;
    Conn.text[Conn.text_len] = 0;
    return 1;
}

static void prepare_header(void)
{
    const TxFrame *f = &Conn.frames[Conn.frame_index];
    memset(Conn.header, 0, sizeof Conn.header);
    memcpy(Conn.header, "FHIM", 4U);
    Conn.header[4] = (u8)FH_ETH_PROTO_VERSION;
    Conn.header[5] = f->sensor;
    Conn.header[6] = (u8)f->rec.type;
    put_u32le(Conn.header+8U, f->rec.frame_id);
    put_u32le(Conn.header+12U, f->rec.timer_pulse);
    put_u32le(Conn.header+16U, 4096U);
    put_u32le(Conn.header+20U, f->rec.type == FH_FRAME_FULL ? 3072U : 1024U);
    put_u32le(Conn.header+24U, f->rec.bytes);
    put_u32le(Conn.header+28U, f->rec.roi_y);
    Conn.header_len=32U;
    Conn.payload_bytes=f->rec.bytes;
    Conn.phase_pos = 0U;
    Conn.crc = 0xFFFFFFFFU;
    Conn.tx_state = TX_BIN_HEADER;
    if(Conn.route.mode) {
        FhRouteGeometry *g=&Conn.geometry;
        if(!fh_router_geometry(&Conn.route,&f->rec,g) ||
           !fh_router_start(&Conn.route,&f->rec,f->sensor)) {
            set_reply("ERR ROUTER invalid geometry or unavailable hardware\n"); return;
        }
        Conn.header[4]=2; Conn.header[7]=(u8)Conn.route.mode;
        put_u32le(Conn.header+16,g->width); put_u32le(Conn.header+20,g->height);
        put_u32le(Conn.header+24,g->bytes);
        put_u32le(Conn.header+32,g->origin_x); put_u32le(Conn.header+36,g->origin_y);
        put_u32le(Conn.header+40,g->step); put_u32le(Conn.header+44,g->step);
        Conn.header_len=48; Conn.payload_bytes=g->bytes;
        Conn.route_started=monotonic_us(); Conn.tx_state=TX_ROUTE_WAIT;
    }
    if (Conn.with_time) {
        u64 values[]={f->rec.trigger_ticks,f->rec.end_ticks,f->rec.utc_us};
        Conn.header[4]+=2;
        for (unsigned i=0;i<3;i++) {
            put_u32le(Conn.header+Conn.header_len,(u32)values[i]);
            put_u32le(Conn.header+Conn.header_len+4,(u32)(values[i]>>32));
            Conn.header_len+=8;
        }
        put_u32le(Conn.header+Conn.header_len,f->rec.rtc_set_seconds);
        put_u32le(Conn.header+Conn.header_len+4,0U); /* Reserved legacy PC-set flag. */
        Conn.header_len+=8;
    }
}

static void parse_command(void)
{
    char *op, *tokens[10], *token;
    unsigned long id=0UL, count=0UL, sensor=0UL;
    u32 i;
    FhFrameRecord r;
    int parsed;
    char row[170];

    parsed=0;
    Conn.with_time=strncmp(Conn.command,"TIME ",5)==0;
    token=strtok(Conn.command+(Conn.with_time?5:0)," \t");
    while (token && parsed<10) {
        tokens[parsed++]=token;
        token=strtok(NULL," \t");
    }
    if(parsed>0 && strcmp(tokens[0],"ROUTEPAIR")==0) {
        unsigned long v[7];
        if(token || parsed!=8) { set_reply("ERR ARG ROUTEPAIR id mode n x0 y0 x1 y1\n"); return; }
        for(i=0;i<7;i++) if(!parse_number(tokens[i+1],&v[i])) { set_reply("ERR ARG unsigned integer required\n"); return; }
        if(!fh_frame_is_ready()) { set_reply("ERR NOT_READY capture must be stopped\n"); return; }
        if(!fh_router_available()) { set_reply("ERR ROUTER hardware unavailable; update XSA and bitstream\n"); return; }
        if(!fh_frame_find((u32)v[0],&r)) { set_reply("ERR NOT_FOUND FrameID not retained\n"); return; }
        Conn.route.mode=(u32)v[1]; Conn.route.n=(u32)v[2];
        if (!r.address[0] || !r.address[1]) { set_reply("ERR MONO use GET with present sensor\n"); return; }
        Conn.route.x0=(u32)v[3]; Conn.route.y0=(u32)v[4]; Conn.route.x1=(u32)v[5]; Conn.route.y1=(u32)v[6];
        if(!fh_router_geometry(&Conn.route,&r,&Conn.geometry)) { set_reply("ERR ARG invalid Router mode, source or bounds\n"); return; }
        Conn.frames[0].rec=r; Conn.frames[0].sensor=0;
        Conn.frames[1].rec=r; Conn.frames[1].sensor=1;
        Conn.frame_count=2; Conn.frame_index=0; prepare_header(); return;
    }
    if (token || parsed<1 || parsed>4 ||
        (parsed>1 && !parse_number(tokens[1],&id)) ||
        (parsed>2 && !parse_number(tokens[2],&count)) ||
        (parsed>3 && !parse_number(tokens[3],&sensor))) {
        set_reply("ERR ARG invalid command or unsigned integer\n");return;
    }
    op=tokens[0];
    if (strcmp(op,"STATUS") == 0 && parsed == 1) {
        char rtc[320];
        fh_rtc_status(rtc,sizeof rtc);
        snprintf(Conn.text,sizeof Conn.text,
                 "STATUS protocol=1 timestamps=1 mode=stopped-only entries=%lu ready=%u capture=%u router=%u routed_protocol=2 release=" FH_RELEASE " release_state=" FH_RELEASE_STATE " %s\n",
                 (unsigned long)fh_frame_count(), (unsigned)fh_frame_is_ready(),
                 (unsigned)fh_frame_capture_active(), (unsigned)fh_router_available(),rtc);
        Conn.text_len=(u32)strlen(Conn.text); Conn.text_pos=0U;
        Conn.tx_state=TX_TEXT;
        return;
    }
    if (strcmp(op,"LIST") == 0 && parsed == 1) {
        if (!fh_frame_is_ready()) { set_reply("ERR NOT_READY capture active or PL DDR not marked safe\n");return; }
        Conn.text_len=0U; Conn.text[0]=0;
        snprintf(row,sizeof row,"COUNT %lu\n",(unsigned long)fh_frame_count());
        if (!append_line(row)) { set_reply("ERR INTERNAL response buffer\n");return; }
        for (i=0U; i<fh_frame_count(); ++i) {
            if (!fh_frame_item_at(i,&r)) { set_reply("ERR INTERNAL LUT iteration\n");return; }
            snprintf(row,sizeof row,
                "FRAME %lu %lu %s %lu %016llx %016llx %lu\n",
                (unsigned long)r.frame_id,(unsigned long)r.timer_pulse,
                r.type==FH_FRAME_FULL?"FULL":"ROI",(unsigned long)r.bytes,
                (unsigned long long)r.address[0],
                (unsigned long long)r.address[1],(unsigned long)r.roi_y);
            if (Conn.with_time) {
                size_t end=strlen(row)-1U;
                snprintf(row+end,sizeof row-end," %llu %llu %llu %lu %lu\n",
                         (unsigned long long)r.trigger_ticks,(unsigned long long)r.end_ticks,
                         (unsigned long long)r.utc_us,(unsigned long)r.rtc_set_seconds,0UL);
            }
            if (!append_line(row)) { set_reply("ERR INTERNAL LUT text too large\n");return; }
        }
        Conn.tx_state=TX_TEXT;return;
    }
    if (strcmp(op,"GET") == 0 && parsed == 3 && id <= 0xFFFFFFFFUL && count <= 1UL) {
        if (!fh_frame_is_ready()) { set_reply("ERR NOT_READY capture active or DDR not mapped\n");return; }
        if (!fh_frame_find((u32)id,&r)) { set_reply("ERR NOT_FOUND FrameID not retained\n");return; }
        Conn.frames[0].rec=r; Conn.frames[0].sensor=(u8)count;
        if (!r.address[count]) { set_reply("ERR MONO sensor absent\n"); return; }
        Conn.frame_count=1U; Conn.frame_index=0U;
        prepare_header();return;
    }
    if (strcmp(op,"PAIR") == 0 && parsed == 2 && id <= 0xFFFFFFFFUL) {
        if (!fh_frame_is_ready()) { set_reply("ERR NOT_READY capture active or DDR not mapped\n");return; }
        if (!fh_frame_find((u32)id,&r)) { set_reply("ERR NOT_FOUND FrameID not retained\n");return; }
        Conn.frames[0].rec=r;Conn.frames[0].sensor=0U;
        if (!r.address[0] || !r.address[1]) { set_reply("ERR MONO use GET with present sensor\n"); return; }
        Conn.frames[1].rec=r;Conn.frames[1].sensor=1U;
        Conn.frame_count=2U;Conn.frame_index=0U;
        prepare_header();return;
    }
    if (strcmp(op,"RANGE") == 0 && parsed == 4 && id <= 0xFFFFFFFFUL &&
        count>=1UL && count<=FH_ETH_MAX_BATCH && sensor<=1UL &&
        (u64)id+(u64)count<=0x100000000ULL) {
        if (!fh_frame_is_ready()) { set_reply("ERR NOT_READY capture active or DDR not mapped\n");return; }
        for (i=0U; i<(u32)count; ++i) {
            if (!fh_frame_find((u32)id+i,&r)) {
                set_reply("ERR NOT_FOUND one or more FrameIDs not retained\n");return;
            }
            Conn.frames[i].rec=r;Conn.frames[i].sensor=(u8)sensor;
            if (!r.address[sensor]) { set_reply("ERR MONO sensor absent\n"); return; }
        }
        Conn.frame_count=(u8)count;Conn.frame_index=0U;
        /* The host requested count, so RANGE returns exactly that many FHIM packets. */
        prepare_header();return;
    }
    set_reply("ERR ARG commands: STATUS | LIST | GET id sensor | PAIR id | RANGE first count sensor(max8)\n");
}

static void pump_tx(void)
{
    struct tcp_pcb *pcb=Conn.pcb;
    u16 free_space;
    u32 n, remaining;
    const u8 *src;
    u64 addr;
    int queued_any=0;
    err_t e;
    if (!pcb) return;
    for (;;) {
        if (Conn.tx_state == TX_FINISHED || Conn.tx_state == TX_IDLE) break;
        if(Conn.tx_state==TX_ROUTE_WAIT) {
            int status=fh_router_poll();
            if(status<0 || monotonic_us()-Conn.route_started>10000000ULL) {
                fh_router_abort(); discard_client(1, "router error/timeout"); return;
            }
            if(!status) break;
            Conn.tx_state=TX_BIN_HEADER;
        }
        free_space = tcp_sndbuf(pcb);
        if (free_space == 0U || tcp_sndqueuelen(pcb) >= (TCP_SND_QUEUELEN-2U)) break;
        src=NULL; remaining=0U;
        if (Conn.tx_state == TX_TEXT) {
            remaining=Conn.text_len-Conn.text_pos;
            src=(const u8*)Conn.text+Conn.text_pos;
        } else if (Conn.tx_state == TX_BIN_HEADER) {
            remaining=Conn.header_len-Conn.phase_pos;
            src=Conn.header+Conn.phase_pos;
        } else if (Conn.tx_state == TX_BIN_PIXELS) {
            const TxFrame *f=&Conn.frames[Conn.frame_index];
            remaining=Conn.payload_bytes-Conn.phase_pos;
            addr=f->rec.address[f->sensor]+(u64)Conn.phase_pos;
            src=(const u8*)(UINTPTR)addr;
            if(Conn.route.mode) src=fh_router_pixels()+Conn.phase_pos;
        } else if (Conn.tx_state == TX_BIN_TRAILER) {
            remaining=4U-Conn.phase_pos;
            src=Conn.trailer+Conn.phase_pos;
        }
        if (remaining == 0U) {
            if (Conn.tx_state == TX_TEXT) Conn.tx_state=TX_FINISHED;
            else if (Conn.tx_state == TX_BIN_HEADER) {
                Conn.tx_state=TX_BIN_PIXELS;Conn.phase_pos=0U;
            } else if (Conn.tx_state == TX_BIN_PIXELS) {
                put_u32le(Conn.trailer,Conn.crc ^ 0xFFFFFFFFU);
                Conn.tx_state=TX_BIN_TRAILER;Conn.phase_pos=0U;
            } else if (Conn.tx_state == TX_BIN_TRAILER) {
                ++Conn.frame_index;
                if (Conn.frame_index >= Conn.frame_count) Conn.tx_state=TX_FINISHED;
                else prepare_header();
            }
            continue;
        }
        n=remaining;
        if (n>FH_ETH_CHUNK) n=FH_ETH_CHUNK;
        if (n>(u32)free_space) n=(u32)free_space;
        if (n==0U) break;
        if (Conn.tx_state == TX_BIN_PIXELS) {
            /* DMA produced these pixels and PS cache is not coherent.
             * V30 capture must be STOPPED before this function is reached. */
            Xil_DCacheInvalidateRange((INTPTR)src,n);
        }
        e=tcp_write(pcb,src,(u16)n,TCP_WRITE_FLAG_COPY);
        if (e==ERR_MEM) { ++Conn.write_mem_errors; break; }
        if (e!=ERR_OK) { xil_printf("TCP write error=%d\r\n", (int)e); discard_client(1, "tcp_write error");return; }
        if (Conn.tx_state == TX_BIN_PIXELS)
            Conn.crc=crc_update(Conn.crc,src,n);
        if (Conn.tx_state == TX_TEXT) Conn.text_pos+=n;
        else Conn.phase_pos+=n;
        if (!Conn.bytes_queued) Conn.last_ack_us=monotonic_us();
        Conn.bytes_queued+=(u64)n;
        queued_any=1;
    }
    if (queued_any && Conn.pcb) {
        e=tcp_output(Conn.pcb);
        ++Conn.output_calls;
        if (e!=ERR_OK) {
            ++Conn.output_errors;
            if (Conn.output_errors==1U || e!=Conn.last_output_error)
                xil_printf("TCP output error=%d calls=%lu errors=%lu\r\n",
                    (int)e,(unsigned long)Conn.output_calls,(unsigned long)Conn.output_errors);
        }
        Conn.last_output_error=e;
    }
    if (Conn.pcb && Conn.tx_state==TX_FINISHED && Conn.bytes_acked==Conn.bytes_queued)
        discard_client(0, "reply acknowledged");
}

static err_t recv_cb(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
    struct pbuf *q;
    u16 j;
    const char *data;
    int complete=0;
    (void)arg;
    if (err!=ERR_OK) {
        if (p) pbuf_free(p);
        xil_printf("TCP receive error=%d\r\n", (int)err);
        discard_client(1, "receive error");return ERR_ABRT;
    }
    if (!p) {
        /* A peer may half-close its request while still reading our reply. */
        if (Conn.tx_state!=TX_IDLE) return ERR_OK;
        discard_client(0, "peer closed before request");return CloseWasAbort ? ERR_ABRT : ERR_OK;
    }
    if (Conn.tx_state!=TX_IDLE) {
        tcp_recved(pcb,p->tot_len);pbuf_free(p);
        return ERR_OK;
    }
    for (q=p; q; q=q->next) {
        data=(const char*)q->payload;
        for (j=0U;j<q->len;++j) {
            if (data[j]=='\r') continue;
            if (data[j]=='\n') { complete=1;break; }
            if (Conn.command_used+1U >= sizeof Conn.command) {
                complete=1;
                Conn.command[0]=0;
                Conn.command_used=0U;
                break;
            }
            Conn.command[Conn.command_used++]=data[j];
        }
        if (complete) break;
    }
    tcp_recved(pcb,p->tot_len);
    pbuf_free(p);
    if (complete) {
        Conn.command[Conn.command_used]=0;
        xil_printf("TCP request: %s\r\n", Conn.command);
        parse_command();
        pump_tx();
        if (!Conn.pcb && CloseWasAbort) return ERR_ABRT;
    }
    return ERR_OK;
}

static err_t sent_cb(void *arg,struct tcp_pcb *pcb,u16 len)
{
    (void)arg;(void)pcb;
    Conn.bytes_acked+=(u64)len;
    if (len) {
        Conn.last_ack_us=monotonic_us();
        Conn.stall_reports=0;
    }
    pump_tx();
    return CloseWasAbort ? ERR_ABRT : ERR_OK;
}

static err_t poll_cb(void *arg,struct tcp_pcb *pcb)
{
    (void)arg;(void)pcb;
    pump_tx();return CloseWasAbort ? ERR_ABRT : ERR_OK;
}

static void err_cb(void *arg,err_t err)
{
    (void)arg;
    xil_printf("TCP lwIP error=%d state=%u queued=%lu acked=%lu\r\n", (int)err,
        (unsigned)Conn.tx_state, (unsigned long)Conn.bytes_queued, (unsigned long)Conn.bytes_acked);
    Conn.pcb=NULL;
    if(Conn.tx_state==TX_ROUTE_WAIT) fh_router_abort();
}

static err_t accept_cb(void *arg,struct tcp_pcb *newpcb,err_t err)
{
    (void)arg;
    if (err!=ERR_OK || Stopping || Conn.pcb) {
        xil_printf("TCP reject: err=%d stopping=%d busy=%d remote_port=%u\r\n",
            (int)err, Stopping, Conn.pcb != NULL, (unsigned)newpcb->remote_port);
        tcp_abort(newpcb);
        return ERR_ABRT;
    }
    memset(&Conn,0,sizeof Conn);
    CloseWasAbort=0;
    Conn.pcb=newpcb;
    xil_printf("TCP accept: remote_port=%u\r\n", (unsigned)newpcb->remote_port);
    Conn.tx_state=TX_IDLE;
    tcp_arg(newpcb,&Conn);
    tcp_recv(newpcb,recv_cb);
    tcp_sent(newpcb,sent_cb);
    tcp_err(newpcb,err_cb);
    tcp_poll(newpcb,poll_cb,2U);
    tcp_nagle_disable(newpcb);
    return ERR_OK;
}

static netif_input_fn SavedInput;
static netif_linkoutput_fn SavedLinkOutput;
static unsigned ArpTraceBudget;
static u32 TxSubmitted, TxRejected;
static void trace_arp(const char *direction, struct pbuf *p)
{
    u8 b[42];
    if (!ArpTraceBudget || pbuf_copy_partial(p,b,sizeof b,0)!=sizeof b ||
        b[12]!=0x08 || b[13]!=0x06) return;
    --ArpTraceBudget;
    xil_printf("ARP %s op=%u %u.%u.%u.%u -> %u.%u.%u.%u\r\n",direction,
        ((unsigned)b[20]<<8)|b[21],b[28],b[29],b[30],b[31],b[38],b[39],b[40],b[41]);
    xil_printf("  sender=%02x:%02x:%02x:%02x:%02x:%02x dst=%02x:%02x:%02x:%02x:%02x:%02x\r\n",
        b[22],b[23],b[24],b[25],b[26],b[27],b[0],b[1],b[2],b[3],b[4],b[5]);
}
static err_t traced_input(struct pbuf *p, struct netif *n)
{
    trace_arp("RX",p);
    return SavedInput(p,n);
}
static err_t traced_output(struct netif *n, struct pbuf *p)
{
    u8 h[14];
    int log_arp = ArpTraceBudget &&
        pbuf_copy_partial(p,h,sizeof h,0)==sizeof h && h[12]==8 && h[13]==6;
    u16 length=p->tot_len;
    err_t result;
    trace_arp("TX",p);
    result=SavedLinkOutput(n,p);
    if (result==ERR_OK) ++TxSubmitted; else ++TxRejected;
    if (log_arp)
        xil_printf("  ARP TX driver=%d len=%u TXSR=%08x (0=queued, not wire confirmation)\r\n",
            (int)result,(unsigned)length,
            XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_TXSR_OFFSET));
    return result;
}

static u32 RxDelivered;
/* Print PHY identity before link polling can enter another negotiation.
 * Read-only standard MDIO registers; no vendor page or delay writes. */
static void ethernet_phy_diagnostics(void)
{
    struct xemac_s *adapter=(struct xemac_s *)Netif.state;
    xemacpsif_s *driver;
    u16 phy_value;
    unsigned reg_index;
    static const u8 phy_regs[]={2,3,0,1,1,4,5,9,10};
    if (!adapter || !adapter->state) {
        xil_printf("  PHY DIAG: GEM adapter unavailable.\r\n");
        return;
    }
    driver=(xemacpsif_s *)adapter->state;
    xil_printf("  PHY DIAG: scanning MDIO before link polling\r\n");
    /* Probe standard ID/status registers without PHY-specific writes. */
    for (u32 phy=0; phy<32; ++phy) {
        u16 id;
        if (XEmacPs_PhyRead(&driver->emacps,phy,2,&id)!=XST_SUCCESS ||
            id==0 || id==0xffff) continue;
        for (reg_index=0; reg_index<sizeof phy_regs; ++reg_index) {
            if (XEmacPs_PhyRead(&driver->emacps,phy,phy_regs[reg_index],&phy_value)==XST_SUCCESS)
                xil_printf("  PHY[%u] reg=%02x value=%04x\r\n",
                    (unsigned)phy,(unsigned)phy_regs[reg_index],(unsigned)phy_value);
        }
    }
    xil_printf("  PHY DIAG: scan complete\r\n");
}

/* Called only from the main loop/UART, never from a DMA interrupt.
 * Bound list walks and snapshot descriptors without changing ownership. */
static void tcp_transfer_diagnostics(const char *reason)
{
    struct tcp_pcb *pcb=Conn.pcb;
    struct tcp_seg *seg;
    unsigned unsent=0, unacked=0;
    u32 unsent_bytes=0, unacked_bytes=0;
    struct xemac_s *adapter=(struct xemac_s *)Netif.state;
    xemacpsif_s *driver;
    XEmacPs_BdRing *ring;
    u64 daif;
    u32 free_count, hw_count, head, head_status=0;
    if (!pcb) { xil_printf("TCP DIAG %s: no active connection\r\n",reason); return; }
    for (seg=pcb->unsent; seg && unsent<1024U; seg=seg->next) {
        ++unsent; unsent_bytes+=seg->len;
    }
    for (seg=pcb->unacked; seg && unacked<1024U; seg=seg->next) {
        ++unacked; unacked_bytes+=seg->len;
    }
    xil_printf("TCP DIAG %s: state=%u tcp_state=%u queued=%lu acked=%lu no_ack_ms=%lu link=%u\r\n",
        reason,(unsigned)Conn.tx_state,(unsigned)pcb->state,
        (unsigned long)Conn.bytes_queued,(unsigned long)Conn.bytes_acked,
        (unsigned long)(Conn.bytes_queued ? (monotonic_us()-Conn.last_ack_us)/1000ULL : 0),
        (unsigned)netif_is_link_up(&Netif));
    if (Conn.frame_index<Conn.frame_count) {
        const TxFrame *f=&Conn.frames[Conn.frame_index];
        u64 address=f->rec.address[f->sensor];
        xil_printf("  frame=%lu sensor=%u source=%08lx%08lx phase_offset=%lu payload=%lu route=%lu\r\n",
            (unsigned long)f->rec.frame_id,(unsigned)f->sensor,
            (unsigned long)(address>>32),(unsigned long)(address & 0xffffffffULL),
            (unsigned long)Conn.phase_pos,(unsigned long)Conn.payload_bytes,(unsigned long)Conn.route.mode);
    }
    xil_printf("  sndbuf=%lu qlen=%u wnd=%lu cwnd=%lu snd_nxt=%lu lastack=%lu rtime=%d nrtx=%u\r\n",
        (unsigned long)tcp_sndbuf(pcb),(unsigned)tcp_sndqueuelen(pcb),
        (unsigned long)pcb->snd_wnd,(unsigned long)pcb->cwnd,
        (unsigned long)pcb->snd_nxt,(unsigned long)pcb->lastack,(int)pcb->rtime,(unsigned)pcb->nrtx);
    xil_printf("  unsent=%u bytes=%lu unacked=%u bytes=%lu (walk limit=1024)\r\n",
        unsent,(unsigned long)unsent_bytes,unacked,(unsigned long)unacked_bytes);
    xil_printf("  output_calls=%lu errors=%lu last=%d write_ERR_MEM=%lu submitted=%lu rejected=%lu rx_delivered=%lu\r\n",
        (unsigned long)Conn.output_calls,(unsigned long)Conn.output_errors,(int)Conn.last_output_error,
        (unsigned long)Conn.write_mem_errors,(unsigned long)TxSubmitted,
        (unsigned long)TxRejected,(unsigned long)RxDelivered);
    if (!adapter || !adapter->state) return;
    driver=(xemacpsif_s *)adapter->state;
    ring=&XEmacPs_GetTxRing(&driver->emacps);
    __asm__ volatile("mrs %0, daif" : "=r"(daif));
    __asm__ volatile("msr daifset, #2" ::: "memory");
    free_count=ring->FreeCnt; hw_count=ring->HwCnt; head=(u32)ring->HwHead;
    if (hw_count) head_status=XEmacPs_BdRead(ring->HwHead,XEMACPS_BD_STAT_OFFSET);
    __asm__ volatile("msr daif, %0" :: "r"(daif) : "memory");
    xil_printf("  DMA free=%lu pending=%lu head=%08lx status=%08lx TXSR=%08lx RXSR=%08lx Q1=%08lx\r\n",
        (unsigned long)free_count,(unsigned long)hw_count,(unsigned long)head,(unsigned long)head_status,
        (unsigned long)XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_TXSR_OFFSET),
        (unsigned long)XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_RXSR_OFFSET),
        (unsigned long)XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_TXQ1BASE_OFFSET));
}

static void tcp_check_stall(void)
{
    u64 now=monotonic_us();
    if (!Conn.pcb || Conn.bytes_queued<=Conn.bytes_acked || Conn.stall_reports>=3U) return;
    if (now-Conn.last_ack_us<5000000ULL || now-Conn.last_stall_us<5000000ULL) return;
    Conn.last_stall_us=now;
    ++Conn.stall_reports;
    tcp_transfer_diagnostics("ACK STALL");
}

static void ethernet_diagnostics(void)
{
    tcp_transfer_diagnostics("UART D");
    u64 daif, el;
    struct xemac_s *adapter=(struct xemac_s *)Netif.state;
    xemacpsif_s *driver=(xemacpsif_s *)adapter->state;
    XEmacPs_BdRing *ring=&XEmacPs_GetTxRing(&driver->emacps);
    u32 free_count, hw_count, head_status=0;
    /* Snapshot the queue with IRQs masked; never reclaim or modify descriptors. */
    __asm__ volatile("mrs %0, daif" : "=r"(daif));
    __asm__ volatile("msr daifset, #2" ::: "memory");
    free_count=ring->FreeCnt; hw_count=ring->HwCnt;
    if (hw_count) head_status=XEmacPs_BdRead(ring->HwHead,XEMACPS_BD_STAT_OFFSET);
    __asm__ volatile("msr daif, %0" :: "r"(daif) : "memory");
    xil_printf("  TX queue: accepted=%lu rejected=%lu free=%lu pending=%lu head=%08x\r\n",
        (unsigned long)TxSubmitted,(unsigned long)TxRejected,
        (unsigned long)free_count,(unsigned long)hw_count,(unsigned)head_status);
    xil_printf("  TXSR=%08x DMACR=%08x TXQBASE=%08x\r\n",
        XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_TXSR_OFFSET),
        XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_DMACR_OFFSET),
        XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_TXQBASE_OFFSET));
    xil_printf("  TX errors (may clear on read): underrun=%lu late_collision=%lu excess_collision=%lu carrier=%lu\r\n",
        (unsigned long)XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_TXURUNCNT_OFFSET),
        (unsigned long)XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_LATECOLLCNT_OFFSET),
        (unsigned long)XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_EXCESSCOLLCNT_OFFSET),
        (unsigned long)XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_TXCSENSECNT_OFFSET));
    ethernet_phy_diagnostics();
    xil_printf("  TX queue pointers: Q0=%08lx Q1=%08lx ring_base=%08lx sw_head=%08lx separation=%u\r\n",
        (unsigned long)XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_TXQBASE_OFFSET),
        (unsigned long)XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_TXQ1BASE_OFFSET),
        (unsigned long)ring->BaseBdAddr, (unsigned long)ring->HwHead,
        (unsigned)ring->Separation);
    xil_printf("  ZynqMP driver uses TX Q1; Q0 is parked, USEDREAD alone is not a TX fault.\r\n");
    ArpTraceBudget=24;
    xil_printf("  Actual netif IPv4=%s; tracing next 24 ARP packets\r\n",ip4addr_ntoa(netif_ip4_addr(&Netif)));
    __asm__ volatile("mrs %0, daif" : "=r"(daif));
    __asm__ volatile("mrs %0, CurrentEL" : "=r"(el));
    xil_printf("GEM DIAG: base=%08x link=%u delivered=%lu EL=%u DAIF=%03x\r\n",
        (unsigned)FH_GEM_BASE, (unsigned)netif_is_link_up(&Netif),
        (unsigned long)RxDelivered, (unsigned)(el>>2), (unsigned)daif);
    xil_printf("  NCR=%08x NCFGR=%08x IMR=%08x RXSR=%08x\r\n",
        XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_NWCTRL_OFFSET),
        XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_NWCFG_OFFSET),
        XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_IMR_OFFSET),
        XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_RXSR_OFFSET));
    xil_printf("  HW counters (may clear on read): RX=%lu TX=%lu FCS=%lu\r\n",
        (unsigned long)XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_RXCNT_OFFSET),
        (unsigned long)XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_TXCNT_OFFSET),
        (unsigned long)XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_RXFCSCNT_OFFSET));
}

/* Keep TX completion IRQs active, but stop new RX allocations outside N.
 * Drain queued pbufs directly: dispatching them could create new TCP clients. */
static void ethernet_rx_pause(void)
{
    struct xemac_s *adapter=(struct xemac_s *)Netif.state;
    xemacpsif_s *driver=(xemacpsif_s *)adapter->state;
    struct pbuf *packet;
    u64 saved;
    __asm__ volatile("mrs %0, daif" : "=r"(saved));
    __asm__ volatile("msr daifset, #2" ::: "memory");
    XEmacPs_WriteReg(FH_GEM_BASE,XEMACPS_NWCTRL_OFFSET,
        XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_NWCTRL_OFFSET) & ~XEMACPS_NWCTRL_RXEN_MASK);
    __asm__ volatile("dsb sy" ::: "memory");
    __asm__ volatile("msr daif, %0" :: "r"(saved) : "memory");
    /* A final in-flight receive interrupt may enqueue a packet; dequeue under
     * the same protection as the vendor driver, freeing outside the section. */
    do {
        __asm__ volatile("msr daifset, #2" ::: "memory");
        packet=(struct pbuf *)pq_dequeue(driver->recv_q);
        __asm__ volatile("msr daif, %0" :: "r"(saved) : "memory");
        if (packet) pbuf_free(packet);
    } while (packet);
}

static void ethernet_rx_resume(void)
{
    u64 saved;
    __asm__ volatile("mrs %0, daif" : "=r"(saved));
    __asm__ volatile("msr daifset, #2" ::: "memory");
    XEmacPs_WriteReg(FH_GEM_BASE,XEMACPS_NWCTRL_OFFSET,
        XEmacPs_ReadReg(FH_GEM_BASE,XEMACPS_NWCTRL_OFFSET) | XEMACPS_NWCTRL_RXEN_MASK);
    __asm__ volatile("dsb sy" ::: "memory");
    __asm__ volatile("msr daif, %0" :: "r"(saved) : "memory");
}

int fh_eth_serve(const u8 mac[6])
{
    ip_addr_t ip,mask,gw;
    struct tcp_pcb *p;
    int reported_link = -1;
    if (!mac || fh_frame_capture_active()) return -1;
    if (!StackInitialized) {
        memcpy(NetMac,mac,6U);
        IP4_ADDR(&ip,192,168,1,123);
        IP4_ADDR(&mask,255,255,255,0);
        IP4_ADDR(&gw,192,168,1,1);
        lwip_init();
        memset(&Netif,0,sizeof Netif);
        if (!xemac_add(&Netif,&ip,&mask,&gw,NetMac,FH_GEM_BASE)) {
            xil_printf("  Ethernet ERROR: xemac_add failed. Check PS GEM, PHY and XSA.\r\n");
            return -1;
        }
        SavedInput=Netif.input; SavedLinkOutput=Netif.linkoutput;
        Netif.input=traced_input; Netif.linkoutput=traced_output;
        netif_set_default(&Netif);
        netif_set_up(&Netif);
        /* Xilinx xadapter sets up GEM IRQ handlers. Enable A53 IRQ delivery. */
        Xil_ExceptionEnable();
        StackInitialized=1;
    }
    Stopping=0;
    LastFastUs=LastSlowUs=LastArpUs=LastLinkUs=monotonic_us();
    memset(&Conn,0,sizeof Conn);
    /* Retain the listener across capture/menu pauses: avoids rebinding against
     * connections still in TIME_WAIT after a previous export session. */
    if (!Listener) {
        err_t bind_result;
        p=tcp_new_ip_type(IPADDR_TYPE_V4);
        if (!p) {
            xil_printf("  Ethernet: TCP PCB allocation failed.\r\n");
            Stopping=1; ethernet_rx_pause(); return -1;
        }
        bind_result=tcp_bind(p,IP_ADDR_ANY,FH_ETH_PORT);
        if (bind_result!=ERR_OK) {
            xil_printf("  Ethernet: TCP bind failed (%d).\r\n",(int)bind_result);
            tcp_close(p); Stopping=1; ethernet_rx_pause(); return -1;
        }
        Listener=tcp_listen_with_backlog(p,1U);
        if (!Listener) {
            xil_printf("  Ethernet: TCP listener allocation failed.\r\n");
            tcp_close(p); Stopping=1; ethernet_rx_pause(); return -1;
        }
        tcp_accept(Listener,accept_cb);
    }
    ethernet_rx_resume();
    xil_printf("\r\nFH Ethernet server " FH_RELEASE_LABEL ", TCP port %u\r\n",(unsigned)FH_ETH_PORT);
    xil_printf("  Static IP: 192.168.1.123/24; gateway: 192.168.1.1; host: router LAN/Wi-Fi\r\n");
    xil_printf("  KFB BASELINE 1000-ONLY: autonegotiation enabled; no 10/100 fallback; recovery without PHY reset; TCP tracing.\r\n");
    xil_printf("  Commands: STATUS LIST GET PAIR RANGE\r\n");
    xil_printf("  Frame mirror: %lu entries; DDR ready: %u\r\n",
               (unsigned long)fh_frame_count(),(unsigned)fh_frame_is_ready());
    xil_printf("  D: GEM/PHY diagnostics; ESC exits; recording must be stopped.\r\n");
    for (;;) {
        if (XUartPs_IsReceiveData(STDIN_BASEADDRESS)) {
            int c=inbyte();
            if (c==27) break;
            if (c=='D' || c=='d') ethernet_diagnostics();

        }
        time_service();
        RxDelivered += (u32)xemacif_input(&Netif);
        service_timers();
        if (reported_link != (int)netif_is_link_up(&Netif)) {
            reported_link = (int)netif_is_link_up(&Netif);
            xil_printf(reported_link ?
                "Ethernet READY: link up; TCP listener active.\r\n" :
                "Ethernet WAITING: no resolved link; TCP listener waiting, ESC exits.\r\n");
        }
        if (Conn.pcb) pump_tx();
        else usleep(100U);
        tcp_check_stall();
    }
    Stopping=1;
    ethernet_rx_pause();
    if (Conn.pcb) discard_client(1, "UART exit");
    xil_printf("  Ethernet RX paused; returning to UART menu.\r\n");
    return 0;
}
