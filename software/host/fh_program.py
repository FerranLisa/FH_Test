"""JTAG launch preflight and subprocess runner; importing never touches hardware."""
import hashlib
import os
from pathlib import Path
import queue
import socket
import struct
import subprocess
import tempfile
import threading
import time
import zipfile


def default_paths(root):
    root = Path(root)
    platform = root / 'software/workspace/FH_TestPlatform'
    return dict(
        xsdb=Path('C:/AMDDesignTools/2025.2/Vitis/bin/xsdb.bat'),
        xsa=root / 'hardware/exports/FH_Firmware.xsa',
        bit=root / 'hardware/exports/FH_Firmware.bit',
        elf=root / 'software/workspace/FH_TestApp/build/FH_TestApp.elf',
        fsbl=platform / 'export/FH_TestPlatform/sw/boot/fsbl.elf',
        platform_xsa=platform / 'hw/FH_Firmware.xsa')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def elf_symbol(path, wanted=None):
    data = Path(path).read_bytes()
    if len(data) < 64 or data[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', data, 18)[0] != 183:
        raise ValueError(f'{path}: expected a 64-bit little-endian AArch64 ELF')
    if wanted is None:
        return
    offset = struct.unpack_from('<Q', data, 40)[0]
    size, count = struct.unpack_from('<HH', data, 58)
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, offset + i*size) for i in range(count)]
    for section in sections:
        if section[1] != 2:  # SHT_SYMTAB
            continue
        strings = sections[section[6]]
        names = data[strings[4]:strings[4]+strings[5]]
        for pos in range(section[4], section[4]+section[5], section[9]):
            name, _, _, index, value, _ = struct.unpack_from('<IBBHQQ', data, pos)
            if index and names[name:].split(b'\0', 1)[0].decode(errors='replace') == wanted:
                return value
    raise ValueError(f'{path}: missing symbol {wanted}')


def preflight(paths):
    paths = {key: Path(value).resolve() for key, value in paths.items()}
    for key, path in paths.items():
        if not path.is_file():
            raise ValueError(f'Missing {key}: {path}')
    with zipfile.ZipFile(paths['xsa']) as archive:
        bits = [n for n in archive.namelist() if n.lower().endswith('.bit')]
        if len(bits) != 1 or digest(archive.read(bits[0])) != digest(paths['bit'].read_bytes()):
            raise ValueError('BIT does not match the bitstream embedded in the exported XSA. Export again.')
    if digest(paths['xsa'].read_bytes()) != digest(paths['platform_xsa'].read_bytes()):
        raise ValueError('Vitis platform uses a different XSA. Update hardware specification and rebuild platform/application first.')
    for key in ('elf', 'fsbl'):
        elf_symbol(paths[key])
        if paths[key].stat().st_mtime < paths['platform_xsa'].stat().st_mtime:
            raise ValueError(f'{key.upper()} predates the imported XSA. Rebuild it before programming.')
    return paths, elf_symbol(paths['fsbl'], 'XFsbl_Exit')


def stop_tree(process):
    if process and process.poll() is None:
        subprocess.run(['taskkill.exe', '/PID', str(process.pid), '/T', '/F'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       creationflags=subprocess.CREATE_NO_WINDOW, timeout=10)


def launch(root, paths, cancelled, output):
    paths, exit_address = preflight(paths)
    if cancelled():
        raise RuntimeError('Programming cancelled before connecting')
    script = Path(root) / 'scripts/program_run.tcl'
    # Only fixed script/tool paths go through cmd.exe; artifact paths go via env.
    for p in (paths['xsdb'], script):
        if any(c in str(p) for c in '&|<>^%!"\r\n'):
            raise ValueError('Unsupported shell metacharacter in XSDB/script path')
    env = os.environ.copy()
    for key in ('bit', 'elf', 'fsbl'):
        env['FH_PROGRAM_' + key.upper()] = str(paths[key])
    env['FH_PROGRAM_FSBL_EXIT'] = str(exit_address)
    server = process = None
    host, port = '127.0.0.1', 3121
    flags = subprocess.CREATE_NO_WINDOW

    def reachable():
        try:
            with socket.create_connection((host, port), timeout=0.25):
                return True
        except OSError:
            return False
    try:
        if not reachable():
            server_path = paths['xsdb'].with_name('hw_server.bat')
            if not server_path.is_file():
                raise ValueError(f'Missing hardware server: {server_path}')
            with socket.socket() as probe:
                try:
                    probe.bind((host, port))
                except OSError:
                    probe.bind((host, 0))
                    port = probe.getsockname()[1]
                    output(f'Local TCP port 3121 is unavailable. Using port {port}.')
            output(f'Starting local AMD hw_server on port {port}...')
            with tempfile.TemporaryFile() as server_log:
                server = subprocess.Popen(
                    f'"{os.environ.get("COMSPEC", "cmd.exe")}" /d /s /c ""{server_path}" -s tcp:{host}:{port} -p0 -I30"',
                    stdout=server_log, stderr=subprocess.STDOUT, creationflags=flags)
                deadline = time.monotonic() + 15
                while not reachable():
                    if cancelled():
                        raise RuntimeError('Programming cancelled')
                    exit_code = server.poll()
                    if exit_code is not None or time.monotonic() > deadline:
                        if exit_code is None:
                            stop_tree(server)
                        server_log.seek(0)
                        for line in server_log.read().decode(errors='replace').splitlines():
                            output(line)
                        reason = f'exit code {exit_code}' if exit_code is not None else 'startup timed out'
                        raise RuntimeError(f'hw_server did not start on {host}:{port} ({reason})')
                    time.sleep(0.1)
        env['FH_PROGRAM_HW_SERVER_URL'] = f'tcp:{host}:{port}'
        output('Connecting XSDB. Keep Vitis debug sessions disconnected.')
        process = subprocess.Popen(f'"{os.environ.get("COMSPEC", "cmd.exe")}" /d /s /c ""{paths["xsdb"]}" "{script}""', env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, errors='replace', creationflags=flags)
        lines = queue.Queue()
        def read_output():
            try:
                for line in process.stdout: lines.put(line.rstrip())
            finally:
                lines.put(None)
        reader = threading.Thread(target=read_output, daemon=True)
        reader.start()
        deadline = time.monotonic()+180
        completed = False
        while True:
            if cancelled(): raise RuntimeError('Programming cancelled; board state is unknown. Use Program & Run again.')
            if time.monotonic()>deadline: raise RuntimeError('JTAG launch timed out; board state is unknown')
            try: line = lines.get(timeout=0.1)
            except queue.Empty: continue
            if line is None: break
            output(line)
            if line == 'FH_PROGRAM_RUN_OK': completed = True
        process.wait(timeout=5)
        if process.returncode or not completed:
            raise RuntimeError(f'XSDB ended with exit code {process.returncode} without confirming JTAG launch. '
                               'Check the XSDB output above.')
    finally:
        stop_tree(process)
        if process and process.stdout: process.stdout.close()
        stop_tree(server)  # Never stop a server that was already running.
