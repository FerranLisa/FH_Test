#ifndef FH_ETH_SERVER_H
#define FH_ETH_SERVER_H
#include "xil_types.h"
#include <stddef.h>
void time_service(void);
void fh_rtc_status(char *buf, size_t size);

/* Blocking standalone/raw-lwIP session, entered by UART N; ESC exits.
 * The PS-side GEM must be enabled in Vivado and lwip220 RAW_API in BSP.
 */
#define FH_ETH_PORT 5001U
int fh_eth_serve(const u8 mac[6]);
void fh_eth_phy_observe(void);

#endif
