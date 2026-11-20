"""Offscreen GUI checks. Requires the application's Qt/NumPy dependencies."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
AVAILABLE = bool(importlib.util.find_spec('numpy') and
                 (importlib.util.find_spec('PyQt6') or importlib.util.find_spec('PyQt5')))
if AVAILABLE:
    import FH_Test as fh


@unittest.skipUnless(AVAILABLE, 'Install the host requirements to run GUI tests')
class GuiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.app = fh.QtWidgets.QApplication.instance() or fh.QtWidgets.QApplication([])
        font_path = Path(os.environ.get('WINDIR', 'C:/Windows')) / 'Fonts' / 'segoeui.ttf'
        if font_path.is_file():
            font_id = fh.QtGui.QFontDatabase.addApplicationFont(str(font_path))
            families = fh.QtGui.QFontDatabase.applicationFontFamilies(font_id)
            if families:
                cls.app.setFont(fh.QtGui.QFont(families[0], 9))
        settings = fh.QtCore.QSettings
        settings.setDefaultFormat(fh.enum(settings, 'Format', 'IniFormat'))
        settings.setPath(fh.enum(settings, 'Format', 'IniFormat'),
                         fh.enum(settings, 'Scope', 'UserScope'), cls.temp.name)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.window = fh.FHTest()
        self.window.show()
        self.app.processEvents()

    def tearDown(self):
        self.window.close()
        self.app.processEvents()

    def test_escape_during_tcp_wait_and_unknown_state(self):
        from unittest.mock import Mock
        window = self.window
        worker = Mock(operation='catalog')
        window.worker = worker
        window.sequence.reset('unknown')
        window.pending_capture = True
        with patch.object(window.serial, 'isOpen', return_value=True), \
             patch.object(window.serial, 'flush'), \
             patch.object(window, 'send', return_value=True) as send:
            window.update_controls()
            self.assertTrue(window.escape.isEnabled())
            window.send_escape()
            send.assert_called_once_with(b'\x1b')
            worker.cancel.assert_called_once()
            self.assertFalse(window.pending_capture)
            self.assertEqual(window.sequence.state, 'unknown')
        window.worker = None

    def test_escape_disabled_during_programming(self):
        from unittest.mock import Mock
        window = self.window
        window.worker = Mock(operation='program')
        with patch.object(window.serial, 'isOpen', return_value=True), \
             patch.object(window, 'send') as send:
            window.update_controls()
            self.assertFalse(window.escape.isEnabled())
            window.send_escape()
            send.assert_not_called()
        window.worker = None

    def test_initial_state_and_catalog(self):
        window = self.window
        self.assertFalse(window.start.isEnabled())
        self.assertFalse(window.stop.isEnabled())
        self.assertTrue(window.attach.isEnabled())
        worker = fh.Worker('catalog', 'unused', 5001)
        row = dict(frame_id=3, timer_pulse=7, type='ROI', roi_y=1024, bytes=8388608)
        window.worker_result(worker, window.generation, dict(rows=[row], status={'ready': '1'}))
        self.assertEqual(window.table.rowCount(), 1)
        self.assertEqual(window.sequence.state, 'export')
        window.update_controls()
        self.assertTrue(window.download.isEnabled())
        self.assertFalse(window.start.isEnabled())  # TCP alone never enables UART capture
        window.host.textEdited.emit('192.168.1.124')
        self.assertEqual(window.table.rowCount(), 0)
        self.assertEqual(window.sequence.state, 'unknown')

    def test_program_worker_mocked_without_hardware(self):
        def fake_launch(root, paths, cancelled, output):
            output('FH_PROGRAM_RUN_OK')
        with patch('FH_Test.launch_jtag', fake_launch):
            self.window.program_board()
            self.assertFalse(self.window.attach.isEnabled())
            self.assertFalse(self.window.program_button.isEnabled())
            deadline = time.monotonic()+5
            while self.window.worker and time.monotonic()<deadline:
                self.app.processEvents()
            self.assertIsNone(self.window.worker)
            self.assertIn('JTAG download and resume completed',self.window.console.toPlainText())
            self.assertEqual(self.window.sequence.state,'unknown')

    def test_router_filter_cache_and_preview(self):
        window = self.window
        rows = [dict(frame_id=3, timer_pulse=7, type='ROI', roi_y=1024),
                dict(frame_id=4, timer_pulse=8, type='FULL', roi_y=0)]
        worker = fh.Worker('catalog', 'unused', 5001)
        window.worker_result(worker, window.generation,
                             dict(rows=rows, status={'ready': '1', 'router': '1'}))
        window.local_files[(4, 'FULL')] = {0: 'old.raw'}
        window.router_mode.setCurrentIndex(1)
        window.router_n.setCurrentText('4')
        self.assertEqual([r['type'] for r in window.rows], ['FULL'])
        self.assertFalse(window.local_files)
        self.assertIn('1024 x 768', window.router_info.text())
        window.router_mode.setCurrentIndex(2)
        self.assertEqual(len(window.rows), 2)
        for spin, value in zip(window.router_coords, (100,200,740,680)):
            spin.setValue(value)
        self.assertIn('640 x 480', window.router_info.text())
        self.assertEqual(window.current_route().key, 'crop_100_200_740_680')
        window.router_coords[2].setValue(100)
        with self.assertRaises(ValueError): window.current_route()

    def test_routed_viewer_geometry(self):
        with tempfile.TemporaryDirectory() as directory:
            raw = Path(directory) / 'frame_0000000003_s0_full.raw'
            fh.np.arange(6, dtype='<u2').tofile(raw)
            raw.with_suffix('.json').write_text(json.dumps(dict(
                protocol=2, frame_id=3, sensor=0, type='FULL', width=3, height=2,
                roi_y=0, router_mode=2, origin_x=13, origin_y=1041, step_x=1, step_y=1)))
            pixels, meta = fh.read_image(raw, 3, 0, 'full')
            self.assertEqual(pixels.shape, (2,3))
            self.assertEqual(int(pixels[1,2]), 5)

    def test_background_pair_load_and_render(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            files = {}
            for sensor in (0, 1):
                raw = folder / f'frame_0000000003_s{sensor}_roi.raw'
                fh.np.full((1024, 4096), sensor + 512, dtype='<u2').tofile(raw)
                raw.with_suffix('.json').write_text(json.dumps(dict(frame_id=3, sensor=sensor,
                                                                  type='ROI', timer_pulse=7)))
                files[sensor] = raw
            row = dict(frame_id=3, type='ROI')
            self.window.rows = [row]
            self.window.local_files = {(3, 'ROI'): files}
            self.window.populate_table()
            self.window.display_selected()
            deadline = time.monotonic() + 10
            while self.window.worker and time.monotonic() < deadline:
                self.app.processEvents()
                time.sleep(0.005)
            self.assertIsNone(self.window.worker)
            self.assertEqual(len(self.window.arrays), 2)
            self.assertIn('FrameID 3', self.window.info.text())
            self.window.gray.setCurrentIndex(1)
            self.assertIsNotNone(self.window.panels[0].original)
            if os.environ.get('FH_TEST_SCREENSHOT'):
                self.window.grab().save(os.environ['FH_TEST_SCREENSHOT'])

    def test_stale_worker_result_is_ignored(self):
        worker = fh.Worker('catalog', 'unused', 5001)
        generation = self.window.generation
        self.window.invalidate_catalog()
        self.window.worker_result(worker, generation, dict(rows=[], status={'ready': '1'}))
        self.assertEqual(self.window.sequence.state, 'unknown')

    def test_uart_capture_stop_export_and_restart(self):
        class Serial:
            data = b''
            def __init__(self):
                self.sent = []
            def isOpen(self):
                return True
            def readAll(self):
                result, self.data = self.data, b''
                return result
            def write(self, data):
                self.sent.append(data)
                return len(data)
            def close(self):
                pass
        window = self.window
        original_serial = window.serial
        serial = Serial()
        window.serial = serial
        refreshes = []
        window.refresh_catalog = lambda: refreshes.append(True)
        def receive(text):
            serial.data = text.encode('ascii')
            window.receive_uart()
        try:
            receive('U: stereo capture + verify\r\n')
            window.start_capture()
            receive('R [0..24 ROI captures after each full; Enter=24]: ')
            receive('Exposure us [1..35791394; Enter=1000]: ')
            receive('Run seconds [0=continuous; Enter=10; ESC stops]: ')
            self.assertEqual(serial.sent, [b'U', b'24\r', b'1000\r', b'10\r'])
            receive('R=24; one stereo trigger every 4000 us; repeat F then R ROI.\r\n')
            window.stop_capture()
            window.stop_capture()
            self.assertEqual(serial.sent.count(b'\x1b'), 1)
            receive('Pairs: full=1 ROI=24\r\n')
            self.assertFalse(window.stop.isEnabled())
            receive('V31 Ethernet: imported 25 valid stereo LUT entries (FrameID 0..24).\r\n')
            self.assertEqual(serial.sent[-1], b'N')
            receive('D: GEM diagnostics; T: toggle PHY TX delay test; ESC exits; recording must be stopped.\r\n')
            self.assertEqual(refreshes, [True])
            window.capture_sensor()
            self.assertEqual(serial.sent[-1], b'\x1b')
            receive('Ethernet RX paused; returning to UART menu.\r\n')
            self.assertEqual(serial.sent[-1], b'C')
            receive('GMAX-A capture failed; returning to main menu.\r\n')
            self.assertEqual(window.sequence.state, 'menu')
            window.capture_sensor()
            self.assertEqual(serial.sent[-1], b'C')
            receive('D: GEM/PHY diagnostics; ESC exits; recording must be stopped.\r\n')
            self.assertEqual(refreshes, [True, True])
            window.start_capture()
            self.assertEqual(serial.sent[-1], b'\x1b')
            receive('Ethernet RX paused; returning to UART menu.\r\n')
            self.assertEqual(serial.sent[-1], b'U')
            self.assertEqual(window.sequence.state, 'prompt_r')
        finally:
            window.serial = original_serial


if __name__ == '__main__':
    unittest.main()
