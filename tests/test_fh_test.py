"""Host-only protocol tests; no serial port, FPGA, or network required."""
from datetime import datetime
import io
from pathlib import Path
import sys
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'software' / 'host'))
from fh_test_backend import CaptureSequence, list_request, status_request, download_pair
from fh_fetch import HEADER, TRAILER, ProtocolError, fetch_image


class Socket:
    def __init__(self, data):
        self.data, self.sent = io.BytesIO(data), []

    def recv(self, count):
        return self.data.read(count)

    def sendall(self, data):
        self.sent.append(data)


class SequenceTests(unittest.TestCase):
    def test_fragmented_prompts_and_verification(self):
        seq = CaptureSequence()
        seq.feed('U: stereo capture + verify   L: valid LUT   N: Ethernet export\r\n')
        self.assertEqual(seq.start(4, 1500, 0), b'U')
        events = []
        for c in ('\r\nV30: TWO SENSORS\r\nR [0..24 ROI captures after each full; Enter=24]: '
                  '4\r\nExposure us [1..35791394; Enter=1000]: '
                  '1500\r\nRun seconds [0=continuous; Enter=10; ESC stops]: '):
            events.extend(seq.feed(c))
        self.assertEqual(events, [('write', b'4\r'), ('write', b'1500\r'), ('write', b'0\r')])
        seq.feed('0\r\n  R=4; one stereo trigger every 4000 us; repeat F then R ROI.\r\n')
        self.assertEqual(seq.state, 'capturing')
        seq.feed('  Pairs: full=1 ROI=4\r\n')
        self.assertEqual(seq.state, 'verifying')
        seq.feed('  PASS: ordered stereo storage and FrameID retrieval\r\n')
        self.assertEqual(seq.state, 'verifying')
        events = seq.feed('  V31 Ethernet: imported 5 valid stereo LUT entries (FrameID 0..4).\r\n')
        self.assertEqual(events[0][0], 'verified')
        self.assertEqual(seq.state, 'menu')

    def test_help_banner_is_not_restart(self):
        seq = CaptureSequence()
        seq.reset('menu')
        for _ in range(2):
            self.assertEqual(seq.feed(' FH_Firmware / FH_Carrier / V33\r\n'), [])
            self.assertEqual(seq.state, 'menu')

    def test_fragmented_boot_detected_once(self):
        seq = CaptureSequence()
        seq.reset('capturing')
        events = []
        for c in (' FH_Firmware / FH_Carrier / V33\r\n'
                  ' PZ-ZU7EV / Cortex-A53_0\r\n'
                  ' FH_Firmware / FH_Carrier / V33\r\n'
                  ' U   - Fixed-exposure 250 Hz timer stereo capture\r\n'):
            events.extend(seq.feed(c))
        self.assertEqual([e[0] for e in events], ['reset'])
        self.assertEqual(seq.state, 'menu')

    def test_unknown_does_not_start_or_write(self):
        seq = CaptureSequence()
        with self.assertRaises(ValueError):
            seq.start(24, 1000, 10)
        self.assertEqual(seq.feed('unrecognized prompt'), [])

    def test_blocked_does_not_return_to_menu(self):
        seq = CaptureSequence()
        seq.feed('  FAIL: controller did not release ownership. Reset/relaunch required; no DDR readback.\r\n')
        seq.feed('Export unavailable until U passes.\r\n')
        self.assertEqual(seq.state, 'blocked')

    def test_server_and_exit(self):
        seq = CaptureSequence()
        events = seq.feed('  D: GEM diagnostics; T: toggle PHY TX delay test; ESC exits; recording must be stopped.\r\n')
        self.assertEqual(events[0][0], 'export')
        seq.feed('  Ethernet RX paused; returning to UART menu.\r\n')
        self.assertEqual(seq.state, 'menu')


class ProtocolTests(unittest.TestCase):
    def test_status(self):
        sock = Socket(b'STATUS protocol=1 mode=stopped-only entries=2 ready=1 capture=0\n')
        self.assertEqual(status_request(sock)['entries'], 2)
        self.assertEqual(sock.sent, [b'STATUS\n'])

    def test_catalog_gaps_preserved(self):
        sock = Socket(b'COUNT 2\nFRAME 2 10 FULL 25165824 1000000040 1080000040 0\n'
                      b'FRAME 9 20 ROI 8388608 1001800080 1081800080 1024\n')
        self.assertEqual([r['frame_id'] for r in list_request(sock)], [2, 9])

    def test_duplicate_catalog_rejected(self):
        record = b'FRAME 2 10 ROI 8388608 1000000040 1080000040 1024\n'
        with self.assertRaises(ProtocolError):
            list_request(Socket(b'COUNT 2\n' + record + record))

    def test_incomplete_catalog_rejected(self):
        with self.assertRaises(EOFError):
            list_request(Socket(b'COUNT 1\n'))

    def packet(self, corrupt=False):
        payload = b'\x01\x00' * (4096 * 1024)
        header = HEADER.pack(b'FHIM', 1, 0, 2, 0, 3, 7, 4096, 1024, len(payload), 1024)
        crc = zlib.crc32(payload) ^ int(corrupt)
        return header + payload + TRAILER.pack(crc)

    def test_timestamped_catalog_and_image(self):
        rise = (1 << 54) + 5
        fall = rise + 120000
        utc = 1795179600123456
        catalog = f'COUNT 1\nFRAME 3 7 ROI 8388608 1000000040 1080000040 1024 {rise} {fall} {utc} 1795179600 1\n'
        sock = Socket(catalog.encode())
        row, = list_request(sock, timestamps=True)
        self.assertEqual(sock.sent, [b'TIME LIST\n'])
        packet = bytearray(self.packet())
        packet[4] = 3
        packet[HEADER.size:HEADER.size] = struct.pack('<QQQII', rise, fall, utc, 1795179600, 1)
        with tempfile.TemporaryDirectory() as folder:
            meta = fetch_image(Socket(packet), Path(folder), 3, 0, quiet=True)
        self.assertEqual(meta['sync_age_us'], 123456)
        self.assertTrue(meta['utc_time'].endswith('.123456Z'))
        self.assertEqual(datetime.fromisoformat(meta['utc_time'].replace('Z', '+00:00')),
                         datetime.fromisoformat(meta['local_time']))
        for key in ('trigger_ticks', 'end_ticks', 'utc_us'):
            self.assertEqual(meta[key], row[key])

    def test_crc_and_progress(self):
        updates = []
        with tempfile.TemporaryDirectory() as folder:
            meta = fetch_image(Socket(self.packet()), Path(folder), 3, 0,
                               progress=lambda done, total: updates.append((done, total)), quiet=True)
            self.assertEqual(meta['timer_pulse'], 7)
            self.assertEqual(updates[-1], (8388608, 8388608))
            self.assertTrue((Path(folder) / meta['data_file']).is_file())

    def test_crc_failure_and_cancellation_leave_no_raw(self):
        for corrupt, cancelled in [(True, lambda: False), (False, lambda: True)]:
            with tempfile.TemporaryDirectory() as folder:
                with self.assertRaises(ProtocolError):
                    fetch_image(Socket(self.packet(corrupt)), Path(folder), 3, 0,
                                cancelled=cancelled, quiet=True)
                self.assertEqual(list(Path(folder).iterdir()), [])

    def test_pair_failure_not_published(self):
        """A partial stereo response must never appear in the catalog cache."""
        calls = []
        def fake_fetch(sock, staging, fid, sensor, **kwargs):
            calls.append(sensor)
            if sensor == 1:
                raise ProtocolError('second sensor failed CRC')
            name = 'frame_0000000003_s0_roi.raw'
            (staging / name).write_bytes(b'test')
            (staging / name).with_suffix('.json').write_text('{}')
            return dict(data_file=name, timer_pulse=7, type='ROI', roi_y=1024, width=4096, height=1024)
        row = dict(frame_id=3, timer_pulse=7, type='ROI', roi_y=1024)
        with tempfile.TemporaryDirectory() as folder, patch('fh_test_backend.fetch_image', fake_fetch):
            with self.assertRaises(ProtocolError):
                download_pair(Socket(b''), row, folder, lambda *_: None, lambda: False)
            self.assertEqual(calls, [0, 1])
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_physical_full_frame_download(self):
        payload = b'\x65\x01' * (4096 * 3072)
        header = HEADER.pack(b'FHIM', 1, 0, 1, 0, 4, 0, 4096, 3072, len(payload), 0)
        sock = Socket(header + payload + TRAILER.pack(zlib.crc32(payload)))
        row = dict(frame_id=4, timer_pulse=0, type='FULL', roi_y=0, address1=0)
        with tempfile.TemporaryDirectory() as folder:
            images = download_pair(sock, row, folder, lambda *_: None, lambda: False)
            self.assertEqual(sock.sent, [b'GET 4 0\n'])
            self.assertEqual(len(images), 1)
            self.assertEqual(images[0][0].stat().st_size, len(payload))


if __name__ == '__main__':
    unittest.main()
