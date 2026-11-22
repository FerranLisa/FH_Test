// Pull protocol, one client, one pair per request. All TCP writes use COPY.
// Request: FHR1, step, ax, ay, bx, by (five little-endian u32).
// Reply: FHJ1, acquisition FrameID, A length, B length, then both JPEGs.
#include "fh_jpeg_monitor.h"
#include "fh_jpeg.h"
#include "lwip/tcp.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xparameters.h"
#include "xil_printf.h"
#include <string.h>
#define WIDTH 1024U
#define HEIGHT 768U
#define SIZE (WIDTH*HEIGHT)
#define CAPACITY (SIZE*4U)
#define BASE(i) (0xA1000000U+0x40000U*(i))
#define INFO 0x10000U
#define DMA 0x20000U
static u8 luma[2][SIZE] __attribute__((aligned(64)));
// At most 19 entropy bits per coefficient plus worst-case byte stuffing.
static u8 jpeg[2][CAPACITY];
static struct tcp_pcb *listener,*client;
static u8 request[24],header[16];
static unsigned got,toggle,eye,row,sent,length[2];
static u64 deadline,next_allowed;
static FhJpeg encoder;
static enum {IDLE,RESETTING,ARM,CAPTURE,ENCODE,TRANSMIT} phase;
static u32 decode(const u8 *p){return (u32)p[0]|(u32)p[1]<<8|(u32)p[2]<<16|(u32)p[3]<<24;}
static void store(u8 *p,u32 n){for(unsigned i=0;i<4;i++)p[i]=(u8)(n>>(8*i));}
static u32 rd(unsigned i,u32 reg){return Xil_In32(BASE(i)+reg);}
static void wr(unsigned i,u32 reg,u32 v){Xil_Out32(BASE(i)+reg,v);}
static void reset_hw(void){
    for(unsigned i=0;i<2;i++){wr(i,8,2);wr(i,DMA+0x30,4);}
    toggle=0;
}
static void lost(void *arg,err_t err){
    (void)arg;(void)err;
    client=NULL;phase=IDLE;got=0;reset_hw();
}
static void disconnect(void){
    if(client){
        struct tcp_pcb *p=client;client=NULL;
        tcp_err(p,NULL);tcp_recv(p,NULL);tcp_abort(p);
    }
    phase=IDLE;got=0;reset_hw();
}
static err_t receive(void *arg,struct tcp_pcb *p,struct pbuf *buf,err_t err){
    (void)arg;
    if(!buf || err!=ERR_OK || phase!=IDLE || got+buf->tot_len>sizeof request){
        if(buf)pbuf_free(buf);
        disconnect();return ERR_ABRT;
    }
    unsigned n=buf->tot_len;
    pbuf_copy_partial(buf,request+got,n,0);tcp_recved(p,n);pbuf_free(buf);got+=n;
    if(got==sizeof request){
        unsigned s=decode(request+4);
        if(memcmp(request,"FHR1",4) || (s!=1 && s!=2 && s!=4)){
            disconnect();return ERR_ABRT;
        }
        for(unsigned i=0;i<2;i++)
            if(decode(request+8+8*i)>4096-WIDTH*s || decode(request+12+8*i)>3072-HEIGHT*s){
                disconnect();return ERR_ABRT;
            }
        phase=ARM;
    }
    return ERR_OK;
}
static err_t accept_client(void *arg,struct tcp_pcb *p,err_t err){
    (void)arg;
    if(err!=ERR_OK || client){tcp_abort(p);return ERR_ABRT;}
    client=p;got=0;reset_hw();deadline=0;
    tcp_err(p,lost);tcp_recv(p,receive);
    // Request can already be in flight when the connection is accepted.
    phase=IDLE;
    return ERR_OK;
}
int fh_jpeg_listen(void){
#ifdef XPAR_MONITOR_A_DMA_BASEADDR
    if(listener)return 0;
    struct tcp_pcb *p=tcp_new_ip_type(IPADDR_TYPE_V4);
    if(!p)return -1;
    if(tcp_bind(p,IP_ADDR_ANY,5002)!=ERR_OK){tcp_abort(p);return -1;}
    listener=tcp_listen_with_backlog(p,1);
    if(!listener){tcp_close(p);return -1;}
    tcp_accept(listener,accept_client);
    return 0;
#else
    xil_printf("JPEG monitor unavailable in this hardware handoff.\r\n");
    return -1;
#endif
}
void fh_jpeg_stop(void){
    if(listener){
        disconnect();tcp_accept(listener,NULL);tcp_close(listener);listener=NULL;
    }
}
void fh_jpeg_poll(u64 now){
    if(!client)return;
    if(phase==ARM && now>=next_allowed){
        unsigned step=decode(request+4);
        if((rd(0,DMA+0x30)|rd(1,DMA+0x30))&4){
            if(!deadline)deadline=now+1000000;
            if(now>=deadline)disconnect();
            return;
        }
        toggle^=1;
        for(unsigned i=0;i<2;i++){
            u32 xy=decode(request+8+8*i)|(decode(request+12+8*i)<<16);
            // Release FIFO reset before arming either eye.
            wr(i,8,toggle^1);wr(i,0,xy);
            Xil_DCacheFlushRange((INTPTR)luma[i],SIZE);
            wr(i,DMA+0x34,0x7000);wr(i,DMA+0x30,1);
            wr(i,DMA+0x48,(u32)(UINTPTR)luma[i]);wr(i,DMA+0x58,SIZE);
        }
        for(unsigned i=0;i<2;i++)wr(i,8,toggle|((step==4?2:step==2?1:0)<<3));
        deadline=now+2000000;next_allowed=now+100000;phase=CAPTURE;
    }
    if(phase==CAPTURE){
        unsigned ready=0;
        for(unsigned i=0;i<2;i++){
            u32 st=rd(i,INFO),ds=rd(i,DMA+0x34);
            if((ds&0x770) || now>=deadline || ((st&7)==5*toggle && (st&8))){
                reset_hw();phase=RESETTING;deadline=now+1000000;return;
            }
            if((st&7)==5*toggle && (ds&0x1002)==0x1002)ready++;
        }
        if(ready!=2)return;
        u32 id=rd(0,INFO+8);
        if(id!=rd(1,INFO+8) || rd(0,DMA+0x58)!=SIZE || rd(1,DMA+0x58)!=SIZE){
            phase=ARM;deadline=0;return;
        }
        for(unsigned i=0;i<2;i++)Xil_DCacheInvalidateRange((INTPTR)luma[i],SIZE);
        memcpy(header,"FHJ1",4);store(header+4,id);
        eye=0;row=0;fh_jpeg_begin(&encoder,jpeg[0],CAPACITY);phase=ENCODE;
    }
    if(phase==RESETTING){
        if(!((rd(0,DMA+0x30)|rd(1,DMA+0x30))&4)){phase=ARM;deadline=0;}
        else if(now>=deadline)disconnect();
        return;
    }
    if(phase==ENCODE){
        // Yield to Ethernet and UART at each strip; never wait for socket space.
        if(!fh_jpeg_strip(&encoder,luma[eye]+row*WIDTH)){disconnect();return;}
        row+=8;
        if(row<HEIGHT)return;
        length[eye]=fh_jpeg_end(&encoder);
        if(!length[eye]){disconnect();return;}
        store(header+8+4*eye,length[eye]);
        if(!eye){eye=1;row=0;fh_jpeg_begin(&encoder,jpeg[1],CAPACITY);return;}
        sent=0;phase=TRANSMIT;
    }
    if(phase==TRANSMIT){
        unsigned total=16+length[0]+length[1];
        for(unsigned batch=0;batch<16 && sent<total;batch++){
            const u8 *ptr;unsigned end;
            if(sent<16){ptr=header+sent;end=16;}
            else if(sent<16+length[0]){ptr=jpeg[0]+(sent-16);end=16+length[0];}
            else {ptr=jpeg[1]+(sent-16-length[0]);end=total;}
            unsigned n=end-sent;
            if(n>tcp_sndbuf(client))n=tcp_sndbuf(client);
            if(n>tcp_mss(client))n=tcp_mss(client);
            if(!n)break;
            err_t e=tcp_write(client,ptr,n,TCP_WRITE_FLAG_COPY);
            if(e==ERR_MEM)break;
            if(e!=ERR_OK){disconnect();return;}
            sent+=n;
        }
        tcp_output(client);
        if(sent==total){got=0;deadline=0;phase=IDLE;}
    }
}
