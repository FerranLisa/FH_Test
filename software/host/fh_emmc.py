"""FH_Test bare-metal eMMC update protocol."""
from pathlib import Path
import zlib


def boot_files(folder):
    files = [Path(folder) / name for name in ('BOOT.BIN', 'image.ub', 'boot.scr')]
    for path in files:
        if not path.is_file() or not 0 < path.stat().st_size <= 0xffffffff:
            raise ValueError(f'Missing, empty or too large for FAT: {path}')
    return files


def install(sock, folder, token, cancelled, progress):
    paths = boot_files(folder)
    sizes = [path.stat().st_size for path in paths]
    total = sum(sizes)
    sent = 0
    with sock.makefile('rb') as reply:
        def expect(expected):
            line = reply.readline(256).decode('ascii', errors='replace').strip()
            if line != expected:
                raise RuntimeError(line or 'Board disconnected before confirming the update')

        sock.sendall(f'EMMC {token} {sizes[0]} {sizes[1]} {sizes[2]}\n'.encode('ascii'))
        expect('READY EMMC')
        checksums = []
        for path, size in zip(paths, sizes):
            crc = 0
            with path.open('rb') as source:
                remaining = size
                while remaining:
                    if cancelled():
                        raise RuntimeError('Update cancelled')
                    chunk = source.read(min(remaining, 64 * 1024))
                    if not chunk:
                        raise IOError(f'{path.name} changed during transfer')
                    sock.sendall(chunk)
                    crc = zlib.crc32(chunk, crc)
                    sent += len(chunk)
                    remaining -= len(chunk)
                    progress(min(99, 100 * sent // total), 100)
                if source.read(1):
                    raise IOError(f'{path.name} changed during transfer')
            checksums.append(crc.to_bytes(4, 'little'))
        sock.sendall(b''.join(checksums))
        expect('OK EMMC')
    return 'Verified BOOT.BIN, image.ub and boot.scr on eMMC.'
