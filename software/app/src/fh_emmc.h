#ifndef FH_EMMC_H
#define FH_EMMC_H
#include "xil_types.h"
const char *fh_emmc_begin(u32 boot, u32 fit, u32 script, u64 rootfs);
const char *fh_emmc_receive(const u8 *data, unsigned bytes);
const char *fh_emmc_poll(unsigned *percent);
void fh_emmc_close(void);
#endif
