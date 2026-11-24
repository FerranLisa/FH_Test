#ifndef FH_EMMC_H
#define FH_EMMC_H
#include "xil_types.h"
const char *fh_emmc_begin(u32 boot, u32 fit, u32 script);
const char *fh_emmc_receive(const u8 *data, unsigned bytes);
void fh_emmc_close(void);
#endif
