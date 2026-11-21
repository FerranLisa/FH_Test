#!/usr/bin/env python3
"""View FH stereo RAW downloads. Install: pip install PyQt6 numpy

Run: python images/view_stereo.py [folder]
Default folder is the directory containing this script. PyQt5 also supported.
"""
import argparse
import json
import re
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'software' / 'host'))
from fh_route import validate_geometry

try:
    import numpy as np
    try:
        from PyQt6 import QtCore, QtGui, QtWidgets
    except ImportError:
        from PyQt5 import QtCore, QtGui, QtWidgets
except ImportError as exc:
    raise SystemExit(f"Missing dependency: {exc}\nInstall with: pip install PyQt6 numpy")


def enum(cls, group, name):
    return getattr(getattr(cls, group, cls), name)


PATTERN = re.compile(r"frame_(\d+)_s([01])_(full|roi)\.raw$", re.I)


def find_pairs(folder):
    groups = {}
    for path in folder.iterdir():
        match = PATTERN.fullmatch(path.name)
        if match and path.is_file():
            fid, sensor, kind = match.groups()
            key = (int(fid), kind.lower())
            groups.setdefault(key, {})[int(sensor)] = path
    pairs = [(key, files) for key, files in sorted(groups.items())
             if 0 in files and 1 in files]
    return pairs, sum(len(files) != 2 for files in groups.values())


def read_image(path, fid, sensor, kind):
    width, height = 4096, 3072 if kind == "full" else 1024
    sidecar = path.with_suffix(".json")
    meta = json.loads(sidecar.read_text(encoding="utf-8-sig")) if sidecar.exists() else {}
    if meta.get('protocol') in (2, 4):
        width, height = meta['width'], meta['height']
        validate_geometry(2, meta['router_mode'], 1 if kind == 'full' else 2,
                          width, height, meta['roi_y'], meta['origin_x'], meta['origin_y'],
                          meta['step_x'], meta['step_y'])
    expected = dict(frame_id=fid, sensor=sensor, type=kind.upper(),
                    width=width, height=height, bytes_per_pixel=2,
                    pixel_type="uint16", endianness="little")
    for name, value in expected.items():
        if name in meta and meta[name] != value:
            raise ValueError(f"{sidecar.name}: unexpected {name}={meta[name]!r}")
    size = width * height * 2
    if path.stat().st_size != size:
        raise ValueError(f"{path.name}: expected {size:,} bytes")
    pixels = np.fromfile(path, dtype="<u2")
    if pixels.size != width * height:
        raise ValueError(f"{path.name}: file changed while reading")
    if np.any(pixels > 1023):
        raise ValueError(f"{path.name}: values exceed the 10-bit range 0–1023")
    return pixels.reshape(height, width), meta


class ImagePanel(QtWidgets.QLabel):
    def __init__(self):
        super().__init__()
        self.original = None
        self.metadata_text = ""
        self.hover_position = None
        self.setMouseTracking(True)
        self.hover_timer = QtCore.QTimer(self)
        self.hover_timer.setSingleShot(True)
        self.hover_timer.setInterval(600)
        self.hover_timer.timeout.connect(self.show_metadata)
        self.popup = QtWidgets.QLabel(self, enum(QtCore.Qt, "WindowType", "ToolTip"))
        self.popup.setTextFormat(enum(QtCore.Qt, "TextFormat", "PlainText"))
        self.popup.setAttribute(enum(QtCore.Qt, "WidgetAttribute", "WA_ShowWithoutActivating"))
        self.popup.setAttribute(enum(QtCore.Qt, "WidgetAttribute", "WA_TransparentForMouseEvents"))
        self.popup.setStyleSheet("background: #fffbdc; color: #202020; "
                                 "border: 1px solid #777; padding: 10px; font-family: Consolas;")
        self.setAlignment(enum(QtCore.Qt, "AlignmentFlag", "AlignCenter"))
        self.setMinimumSize(160, 120)
        ignored = enum(QtWidgets.QSizePolicy, "Policy", "Ignored")
        self.setSizePolicy(ignored, ignored)
        self.setStyleSheet("background: #171717; color: #cccccc;")

    def show_pixels(self, pixels):
        height, width = pixels.shape
        # Copy owns its storage after the temporary NumPy array goes away.
        image = QtGui.QImage(pixels.data, width, height, pixels.strides[0],
                             enum(QtGui.QImage, "Format", "Format_Grayscale8")).copy()
        self.original = QtGui.QPixmap.fromImage(image)
        self.fit()

    def clear_image(self):
        self.hide_metadata()
        self.metadata_text = ""
        self.original = None
        self.clear()

    def set_metadata(self, filename, metadata):
        self.hide_metadata()
        self.metadata_text = filename + "\n\n" + json.dumps(metadata, indent=2, ensure_ascii=False)

    def hide_metadata(self):
        self.hover_timer.stop()
        self.popup.hide()

    def over_image(self, point):
        pixmap = self.pixmap()
        if self.original is None or pixmap is None or pixmap.isNull():
            return False
        rect = QtCore.QRect(0, 0, pixmap.width(), pixmap.height())
        rect.moveCenter(self.contentsRect().center())
        return rect.contains(point)

    def mouseMoveEvent(self, event):
        self.hide_metadata()
        self.hover_position = QtGui.QCursor.pos()
        if self.metadata_text and self.over_image(self.mapFromGlobal(self.hover_position)):
            self.hover_timer.start()
        super().mouseMoveEvent(event)

    def enterEvent(self, event):
        self.hover_position = QtGui.QCursor.pos()
        if self.metadata_text and self.over_image(self.mapFromGlobal(self.hover_position)):
            self.hover_timer.start()
        super().enterEvent(event)

    def leaveEvent(self, event):
        self.hide_metadata()
        super().leaveEvent(event)

    def hideEvent(self, event):
        self.hide_metadata()
        super().hideEvent(event)

    def show_metadata(self):
        position = QtGui.QCursor.pos()
        if (position != self.hover_position or not self.isVisible()
                or not self.window().isActiveWindow()
                or not self.over_image(self.mapFromGlobal(position))):
            return
        self.popup.setText(self.metadata_text)
        self.popup.adjustSize()
        screen = QtWidgets.QApplication.screenAt(position) or QtWidgets.QApplication.primaryScreen()
        bounds = screen.availableGeometry()
        x = min(position.x() + 18, bounds.right() - self.popup.width() + 1)
        y = min(position.y() + 18, bounds.bottom() - self.popup.height() + 1)
        self.popup.move(max(bounds.left(), x), max(bounds.top(), y))
        self.popup.show()

    def fit(self):
        self.hide_metadata()
        if self.original is not None:
            self.setPixmap(self.original.scaled(
                self.size(), enum(QtCore.Qt, "AspectRatioMode", "KeepAspectRatio"),
                enum(QtCore.Qt, "TransformationMode", "FastTransformation")))

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.fit()


class Viewer(QtWidgets.QMainWindow):
    def __init__(self, folder):
        super().__init__()
        self.folder = folder
        self.pairs, self.index, self.arrays = [], 0, []
        self.setWindowTitle("FH stereo image viewer")
        self.resize(1400, 700)
        central = QtWidgets.QWidget()
        self.setCentralWidget(central)
        layout = QtWidgets.QVBoxLayout(central)
        folder_label = QtWidgets.QLabel(str(folder))
        folder_label.setWordWrap(True)
        layout.addWidget(folder_label)
        controls = QtWidgets.QHBoxLayout()
        layout.addLayout(controls)
        self.buttons = []
        for title, target in [("First", lambda: 0), ("Previous", lambda: self.index - 1),
                              ("Next", lambda: self.index + 1),
                              ("Last", lambda: len(self.pairs) - 1)]:
            button = QtWidgets.QPushButton(title)
            button.clicked.connect(lambda checked=False, target=target: self.load(target()))
            controls.addWidget(button)
            self.buttons.append(button)
        refresh = QtWidgets.QPushButton("Refresh folder")
        refresh.clicked.connect(self.refresh)
        controls.addWidget(refresh)
        controls.addStretch()
        controls.addWidget(QtWidgets.QLabel("Grayscale:"))
        self.mode = QtWidgets.QComboBox()
        self.mode.addItems(["8 MSBs — bits 9–2", "8 LSBs — bits 7–0"])
        self.mode.setToolTip("MSB: pixel >> 2. LSB: pixel & 255. No automatic contrast scaling.")
        self.mode.currentIndexChanged.connect(self.render)
        controls.addWidget(self.mode)
        self.info = QtWidgets.QLabel()
        self.info.setWordWrap(True)
        layout.addWidget(self.info)
        row = QtWidgets.QHBoxLayout()
        layout.addLayout(row, 1)
        self.panels = []
        for sensor in (0, 1):
            column = QtWidgets.QVBoxLayout()
            column.addWidget(QtWidgets.QLabel(f"Sensor {sensor + 1}"))
            panel = ImagePanel()
            column.addWidget(panel, 1)
            row.addLayout(column, 1)
            self.panels.append(panel)
        shortcut_class = getattr(QtGui, "QShortcut", None) or QtWidgets.QShortcut
        self.shortcuts = []
        for key, target in [("Left", lambda: self.index - 1), ("Right", lambda: self.index + 1),
                            ("Home", lambda: 0), ("End", lambda: len(self.pairs) - 1)]:
            shortcut = shortcut_class(QtGui.QKeySequence(key), self)
            shortcut.activated.connect(lambda target=target: self.load(target()))
            self.shortcuts.append(shortcut)
        self.refresh()

    def refresh(self):
        current = self.pairs[self.index][0] if self.pairs else None
        try:
            self.pairs, skipped = find_pairs(self.folder)
        except OSError as exc:
            QtWidgets.QMessageBox.warning(self, "Folder error", str(exc))
            return
        self.statusBar().showMessage(
            f"{len(self.pairs)} stereo pairs; {skipped} incomplete pairs skipped. "
            "Arrow keys: previous/next; Home/End: first/last. Refresh after downloading.")
        self.load(next((i for i, (key, _) in enumerate(self.pairs) if key == current), 0))

    def load(self, index):
        self.arrays = []
        for panel in self.panels:
            panel.clear_image()
        if not self.pairs:
            self.info.setText("No complete stereo pairs found (frame_<ID>_s0/s1_full/roi.raw).")
            for button in self.buttons:
                button.setEnabled(False)
            return
        self.index = max(0, min(index, len(self.pairs) - 1))
        for button, enabled in zip(self.buttons, [self.index > 0, self.index > 0,
                                  self.index < len(self.pairs)-1, self.index < len(self.pairs)-1]):
            button.setEnabled(enabled)
        (fid, kind), files = self.pairs[self.index]
        try:
            loaded = [read_image(files[s], fid, s, kind) for s in (0, 1)]
            pulses = [meta.get("timer_pulse") for _, meta in loaded]
            if all(p is not None for p in pulses) and pulses[0] != pulses[1]:
                raise ValueError("Stereo timer pulses do not match")
            self.arrays = [pixels for pixels, _ in loaded]
            for sensor, (_, metadata) in enumerate(loaded):
                self.panels[sensor].set_metadata(files[sensor].with_suffix(".json").name, metadata)
            height, width = self.arrays[0].shape
            self.info.setText(f"Pair {self.index+1}/{len(self.pairs)}  |  FrameID {fid}  |  "
                              f"{kind.upper()} {width} × {height}  |  Timer pulse {pulses[0]}\n"
                              f"{files[0].name}   +   {files[1].name}")
            self.render()
        except (OSError, ValueError, TypeError, AttributeError) as exc:
            self.info.setText(f"Cannot display FrameID {fid}: {exc}")

    def render(self, *_):
        for panel, pixels in zip(self.panels, self.arrays):
            gray = (pixels >> 2) if self.mode.currentIndex() == 0 else (pixels & 255)
            panel.show_pixels(np.ascontiguousarray(gray, dtype=np.uint8))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", nargs="?", type=Path, default=Path(__file__).resolve().parent)
    args = parser.parse_args()
    if not args.folder.is_dir():
        parser.error(f"Folder does not exist: {args.folder}")
    app = QtWidgets.QApplication(sys.argv[:1])
    viewer = Viewer(args.folder.resolve())
    viewer.show()
    return app.exec() if hasattr(app, "exec") else app.exec_()


if __name__ == "__main__":
    sys.exit(main())
