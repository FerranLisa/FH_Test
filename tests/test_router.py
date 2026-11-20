import io
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'software' / 'host'))
from fh_route import Route, validate_geometry
from fh_fetch import HEADER, ProtocolError, fetch_image
from fh_test_backend import download_pair


class Socket:
    def __init__(self, data): self.data, self.command = io.BytesIO(data), b''
    def recv(self, n): return self.data.read(n)
    def sendall(self, data): self.command += data


def packet(sensor=0, kind=2, ox=13, oy=1041, corrupt=False):
    payload = struct.pack('<6H', 1, 1023, 2, 3, 4, 5)
    return (HEADER.pack(b'FHIM', 2, sensor, kind, 2, 7, 99, 3, 2, len(payload), 1024 if kind == 2 else 0)
            + struct.pack('<4I', ox, oy, 1, 1) + payload
            + struct.pack('<I', zlib.crc32(payload) ^ int(corrupt)))


class RouterTests(unittest.TestCase):
    def test_subsampling(self):
        for n in (1, 2, 4, 8, 16):
            route = Route(1, n)
            self.assertEqual(route.geometry('FULL'), (4096//n, 3072//n))
            with self.assertRaises(ValueError): route.geometry('ROI')
        with self.assertRaises(ValueError): Route(1, 3).validate()

    def test_bounds(self):
        for coords in ((0,0,0,1), (1,2,0,3), (0,0,4097,1024), (0,0,1,1025)):
            with self.assertRaises(ValueError): Route(2, 1, *coords).validate()
        self.assertEqual(Route(2, 1, 4095, 1023, 4096, 1024).geometry('ROI'), (1,1))

    def test_pair_both_source_types_and_variant_directories(self):
        route = Route(2, 1, 13, 17, 16, 19)
        for kind in (1,2):
            row = dict(frame_id=7, timer_pulse=99, type='FULL' if kind==1 else 'ROI', roi_y=0 if kind==1 else 1024)
            sock = Socket(packet(0,kind)+packet(1,kind))
            with tempfile.TemporaryDirectory() as d:
                result = download_pair(sock,row,d,lambda *_:None,lambda:False,route)
                self.assertEqual(sock.command, b'ROUTEPAIR 7 2 1 13 17 16 19\n')
                self.assertEqual(result[0][0].parent.name, route.key)
                self.assertEqual(result[1][1]['origin_y'],1041)
                self.assertEqual(result[0][0].stat().st_size,12)

    def test_bad_crc_and_mismatched_geometry_not_published(self):
        route=Route(2,1,13,17,16,19)
        row=dict(frame_id=7,timer_pulse=99,type='ROI',roi_y=1024)
        for second in (packet(1,corrupt=True),packet(1,ox=14)):
            with tempfile.TemporaryDirectory() as d:
                with self.assertRaises(ProtocolError):
                    download_pair(Socket(packet()+second),row,d,lambda *_:None,lambda:False,route)
                self.assertEqual(list(Path(d).rglob('*.raw')),[])

    def test_invalid_wire_geometry(self):
        with self.assertRaises(ValueError): validate_geometry(2,2,2,4,1,1024,4094,1024,1,1)
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ProtocolError): fetch_image(Socket(packet(oy=2048)),Path(d),quiet=True)


if __name__ == '__main__': unittest.main()
