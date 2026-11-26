import io
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'software/host'))
from fh_program import preflight, elf_symbol, launch


def sample_elf():
    data = bytearray(512)
    data[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<H', data, 18, 183)
    struct.pack_into('<Q', data, 40, 256)
    struct.pack_into('<HH', data, 58, 64, 3)
    struct.pack_into('<IBBHQQ', data, 88, 1, 0, 0, 1, 0x12340, 0)
    data[128:140] = b'\0XFsbl_Exit\0\0'
    struct.pack_into('<IIQQQQIIQQ', data, 320, 0, 2, 0, 0, 64, 48, 2, 0, 8, 24)
    struct.pack_into('<IIQQQQIIQQ', data, 384, 0, 3, 0, 0, 128, 12, 0, 0, 1, 0)
    return data


class ProgramTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.paths = {k: root/k for k in ('xsdb','bit','xsa','platform_xsa','elf','fsbl')}
        self.paths['xsdb'].write_text('test')
        self.paths['bit'].write_bytes(b'bitstream')
        with zipfile.ZipFile(self.paths['xsa'],'w') as z: z.writestr('design.bit',b'bitstream')
        self.paths['platform_xsa'].write_bytes(self.paths['xsa'].read_bytes())
        os.utime(self.paths['platform_xsa'], (100,100))
        for k in ('elf','fsbl'): self.paths[k].write_bytes(sample_elf())

    def test_matching_artifacts_and_exit_symbol(self):
        _, address = preflight(self.paths)
        self.assertEqual(address,0x12340)

    def test_stale_platform_rejected(self):
        self.paths['platform_xsa'].write_bytes(b'old handoff')
        with self.assertRaisesRegex(ValueError,'different XSA'): preflight(self.paths)

    def test_wrong_bit_rejected(self):
        self.paths['bit'].write_bytes(b'wrong')
        with self.assertRaisesRegex(ValueError,'BIT does not match'): preflight(self.paths)

    def test_old_application_rejected(self):
        os.utime(self.paths['elf'],(50,50))
        with self.assertRaisesRegex(ValueError,'ELF predates'): preflight(self.paths)

    def test_invalid_elf_and_missing_symbol(self):
        self.paths['elf'].write_bytes(b'invalid')
        with self.assertRaisesRegex(ValueError,'AArch64'): preflight(self.paths)
        with self.assertRaisesRegex(ValueError,'missing symbol'): elf_symbol(self.paths['fsbl'],'not_present')

    def test_cancel_before_any_hardware_access(self):
        with patch('fh_program.socket.create_connection') as connect, patch('fh_program.subprocess.Popen') as popen:
            with self.assertRaisesRegex(RuntimeError,'cancelled'):
                launch(self.tmp.name,self.paths,lambda:True,lambda _:None)
            connect.assert_not_called()
            popen.assert_not_called()

    def test_reserved_default_port_is_replaced_before_launching_xsdb(self):
        self.paths['xsdb'].with_name('hw_server.bat').touch()
        server = Mock()
        xsdb = Mock(stdout=io.StringIO('FH_PROGRAM_RUN_OK\n'), returncode=0)
        with patch('fh_program.socket.create_connection') as connect, \
             patch('fh_program.socket.socket') as socket_factory, \
             patch('fh_program.subprocess.Popen', side_effect=[server, xsdb]) as popen, \
             patch('fh_program.subprocess.CREATE_NO_WINDOW', 0, create=True), \
             patch('fh_program.stop_tree'):
            connect.side_effect = [ConnectionRefusedError(), connect.return_value]
            probe = socket_factory.return_value.__enter__.return_value
            probe.bind.side_effect = [PermissionError(), None]
            probe.getsockname.return_value = ('127.0.0.1', 45125)
            launch(self.tmp.name, self.paths, lambda: False, lambda _: None)
        self.assertIn('-s tcp:127.0.0.1:45125', popen.call_args_list[0].args[0])
        self.assertEqual(popen.call_args_list[1].kwargs['env']['FH_PROGRAM_HW_SERVER_URL'],
                         'tcp:127.0.0.1:45125')

    def test_tcl_launch_sequence_with_mock_debugger(self):
        try:
            import tkinter
        except ImportError:
            self.skipTest('Tcl interpreter not installed')
        try:
            interp = tkinter.Tcl()
        except tkinter.TclError:
            self.skipTest('Python Tcl runtime not configured; run mock script through XSDB instead')
        interp.eval('''
            set calls {}
            foreach command {connect targets rst fpga dow bpremove con disconnect} {
                proc $command {args} [format {lappend ::calls [linsert $args 0 %s]} $command]
            }
            proc bpadd {args} {return 17}
            proc rrd {args} {return "pc: 00000000fffc0c08"}
            proc after {args} {}
            proc exit {code} {if {$code != 0} {error "launch failed"}}
            proc puts {args} {}
            set env(FH_PROGRAM_HW_SERVER_URL) tcp:127.0.0.1:45125
            set env(FH_PROGRAM_BIT) test.bit
            set env(FH_PROGRAM_FSBL) fsbl.elf
            set env(FH_PROGRAM_ELF) app.elf
            set env(FH_PROGRAM_FSBL_EXIT) 0xfffc0c08
        ''')
        interp.call('source', str(Path(__file__).resolve().parents[1] / 'scripts/program_run.tcl'))
        calls = str(interp.eval('set calls'))
        self.assertIn('connect -url tcp:127.0.0.1:45125', calls)
        self.assertLess(calls.index('dow fsbl.elf'), calls.index('con -block -timeout 60'))
        self.assertLess(calls.index('bpremove 17'), calls.index('dow app.elf'))
        self.assertTrue(calls.endswith('con disconnect'))
        interp.eval('proc rrd {args} {return "pc: 0000000000000000"}')
        with self.assertRaises(tkinter.TclError):
            interp.call('source', str(Path(__file__).resolve().parents[1] / 'scripts/program_run.tcl'))


if __name__=='__main__': unittest.main()
