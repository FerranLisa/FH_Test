#include "fh_sensor_control.h"
#include "fh_frame_buffer.h"
#include "fh_frame_export.h"
/* V30 fixed-exposure stereo qualification. Included by BringupTest.c so
 * both GUI CMake and the maintained command-line build use exactly this code. */
#define DUAL_GPIO ((UINTPTR)0xA00B0000U)
static u32 DualControl;
static int DualOwnershipBlocked;
static int DualLastCaptureVerified;
static u32 dual_diag(u32 bank)
{
    DualControl=(DualControl&~15U)|bank;
    cap_write(DUAL_GPIO,DualControl);return cap_read(DUAL_GPIO+8U);
}
static void dual_cmd(u32 op,u32 value)
{
    DualControl=((DualControl^0x80000000U)&0x80000000U)|(op<<28)|((value&0xFFFFFU)<<8)|1U;
    cap_write(DUAL_GPIO,DualControl);usleep(2U);
}
/* Frame_Addr_LUT is one stereo table: Master Addr plus 2 GiB gives Slave Addr.
 * Entries publish after both DMA completions, and are invalidated before overwrite.
 * Callers serialize access to the GPIO command port. For live image copies, repeat
 * lookup after copying and discard the copy if FrameID/address is no longer valid.
 * IDs never repeat before PL reset; restarting acquisition does not reset the ID. */
static void fh_frame_entry(u32 index, FhFrameAddress *entry)
{
    DualControl=cap_read(DUAL_GPIO);
    dual_cmd(6,index);
    entry->FrameID=dual_diag(2);entry->TimerPulse=dual_diag(10);
    entry->Addr=(UINTPTR)(((u64)dual_diag(5)<<32)|dual_diag(3));
    entry->Bytes=dual_diag(6);entry->Seed=dual_diag(8);
    u32 flags=dual_diag(7);entry->Valid=flags&1U;entry->ROI=(flags>>1)&1U;
    dual_cmd(7,0);
}
int fh_frame_read_slot(u32 slot, u32 sensor, FhFrameAddress *entry)
{
    if(!entry)return 0;
    *entry=(FhFrameAddress){0};
    if(slot>=256U || sensor>1U)return 0;
    fh_frame_entry(slot,entry);
    if(!entry->Valid)return 0;
    entry->Addr+=(UINTPTR)(sensor*0x80000000ULL);
    entry->Seed=(entry->Seed+sensor*113U)&1023U;
    return 1;
}
int fh_frame_lookup(u32 FrameID, u32 sensor, FhFrameAddress *entry)
{
    if(sensor>1U || !entry)return 0;
    for(u32 index=0;index<256;index++) {
        fh_frame_entry(index,entry);
        if(entry->Valid && entry->FrameID==FrameID) {
            entry->Addr+=(UINTPTR)(sensor*0x80000000ULL);
            entry->Seed=(entry->Seed+sensor*113U)&1023U;return 1;
        }
    }
    entry->Valid=0;
    return 0; /* expired, overwritten, incomplete, or never captured */
}
static void show_frame_storage_lut(void)
{
    /* Static storage avoids placing the complete inventory on the A53 stack.
     * This menu is serialized and only snapshots a stopped acquisition. */
    static FhFrameAddress entries[256];
    static u32 slots[256];
    u32 count=0;
    if(!gmax_pl_ready())return;
    DualControl=cap_read(DUAL_GPIO);
    if(dual_diag(0)!=0x3412D035U) {
        xil_printf("  Frame storage LUT hardware unavailable.\r\n");return;
    }
    if(dual_diag(1)&1U) {
        xil_printf("  Stop capture before dumping a stable LUT.\r\n");return;
    }
    for(u32 slot=0;slot<256U;slot++) {
        FhFrameAddress f;
        if(!fh_frame_read_slot(slot,0,&f))continue;
        /* FrameIDs never wrap: hardware stops at exhaustion. Sort by ID,
         * not TimerPulse, which may wrap during an acquisition. */
        u32 pos=count;
        while(pos>0 && entries[pos-1].FrameID>f.FrameID) {
            entries[pos]=entries[pos-1];slots[pos]=slots[pos-1];pos--;
        }
        entries[pos]=f;slots[pos]=slot;count++;
    }
    xil_printf("\r\nFrame storage LUT: oldest to newest; pixel addresses (hex), bytes per sensor\r\n");
    if(count) xil_printf("  Retained=%lu; oldest FrameID=%lu; newest FrameID=%lu.\r\n",
        (unsigned long)count,(unsigned long)entries[0].FrameID,
        (unsigned long)entries[count-1].FrameID);
    xil_printf("Index Slot FrameID    TimerPulse Type  Sensor0 address     Sensor1 address     Bytes\r\n");
    for(u32 index=0;index<count;index++) {
        FhFrameAddress f=entries[index];
        u64 a=(u64)f.Addr,b=a+0x80000000ULL;
        xil_printf("%3lu   %3lu %10lu %10lu %s  %08lx%08lx  %08lx%08lx  %lu\r\n",
            (unsigned long)index,(unsigned long)slots[index],
            (unsigned long)f.FrameID,(unsigned long)f.TimerPulse,f.ROI?"ROI ":"FULL",
            (unsigned long)(a>>32),(unsigned long)(a&0xFFFFFFFFULL),
            (unsigned long)(b>>32),(unsigned long)(b&0xFFFFFFFFULL),
            (unsigned long)f.Bytes);
    }
    xil_printf("  %lu valid stereo entries; other slots are empty/expired.\r\n",(unsigned long)count);
}
static void test_gmax3412_dual(void)
{
    u32 exposure_us=0,R,seconds,status,counts[2],total;
    u64 start,stop_start=0;
    int stopping=0,ok=1;
    DualLastCaptureVerified=0;
    if (!gmax_pl_ready()) return;
    for (SensorIndex=0;SensorIndex<2;++SensorIndex) {
        if (!GmaxStreamEnabled || GmaxPatternRecoveryRequired ||
            gmax_training_result_from_status(gmax_status_read())!=0xFFFFU ||
            gmax_select_image_source(0)!=XST_SUCCESS) {
            gmax_log("Sensor unavailable. Run sensor diagnostics.\r\n");
            SensorIndex=0;
            return;
        }
    }
    SensorIndex=0;
    DualControl=cap_read(DUAL_GPIO);
    if(dual_diag(0)!=0x3412D035U || (dual_diag(1)&1U)) return;
    /* U is an immediate UART command. Its first input can be the R answer
     * from the host, or the :exposure suffix from a terminal. */
    int suffix=0;
    const char *ratio_prompt="R [0..24 ROI captures after each full; Enter=24]: ";
    if(!plr_read_argument(ratio_prompt,24,&R,&suffix))return;
    if(suffix) {
        exposure_us=R;
        if(exposure_us<1 || exposure_us>1048575U) {
            xil_printf("Exposure must be 1..1048575 us. [GMAX3412-A + GMAX3412-B]\r\n");
            return;
        }
        if(!plr_read_number(ratio_prompt,24,&R))return;
    }
    if(R>24) {xil_printf("  REJECTED: R must be 0..24. [GMAX3412-A + GMAX3412-B]\r\n");return;}
    if(!suffix && (!plr_read_number("Exposure us [1..1048575; Enter=1000]: ",1000,&exposure_us) || exposure_us<1 || exposure_us>1048575))return;
    if(!plr_read_number("Run seconds [0=continuous; Enter=10; ESC stops]: ",10,&seconds))return;
    start=capture_us();
    while(!dual_diag(12)) {
        if(capture_us()-start>10000000ULL){xil_printf("  FAIL: DDR calibration timeout. [GMAX3412-A + GMAX3412-B]\r\n");return;}
        usleep(1000);
    }
    for(u32 i=0;i<4;i++) Xil_SetTlbAttributes((UINTPTR)(PLR_BASE+i*0x40000000ULL),NORM_WB_CACHE);
    xil_printf("  Ordered 2 GiB circular buffer per sensor; mixed full/ROI frames. [GMAX3412-A + GMAX3412-B]\r\n");
    dual_cmd(4,exposure_us);
    dual_cmd(1,R);
    if(dual_diag(4)||dual_diag(8)!=R||dual_diag(9)!=4000U) {ok=0;goto cleanup;}
    xil_printf("  R=%lu; one stereo trigger every 4000 us; repeat F then R ROI. [GMAX3412-A + GMAX3412-B]\r\n",(unsigned long)R);
    xil_printf("  Exposure=%lu us; 16 channels; fixed exposure; busy timer ticks are discarded. [GMAX3412-A + GMAX3412-B]\r\n",(unsigned long)exposure_us);
    start=capture_us();dual_cmd(2,0);
    if(!(dual_diag(1)&1U)){ok=0;goto cleanup;}
    do {
        status=dual_diag(1);
        if(!stopping && ((seconds && capture_us()-start>seconds*1000000ULL)||
           (XUartPs_IsReceiveData(STDIN_BASEADDRESS)&&inbyte()==27))) {
            dual_cmd(3,0);stopping=1;stop_start=capture_us();
        }
        if(stopping && (status&1U) && capture_us()-stop_start>60000000ULL) {
            DualOwnershipBlocked=1;
            xil_printf("  FAIL: controller did not release ownership. Reset/relaunch required; no DDR readback. [GMAX3412-A + GMAX3412-B]\r\n");
            return;
        }
        usleep(1000);
    } while(status&1U);
    counts[0]=dual_diag(3);counts[1]=dual_diag(5);
    xil_printf("  Pairs: full=%lu ROI=%lu elapsed=%lu us timer slots=%lu. [GMAX3412-A + GMAX3412-B]\r\n",
      (unsigned long)counts[0],(unsigned long)counts[1],(unsigned long)dual_diag(10),(unsigned long)dual_diag(11));
    if((status&7U)!=2U||dual_diag(4)||counts[0]+counts[1]==0U) {ok=0;goto cleanup;}
    total=counts[0]+counts[1];
    if(counts[0]!=(total+R)/(R+1U)||counts[1]!=total-counts[0]) {ok=0;goto cleanup;}
cleanup:
    if(!ok) xil_printf("  Controller status=0x%08lx error=%lu DMA=0x%08lx capture=0x%08lx [GMAX3412-A + GMAX3412-B]\r\n",
      (unsigned long)dual_diag(1),(unsigned long)dual_diag(4),(unsigned long)dual_diag(6),(unsigned long)dual_diag(7));
    DualLastCaptureVerified=ok && !DualOwnershipBlocked &&
        ((dual_diag(1)&1U)==0U) && ((plr_diag(1)&1U)==0U) &&
        ((burst_diag(1)&1U)==0U);
    xil_printf(ok?"  PASS: ordered stereo storage and FrameID retrieval (fixed exposure; busy slots skipped). [GMAX3412-A + GMAX3412-B]\r\n":
                  "  FAIL: dual-stream test; inspect status/error. [GMAX3412-A + GMAX3412-B]\r\n");
}

/* V31.1: Snapshot the REAL hardware Frame_Addr_LUT only after V30 has
 * stopped, verified every retained image, and released all DMA ownership.
 * Hardware LUT publication already waits for both stereo DMA completions.
 * Importing all valid slots eliminates the stale/manual software LUT issue.
 * Sorting by 32-bit FrameID is safe: V30 stops at ID exhaustion. */
static int fh_frame_import_v30_lut(void)
{
    static FhFrameAddress snapshot[256];
    FhFrameAddress row;
    u32 count=0U, i, j;
    /* Clear even when a precondition fails; never retain an earlier catalog. */
    fh_frame_reset();
    if (!DualLastCaptureVerified || DualOwnershipBlocked || !gmax_pl_ready())
        return 0;
    DualControl=cap_read(DUAL_GPIO);
    if (dual_diag(0)!=0x3412D035U ||
        (dual_diag(1)&1U) || (plr_diag(1)&1U) || (burst_diag(1)&1U) ||
        !dual_diag(12)) return 0; /* signature, no ownership, DDR calibrated */
    /* Mirror remains not-ready until every slot and final status agree. */
    for (i=0U;i<256U;++i) {
        if (!fh_frame_read_slot(i,0U,&row)) continue;
        if (row.Bytes!=(row.ROI?FH_FRAME_ROI_BYTES:FH_FRAME_FULL_BYTES) ||
            !fh_frame_address_valid((u64)row.Addr,0U,row.Bytes) ||
            !fh_frame_address_valid((u64)row.Addr+0x80000000ULL,1U,row.Bytes))
            goto fail;
        /* The LUT slot is read-only and stable now. Keep valid slots only. */
        snapshot[count++]=row;
    }
    if (count==0U) goto fail;
    /* Small fixed 256-slot table: sort by persistent FrameID, never slot idx. */
    for (i=1U;i<count;++i) {
        row=snapshot[i];
        j=i;
        while (j>0U && snapshot[j-1U].FrameID>row.FrameID) {
            snapshot[j]=snapshot[j-1U];--j;
        }
        snapshot[j]=row;
    }
    for (i=0U;i<count;++i) {
        FhFrameAddress *f=&snapshot[i];
        if (i && snapshot[i-1U].FrameID==f->FrameID) goto fail;
        if (!fh_frame_publish(f->FrameID,f->TimerPulse,
                f->ROI?FH_FRAME_ROI:FH_FRAME_FULL,
                (u64)f->Addr,(u64)f->Addr+0x80000000ULL,
                f->Bytes,f->ROI?1024U:0U)) goto fail;
    }
    /* Overlap eviction must agree EXACTLY with the HW valid-entry count. */
    if (fh_frame_count()!=count) goto fail;
    /* Recheck status before publishing this mirror to the TCP server. */
    if ((dual_diag(1)&1U) || (plr_diag(1)&1U) || (burst_diag(1)&1U))
        goto fail;
    fh_frame_set_ddr_ready(1);
    xil_printf("  V35 Ethernet: imported %lu valid stereo LUT entries (FrameID %lu..%lu). [GMAX3412-A + GMAX3412-B]\r\n",
        (unsigned long)count,(unsigned long)snapshot[0].FrameID,
        (unsigned long)snapshot[count-1U].FrameID);
    return 1;
fail:
    fh_frame_reset();
    xil_printf("  V35 Ethernet: LUT mirror rejected; network frame export DISABLED. [GMAX3412-A + GMAX3412-B]\r\n");
    return 0;
}

