"""FH_Test bare-metal eMMC update protocol."""
import hashlib
from pathlib import Path
import zlib


def boot_files(folder):
    files = [Path(folder) / name for name in ('BOOT.BIN', 'image.ub', 'boot.scr')]
    for path in files:
        if not path.is_file() or not 0 < path.stat().st_size <= 0xffffffff:
            raise ValueError(f'Missing, empty or too large for FAT: {path}')
    return files


def rootfs_file(folder):
    path = Path(folder) / 'rootfs.ext4'
    size = path.stat().st_size
    if size < 2048 or size % 512:
        raise ValueError('rootfs.ext4 must be a raw ext4 image aligned to 512-byte sectors.')
    with path.open('rb') as source:
        source.seek(1024)
        superblock = source.read(1024)

    def value(offset):
        return int.from_bytes(superblock[offset:offset + 4], 'little')

    blocks = value(4)
    if value(96) & 0x80:
        blocks |= value(0x150) << 32
    log_block_size = value(24)
    if (len(superblock) != 1024 or superblock[56:58] != b'\x53\xef' or
            log_block_size > 6 or not 0 < blocks <= size >> (10 + log_block_size)):
        raise ValueError('rootfs.ext4 has an invalid ext4 superblock or a truncated filesystem.')
    return path


def install(sock, folder, token, cancelled, progress, *, ext4=False, phase=lambda _: None):
    boot = boot_files(folder)
    rootfs = rootfs_file(folder) if ext4 else None
    paths = [*boot, rootfs] if rootfs else boot
    sizes = [path.stat().st_size for path in paths]
    total = sum(sizes)
    upload_limit = 70 if ext4 else 99
    sent = 0
    with sock.makefile('rb') as reply:
        def read_reply():
            return reply.readline(256).decode('ascii', errors='replace').strip()

        def expect(expected):
            line = read_reply()
            if line != expected:
                raise RuntimeError(line or 'Board disconnected before confirming the update')

        def send_file(path, size, update_checksum):
            nonlocal sent
            with path.open('rb') as source:
                remaining = size
                while remaining:
                    if cancelled():
                        raise RuntimeError('Update cancelled')
                    chunk = source.read(min(remaining, 64 * 1024))
                    if not chunk:
                        raise IOError(f'{path.name} changed during transfer')
                    try:
                        sock.sendall(chunk)
                    except OSError:
                        if not cancelled():
                            try:
                                line = read_reply()
                            except OSError:
                                line = ''
                            if line.startswith('ERR '):
                                raise RuntimeError(line) from None
                        raise
                    update_checksum(chunk)
                    sent += len(chunk)
                    remaining -= len(chunk)
                    progress(upload_limit * sent // total, 100)
                if source.read(1):
                    raise IOError(f'{path.name} changed during transfer')

        command = 'EMMC3' if ext4 else 'EMMC'
        wire_sizes = ' '.join(map(str, sizes))
        sock.sendall(f'{command} {token} {wire_sizes}\n'.encode('ascii'))
        expect('READY EMMC')
        phase('Staging and checking boot files on eMMC p1.')
        checksums = []
        for path, size in zip(boot, sizes):
            crc = 0

            def update_crc(chunk):
                nonlocal crc
                crc = zlib.crc32(chunk, crc)

            send_file(path, size, update_crc)
            checksums.append(crc.to_bytes(4, 'little'))
        sock.sendall(b''.join(checksums))
        if not ext4:
            expect('OK EMMC')
        else:
            expect('READY ROOTFS')
            phase('Writing rootfs.ext4 to eMMC p2.')
            sha = hashlib.sha256()
            send_file(rootfs, sizes[-1], sha.update)
            sock.sendall(sha.digest())
            phase('Reading eMMC p2 back and checking SHA-256.')
            while True:
                line = read_reply()
                if line == 'OK EMMC':
                    return 'Verified rootfs.ext4 (SHA-256) and installed BOOT.BIN, image.ub and boot.scr on eMMC.'
                prefix = 'VERIFY ROOTFS '
                if line.startswith(prefix) and line[len(prefix):].isdigit():
                    percent = int(line[len(prefix):])
                    if 0 <= percent <= 100:
                        progress(min(99, 70 + 30 * percent // 100), 100)
                        continue
                raise RuntimeError(line or 'Board disconnected before verifying rootfs and publishing boot files')
    return 'Verified BOOT.BIN, image.ub and boot.scr on eMMC.'
