#include "fh_emmc.h"
#ifndef FH_MONITOR_AMP
#include "ff.h"
#include "diskio.h"
#include "fh_sha256.h"
#include <string.h>

/* SD0 is the only SD controller enabled in FH_Test and is wired to the eMMC. */
static const char *const target[] = {"0:/BOOT.BIN", "0:/image.ub", "0:/boot.scr"};
static const char *const stage[] = {"0:/FHUPDATE/BOOT.NEW", "0:/FHUPDATE/FIT.NEW", "0:/FHUPDATE/SCRIPT.NEW"};
static const char *const backup[] = {"0:/FHUPDATE/BOOT.OLD", "0:/FHUPDATE/FIT.OLD", "0:/FHUPDATE/SCRIPT.OLD"};
static const char *const absent[] = {"0:/FHUPDATE/BOOT.NIL", "0:/FHUPDATE/FIT.NIL", "0:/FHUPDATE/SCRIPT.NIL"};
#define JOURNAL "0:/FHUPDATE/PENDING"
enum { FILE_COUNT = sizeof target / sizeof target[0] };
enum { SECTOR_BYTES = 512, MBR_ENTRIES = 446, EXT4_SUPER = 1024 };
enum UpdatePhase { BOOT_FILES, ROOTFS_DATA, ROOTFS_DIGEST, ROOTFS_VERIFY };
static FATFS fs;
static FIL file;
static int mounted, opened, index_now;
static u32 size[FILE_COUNT], remaining, read_crc[FILE_COUNT], table[256];
static u8 buf[32768] __attribute__((aligned(64)));
static u8 trailer[4 * FILE_COUNT];
static unsigned used, trailer_used;
static enum UpdatePhase phase;
static LBA_t root_start;
static u64 root_size, root_offset;
static u8 root_digest[32];
static FhSha256 root_sha;

static u32 read_le32(const u8 *p)
{
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}

static const char *check_partitions(u64 bytes)
{
    const u8 *p1 = buf + MBR_ENTRIES;
    const u8 *p2 = p1 + 16;
    DWORD media_sectors = 0;
    if (disk_ioctl(fs.pdrv, GET_SECTOR_COUNT, &media_sectors) != RES_OK ||
        disk_read(fs.pdrv, buf, 0, 1) != RES_OK)
        return "ERR cannot read eMMC partition table or capacity\n";

    u32 fat_start = read_le32(p1 + 8), fat_count = read_le32(p1 + 12);
    u32 ext_start = read_le32(p2 + 8), ext_count = read_le32(p2 + 12);
    if (buf[510] != 0x55 || buf[511] != 0xaa ||
        (p1[4] != 0x0b && p1[4] != 0x0c) || p2[4] != 0x83 ||
        !fat_start || !fat_count || !ext_count ||
        (u64)fat_start + fat_count > ext_start ||
        (u64)ext_start + ext_count > media_sectors ||
        p2[16 + 4] || p2[32 + 4] ||
        fs.fs_type != FS_FAT32 || fs.volbase != fat_start)
        return "ERR expected DOS table with FAT32 p1 and Linux p2 on eMMC\n";

    if (disk_read(fs.pdrv, buf, fat_start, 1) != RES_OK ||
        buf[11] != 0 || buf[12] != 2 || buf[19] || buf[20] ||
        read_le32(buf + 32) == 0 || read_le32(buf + 32) > fat_count)
        return "ERR FAT32 volume extends outside eMMC p1 or has invalid geometry\n";

    if (bytes < 2 * EXT4_SUPER || bytes % SECTOR_BYTES || bytes / SECTOR_BYTES > ext_count)
        return "ERR rootfs.ext4 must be sector-aligned and fit in eMMC p2\n";
    root_start = ext_start;
    return NULL;
}

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

const char *fh_emmc_begin(u32 boot, u32 fit, u32 script, u64 rootfs)
{
    mounted = 1;
    if (f_mount(&fs, "0:", 1) != FR_OK)
        return "ERR eMMC requires an existing writable FAT boot volume\n";
    if (rootfs) {
        const char *error = check_partitions(rootfs);
        if (error) return error;
    }
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
    root_size = rootfs;
    phase = BOOT_FILES;
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

static int boot_crc_matches(void)
{
    for (int i = 0; i < FILE_COUNT; ++i) {
        for (int j = 0; j < 4; ++j)
            if (trailer[4*i+j] != (u8)(read_crc[i] >> (8*j)))
                return 0;
    }
    return 1;
}

static const char *activate(void)
{
    for (int i = 0; i < FILE_COUNT; ++i) {
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

static int ext_image_fits(void)
{
    const u8 *super = buf + EXT4_SUPER;
    u32 log_block = read_le32(super + 24);
    u64 blocks = read_le32(super + 4);
    if (read_le32(super + 96) & 0x80)
        blocks |= (u64)read_le32(super + 0x150) << 32;
    return super[56] == 0x53 && super[57] == 0xef &&
           log_block <= 6 && blocks && blocks <= (root_size >> (10 + log_block));
}

static const char *receive_rootfs(const u8 *data, unsigned bytes)
{
    while (bytes && phase == ROOTFS_DATA) {
        unsigned n = sizeof buf - used;
        u64 left = root_size - root_offset - used;
        if (n > bytes) n = bytes;
        if (n > left) n = (unsigned)left;
        memcpy(buf + used, data, n);
        used += n; data += n; bytes -= n;
        if (used == sizeof buf || root_offset + used == root_size) {
            if (!root_offset && !ext_image_fits())
                return "ERR rootfs.ext4 has an invalid filesystem superblock or size\n";
            if (disk_write(fs.pdrv, buf, root_start + root_offset / SECTOR_BYTES,
                           used / SECTOR_BYTES) != RES_OK)
                return "ERR eMMC p2 write failed; rootfs may be incomplete\n";
            root_offset += used;
            used = 0;
            if (root_offset == root_size) phase = ROOTFS_DIGEST;
        }
    }
    if (phase == ROOTFS_DATA) return NULL;
    if (phase != ROOTFS_DIGEST || bytes > sizeof root_digest - used)
        return "ERR unexpected rootfs payload length\n";
    memcpy(root_digest + used, data, bytes);
    used += bytes;
    if (used == sizeof root_digest) {
        if (disk_ioctl(fs.pdrv, CTRL_SYNC, NULL) != RES_OK)
            return "ERR cannot synchronize eMMC after writing rootfs\n";
        fh_sha256_init(&root_sha);
        root_offset = 0;
        phase = ROOTFS_VERIFY;
    }
    return NULL;
}

const char *fh_emmc_poll(unsigned *percent)
{
    if (phase != ROOTFS_VERIFY) return NULL;
    u64 left = root_size - root_offset;
    unsigned n = left < sizeof buf ? (unsigned)left : sizeof buf;
    if (disk_read(fs.pdrv, buf, root_start + root_offset / SECTOR_BYTES,
                  n / SECTOR_BYTES) != RES_OK)
        return "ERR eMMC p2 readback failed\n";
    fh_sha256_blocks(&root_sha, buf, n);
    root_offset += n;
    *percent = (unsigned)(100 * root_offset / root_size);
    if (root_offset != root_size) return NULL;
    u8 digest[sizeof root_digest];
    fh_sha256_finish(&root_sha, digest);
    if (memcmp(digest, root_digest, sizeof digest))
        return "ERR eMMC p2 SHA-256 mismatch; boot update withheld\n";
    return activate();
}

const char *fh_emmc_receive(const u8 *data, unsigned bytes)
{
    if (phase != BOOT_FILES) return receive_rootfs(data, bytes);
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
    if (trailer_used != sizeof trailer) return NULL;
    if (!boot_crc_matches())
        return "ERR eMMC readback CRC mismatch; original boot files retained\n";
    if (!root_size) return activate();
    root_offset = used = 0;
    phase = ROOTFS_DATA;
    return "READY ROOTFS\n";
}
#endif
