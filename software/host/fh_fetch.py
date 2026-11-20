#!/usr/bin/env python3
"""FH_Bringup V31 TCP image receiver (stdlib-only, Python >=3.9).

Example:
  python fh_fetch.py --host 192.168.1.123 status
  python fh_fetch.py --host 192.168.1.123 list
  python fh_fetch.py --host 192.168.1.123 pair 2325 -o images/
  python fh_fetch.py --host 192.168.1.123 get 2325 0 -o images/
  python fh_fetch.py --host 192.168.1.123 range 2320 4 1 -o images/

Image is raw uint16 LE row-major 4096 x (3072 or 1024), not 10-bit packed.
"""
from __future__ import annotations
import argparse
import json
import socket
import struct
import sys
import zlib
from pathlib import Path
from fh_route import validate_geometry

HEADER = struct.Struct('<4sBBBBIIIIII')  # 32 bytes
TRAILER = struct.Struct('<I')
MAX_PAYLOAD = 4096 * 3072 * 2

class ProtocolError(RuntimeError):
    pass


def recv_exact(sock: socket.socket, count: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < count:
        part = sock.recv(min(65536, count - len(chunks)))
        if not part:
            raise ProtocolError(f'premature end of TCP stream ({len(chunks)}/{count} bytes)')
        chunks.extend(part)
    return bytes(chunks)


def read_line(sock: socket.socket, max_length: int = 4096, prefix: bytes = b'') -> str:
    # byte-by-byte only for short text lines; images are read in large chunks.
    buf = bytearray(prefix)
    while not buf.endswith(b'\n'):
        if len(buf) >= max_length:
            raise ProtocolError('response line is too long')
        c = sock.recv(1)
        if not c:
            if not buf:
                raise EOFError('end of response')
            raise ProtocolError('truncated response line')
        buf.extend(c)
    return buf.decode('ascii').strip()


def fetch_image(sock: socket.socket, out: Path, expected_id=None, expected_sensor=None,
                progress=None, cancelled=None, quiet=False) -> dict:
    first = recv_exact(sock, 4)
    if first != b'FHIM':
        if first.startswith(b'ERR '):
            raise ProtocolError(read_line(sock, prefix=first))
        raise ProtocolError(f'unknown image response magic {first!r}')
    b = first + recv_exact(sock, HEADER.size - 4)
    magic, version, sensor, kind, flags, fid, pulse, width, height, length, roi_y = HEADER.unpack(b)
    if version not in (1, 2) or sensor not in (0, 1) or kind not in (1, 2):
        raise ProtocolError('unsupported protocol/version/image fields')
    ox, oy, sx, sy = (0, roi_y, 1, 1)
    if version == 2:
        ox, oy, sx, sy = struct.unpack('<IIII', recv_exact(sock, 16))
    try:
        validate_geometry(version, flags, kind, width, height, roi_y, ox, oy, sx, sy)
    except ValueError as exc:
        raise ProtocolError(str(exc)) from exc
    if length != width * height * 2 or length > MAX_PAYLOAD:
        raise ProtocolError('invalid image geometry / byte length')
    if roi_y != (0 if kind == 1 else 1024):
        raise ProtocolError('invalid V30 ROI origin')
    if expected_id is not None and (fid != expected_id or sensor != expected_sensor):
        raise ProtocolError('image identity does not match the request')
    out.mkdir(parents=True, exist_ok=True)
    name = f'frame_{fid:010d}_s{sensor}_{"full" if kind == 1 else "roi"}'
    temp = out / (name + '.partial')
    path = out / (name + '.raw')
    crc = 0
    remaining = length
    try:
        with temp.open('wb') as fd:
            while remaining:
                if cancelled is not None and cancelled():
                    raise ProtocolError('download cancelled')
                block = recv_exact(sock, min(65536, remaining))
                fd.write(block)
                crc = zlib.crc32(block, crc)
                remaining -= len(block)
                if progress is not None:
                    progress(length - remaining, length)
        expected, = TRAILER.unpack(recv_exact(sock, TRAILER.size))
        if crc != expected:
            raise ProtocolError(f'CRC mismatch: computed {crc:08X}, received {expected:08X}')
        temp.replace(path)
    except Exception:
        temp.unlink(missing_ok=True)
        raise
    meta = {
        'protocol': version, 'frame_id': fid, 'timer_pulse': pulse,
        'sensor': sensor, 'type': 'FULL' if kind == 1 else 'ROI',
        'width': width, 'height': height, 'roi_y': roi_y,
        'router_mode': flags, 'origin_x': ox, 'origin_y': oy, 'step_x': sx, 'step_y': sy,
        'bytes_per_pixel': 2, 'pixel_type': 'uint16', 'endianness': 'little',
        'data_file': path.name, 'crc32': f'{crc:08X}',
    }
    (out / (name + '.json')).write_text(json.dumps(meta, indent=2) + '\n', encoding='utf-8')
    if not quiet:
        print(f"FrameID={fid} sensor={sensor} {width}x{height} {length:,} bytes -> {path} (CRC OK)")
    return meta


def run(host: str, port: int, command: str, output: Path, expected_images: int) -> None:
    with socket.create_connection((host, port), timeout=10) as sock:
        sock.settimeout(30)
        sock.sendall(command.encode('ascii') + b'\n')
        if expected_images:
            fields = command.split()
            first_id = int(fields[1])
            for index in range(expected_images):
                if fields[0] == 'PAIR':
                    fid, sensor = first_id, index
                elif fields[0] == 'RANGE':
                    fid, sensor = first_id + index, int(fields[3])
                else:
                    fid, sensor = first_id, int(fields[2])
                fetch_image(sock, output, fid, sensor)
            return
        lines = []
        while True:
            try:
                line = read_line(sock)
            except EOFError:
                break
            lines.append(line)
            print(line)
            if line.startswith('ERR '):
                raise ProtocolError(line)
        if not lines:
            raise ProtocolError('empty server response')
        if command == 'STATUS' and (len(lines) != 1 or not lines[0].startswith('STATUS ')):
            raise ProtocolError('invalid STATUS response')
        if command == 'LIST':
            if not lines[0].startswith('COUNT '):
                raise ProtocolError('missing LIST count')
            count = int(lines[0][6:])
            if not 0 <= count <= 256 or len(lines) != count + 1:
                raise ProtocolError('truncated or invalid LIST response')
            if any(len(line.split()) != 8 or not line.startswith('FRAME ') for line in lines[1:]):
                raise ProtocolError('invalid LIST record')


def frame_id_arg(value: str) -> int:
    n = int(value)
    if not 0 <= n <= 0xFFFFFFFF:
        raise argparse.ArgumentTypeError('FrameID must be in 0..4294967295')
    return n


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--host', default='192.168.1.123')
    ap.add_argument('--port', type=int, default=5001)
    sp = ap.add_subparsers(dest='op', required=True)
    sp.add_parser('status')
    sp.add_parser('list')
    get = sp.add_parser('get')
    get.add_argument('frame_id', type=frame_id_arg)
    get.add_argument('sensor', type=int, choices=(0, 1))
    get.add_argument('-o', '--output', type=Path, default=Path('frames'))
    pair = sp.add_parser('pair')
    pair.add_argument('frame_id', type=frame_id_arg)
    pair.add_argument('-o', '--output', type=Path, default=Path('frames'))
    rng = sp.add_parser('range')
    rng.add_argument('first_frame_id', type=frame_id_arg)
    rng.add_argument('count', type=int, choices=range(1, 9), metavar='{1..8}')
    rng.add_argument('sensor', type=int, choices=(0, 1))
    rng.add_argument('-o', '--output', type=Path, default=Path('frames'))
    args = ap.parse_args(argv)
    if args.op == 'status':
        command, expected, output = 'STATUS', 0, Path('.')
    elif args.op == 'list':
        command, expected, output = 'LIST', 0, Path('.')
    elif args.op == 'get':
        command, expected, output = f'GET {args.frame_id} {args.sensor}', 1, args.output
    elif args.op == 'pair':
        command, expected, output = f'PAIR {args.frame_id}', 2, args.output
    else:
        if args.first_frame_id + args.count > 0x100000000:
            ap.error('range exceeds the 32-bit FrameID space')
        command, expected, output = f'RANGE {args.first_frame_id} {args.count} {args.sensor}', args.count, args.output
    try:
        run(args.host, args.port, command, output, expected)
    except (ProtocolError, EOFError, OSError, ValueError) as e:
        print(f'ERROR: {e}', file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
