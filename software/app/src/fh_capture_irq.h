#ifndef FH_CAPTURE_IRQ_H
#define FH_CAPTURE_IRQ_H

#include "xinterrupt_wrap.h"
#include "xttcps.h"

#define FH_DMA_IOC 0x1000U
#define FH_DMA_ERR_IRQ 0x4000U
#define FH_DMA_ERRORS 0x770U
#define FH_DMA_PENDING 0x7000U

typedef struct {
    UINTPTR base;
    u32 irq;
    UINTPTR parent;
    volatile u32 status;
} FhCaptureIrq;

static FhCaptureIrq CaptureIrq[2] = {
    {XPAR_GMAX_CAPTURE_DMA_BASEADDR, XPAR_GMAX_CAPTURE_DMA_INTERRUPTS,
     XPAR_GMAX_CAPTURE_DMA_INTERRUPT_PARENT, 0},
    {XPAR_GMAX_CAPTURE_DMA_B_BASEADDR, XPAR_GMAX_CAPTURE_DMA_B_INTERRUPTS,
     XPAR_GMAX_CAPTURE_DMA_B_INTERRUPT_PARENT, 0}
};
static XTtcPs CaptureWakeTimer;

static void capture_dma_irq(void *ref)
{
    FhCaptureIrq *channel = ref;
    u32 status = cap_read(channel->base + 0x34U);
    if (!(status & FH_DMA_PENDING)) return;
    channel->status |= status;
    cap_write(channel->base + 0x34U, status & FH_DMA_PENDING);
    __asm__ volatile("dsb sy; sev" ::: "memory");
}

static void capture_timer_irq(void *ref)
{
    XTtcPs *timer = ref;
    u32 pending = XTtcPs_GetInterruptStatus(timer);
    XTtcPs_ClearInterruptStatus(timer, pending);
    __asm__ volatile("dsb sy; sev" ::: "memory");
}

static int capture_irq_init(void)
{
    static int ready;
    if (ready) return XST_SUCCESS;
    XTtcPs_Config *config = XTtcPs_LookupConfig(XPAR_TTC2_BASEADDR);
    XInterval interval;
    u8 prescaler;
    if (!config || XTtcPs_CfgInitialize(&CaptureWakeTimer, config, config->BaseAddress) != XST_SUCCESS)
        return XST_FAILURE;
    XTtcPs_Stop(&CaptureWakeTimer);
    XTtcPs_SetOptions(&CaptureWakeTimer, XTTCPS_OPTION_INTERVAL_MODE | XTTCPS_OPTION_WAVE_DISABLE);
    XTtcPs_CalcIntervalFromFreq(&CaptureWakeTimer, 100U, &interval, &prescaler);
    if (!interval) return XST_FAILURE;
    XTtcPs_SetPrescaler(&CaptureWakeTimer, prescaler);
    XTtcPs_SetInterval(&CaptureWakeTimer, interval);
    if (XSetupInterruptSystem(&CaptureWakeTimer, capture_timer_irq, XPAR_TTC2_INTERRUPTS,
                              XPAR_TTC2_INTERRUPT_PARENT, XINTERRUPT_DEFAULT_PRIORITY) != XST_SUCCESS)
        return XST_FAILURE;
    for (unsigned i = 0; i < 2; ++i) {
        FhCaptureIrq *ch = &CaptureIrq[i];
        if (XSetupInterruptSystem(ch, capture_dma_irq, ch->irq, ch->parent,
                                  XINTERRUPT_DEFAULT_PRIORITY) != XST_SUCCESS)
            return XST_FAILURE;
        XDisableIntrId(ch->irq, ch->parent);
    }
    ready = 1;
    return XST_SUCCESS;
}

static int capture_wait_irqs(unsigned armed, u64 deadline)
{
    int ok = 0;
    for (;;) {
        unsigned done = 0;
        for (unsigned i = 0; i < 2; ++i) {
            if (!(armed & (1U << i))) continue;
            u32 status = CaptureIrq[i].status;
            if (status & (FH_DMA_ERR_IRQ | FH_DMA_ERRORS)) goto finish;
            if (status & FH_DMA_IOC) done |= 1U << i;
        }
        if (done == armed) { ok = 1; break; }
        if (capture_us() >= deadline) break;
        /* SEV from either ISR also covers an interrupt just before WFE. */
        __asm__ volatile("wfe" ::: "memory");
    }
finish:
    if (!ok)
        xil_printf("Capture IRQ failure/timeout: mask=%x DMA A=%08x B=%08x\r\n",
                   armed, CaptureIrq[0].status, CaptureIrq[1].status);
    return ok;
}
#endif
