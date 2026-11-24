import io
from pathlib import Path
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'software/host'))
from fh_emmc import install


class Endpoint:
    def __init__(self, reply):
        self.reply = reply
        self.received = bytearray()

    def makefile(self, mode):
        return io.BytesIO(self.reply)

    def sendall(self, data):
        self.received.extend(data)


class EmmcTests(unittest.TestCase):
    def test_missing_or_empty_boot_script_prevents_transfer(self):
        board = Endpoint(b'')
        with tempfile.TemporaryDirectory() as folder:
            for name in ('BOOT.BIN', 'image.ub'):
                (Path(folder) / name).write_bytes(b'x')
            for missing in (True, False):
                if not missing:
                    (Path(folder) / 'boot.scr').touch()
                with self.assertRaisesRegex(ValueError, r'boot\.scr'):
                    install(board, folder, 'abc', lambda: False, lambda *_: None)
                self.assertFalse(board.received)

    def test_three_files_and_crc(self):
        board = Endpoint(b'READY EMMC\nOK EMMC\n')
        with tempfile.TemporaryDirectory() as folder:
            boot, fit = bytes(range(256)) * 300, b'fit'
            for name, data in [('BOOT.BIN', boot), ('image.ub', fit), ('boot.scr', b'script')]:
                (Path(folder) / name).write_bytes(data)
            install(board, folder, 'abc', lambda: False, lambda *_: None)
        crc = b''.join(zlib.crc32(data).to_bytes(4, 'little') for data in (boot, fit, b'script'))
        self.assertEqual(board.received, b'EMMC abc 76800 3 6\n' + boot + fit + b'script' + crc)

    def test_board_rejection_and_missing_confirmation(self):
        with tempfile.TemporaryDirectory() as folder:
            for name in ('BOOT.BIN', 'image.ub', 'boot.scr'):
                (Path(folder) / name).write_bytes(b'x')
            for reply in (b'ERR unauthorized\n', b'READY EMMC\n'):
                board = Endpoint(reply)
                with self.assertRaises(RuntimeError):
                    install(board, folder, 'abc', lambda: False, lambda *_: None)
                if reply.startswith(b'ERR'):
                    self.assertEqual(board.received, b'EMMC abc 1 1 1\n')
