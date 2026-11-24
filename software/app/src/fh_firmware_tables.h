#ifndef FH_FIRMWARE_TABLES_H
#define FH_FIRMWARE_TABLES_H
#include "xil_io.h"
static inline void fh_sensor_lut_write(UINTPTR base,u8 index,u32 cycles,
                                      u8 flash,u8 analog,u16 digital,u8 roi)
{
    Xil_Out32(base+0x74,index);
    Xil_Out32(base+0x78,cycles);
    Xil_Out32(base+0x7C,(flash&1U)|((u32)analog<<1)|((u32)digital<<9));
    Xil_Out32(base+0x80,roi&1U);
}
static inline int fh_sensor_lut_commit(UINTPTR base,unsigned capture_length,unsigned readout_length)
{
    if(capture_length<1 || capture_length>256 || readout_length<1 || readout_length>256)return -1;
    if(Xil_In32(base+8)&6U)return -1;
    Xil_Out32(base+0x84,(capture_length&255U)|((readout_length&255U)<<8));
    return Xil_In32(base+0x84)==((capture_length&255U)|((readout_length&255U)<<8))?0:-1;
}
#endif
