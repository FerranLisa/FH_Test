#ifndef FH_JPEG_MONITOR_H
#define FH_JPEG_MONITOR_H
#include "xil_types.h"
int fh_monitor_net_start(const u8 mac[6]);
void fh_monitor_net_poll(void);
void fh_monitor_net_stop(void);
int fh_jpeg_listen(void);
void fh_jpeg_poll(u64 now);
void fh_jpeg_stop(void);
#endif
