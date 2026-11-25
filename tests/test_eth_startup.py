"""Exercise the actual GUI worker without requiring Qt or hardware."""
import ast
from pathlib import Path
import socket
import threading
import time
import types
import unittest
from unittest.mock import Mock, patch

source = Path(__file__).resolve().parents[1] / 'FH_Test.py'
tree = ast.parse(source.read_text())
worker_node = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'Worker')
namespace = dict(QtCore=types.SimpleNamespace(QThread=object, pyqtSignal=lambda *a: Mock()),
                 threading=threading, time=time, socket=socket, Route=lambda: None,
                 status_request=Mock(), list_request=Mock())
exec(compile(ast.Module(body=[worker_node], type_ignores=[]), str(source), 'exec'), namespace)
Worker = namespace['Worker']

class StartupTests(unittest.TestCase):
    def worker(self):
        w = Worker('catalog', '127.0.0.1', 5001)
        w.result, w.failed = Mock(), Mock()
        return w

    def test_transient_connection_failure_then_catalog(self):
        w = self.worker()
        w.request = Mock(side_effect=[TimeoutError(), {'ready': '1'}, ['frame']])
        with patch.object(w.cancelled, 'wait', return_value=False):
            w.run()
        w.failed.emit.assert_not_called()
        w.result.emit.assert_called_once_with(dict(status={'ready': '1'}, rows=['frame']))
        self.assertEqual(w.request.call_count, 3)

    def test_deadline_reports_actionable_failure(self):
        w = self.worker()
        w.request = Mock(side_effect=TimeoutError())
        with patch.object(time, 'monotonic', side_effect=[0, 0, 46]):
            w.run()
        self.assertIn('45 seconds', w.failed.emit.call_args.args[0])
        w.result.emit.assert_not_called()

    def test_cancel_does_not_retry(self):
        w = self.worker()
        def cancel(*args, **kwargs):
            w.cancelled.set()
            raise OSError()
        w.request = Mock(side_effect=cancel)
        w.run()
        self.assertEqual(w.request.call_count, 1)
        w.failed.emit.assert_called_once_with('Operation cancelled')

    def test_install_waits_for_status_before_arming_and_skips_catalog(self):
        w = self.worker()
        w.operation = 'emmc'
        w.armed = threading.Event()
        w.request_arm = Mock()
        w.request_arm.emit.side_effect = w.armed.set
        w.request = Mock(side_effect=[TimeoutError(), {'emmc': '2', 'emmc_ext4': '1'}, 'verified'])
        with patch.object(w.cancelled, 'wait', return_value=False):
            w.run()
        w.request_arm.emit.assert_called_once()
        w.result.emit.assert_called_once_with('verified')
        self.assertEqual(w.request.call_count, 3)

    def test_incompatible_firmware_is_rejected_before_arming(self):
        w = self.worker()
        w.operation = 'emmc'
        w.request_arm = Mock()
        w.request = Mock(return_value={'emmc': '2'})
        w.run()
        w.request_arm.emit.assert_not_called()
        self.assertIn('ext4 eMMC', w.failed.emit.call_args.args[0])

if __name__ == '__main__':
    unittest.main()

