"""Shared Router geometry and metadata validation (no Qt dependency)."""
from dataclasses import dataclass


@dataclass(frozen=True)
class Route:
    mode: int = 0
    n: int = 2
    x0: int = 0
    y0: int = 0
    x1: int = 4096
    y1: int = 1024

    def validate(self):
        if self.mode not in (0, 1, 2):
            raise ValueError('Unknown Router mode')
        if self.mode == 1 and self.n not in (1, 2, 4, 8, 16):
            raise ValueError('Subsampling n must be 1, 2, 4, 8 or 16')
        if self.mode == 2 and not (0 <= self.x0 < self.x1 <= 4096 and 0 <= self.y0 < self.y1 <= 1024):
            raise ValueError('Rectangle must satisfy 0 <= Xi < Xj <= 4096 and 0 <= Yi < Yj <= 1024')
        return self

    @property
    def key(self):
        self.validate()
        return 'raw' if self.mode == 0 else (f'sub{self.n}' if self.mode == 1 else f'crop_{self.x0}_{self.y0}_{self.x1}_{self.y1}')

    def geometry(self, kind):
        self.validate()
        if self.mode == 0:
            return 4096, 3072 if kind == 'FULL' else 1024
        if self.mode == 1:
            if kind != 'FULL':
                raise ValueError('Subsampling is available only for FULL frames')
            return 4096 // self.n, 3072 // self.n
        return self.x1 - self.x0, self.y1 - self.y0

    def command(self, fid):
        self.validate()
        if self.mode == 0:
            return f'PAIR {fid}\n'.encode('ascii')
        return f'ROUTEPAIR {fid} {self.mode} {self.n} {self.x0} {self.y0} {self.x1} {self.y1}\n'.encode('ascii')


def validate_geometry(version, mode, kind, width, height, roi_y, ox, oy, sx, sy):
    if kind not in (1, 2) or roi_y != (0 if kind == 1 else 1024):
        raise ValueError('Invalid source geometry')
    if version == 1:
        if mode or (width, height) != (4096, 3072 if kind == 1 else 1024):
            raise ValueError('Invalid raw geometry')
    elif version == 2 and mode == 1:
        if kind != 1 or sx != sy or sx not in (1, 2, 4, 8, 16) or (ox, oy) != (0, 0) or (width, height) != (4096 // sx, 3072 // sx):
            raise ValueError('Invalid subsampling geometry')
    elif version == 2 and mode == 2:
        if sx != 1 or sy != 1 or width < 1 or height < 1 or ox < 0 or oy < 1024 or ox + width > 4096 or oy + height > 2048:
            raise ValueError('Invalid rectangle geometry')
    else:
        raise ValueError('Unsupported Router version/mode')
