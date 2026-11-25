import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'software/host'))
from fh_emmc import install, rootfs_file


class Endpoint:
    def __init__(self, reply):
        self.reply = reply
        self.received = bytearray()

    def makefile(self, mode):
        return io.BytesIO(self.reply)

    def sendall(self, data):
        self.received.extend(data)


class EmmcTests(unittest.TestCase):
    def rootfs_bundle(self, folder):
        directory = Path(folder)
        for name in ('BOOT.BIN', 'image.ub', 'boot.scr'):
            (directory / name).write_bytes(b'x')
        image = bytearray(65536)
        image[1028:1032] = (64).to_bytes(4, 'little')
        image[1080:1082] = b'\x53\xef'
        (directory / 'rootfs.ext4').write_bytes(image)
        return image

    def test_ext4_upload_and_readback_progress(self):
        board = Endpoint(b'READY EMMC\nREADY ROOTFS\nVERIFY ROOTFS 50\nOK EMMC\n')
        progress = []
        with tempfile.TemporaryDirectory() as folder:
            rootfs = self.rootfs_bundle(folder)
            result = install(board, folder, 'abc', lambda: False,
                             lambda done, _: progress.append(done), ext4=True)
        crc = zlib.crc32(b'x').to_bytes(4, 'little')
        self.assertEqual(board.received, b'EMMC3 abc 1 1 1 65536\nxxx' +
                         crc * 3 + rootfs + hashlib.sha256(rootfs).digest())
        self.assertEqual(progress[-2:], [70, 85])
        self.assertIn('SHA-256', result)

    def test_ext4_rejects_bad_inputs_before_transfer(self):
        board = Endpoint(b'')
        with tempfile.TemporaryDirectory() as folder:
            self.rootfs_bundle(folder)
            rootfs_file(folder).write_bytes(b'\0' * 4096)
            with self.assertRaisesRegex(ValueError, 'superblock'):
                install(board, folder, 'abc', lambda: False, lambda *_: None, ext4=True)
        self.assertFalse(board.received)

    def test_ext4_rootfs_waits_for_successful_boot_staging(self):
        board = Endpoint(b'READY EMMC\nERR eMMC readback CRC mismatch\n')
        with tempfile.TemporaryDirectory() as folder:
            self.rootfs_bundle(folder)
            with self.assertRaisesRegex(RuntimeError, 'CRC mismatch'):
                install(board, folder, 'abc', lambda: False, lambda *_: None, ext4=True)
        self.assertEqual(len(board.received), len(b'EMMC3 abc 1 1 1 65536\nxxx') + 12)

    def test_ext4_reports_final_digest_failure(self):
        board = Endpoint(b'READY EMMC\nREADY ROOTFS\nERR eMMC p2 SHA-256 mismatch\n')
        with tempfile.TemporaryDirectory() as folder:
            self.rootfs_bundle(folder)
            with self.assertRaisesRegex(RuntimeError, 'SHA-256 mismatch'):
                install(board, folder, 'abc', lambda: False, lambda *_: None, ext4=True)

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
