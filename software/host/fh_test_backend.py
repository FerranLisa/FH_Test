"""Non-GUI protocol and UART sequencing for FH_Test (no board writes on import)."""
from pathlib import Path
import tempfile

from fh_fetch import ProtocolError, fetch_image, read_line
from fh_version import RELEASE
from fh_route import Route


class CaptureSequence:
    """Incremental prompt parser. Output is (event, value); writes are explicit.

    Never sends ESC itself. An uncertain state must be resynchronized by the user.
    """
    def __init__(self):
        self.state = 'unknown'
        self.buffer = ''
        self.values = ()
        self.monitor_ready = False

    def reset(self, state='unknown'):
        self.state, self.buffer = state, ''
        self.monitor_ready = False

    def start(self, r, exposure, seconds):
        if self.state != 'menu':
            raise ValueError('Synchronize with the UART menu before capture')
        if not 0 <= r <= 24 or not 1 <= exposure <= 1048575 or not 0 <= seconds <= 4294967295:
            raise ValueError('Capture parameters are outside firmware limits')
        self.values = (r, exposure, seconds)
        self.reset('prompt_r')
        return b'U'

    def feed(self, text):
        self.buffer += text
        events = []
        prompts = {
            'prompt_r': ('R [0..24 ROI captures after each full; Enter=24]: ', 0, 'prompt_exposure'),
            'prompt_exposure': ('Exposure us [1..1048575; Enter=1000]: ', 1, 'prompt_duration'),
            'prompt_duration': ('Run seconds [0=continuous; Enter=10; ESC stops]: ', 2, 'starting'),
        }
        while self.buffer:
            if self.state in prompts:
                token, index, next_state = prompts[self.state]
                if self.state == 'prompt_exposure' and token not in self.buffer:
                    for legacy in ('Exposure us [1..35791394; Enter=5000]: ', 'Exposure us [1..35791394; Enter=1000]: '):
                        if legacy in self.buffer:
                            token = legacy
                            break
                if token in self.buffer:
                    self.buffer = self.buffer.split(token, 1)[1]
                    self.state = next_state
                    events.append(('write', f'{self.values[index]}\r'.encode('ascii')))
                    continue
            if '\n' not in self.buffer:
                break
            line, self.buffer = self.buffer.split('\n', 1)
            line = line.strip()
            # The release banner is also printed by H; only this boot-only
            # identification line establishes an application restart.
            if line == 'PZ-ZU7EV / Cortex-A53_0':
                self.state = 'unknown'
                events.append(('reset', line))
            elif line.startswith(('U: stereo capture + verify',
                                  'U   - Fixed-exposure 250 Hz timer stereo capture')):
                self.state = 'menu'
            elif line.startswith('R=') and 'one stereo trigger' in line:
                self.state = 'capturing'
                self.monitor_ready = False
            elif line == 'JPEG monitor listening on TCP 5002.':
                self.monitor_ready = self.state == 'capturing'
            elif line.startswith('JPEG monitor unavailable'):
                self.monitor_ready = False
            elif line.startswith('Pairs:'):
                self.state = 'verifying'
            elif line.startswith(('V31 Ethernet: imported ', 'V32 Ethernet: imported ', 'V33 Ethernet: imported ', 'V33.1 Ethernet: imported ', 'V34 Ethernet: imported ', 'V35 Ethernet: imported ', 'V35.1 Ethernet: imported ', f'{RELEASE} Ethernet: imported ')):
                self.state = 'menu'
                events.append(('verified', line))
            elif ('Export unavailable until U passes.' in line or
                  'Ethernet images unavailable until U passes.' in line):
                if self.state != 'blocked':
                    self.state = 'menu'
                events.append(('failure', line))
            elif 'Ethernet RX paused; returning to UART menu.' in line:
                self.state = 'menu'
            elif 'ESC exits; recording must be stopped.' in line:
                self.state = 'export'
                events.append(('export', line))
            elif ('DMA ownership unresolved' in line or
                  'controller did not release ownership.' in line):
                self.state = 'blocked'
                events.append(('failure', line))
            elif ('Ethernet server failed to start.' in line or
                  'capture failed; returning to main menu.' in line):
                self.state = 'menu'
                events.append(('failure', line))
            elif self.state == 'entering_export' and (
                    'Load the matching FH_Firmware bitstream first.' in line or
                    'Capture owns DMA or hardware signature mismatch.' in line or
                    'Stop all capture owners before starting Ethernet.' in line):
                self.state = 'menu'
                events.append(('failure', line))
        # Bound noise/incomplete input, retaining more than the longest prompt.
        self.buffer = self.buffer[-8192:]
        return events


def status_request(sock):
    sock.sendall(b'STATUS\n')
    line = read_line(sock)
    if not line.startswith('STATUS '):
        raise ProtocolError(line)
    try:
        fields = dict(item.split('=', 1) for item in line.split()[1:])
        if fields['protocol'] != '1' or fields['mode'] != 'stopped-only':
            raise ValueError('unsupported protocol')
        fields['entries'] = int(fields['entries'])
        if not 0 <= fields['entries'] <= 256 or fields['ready'] not in ('0', '1') or fields['capture'] != '0':
            raise ValueError('invalid status')
    except (KeyError, ValueError) as exc:
        raise ProtocolError('Invalid STATUS response') from exc
    return fields


def list_request(sock, timestamps=False):
    sock.sendall(b'TIME LIST\n' if timestamps else b'LIST\n')
    line = read_line(sock)
    if not line.startswith('COUNT '):
        raise ProtocolError(line)
    count = int(line[6:])
    if not 0 <= count <= 256:
        raise ProtocolError('Invalid catalog count')
    rows, ids = [], set()
    for _ in range(count):
        fields = read_line(sock).split()
        if len(fields) != (13 if timestamps else 8) or fields[0] != 'FRAME':
            raise ProtocolError('Invalid catalog record')
        _, fid, pulse, kind, size, addr0, addr1, roi_y = fields[:8]
        row = dict(frame_id=int(fid), timer_pulse=int(pulse), type=kind,
                   bytes=int(size), address0=int(addr0, 16), address1=int(addr1, 16), roi_y=int(roi_y))
        if timestamps:
            rise, fall, utc, last_set, pc_set = map(int, fields[8:])
            if not (0 < rise < fall < 1 << 64 and 0 <= utc < (1 << 32)*1000000
                    and 0 <= last_set < 1 << 32 and pc_set in (0, 1)):
                raise ProtocolError('Invalid catalog timestamps')
            row.update(trigger_ticks=rise, end_ticks=fall, utc_us=utc, rtc_set_seconds=last_set, rtc_pc_set=pc_set)
        if (kind not in ('FULL', 'ROI') or row['frame_id'] in ids or
                not 0 <= row['frame_id'] <= 0xffffffff or not 0 <= row['timer_pulse'] <= 0xffffffff or
                row['bytes'] != 4096 * (3072 if kind == 'FULL' else 1024) * 2 or
                row['roi_y'] != (0 if kind == 'FULL' else 1024)):
            raise ProtocolError('Invalid catalog identity/geometry')
        ids.add(row['frame_id'])
        rows.append(row)
    return rows


def download_pair(sock, row, folder, progress, cancelled, route=None):
    """Stage both sensors and metadata before exposing the pair to the UI."""
    mono = 0 in (row.get('address0'), row.get('address1'))
    single_sensor = int(row.get('address0') == 0)
    route = (Route() if mono else (route or Route())).validate()
    width, height = route.geometry(row['type'])
    folder = Path(folder) / route.key if route.mode else Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    fid = row['frame_id']
    with tempfile.TemporaryDirectory(prefix='.pair-', dir=folder) as staging:
        staging = Path(staging)
        command = f'GET {fid} {single_sensor}\n'.encode('ascii') if mono else route.command(fid)
        sock.sendall(b'TIME ' + command if 'trigger_ticks' in row else command)
        metadata = []
        sensors = (single_sensor,) if mono else (0, 1)
        for index, sensor in enumerate(sensors):
            meta = fetch_image(sock, staging, fid, sensor,
                               progress=lambda done, total, s=index: progress(s * total + done, len(sensors) * total),
                               cancelled=cancelled, quiet=True)
            if (meta['timer_pulse'] != row['timer_pulse'] or meta['type'] != row['type'] or
                    meta['roi_y'] != row['roi_y']):
                raise ProtocolError('Downloaded pair does not match the selected catalog entry')
            if any(meta.get(k) != row.get(k) for k in ('trigger_ticks', 'end_ticks', 'utc_us', 'rtc_set_seconds', 'rtc_pc_set')):
                raise ProtocolError('Downloaded timestamps differ from catalog')
            metadata.append(meta)
            expected_origin = (0, row['roi_y']) if route.mode == 0 else ((0, 0) if route.mode == 1 else (route.x0, 1024 + route.y0))
            step = route.n if route.mode == 1 else 1
            if ((meta['width'], meta['height']) != (width, height) or
                    meta.get('router_mode', 0) != route.mode or
                    (meta.get('origin_x', 0), meta.get('origin_y', row['roi_y'])) != expected_origin or
                    (meta.get('step_x', 1), meta.get('step_y', 1)) != (step, step)):
                raise ProtocolError('Downloaded geometry does not match Router request')
        if cancelled():
            raise ProtocolError('download cancelled')
        for meta in metadata:
            raw = staging / meta['data_file']
            raw.with_suffix('.json').replace(folder / raw.with_suffix('.json').name)
            raw.replace(folder / raw.name)
    return [(folder / m['data_file'], m) for m in metadata]
