#!/usr/bin/env python3
"""Unified FH UART control, TCP frame download and stereo viewer.

Install: python -m pip install -r software/host/requirements.txt
Run: python FH_Test.py
"""
import sys
import socket
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'images'))
sys.path.insert(0, str(ROOT / 'software' / 'host'))
from fh_jpeg_viewer import Eye, StereoMonitor
from view_stereo import QtCore, QtGui, QtWidgets, ImagePanel, enum, find_pairs, read_image, np
if QtCore.__name__.startswith('PyQt6'):
    from PyQt6 import QtSerialPort
else:
    from PyQt5 import QtSerialPort
from fh_test_backend import CaptureSequence, status_request, list_request, download_pair
from fh_fetch import frame_times
from fh_route import Route
from fh_version import RELEASE_LABEL
from fh_program import default_paths, launch as launch_jtag
from fh_emmc import boot_files, install as install_emmc


class Worker(QtCore.QThread):
    result = QtCore.pyqtSignal(object)
    failed = QtCore.pyqtSignal(str)
    progress = QtCore.pyqtSignal(int, int)

    def __init__(self, operation, host, port, row=None, folder=None, files=None, route=None):
        super().__init__()
        self.operation, self.host, self.port = operation, host, port
        self.row, self.folder, self.files = row, folder, files
        self.route = route or Route()
        self.cancelled = threading.Event()
        self.sock = None

    def cancel(self):
        self.cancelled.set()
        sock = self.sock
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def request(self, func, connect_timeout=5, response_timeout=30, deadline=None):
        if self.cancelled.is_set():
            raise RuntimeError('Operation cancelled')
        with socket.create_connection((self.host, self.port), timeout=connect_timeout) as sock:
            self.sock = sock
            try:
                if deadline is not None:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError('Ethernet readiness deadline expired')
                    response_timeout = min(response_timeout, remaining)
                sock.settimeout(response_timeout)
                if self.cancelled.is_set():
                    raise RuntimeError('Operation cancelled')
                return func(sock)
            finally:
                self.sock = None

    def run(self):
        try:
            if self.operation == 'emmc':
                if not self.armed.wait(5):
                    raise RuntimeError('Board did not authorize eMMC upload. Load the updated standalone firmware and enter Ethernet export.')
                result = self.request(lambda sock: install_emmc(
                    sock, self.folder, self.token, self.cancelled.is_set, self.progress.emit),
                    response_timeout=240)
            elif self.operation == 'catalog':
                # Only retry the read-only readiness probe, never image downloads.
                deadline = time.monotonic() + 45
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError('Ethernet not ready after 45 seconds; check UART link status and use Attach to retry.')
                    try:
                        status = self.request(status_request, min(3, remaining),
                                              min(3, remaining), deadline=deadline)
                        break
                    except (OSError, EOFError) as exc:
                        if self.cancelled.is_set():
                            raise RuntimeError('Operation cancelled') from exc
                        if time.monotonic() >= deadline:
                            raise TimeoutError('Ethernet not ready after 45 seconds; check UART link status and use Attach to retry.') from exc
                        self.cancelled.wait(min(0.5, max(0, deadline - time.monotonic())))
                rows = []
                if status['ready'] == '1':
                    rows = self.request(lambda sock: list_request(sock, status.get('timestamps') == '1'))
                result = dict(status=status, rows=rows)
            else:
                if self.operation == 'download':
                    downloaded = self.request(lambda sock: download_pair(
                        sock, self.row, self.folder, self.progress.emit, self.cancelled.is_set, self.route))
                    files = {item[1]['sensor']: item[0] for item in downloaded}
                else:
                    files = self.files
                fid, kind = self.row['frame_id'], self.row['type'].lower()
                loaded = [read_image(files[s], fid, s, kind) for s in sorted(files)]
                pulses = [meta.get('timer_pulse') for _, meta in loaded]
                if len(pulses) == 2 and all(p is not None for p in pulses) and pulses[0] != pulses[1]:
                    raise ValueError('Stereo timer pulses do not match')
                result = dict(loaded=loaded, files=files, row=self.row)
            if self.cancelled.is_set():
                raise RuntimeError('Operation cancelled')
            self.result.emit(result)
        except Exception as exc:
            self.failed.emit('Operation cancelled' if self.cancelled.is_set() else str(exc))


class ProgramWorker(Worker):
    log_line = QtCore.pyqtSignal(str)

    def __init__(self, paths):
        super().__init__('program', '', 0)
        self.paths = paths
        self.succeeded = False

    def run(self):
        try:
            launch_jtag(ROOT, self.paths, self.cancelled.is_set, self.log_line.emit)
            self.succeeded = True
            self.result.emit({'programmed': True})
        except Exception as exc:
            self.failed.emit(str(exc))


class FHTest(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(f'FH_Test FH_Carrier {RELEASE_LABEL} - ZU7EV stereo test')
        self.resize(1500, 950)
        self.raw_uart = bytearray()
        self.sequence = CaptureSequence()
        self.worker = None
        self.closing = False
        self.generation = 0
        self.rows, self.local_files, self.arrays = [], {}, []
        self.all_rows = []
        self.emmc_available = False
        self.router_available = False
        self.pending_capture = False
        self.deadline = None
        self.output_root = ROOT / 'images' / 'sessions'
        self.session = None
        self.settings = QtCore.QSettings('FH_Emulator', 'FH_Test')
        self.serial = QtSerialPort.QSerialPort(self)
        self.serial.readyRead.connect(self.receive_uart)
        self.serial.errorOccurred.connect(self.serial_error)
        self.build_ui()
        self.scan_ports()
        self.timer = QtCore.QTimer(self)
        self.timer.setInterval(250)
        self.timer.timeout.connect(self.tick)
        self.timer.start()
        self.update_controls()

    def button(self, layout, title, callback):
        button = QtWidgets.QPushButton(title)
        button.clicked.connect(callback)
        layout.addWidget(button)
        return button

    def field_label(self, title):
        label = QtWidgets.QLabel(title)
        label.setAlignment(enum(QtCore.Qt, 'AlignmentFlag', 'AlignRight') |
                           enum(QtCore.Qt, 'AlignmentFlag', 'AlignVCenter'))
        return label

    def toggle_monitor(self, enabled):
        if enabled:
            self.monitor = StereoMonitor(self.host.text().strip(), self.live_eyes, self.live_status, self)
            self.live_status.setText('Waiting for stereo pair')
        elif self.monitor is not None:
            self.monitor.close()
            self.monitor = None
        for stack, eye in zip(self.sensor_stacks, self.live_eyes):
            eye.clear()
            stack.setCurrentIndex(int(enabled))
        self.live_status.setVisible(enabled)
        self.info.setVisible(not enabled)
        self.full_field.setVisible(enabled)
        self.gray.setVisible(not enabled)
        self.update_controls()

    def set_board_rtc(self):
        self.send(f'T:{int(time.time())}\r'.encode('ascii'))

    def build_ui(self):
        central = QtWidgets.QWidget()
        self.setCentralWidget(central)
        layout = QtWidgets.QVBoxLayout(central)
        connections = QtWidgets.QHBoxLayout()
        layout.addLayout(connections)
        connections.addWidget(QtWidgets.QLabel('UART'))
        self.com = QtWidgets.QComboBox()
        self.com.setEditable(True)
        connections.addWidget(self.com)
        self.scan = self.button(connections, 'Refresh ports', self.scan_ports)
        self.baud = QtWidgets.QComboBox()
        self.baud.addItems(['115200', '9600', '57600', '230400'])
        connections.addWidget(self.baud)
        self.connect_button = self.button(connections, 'Connect', self.toggle_serial)
        connections.addWidget(QtWidgets.QLabel('Board IP'))
        self.host = QtWidgets.QLineEdit(str(self.settings.value('host', '192.168.1.123')))
        self.host.setMaximumWidth(180)
        connections.addWidget(self.host)
        self.port = QtWidgets.QSpinBox()
        self.port.setRange(1, 65535)
        self.port.setValue(5001)
        connections.addWidget(self.port)
        self.host.textEdited.connect(self.endpoint_changed)
        self.port.valueChanged.connect(self.endpoint_changed)
        self.attach = self.button(connections, 'Attach / refresh export', self.refresh_catalog)
        self.program_button = self.button(connections, 'Program & Run (JTAG)', self.program_board)
        self.program_button.setToolTip('Resets the board, loads BIT and FSBL, downloads and runs the A53 ELF. Clears retained frames.')
        self.program_files = self.button(connections, 'JTAG files...', self.configure_program)
        self.emmc_button = self.button(connections, 'Install PetaLinux on eMMC...', self.program_emmc)
        self.emmc_button.setToolTip('Connect UART and enter Ethernet export to install BOOT.BIN and image.ub.')
        connections.addStretch()

        capture = QtWidgets.QHBoxLayout()
        layout.addLayout(capture)
        self.r = QtWidgets.QSpinBox()
        self.r.setRange(0, 24)
        self.r.setValue(24)
        self.exposure = QtWidgets.QSpinBox()
        self.exposure.setRange(1, 1048575)
        self.exposure.setValue(1000)
        self.seconds = QtWidgets.QSpinBox()
        self.seconds.setRange(0, 2147483647)
        self.seconds.setValue(10)
        self.seconds.setSpecialValueText('Continuous')
        for title, widget in [('R', self.r), ('Exposure (µs)', self.exposure), ('Duration (s)', self.seconds)]:
            capture.addWidget(self.field_label(title))
            capture.addWidget(widget)
        self.start = self.button(capture, 'Start capture', self.start_capture)
        self.stop = self.button(capture, 'Stop capture', self.stop_capture)
        self.sensor_select = QtWidgets.QComboBox()
        self.sensor_select.addItems(['Sensor 1', 'Sensor 2', 'Stereo'])
        capture.addWidget(self.sensor_select)
        self.sensor_capture = self.button(capture, 'Capture sensor', self.capture_sensor)
        self.sensor_capture.setToolTip('Capture one image or a synchronized stereo pair at the specified exposure and refresh Ethernet export.')
        self.export = self.button(capture, 'Enter export', self.enter_export)
        self.leave = self.button(capture, 'Return to menu', self.leave_export)
        self.escape = self.button(capture, 'Send ESC', self.send_escape)
        self.escape.setToolTip('Send UART byte 0x1B even when board state is unknown or TCP is waiting. At the main menu, ESC exits the firmware.')
        self.auto_export = QtWidgets.QCheckBox('Export after verification')
        self.auto_export.setChecked(True)
        capture.addWidget(self.auto_export)
        capture.addStretch()

        router_bar = QtWidgets.QHBoxLayout()
        layout.addLayout(router_bar)
        router_bar.addWidget(self.field_label('Router'))
        self.router_mode = QtWidgets.QComboBox()
        self.router_mode.addItems(['Disabled', 'Full-frame subsampling', 'ROI rectangle'])
        router_bar.addWidget(self.router_mode)
        self.router_n = QtWidgets.QComboBox()
        self.router_n.addItems(['1', '2', '4', '8', '16'])
        self.router_n.setCurrentText('2')
        router_bar.addWidget(self.field_label('n'))
        router_bar.addWidget(self.router_n)
        self.router_coords = []
        for title, maximum, value in [('Xi', 4095, 0), ('Yi', 1023, 0), ('Xj', 4096, 4096), ('Yj', 1024, 1024)]:
            spin = QtWidgets.QSpinBox()
            spin.setRange(0, maximum)
            spin.setValue(value)
            router_bar.addWidget(self.field_label(title))
            router_bar.addWidget(spin)
            self.router_coords.append(spin)
        self.router_info = QtWidgets.QLabel('Original images')
        router_bar.addWidget(self.router_info)
        self.router_mode.currentIndexChanged.connect(self.router_changed)
        self.router_n.currentIndexChanged.connect(self.router_changed)
        for spin in self.router_coords:
            spin.valueChanged.connect(self.router_changed)
        split = QtWidgets.QSplitter(enum(QtCore.Qt, 'Orientation', 'Horizontal'))
        layout.addWidget(split, 1)
        browser = QtWidgets.QWidget()
        left = QtWidgets.QVBoxLayout(browser)
        self.table = QtWidgets.QTableWidget(0, 9)
        self.table.setHorizontalHeaderLabels(['FrameID', 'Sensor', 'Type', 'TimmerPulse', 'Counter (64-bit)', 'Measured exposure (µs)', 'UTC time', 'Local time', 'Local'])
        self.table.setHorizontalScrollBarPolicy(enum(QtCore.Qt, 'ScrollBarPolicy', 'ScrollBarAsNeeded'))
        self.table.setHorizontalScrollMode(enum(QtWidgets.QAbstractItemView, 'ScrollMode', 'ScrollPerPixel'))
        self.table.setSelectionBehavior(enum(QtWidgets.QAbstractItemView, 'SelectionBehavior', 'SelectRows'))
        self.table.setSelectionMode(enum(QtWidgets.QAbstractItemView, 'SelectionMode', 'SingleSelection'))
        self.table.setEditTriggers(enum(QtWidgets.QAbstractItemView, 'EditTrigger', 'NoEditTriggers'))
        self.table.itemSelectionChanged.connect(self.update_controls)
        self.table.cellDoubleClicked.connect(lambda *_: self.display_selected())
        left.addWidget(self.table)
        self.download = self.button(left, 'Download / display selected frame', self.display_selected)
        self.cancel = self.button(left, 'Cancel transfer / load', self.cancel_worker)
        self.open_folder = self.button(left, 'Open downloaded folder…', self.browse_folder)
        self.output = self.button(left, 'Choose download root…', self.choose_output)
        self.folder_label = QtWidgets.QLabel(str(self.output_root))
        self.folder_label.setWordWrap(True)
        left.addWidget(self.folder_label)
        self.progress = QtWidgets.QProgressBar()
        left.addWidget(self.progress)
        split.addWidget(browser)

        view = QtWidgets.QWidget()
        right = QtWidgets.QVBoxLayout(view)
        navigation = QtWidgets.QHBoxLayout()
        right.addLayout(navigation)
        self.previous = self.button(navigation, 'Previous', lambda: self.navigate(-1))
        self.next = self.button(navigation, 'Next', lambda: self.navigate(1))
        self.monitor = None
        self.monitor_button = QtWidgets.QPushButton('Live Stereo Monitor')
        self.monitor_button.setCheckable(True)
        self.monitor_button.toggled.connect(self.toggle_monitor)
        navigation.addWidget(self.monitor_button)
        self.full_field = self.button(navigation, 'Full field', lambda: self.monitor.overview())
        self.full_field.hide()
        navigation.addStretch()
        self.gray = QtWidgets.QComboBox()
        self.gray.addItems(['8 MSBs — bits 9–2', '8 LSBs — bits 7–0'])
        self.gray.currentIndexChanged.connect(self.render)
        navigation.addWidget(self.gray)
        self.info = QtWidgets.QLabel('Connect UART and use Help / sync at the board menu, or attach to an existing export server.')
        self.info.setWordWrap(True)
        right.addWidget(self.info)
        self.live_status = QtWidgets.QLabel()
        right.addWidget(self.live_status)
        self.live_status.hide()
        self.sensor_stacks = []
        self.live_eyes = []
        panels = QtWidgets.QHBoxLayout()
        right.addLayout(panels, 1)
        self.panels = []
        for sensor in (0, 1):
            column = QtWidgets.QVBoxLayout()
            column.addWidget(QtWidgets.QLabel(f'Sensor {sensor + 1}'))
            panel = ImagePanel()
            stack = QtWidgets.QStackedWidget()
            stack.addWidget(panel)
            eye = Eye()
            eye.setAlignment(enum(QtCore.Qt, 'AlignmentFlag', 'AlignCenter'))
            eye.setSizePolicy(enum(QtWidgets.QSizePolicy, 'Policy', 'Ignored'),
                              enum(QtWidgets.QSizePolicy, 'Policy', 'Ignored'))
            eye.anchor.connect(lambda inward, u, v, i=sensor: self.monitor.zoom(i, inward, u, v))
            stack.addWidget(eye)
            self.live_eyes.append(eye)
            self.sensor_stacks.append(stack)
            column.addWidget(stack, 1)
            panels.addLayout(column, 1)
            self.panels.append(panel)
        split.addWidget(view)
        split.setSizes([360, 1140])

        console_controls = QtWidgets.QHBoxLayout()
        layout.addLayout(console_controls)
        self.help_button = self.button(console_controls, 'Help / sync (H)', self.help_sync)
        self.rtc_button = self.button(console_controls, 'Set ZU7EV RTC from PC clock', self.set_board_rtc)
        self.lut = self.button(console_controls, 'Print UART LUT (L)', lambda: self.send(b'L'))
        self.diag = self.button(console_controls, 'Ethernet diagnostics (D)', lambda: self.send(b'D'))
        self.button(console_controls, 'Save UART log…', self.save_log)
        self.button(console_controls, 'Clear console', lambda: self.console.clear())
        console_controls.addStretch()
        manual_controls = QtWidgets.QHBoxLayout()
        layout.addLayout(manual_controls)
        manual_controls.addWidget(QtWidgets.QLabel('Manual recovery:'))
        self.command = QtWidgets.QLineEdit()
        self.command.setPlaceholderText('Manual UART text')
        self.command.setMaximumWidth(170)
        self.command.setToolTip('For manual recovery. Automation returns to unknown state until firmware output identifies it.')
        manual_controls.addWidget(self.command)
        self.raw_send = self.button(manual_controls, 'Send text', lambda: self.manual_send(False))
        self.line_send = self.button(manual_controls, 'Send + Enter', lambda: self.manual_send(True))
        manual_controls.addStretch()
        self.console = QtWidgets.QPlainTextEdit()
        self.console.setReadOnly(True)
        self.console.document().setMaximumBlockCount(10000)
        self.console.setMaximumHeight(210)
        self.console.setStyleSheet('font-family: Consolas, monospace;')
        layout.addWidget(self.console)

    def log(self, text):
        cursor = self.console.textCursor()
        cursor.movePosition(enum(QtGui.QTextCursor, 'MoveOperation', 'End'))
        cursor.insertText(text.replace('\r\n', '\n'))
        self.console.setTextCursor(cursor)
        self.console.ensureCursorVisible()

    def log_event(self, source, text):
        stamp = datetime.now().astimezone().isoformat(timespec='milliseconds')
        self.log(f'\n[{stamp}] [{source}] {text}\n')

    def notice(self, text):
        self.log_event('PC', text)
        self.info.setText(text)

    def scan_ports(self):
        current = self.com.currentText() or str(self.settings.value('com', ''))
        self.com.clear()
        for port in QtSerialPort.QSerialPortInfo.availablePorts():
            self.com.addItem(port.portName())
            self.com.setItemData(self.com.count() - 1, port.description(), enum(QtCore.Qt, 'ItemDataRole', 'ToolTipRole'))
        if current:
            self.com.setCurrentText(current)

    def toggle_serial(self):
        if self.serial.isOpen():
            self.serial.close()
            self.sequence.reset()
            self.pending_capture = False
            self.deadline = None
            self.notice('UART disconnected. This does not stop the board.')
        else:
            self.serial.setPortName(self.com.currentText())
            self.serial.setBaudRate(int(self.baud.currentText()))
            self.serial.setDataBits(enum(QtSerialPort.QSerialPort, 'DataBits', 'Data8'))
            self.serial.setParity(enum(QtSerialPort.QSerialPort, 'Parity', 'NoParity'))
            self.serial.setStopBits(enum(QtSerialPort.QSerialPort, 'StopBits', 'OneStop'))
            self.serial.setFlowControl(enum(QtSerialPort.QSerialPort, 'FlowControl', 'NoFlowControl'))
            if not self.serial.open(enum(QtCore.QIODevice, 'OpenModeFlag', 'ReadWrite')):
                self.notice(f'Cannot open UART: {self.serial.errorString()}. Close other serial terminals.')
            else:
                self.sequence.reset()
                self.settings.setValue('com', self.com.currentText())
                self.notice('UART connected (8N1). No command sent. Use Help / sync at the main menu; use Attach if already exporting.')
        self.update_controls()

    def serial_error(self, error):
        if error == enum(QtSerialPort.QSerialPort, 'SerialPortError', 'ResourceError'):
            port = self.serial.portName()
            detail = self.serial.errorString()
            self.serial.close()
            self.sequence.reset()
            self.deadline = None
            self.pending_capture = False
            self.notice(f'UART {port}: ResourceError: {detail}; port closed, board state is unknown.')
            self.update_controls()

    def send(self, data):
        if not self.serial.isOpen() or self.serial.write(data) != len(data):
            self.sequence.reset()
            self.pending_capture = False
            self.deadline = None
            self.notice('UART write failed; reconnect and synchronize.')
            return False
        self.log_event('TX', repr(data))
        return True

    def help_sync(self):
        self.send(b'H')
        self.notice('Requested menu help. If no response, the board may be capturing or awaiting a numeric answer; no ESC is sent automatically.')

    def manual_send(self, newline):
        if self.command.text().strip().upper() == 'T' and self.sequence.state == 'menu':
            self.set_board_rtc()
            self.command.clear()
            return
        try:
            data = self.command.text().encode('ascii') + (b'\r' if newline else b'')
        except UnicodeEncodeError:
            self.notice('UART commands must contain ASCII characters.')
            return
        if not data:
            return
        self.sequence.reset()
        self.deadline = None
        self.pending_capture = False
        self.invalidate_catalog()
        self.send(data)
        self.command.clear()
        self.update_controls()

    def receive_uart(self):
        data = bytes(self.serial.readAll())
        self.raw_uart.extend(data)
        if self.worker and self.worker.operation == 'emmc':
            self.worker.arm_reply = (self.worker.arm_reply + data)[-max(128, len(data) + 32):]
            if b'FH eMMC upload armed' in self.worker.arm_reply:
                self.worker.armed.set()
        text = data.decode('utf-8', errors='replace')
        self.log(text)
        old = self.sequence.state
        events = self.sequence.feed(text)
        for event, value in events:
            if event == 'write':
                self.send(value)
            elif event == 'reset':
                if self.worker and self.worker.operation == 'program':
                    self.notice('Application startup received during JTAG launch.')
                    continue
                self.invalidate_catalog()
                self.pending_capture = False
                self.cancel_worker()
                self.notice('Board restarted; previous remote catalog discarded.')
            elif event == 'failure':
                self.pending_capture = False
                self.notice(value)
            elif event == 'verified':
                self.notice(value)
                if self.auto_export.isChecked():
                    self.enter_export()
            elif event == 'export':
                self.refresh_catalog()
        if self.pending_capture and self.sequence.state == 'menu':
            pending = self.pending_capture
            self.pending_capture = False
            if isinstance(pending, bytes):
                self.send_sensor_capture(pending)
            else:
                self.begin_capture()
        if self.sequence.state != old:
            self.set_deadline()
        self.update_controls()

    def set_deadline(self):
        state = self.sequence.state
        timeout = 60 if state in ('entering_export', 'starting') else 15
        self.deadline = time.monotonic() + timeout if state in (
            'prompt_r', 'prompt_exposure', 'prompt_duration', 'starting', 'entering_export', 'leaving_export') else None

    def tick(self):
        if self.deadline and time.monotonic() > self.deadline:
            self.deadline = None
            self.sequence.reset()
            self.pending_capture = False
            self.notice('Timed out waiting for firmware. State is unknown; inspect UART output before resynchronizing.')
        self.update_controls()

    def new_session(self):
        self.session = self.output_root / (datetime.now().strftime('%Y%m%d_%H%M%S') + '_' + uuid.uuid4().hex[:8])
        self.folder_label.setText(str(self.session))

    def invalidate_catalog(self):
        self.generation += 1
        self.emmc_available = False
        self.rows, self.local_files = [], {}
        self.all_rows = []
        self.router_available = False
        self.session = None
        self.table.setRowCount(0)

    def endpoint_changed(self, *_):
        self.invalidate_catalog()
        if self.sequence.state == 'export':
            self.sequence.reset()
        self.update_controls()

    def start_capture(self):
        if self.sequence.state == 'export':
            self.pending_capture = True
            self.leave_export()
        else:
            self.begin_capture()

    def begin_capture(self):
        try:
            command = self.sequence.start(self.r.value(), self.exposure.value(), self.seconds.value())
        except ValueError as exc:
            self.notice(str(exc))
            return
        self.invalidate_catalog()
        self.new_session()
        self.send(command)
        self.set_deadline()
        self.notice('Capture setup started. Displayed images, if any, belong to the previous selection.')
        self.update_controls()

    def capture_sensor(self):
        target = ('1', '2', 'S')[self.sensor_select.currentIndex()]
        command = f'C{target}:{self.exposure.value()}\r'.encode('ascii')
        if self.sequence.state == 'export':
            self.pending_capture = command
            self.leave_export()
        elif self.sequence.state == 'menu':
            self.send_sensor_capture(command)

    def send_sensor_capture(self, command):
        if self.send(command):
            self.invalidate_catalog()
            self.sequence.reset('entering_export')
            self.set_deadline()
            self.update_controls()

    def stop_capture(self):
        if self.sequence.state == 'capturing' and self.send(b'\x1b'):
            self.sequence.reset('stopping')
            self.notice('Stop requested; waiting for DMA release and retained-frame verification.')
        self.update_controls()

    def enter_export(self):
        if self.sequence.state == 'menu' and self.send(b'N'):
            self.sequence.reset('entering_export')
            self.set_deadline()
        self.update_controls()

    def send_escape(self):
        if self.worker and self.worker.operation == 'program':
            return
        if not self.serial.isOpen():
            return
        state = self.sequence.state
        self.pending_capture = False
        self.deadline = None
        if self.worker:
            self.worker.cancel()
        if self.send(b'\x1b'):
            self.serial.flush()
            if state in ('export', 'entering_export', 'leaving_export'):
                self.sequence.reset('leaving_export')
            elif state in ('capturing', 'stopping'):
                self.sequence.reset('stopping')
            else:
                self.sequence.reset()
            self.notice('ESC sent (0x1B). Waiting for firmware; PHY negotiation may delay the response by up to 15 seconds.')
        self.update_controls()

    def leave_export(self):
        if self.sequence.state == 'export' and not self.worker and self.send(b'\x1b'):
            self.sequence.reset('leaving_export')
            self.set_deadline()
        self.update_controls()

    def run_worker(self, worker):
        if self.worker:
            return
        self.worker = worker
        generation = self.generation
        worker.result.connect(lambda result: self.worker_result(worker, generation, result))
        worker.failed.connect(self.notice)
        worker.progress.connect(lambda done, total: self.progress.setValue(int(done * 100 / total)))
        worker.finished.connect(self.worker_finished)
        self.progress.setValue(0)
        worker.start()
        self.update_controls()

    def refresh_catalog(self):
        if self.worker:
            return
        self.settings.setValue('host', self.host.text().strip())
        self.notice('Waiting for Ethernet response (up to 45 seconds); link negotiation may still be completing.')
        self.run_worker(Worker('catalog', self.host.text().strip(), self.port.value()))

    def worker_result(self, worker, generation, result):
        if generation != self.generation or worker.cancelled.is_set():
            return
        if worker.operation == 'emmc':
            self.progress.setValue(100)
            self.notice(result)
            return
        if worker.operation == 'program':
            self.notice('JTAG download and resume completed. Verify the application menu on UART before capture.')
            return
        if worker.operation == 'catalog':
            self.sequence.reset('export')
            self.deadline = None
            self.all_rows = result['rows']
            self.emmc_available = result['status'].get('emmc') == '1'
            self.router_available = result['status'].get('router') == '1'
            self.rows = [r for r in self.all_rows if self.router_mode.currentIndex() != 1 or r['type'] == 'FULL']
            self.local_files = {}
            self.new_session()
            self.populate_table()
            self.notice(f"Export connected: {len(self.all_rows)} retained entries, {len(self.rows)} eligible; "
                        f"ready={result['status']['ready']}; Router={'available' if self.router_available else 'unavailable'}; "
                        f"firmware={result['status'].get('release', 'unreported')} "
                        f"{result['status'].get('release_state', '')}.")
        else:
            row = result['row']
            key = (row['frame_id'], row['type'])
            self.local_files[key] = result['files']
            self.arrays = [pixels for pixels, _ in result['loaded']]
            if len(self.arrays) == 1:
                self.panels[1 - next(iter(result['files']))].clear()
            self.display_sensors = sorted(result['files'])
            for sensor, (_, meta) in zip(self.display_sensors, result['loaded']):
                self.panels[sensor].set_metadata(str(result['files'][sensor].with_suffix('.json')), meta)
            self.render()
            self.info.setText(f"FrameID {row['frame_id']} | {row['type']} | "
                              f"TimerPulse {result['loaded'][0][1].get('timer_pulse', 'unknown')} | "
                              f"{self.arrays[0].shape[1]} × {self.arrays[0].shape[0]}\n{next(iter(result['files'].values())).parent}")
            self.progress.setValue(100)
            for index, item in enumerate(self.rows):
                if (item['frame_id'], item['type']) == key:
                    self.table.setItem(index, 8, QtWidgets.QTableWidgetItem('Yes'))
                    break

    def worker_finished(self):
        worker = self.worker
        self.worker = None
        if worker:
            # Firmware prints its menu at startup; do not inject UART commands.
            worker.deleteLater()
        self.update_controls()
        if self.closing:
            self.close()

    def cancel_worker(self):
        if self.worker:
            self.worker.cancel()

    def populate_table(self):
        self.table.setRowCount(len(self.rows))
        for index, row in enumerate(self.rows):
            key = (row['frame_id'], row['type'])
            sensors = (bool(row.get('address0')), bool(row.get('address1')))
            sensor = {(True, False): '1', (False, True): '2', (True, True): 'Stereo'}.get(sensors, '')
            rise, fall = row.get('trigger_ticks'), row.get('end_ticks')
            exposure = '—'
            if rise is not None and fall is not None and fall > rise:
                # The FH_Test capture counter runs at 120 ticks per microsecond.
                exposure = f'{(fall - rise) / 120:.3f}'
            utc_text, local_text = frame_times(row.get('utc_us'))
            for col, value in enumerate((row['frame_id'], sensor, row['type'], row.get('timer_pulse', ''),
                                         row.get('trigger_ticks', '—'), exposure, utc_text or '—', local_text or '—',
                                         'Yes' if key in self.local_files else '')):
                self.table.setItem(index, col, QtWidgets.QTableWidgetItem(str(value)))
        self.table.resizeColumnsToContents()
        if self.rows:
            self.table.selectRow(0)

    def display_selected(self):
        index = self.table.currentRow()
        if self.worker or not 0 <= index < len(self.rows):
            return
        row = self.rows[index]
        try:
            route = Route() if 0 in (row.get('address0'), row.get('address1')) else self.current_route()
        except ValueError as exc:
            self.notice(str(exc))
            return
        files = self.local_files.get((row['frame_id'], row['type']))
        if files:
            operation = 'load'
        elif self.sequence.state == 'export':
            if route.mode and not self.router_available:
                self.notice('Router unavailable. Load the updated hardware and firmware, then refresh export.')
                return
            operation = 'download'
        else:
            self.notice('Enter Ethernet export before downloading this pair.')
            return
        self.run_worker(Worker(operation, self.host.text().strip(), self.port.value(),
                               row=row, folder=self.session, files=files, route=route))

    def current_route(self):
        return Route(self.router_mode.currentIndex(), int(self.router_n.currentText()),
                     *(s.value() for s in self.router_coords)).validate()

    def router_changed(self, *_):
        # A variant has its own disk directory; never reuse another variant's cache.
        self.local_files = {}
        self.arrays = []
        for panel in self.panels:
            panel.clear()
        if self.all_rows:
            self.rows = [r for r in self.all_rows if self.router_mode.currentIndex() != 1 or r['type'] == 'FULL']
            self.populate_table()
        try:
            route = self.current_route()
            if route.mode:
                w, h = route.geometry('FULL')
                self.router_info.setText(f'{w} x {h} | stereo {w*h*4/1048576:.2f} MiB')
            else:
                self.router_info.setText('Original images')
        except ValueError as exc:
            self.router_info.setText(str(exc))
        self.update_controls()

    def navigate(self, direction):
        index = self.table.currentRow() + direction
        if not self.worker and 0 <= index < len(self.rows):
            self.table.selectRow(index)
            self.display_selected()

    def render(self, *_):
        for sensor, pixels in zip(getattr(self, 'display_sensors', (0, 1)), self.arrays):
            panel = self.panels[sensor]
            gray = pixels >> 2 if self.gray.currentIndex() == 0 else pixels & 255
            panel.show_pixels(np.ascontiguousarray(gray, dtype=np.uint8))

    def browse_folder(self):
        folder = QtWidgets.QFileDialog.getExistingDirectory(self, 'Open folder containing RAW stereo pairs', str(self.output_root))
        if not folder:
            return
        try:
            self.router_mode.setCurrentIndex(0)
            pairs, skipped = find_pairs(Path(folder))
            self.invalidate_catalog()
            self.rows = [dict(frame_id=key[0], type=key[1].upper()) for key, _ in pairs]
            self.local_files = {(key[0], key[1].upper()): files for key, files in pairs}
            self.populate_table()
            self.notice(f'{len(pairs)} local pairs; {skipped} incomplete pairs skipped. {folder}')
            self.display_selected()
        except OSError as exc:
            self.notice(str(exc))

    def choose_output(self):
        folder = QtWidgets.QFileDialog.getExistingDirectory(self, 'Download root', str(self.output_root))
        if folder:
            self.output_root = Path(folder)
            self.new_session()

    def save_log(self):
        filename, _ = QtWidgets.QFileDialog.getSaveFileName(self, 'Save console log and raw UART session', str(ROOT / 'uart.log'), 'Logs (*.log);;All files (*)')
        if filename:
            try:
                path = Path(filename)
                path.write_text(self.console.toPlainText(), encoding='utf-8')
                raw_path = path.with_name(path.stem + '.raw-uart' + path.suffix)
                raw_path.write_bytes(bytes(self.raw_uart))
                self.notice(f'Saved console: {path}; complete raw UART session: {raw_path}')
            except OSError as exc:
                self.notice(str(exc))

    def program_paths(self):
        return {key: Path(str(self.settings.value('jtag/' + key, str(path))))
                for key, path in default_paths(ROOT).items()}

    def configure_program(self):
        dialog = QtWidgets.QDialog(self)
        dialog.setWindowTitle('JTAG launch files - existing builds only')
        dialog.resize(950, 350)
        layout = QtWidgets.QVBoxLayout(dialog)
        layout.addWidget(QtWidgets.QLabel('Program & Run resets the board and clears captures. Connect USB JTAG; end Vitis debug sessions.'))
        edits = {}
        for key, path in self.program_paths().items():
            row = QtWidgets.QHBoxLayout()
            layout.addLayout(row)
            row.addWidget(QtWidgets.QLabel(key.upper()))
            edit = QtWidgets.QLineEdit(str(path))
            row.addWidget(edit, 1)
            edits[key] = edit
            def browse(checked=False, field=edit):
                value, _ = QtWidgets.QFileDialog.getOpenFileName(dialog, 'Select launch artifact', field.text())
                if value: field.setText(value)
            self.button(row, 'Browse', browse)
        box = QtWidgets.QDialogButtonBox(enum(QtWidgets.QDialogButtonBox, 'StandardButton', 'Ok') |
                                        enum(QtWidgets.QDialogButtonBox, 'StandardButton', 'Cancel'))
        box.accepted.connect(dialog.accept)
        box.rejected.connect(dialog.reject)
        layout.addWidget(box)
        if (dialog.exec() if hasattr(dialog, 'exec') else dialog.exec_()):
            for key, edit in edits.items(): self.settings.setValue('jtag/' + key, edit.text().strip())

    def program_emmc(self):
        folder = QtWidgets.QFileDialog.getExistingDirectory(
            self, 'Select folder containing BOOT.BIN and image.ub',
            str(self.settings.value('emmc_folder', '')))
        if not folder:
            return
        try:
            files = boot_files(folder)
        except (OSError, ValueError) as exc:
            QtWidgets.QMessageBox.warning(self, 'PetaLinux boot files', str(exc))
            return
        host = self.host.text().strip()
        details = '\n'.join(f'{path.name} ({path.stat().st_size:,} bytes)' for path in files)
        yes = enum(QtWidgets.QMessageBox, 'StandardButton', 'Yes')
        no = enum(QtWidgets.QMessageBox, 'StandardButton', 'No')
        if QtWidgets.QMessageBox.question(
                self, 'Replace eMMC boot files?',
                f'{folder}\n{details}\n\nReplace these files on the eMMC boot volume of {host}?\n'
                'Keep the board powered until verification completes.',
                yes | no, no) != yes:
            return
        self.settings.setValue('emmc_folder', folder)
        worker = Worker('emmc', host, self.port.value(), folder=folder)
        worker.token = uuid.uuid4().hex
        worker.armed = threading.Event()
        worker.arm_reply = b''
        if self.send(b'!' + worker.token.encode('ascii') + b'\n'):
            self.run_worker(worker)

    def program_board(self):
        if self.worker or self.sequence.state not in ('unknown', 'menu', 'export'):
            return
        self.invalidate_catalog()
        self.sequence.reset()
        self.pending_capture = False
        self.deadline = None
        self.arrays = []
        for panel in self.panels: panel.clear()
        self.notice('JTAG launch requested: checking files, then resetting and programming the board. Captures will be cleared.')
        worker = ProgramWorker(self.program_paths())
        worker.log_line.connect(lambda line: self.log_event('JTAG', line))
        self.run_worker(worker)

    def update_controls(self):
        if hasattr(self, 'router_mode'):
            idle_router = self.worker is None
            self.router_mode.setEnabled(idle_router)
            self.router_n.setEnabled(idle_router and self.router_mode.currentIndex() == 1)
            for spin in self.router_coords:
                spin.setEnabled(idle_router and self.router_mode.currentIndex() == 2)
        if not hasattr(self, 'table'):
            return
        state, connected, idle = self.sequence.state, self.serial.isOpen(), self.worker is None
        self.program_button.setEnabled(idle and state in ('unknown', 'menu', 'export'))
        self.program_files.setEnabled(idle)
        self.emmc_button.setEnabled(idle and connected and self.emmc_available and state == 'export'
                                    and bool(self.host.text().strip()))
        self.connect_button.setEnabled(idle)
        self.connect_button.setText('Disconnect' if connected else 'Connect')
        for widget in (self.com, self.baud, self.scan):
            widget.setEnabled(not connected)
        self.start.setEnabled(connected and idle and state in ('menu', 'export'))
        self.rtc_button.setEnabled(connected and idle and state == 'menu')
        ready = (connected and idle and state == 'capturing' and
                 self.sequence.monitor_ready and bool(self.host.text().strip()))
        if not ready and self.monitor_button.isChecked():
            self.monitor_button.setChecked(False)
        self.monitor_button.setEnabled(ready)
        self.sensor_capture.setEnabled(self.start.isEnabled())
        self.stop.setEnabled(connected and state == 'capturing')
        self.export.setEnabled(connected and idle and state == 'menu')
        self.leave.setEnabled(connected and idle and state == 'export')
        self.escape.setEnabled(connected and not (self.worker and self.worker.operation == 'program'))
        self.help_button.setEnabled(connected and idle and state in ('unknown', 'menu'))
        self.lut.setEnabled(connected and idle and state == 'menu')
        self.diag.setEnabled(connected and idle and state == 'export')
        self.attach.setEnabled(idle and state in ('unknown', 'menu', 'export'))
        for widget in (self.command, self.raw_send, self.line_send):
            widget.setEnabled(connected and idle and state in ('unknown', 'menu', 'export'))
        for widget in (self.host, self.port, self.output, self.open_folder):
            widget.setEnabled(idle)
        self.cancel.setEnabled(not idle)
        index = self.table.currentRow()
        selected = 0 <= index < len(self.rows)
        local = selected and (self.rows[index]['frame_id'], self.rows[index]['type']) in self.local_files
        self.download.setEnabled(idle and selected and (local or state == 'export'))
        self.previous.setEnabled(self.monitor is None and idle and index > 0)
        self.next.setEnabled(self.monitor is None and idle and selected and index < len(self.rows) - 1)
        for widget in (self.r, self.exposure, self.seconds):
            widget.setEnabled(idle and state in ('unknown', 'menu', 'export'))
        self.statusBar().showMessage(f"Board: {state.replace('_', ' ')} | UART: {'connected' if connected else 'disconnected'} | "
                                     f"{'Working…' if not idle else 'Idle'} | Closing the window does not stop the board")

    def closeEvent(self, event):
        if self.worker:
            self.closing = True
            self.worker.cancel()
            self.notice('Waiting for background operation to stop…')
            event.ignore()
            return
        if self.monitor is not None:
            self.monitor.close()
        self.serial.close()
        event.accept()


def main():
    app = QtWidgets.QApplication(sys.argv)
    window = FHTest()
    window.show()
    return app.exec() if hasattr(app, 'exec') else app.exec_()


if __name__ == '__main__':
    sys.exit(main())
