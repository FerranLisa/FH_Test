#include "fh_router.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "xparameters.h"

#define ROUTER 0xA00C0000ULL
#define DMA 0xA00D0000ULL
/* Linker-owned BSS, never a hardcoded scratch address. */
static u8 staging[FH_FRAME_FULL_BYTES] __attribute__((aligned(64)));
static u32 active_bytes;
static int active;
static u32 rd(u64 base, u32 off) { return Xil_In32((UINTPTR)(base+off)); }
static void wr(u64 base,u32 off,u32 v) { Xil_Out32((UINTPTR)(base+off),v); }
int fh_router_available(void)
{
/* Old XSAs must never provoke an access to an unmapped peripheral. */
#if defined(XPAR_FH_EXPORT_DMA_BASEADDR)
    return rd(ROUTER,0)==0x46525231U;
#else
    return 0;
#endif
}
int fh_router_geometry(const FhRoute *c,const FhFrameRecord *r,FhRouteGeometry *g)
{
    if(c->mode==1) {
        if(r->type!=FH_FRAME_FULL || !(c->n==1 || c->n==2 || c->n==4 || c->n==8 || c->n==16)) return 0;
        g->width=4096/c->n; g->height=3072/c->n;
        g->origin_x=0; g->origin_y=0; g->step=c->n;
    } else if(c->mode==2) {
        if(c->x0>=c->x1 || c->x1>4096 || c->y0>=c->y1 || c->y1>1024 ||
           (r->type==FH_FRAME_ROI && r->roi_y!=1024)) return 0;
        g->width=c->x1-c->x0; g->height=c->y1-c->y0;
        g->origin_x=c->x0; g->origin_y=1024+c->y0; g->step=1;
    } else return 0;
    g->bytes=g->width*g->height*2;
    return 1;
}
void fh_router_abort(void)
{
    if(!fh_router_available()) return;
    wr(DMA,0,4); wr(ROUTER,4,2); active=0;
}
int fh_router_start(const FhRoute *c,const FhFrameRecord *r,u32 sensor)
{
    FhRouteGeometry g;
    u32 k, y0, y1;
    u64 dst=(u64)(UINTPTR)staging, src;
    if(active || sensor>1 || !fh_frame_is_ready() || !fh_router_available() ||
       !fh_router_geometry(c,r,&g) || !fh_frame_address_valid(r->address[sensor],sensor,r->bytes)) return 0;
    wr(DMA,0,4);
    for(k=0;k<100000;k++) if(!(rd(DMA,0)&4)) break;
    if(k==100000) return 0;
    wr(ROUTER,4,2);
    y0=g.origin_y-(r->type==FH_FRAME_ROI?r->roi_y:0);
    y1=c->mode==1?3072:y0+g.height;
    wr(ROUTER,8,r->type==FH_FRAME_FULL?3072:1024);
    wr(ROUTER,12,g.origin_x); wr(ROUTER,16,y0);
    wr(ROUTER,20,c->mode==1?4096:c->x1); wr(ROUTER,24,y1);
    wr(ROUTER,28,g.step); wr(ROUTER,32,g.width*g.height);
    Xil_DCacheFlushRange((INTPTR)staging,(g.bytes+63U)&~63U);
    wr(DMA,0x34,0x7000); wr(DMA,4,0x7000);
    wr(DMA,0x30,1); wr(DMA,0x48,(u32)dst); wr(DMA,0x4c,(u32)(dst>>32)); wr(DMA,0x58,g.bytes);
    wr(ROUTER,4,1);
    src=r->address[sensor];
    wr(DMA,0,1); wr(DMA,0x18,(u32)src); wr(DMA,0x1c,(u32)(src>>32)); wr(DMA,0x28,r->bytes);
    active_bytes=g.bytes; active=1;
    return 1;
}
int fh_router_poll(void)
{
    u32 a,b,s;
    if(!active) return -1;
    a=rd(DMA,4); b=rd(DMA,0x34); s=rd(ROUTER,4);
    if((a|b)&0x770 || (s&4)) { fh_router_abort(); return -1; }
    if((a&2) && (b&2) && (s&2)) {
        if(rd(ROUTER,32)!=active_bytes/2) { fh_router_abort(); return -1; }
        Xil_DCacheInvalidateRange((INTPTR)staging,(active_bytes+63U)&~63U);
        active=0; return 1;
    }
    return 0;
}
const u8 *fh_router_pixels(void) { return staging; }
