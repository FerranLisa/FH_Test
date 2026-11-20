#ifndef FH_SENSOR_CONTROL_H
#define FH_SENSOR_CONTROL_H
/* Shared by application and FSBL. SPI GPIO bit assignments match GMX_A_CTRL.
 * Call only after PL configuration, sensor power/reset/clock setup and exclusive
 * ownership of this GPIO. No boot-time sensor writes are performed implicitly. */
#include "xil_io.h"
#include "sleep.h"
static inline int fh_sensor_spi_write(UINTPTR gpio, u16 address, u8 value)
{
    u32 pins,word;int bit;
    if(address>0x7FFFU)return -1;
    pins=Xil_In32(gpio)&~((1U<<3)|(1U<<7)|(1U<<8)); /* SPI mode, SCK low */
    Xil_Out32(gpio,pins|(1U<<4));usleep(2);
    Xil_Out32(gpio,pins&~(1U<<4));usleep(2); /* XCE setup >= one SCK */
    word=((u32)address<<8)|value; /* A15=0, A14..A0, D7..D0, MSB first */
    pins&=~(1U<<4);
    for(bit=23;bit>=0;bit--) {
        pins=(pins&~(1U<<8))|(((word>>bit)&1U)<<8);
        Xil_Out32(gpio,pins);usleep(1);
        Xil_Out32(gpio,pins|(1U<<7));usleep(1);
        Xil_Out32(gpio,pins);
    }
    usleep(2);Xil_Out32(gpio,pins|(1U<<4));usleep(2);
    return 0;
}
/* Datasheet digital-gain bytes are EVEN then ODD, not a Q-format multiplier. */
static inline int fh_sensor_spi_gains(UINTPTR gpio,u8 analog,u16 digital)
{
    if(fh_sensor_spi_write(gpio,0x00AE,analog))return -1;
    if(fh_sensor_spi_write(gpio,0x0A04,(u8)digital))return -1;
    return fh_sensor_spi_write(gpio,0x0904,(u8)(digital>>8));
}
static inline int fh_sensor_spi_roi(UINTPTR gpio,int roi)
{
    unsigned window;
    /* Single vertical window, WIN1_S=1024 and WIN1_L=1024 for ROI. */
    for(window=0;window<7;window++) {
        if(fh_sensor_spi_write(gpio,(u16)(0x23+4*window),0))return -1;
        if(fh_sensor_spi_write(gpio,(u16)(0x24+4*window),0))return -1;
    }
    if(fh_sensor_spi_write(gpio,0x0016,0) || fh_sensor_spi_write(gpio,0x0017,0))return -1;
    if(fh_sensor_spi_write(gpio,0x0014,0) || fh_sensor_spi_write(gpio,0x0015,0))return -1;
    if(fh_sensor_spi_write(gpio,0x001D,0))return -1;
    if(fh_sensor_spi_write(gpio,0x001E,roi?4:0))return -1;
    if(fh_sensor_spi_write(gpio,0x001F,0))return -1;
    return fh_sensor_spi_write(gpio,0x0020,roi?4:12);
}
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
