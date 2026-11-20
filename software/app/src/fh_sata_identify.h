/* Included by main.c after SATA MMIO helpers. Bare-metal identity-mapped PS
 * DDR only; buffers stay allocated even if a DMA engine cannot be stopped.
 * AHCI 1.3.1 command header/table/PRDT; ATA command 0xEC only (device to host).
 */
#ifndef FH_SATA_IDENTIFY_H
#define FH_SATA_IDENTIFY_H
static u8 SataClb[1024] __attribute__((aligned(1024)));
static u8 SataFis[256] __attribute__((aligned(256)));
static u8 SataTable[256] __attribute__((aligned(128)));
static u8 SataIdentify[512] __attribute__((aligned(64)));
static int SataDmaBlocked;

static void sata_le32(u8 *p, u32 v)
{
    p[0]=(u8)v; p[1]=(u8)(v>>8); p[2]=(u8)(v>>16); p[3]=(u8)(v>>24);
}
static u32 sata_get32(const u8 *p)
{
    return (u32)p[0] | ((u32)p[1]<<8) | ((u32)p[2]<<16) | ((u32)p[3]<<24);
}
static u16 sata_id_word(unsigned w)
{
    return (u16)((u16)SataIdentify[w*2] | ((u16)SataIdentify[w*2+1]<<8));
}
static void sata_id_string(char *out, unsigned first, unsigned words)
{
    unsigned i, n=words*2;
    for (i=0;i<n;i++) {
        u8 c=SataIdentify[first*2+(i^1U)];
        out[i]=(c>=32 && c<=126)?(char)c:'?';
    }
    while(n && out[n-1]==' ') --n;
    out[n]=0;
}
static int sata_wait_clear(u32 off, u32 mask, unsigned ms)
{
    unsigned i;
    for(i=0;i<=ms;i++) {
        if(!(sata_reg(off)&mask)) return 1;
        if(i<ms) usleep(1000U);
    }
    return 0;
}
static void sata_cache_flush(void *p, u32 bytes)
{
    Xil_DCacheFlushRange((INTPTR)p,bytes);
}
static int sata_identify_device(void)
{
    u32 saved[4], oldcmd=sata_reg(0x118), elapsed, is=0, tfd=0, transferred;
    int completed=0, stopped, valid=1;
    unsigned i;
    char model[41], serial[21], firmware[9], row[160];
    u64 sectors, bytes;
    u32 sector_bytes=512U, words;
    u16 w83, w106;
    u8 sum=0;
    if(SataDmaBlocked || (oldcmd & FH_SATA_CMD_BUSY) || sata_reg(0x134) || sata_reg(0x138)) {
        xil_printf("  IDENTIFY BLOCKED: DMA state not idle; reset/reload required if previously blocked.\r\n");
        return 0;
    }
    /* lscript.ld places these buffers in identity-mapped low PS DDR (256 MiB).
     * Reject a changed linker mapping instead of treating a virtual address as DMA. */
    if ((u64)(UINTPTR)SataClb+sizeof SataClb>0x10000000ULL ||
        (u64)(UINTPTR)SataFis+sizeof SataFis>0x10000000ULL ||
        (u64)(UINTPTR)SataTable+sizeof SataTable>0x10000000ULL ||
        (u64)(UINTPTR)SataIdentify+sizeof SataIdentify>0x10000000ULL) {
        xil_printf("  IDENTIFY BLOCKED: buffers outside the supported low PS DDR mapping.\r\n");
        return 0;
    }
    for(i=0;i<4;i++) saved[i]=sata_reg(0x100U+4U*i);
    memset(SataClb,0,sizeof SataClb); memset(SataFis,0,sizeof SataFis);
    memset(SataTable,0,sizeof SataTable); memset(SataIdentify,0,sizeof SataIdentify);
    sata_le32(SataClb,5U | (1U<<16)); /* CFL=5 DWORDs, W=0, PRDTL=1 */
    sata_le32(SataClb+8,(u32)(UINTPTR)SataTable);
    SataTable[0]=0x27; SataTable[1]=0x80; SataTable[2]=0xEC;
    sata_le32(SataTable+128,(u32)(UINTPTR)SataIdentify);
    sata_le32(SataTable+140,511U); /* byte count minus 1, 512-byte transfer */
    sata_cache_flush(SataClb,sizeof SataClb); sata_cache_flush(SataFis,sizeof SataFis);
    sata_cache_flush(SataTable,sizeof SataTable); sata_cache_flush(SataIdentify,sizeof SataIdentify);
    sata_write(0x100,(u32)(UINTPTR)SataClb); sata_write(0x104,0U);
    sata_write(0x108,(u32)(UINTPTR)SataFis); sata_write(0x10C,0U);
    sata_write(0x130,sata_reg(0x130)); sata_write(0x110,sata_reg(0x110));
    xil_printf("  IDENTIFY DEVICE: command EC, 512 bytes into PS DDR; timeout 5000 ms.\r\n");
    sata_write(0x118,oldcmd | 0x10U); /* receive FIS before starting commands */
    if (!sata_wait_clear(0x120,0x88U,1000U)) {
        xil_printf("  IDENTIFY FAIL: task-file BSY/DRQ did not clear.\r\n");
        goto cleanup;
    }
    sata_write(0x118,(oldcmd | 0x11U));
    if ((sata_reg(0x118)&0x11U)!=0x11U) {
        xil_printf("  IDENTIFY FAIL: engine enable did not latch.\r\n");
        goto cleanup;
    }
    sata_write(0x138,1U); /* command slot 0; only command issued by this test */
    for(elapsed=0;elapsed<=5000U;elapsed++) {
        is=sata_reg(0x110); tfd=sata_reg(0x120);
        if((is & 0x7D000000U) || (tfd & 0x21U) || (sata_reg(0x128)&15U)!=3U) break;
        if(!(sata_reg(0x138)&1U)) { completed=1; break; }
        if(elapsed<5000U) usleep(1000U);
    }
    xil_printf("  IDENTIFY completion=%u elapsed=%lu ms PxIS=%08lx PxTFD=%08lx PxSERR=%08lx\r\n",
        (unsigned)completed,(unsigned long)elapsed,(unsigned long)is,
        (unsigned long)tfd,(unsigned long)sata_reg(0x130));
cleanup:
    sata_write(0x118,sata_reg(0x118)&~1U);
    stopped=sata_wait_clear(0x118,0x8000U,1000U);
    if(stopped) {
        sata_write(0x118,sata_reg(0x118)&~0x10U);
        stopped=sata_wait_clear(0x118,0x4000U,1000U);
    }
    if(!stopped || sata_reg(0x138) || sata_reg(0x134)) {
        SataDmaBlocked=1;
        xil_printf("  IDENTIFY FAIL: DMA/command ownership unresolved. Buffers retained; reset/reload before retry.\r\n");
        return 0;
    }
    for(i=0;i<4;i++) sata_write(0x100U+4U*i,saved[i]);
    sata_write(0x118,oldcmd & ~0x11U);
    Xil_DCacheInvalidateRange((INTPTR)SataClb,sizeof SataClb);
    Xil_DCacheInvalidateRange((INTPTR)SataIdentify,sizeof SataIdentify);
    transferred=sata_get32(SataClb+4);
    if(!completed || transferred!=512U) {
        xil_printf("  IDENTIFY FAIL: command error/timeout or incomplete transfer (%lu/512 bytes).\r\n",
                   (unsigned long)transferred);
        return 0;
    }
    if(sata_id_word(0)==0U || sata_id_word(0)==0xFFFFU || (sata_id_word(0)&0x8000U)) valid=0;
    if(SataIdentify[510]==0xA5U) {
        for(i=0;i<512;i++) sum=(u8)(sum+SataIdentify[i]);
        if(sum) valid=0;
        xil_printf("  IDENTIFY checksum: %s\r\n",sum?"FAIL":"PASS");
    } else xil_printf("  IDENTIFY checksum: not supplied by device.\r\n");
    if(!valid) { xil_printf("  IDENTIFY FAIL: invalid ATA data.\r\n"); return 0; }
    sata_id_string(serial,10,10); sata_id_string(firmware,23,4); sata_id_string(model,27,20);
    w83=sata_id_word(83); w106=sata_id_word(106);
    if((w83&0xC400U)==0x4400U)
        sectors=(u64)sata_id_word(100) | ((u64)sata_id_word(101)<<16) |
                ((u64)sata_id_word(102)<<32) | ((u64)sata_id_word(103)<<48);
    else sectors=(u64)sata_id_word(60) | ((u64)sata_id_word(61)<<16);
    if((w106&0xD000U)==0x5000U) {
        words=(u32)sata_id_word(117) | ((u32)sata_id_word(118)<<16);
        if(words<=256U || words>0x7FFFFFFFU) valid=0;
        else sector_bytes=words*2U;
    }
    if(!(sata_id_word(49)&0x0200U) || !sectors ||
       sectors>0x0000FFFFFFFFFFFFULL || sectors>(~(u64)0)/sector_bytes) valid=0;
    xil_printf("  Model: %s\r\n  Serial: %s\r\n  Firmware: %s\r\n",model,serial,firmware);
    if(!valid) { xil_printf("  IDENTIFY FAIL: invalid capacity fields.\r\n"); return 0; }
    bytes=sectors*sector_bytes;
    snprintf(row,sizeof row,"  Capacity: %llu bytes (%llu MiB); %llu logical sectors x %lu bytes\r\n",
        (unsigned long long)bytes,(unsigned long long)(bytes/1048576ULL),
        (unsigned long long)sectors,(unsigned long)sector_bytes);
    xil_printf("%s",row);
    xil_printf("  PASS: read-only ATA IDENTIFY completed; disk sectors were not read or written.\r\n");
    return 1;
}
#endif