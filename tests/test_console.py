"""Carrier firmware/desktop UART compatibility; no device access or compilation."""
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'software/host'))
from fh_test_backend import CaptureSequence


class CarrierConsoleTests(unittest.TestCase):
    def test_actual_carrier_menu_recognized_in_fragments(self):
        source = (ROOT/'software/app/src/main.c').read_text()
        menu = source.split('static void show_menu(void)', 1)[1].split('static int init_gpio', 1)[0]
        text = ''.join(bytes(s, 'utf-8').decode('unicode_escape')
                       for s in re.findall(r'xil_printf\("([^"\n]*)"\);', menu))
        seq = CaptureSequence()
        seq.feed(' FH_Emulator / FH_Carrier / V33 (in-validation)\r\n')
        for char in text:
            seq.feed(char)
        self.assertEqual(seq.start(24, 1000, 10), b'U')

    def test_carrier_failed_capture_releases_gui(self):
        seq = CaptureSequence()
        seq.reset('verifying')
        events = seq.feed('  Ethernet images unavailable until U passes.\r\n')
        self.assertEqual(seq.state, 'menu')
        self.assertEqual(events[0][0], 'failure')

    def test_carrier_ownership_failure_stays_blocked(self):
        seq = CaptureSequence()
        seq.feed('Reset/relaunch required: DMA ownership unresolved.\r\n')
        seq.feed('  Ethernet images unavailable until U passes.\r\n')
        self.assertEqual(seq.state, 'blocked')

    def test_carrier_export_refusal(self):
        seq = CaptureSequence()
        seq.reset('entering_export')
        seq.feed('  Stop all capture owners before starting Ethernet.\r\n')
        self.assertEqual(seq.state, 'menu')


if __name__ == '__main__':
    unittest.main()
