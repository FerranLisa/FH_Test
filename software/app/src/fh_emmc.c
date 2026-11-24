#include "fh_emmc.h"
#ifndef FH_MONITOR_AMP
#include "ff.h"
#include <string.h>

/* SD0 is the only SD controller enabled in FH_Test and is wired to the eMMC. */
static const char *const target[] = {"0:/BOOT.BIN", "0:/image.ub", "0:/boot.scr"};
static const char *const stage[] = {"0:/FHUPDATE/BOOT.NEW", "0:/FHUPDATE/FIT.NEW", "0:/FHUPDATE/SCRIPT.NEW"};
static const char *const backup[] = {"0:/FHUPDATE/BOOT.OLD", "0:/FHUPDATE/FIT.OLD", "0:/FHUPDATE/SCRIPT.OLD"};
static const char *const absent[] = {"0:/FHUPDATE/BOOT.NIL", "0:/FHUPDATE/FIT.NIL", "0:/FHUPDATE/SCRIPT.NIL"};
#define JOURNAL "0:/FHUPDATE/PENDING"
enum { FILE_COUNT = sizeof target / sizeof target[0] };
static FATFS fs;
static FIL file;
static int mounted, opened, index_now;
static u32 size[FILE_COUNT], remaining, read_crc[FILE_COUNT], table[256];
static u8 buf[32768] __attribute__((aligned(64)));
static u8 trailer[4 * FILE_COUNT];
static unsigned used, trailer_used;

static int remove_if_present(const char *path)
{
    FRESULT r = f_unlink(path);
    return r == FR_OK || r == FR_NO_FILE;
}

static FRESULT probe(const char *path)
{
    FILINFO info;
    return f_stat(path, &info);
}

static int mark(const char *path)
{
    FIL marker;
    return f_open(&marker, path, FA_CREATE_NEW | FA_WRITE) == FR_OK &&
           f_close(&marker) == FR_OK;
}

/* Replayable rollback if power failed between the FAT renames. */
static int recover(void)
{
    FRESULT pending = probe(JOURNAL);
    if (pending == FR_NO_FILE) return 1;
    if (pending != FR_OK) return 0;
    for (int i = 0; i < FILE_COUNT; ++i) {
        FRESULT old = probe(backup[i]), nil = probe(absent[i]);
        if (old != FR_OK && old != FR_NO_FILE) return 0;
        if (nil != FR_OK && nil != FR_NO_FILE) return 0;
        if (old == FR_OK || nil == FR_OK) {
            if (!remove_if_present(target[i])) return 0;
            if (old == FR_OK && f_rename(backup[i], target[i]) != FR_OK) return 0;
        }
    }
    return remove_if_present(JOURNAL);
}

void fh_emmc_close(void)
{
    if (opened) f_close(&file);
    if (mounted) f_mount(NULL, "0:", 0);
    opened = mounted = 0;
}

static int open_stage(void)
{
    remaining = size[index_now];
    used = 0;
    opened = f_open(&file, stage[index_now], FA_WRITE | FA_CREATE_ALWAYS) == FR_OK;
    return opened;
}

const char *fh_emmc_begin(u32 boot, u32 fit, u32 script)
{
    mounted = 1;
    if (f_mount(&fs, "0:", 1) != FR_OK)
        return "ERR eMMC requires an existing writable FAT boot volume\n";
    FRESULT r = f_mkdir("0:/FHUPDATE");
    if ((r != FR_OK && r != FR_EXIST) || !recover())
        return "ERR cannot prepare eMMC update directory or recover previous update\n";
    for (int i = 0; i < FILE_COUNT; ++i) {
        if (!remove_if_present(backup[i]) || !remove_if_present(absent[i]) ||
            !remove_if_present(stage[i])) return "ERR cannot clear eMMC staging files\n";
    }
    for (u32 i = 0; i < 256; ++i) {
        u32 c = i;
        for (unsigned j = 0; j < 8; ++j) c = (c >> 1) ^ ((c & 1) ? 0xedb88320U : 0);
        table[i] = c;
    }
    size[0] = boot;
    size[1] = fit;
    size[2] = script;
    index_now = trailer_used = 0;
    return open_stage() ? NULL : "ERR cannot open eMMC boot staging file\n";
}

static int verify_stage(void)
{
    if (f_close(&file) != FR_OK) return 0;
    opened = 0;
    if (f_open(&file, stage[index_now], FA_READ) != FR_OK) return 0;
    opened = 1;
    if (f_size(&file) != size[index_now]) return 0;
    u32 crc = 0xffffffffU;
    UINT n;
    do {
        if (f_read(&file, buf, sizeof buf, &n) != FR_OK) return 0;
        for (UINT j = 0; j < n; ++j) crc = table[(crc ^ buf[j]) & 255] ^ (crc >> 8);
    } while (n == sizeof buf);
    read_crc[index_now] = ~crc;
    if (f_close(&file) != FR_OK) return 0;
    opened = 0;
    return 1;
}

static const char *activate(void)
{
    for (int i = 0; i < FILE_COUNT; ++i) {
        for (int j = 0; j < 4; ++j)
            if (trailer[4*i+j] != (u8)(read_crc[i] >> (8*j)))
                return "ERR eMMC readback CRC mismatch; original boot files retained\n";
        FRESULT r = probe(target[i]);
        if (r != FR_OK && (r != FR_NO_FILE || !mark(absent[i])))
            return "ERR cannot inspect original eMMC boot files\n";
    }
    if (!mark(JOURNAL)) return "ERR cannot create eMMC update journal\n";
    for (int i = FILE_COUNT - 1; i >= 0; --i) {
        FRESULT r = f_rename(target[i], backup[i]);
        if ((r != FR_OK && r != FR_NO_FILE) || f_rename(stage[i], target[i]) != FR_OK)
            return recover() ? "ERR update failed; original boot files restored\n" :
                               "ERR rollback incomplete; retry before reboot\n";
    }
    if (!remove_if_present(JOURNAL)) return "ERR commit incomplete; retry before reboot\n";
    for (int i = 0; i < FILE_COUNT; ++i) {
        remove_if_present(backup[i]);
        remove_if_present(absent[i]);
    }
    return "OK EMMC\n";
}

const char *fh_emmc_receive(const u8 *data, unsigned bytes)
{
    while (bytes && index_now < FILE_COUNT) {
        unsigned n = sizeof buf - used;
        if (n > bytes) n = bytes;
        if (n > remaining) n = remaining;
        memcpy(buf + used, data, n);
        used += n; data += n; bytes -= n; remaining -= n;
        if (used == sizeof buf || !remaining) {
            UINT written;
            if (f_write(&file, buf, used, &written) != FR_OK || written != used)
                return "ERR eMMC write failed; check free space\n";
            used = 0;
        }
        if (!remaining) {
            if (!verify_stage()) return "ERR eMMC readback failed\n";
            if (++index_now < FILE_COUNT && !open_stage()) return "ERR cannot open eMMC staging file\n";
        }
    }
    if (bytes > sizeof trailer - trailer_used) return "ERR unexpected eMMC payload length\n";
    memcpy(trailer + trailer_used, data, bytes);
    trailer_used += bytes;
    return trailer_used == sizeof trailer ? activate() : NULL;
}
#endif
