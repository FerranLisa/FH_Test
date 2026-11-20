import re
import sys
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'software/host'))
from fh_version import RELEASE, RELEASE_STATE
from fh_test_backend import CaptureSequence


class VersionTests(unittest.TestCase):
    def test_firmware_and_host_release_match(self):
        header = (ROOT / 'software/app/src/fh_version.h').read_text()
        for name, expected in [('FH_RELEASE', RELEASE), ('FH_RELEASE_STATE', RELEASE_STATE)]:
            self.assertEqual(re.search(r'#define ' + name + r' "([^"]+)"', header).group(1), expected)

    def test_old_and_new_capture_import_banners(self):
        for release in ('V31', RELEASE):
            seq = CaptureSequence()
            seq.reset('verifying')
            events = seq.feed(f'  {release} Ethernet: imported 235 valid stereo LUT entries (FrameID 246..480).\r\n')
            self.assertEqual(seq.state, 'menu')
            self.assertEqual(events[0][0], 'verified')


if __name__ == '__main__': unittest.main()
