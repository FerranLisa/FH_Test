"""FH live DMA reader. One owner per process, one outstanding stereo pair."""
import mmap
import os
import struct
import time

class Capture:
    def __init__(self):
        # The physical addresses below must belong to reserved-memory.
        # Refuse access on a legacy or mismatched Linux device tree.
        from pathlib import Path
        expected = struct.pack(">QQ", 0x34000000, 0x800000)
        region_node = Path("/proc/device-tree/reserved-memory/fh-monitor@34000000")
        if (region_node/"reg").read_bytes() != expected or not (region_node/"no-map").exists():
            raise RuntimeError("FH monitor DMA reservation is missing")
        self.fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.maps = []
        def region(addr, size=4096):
            area = mmap.mmap(self.fd, size, offset=addr)
            self.maps.append(area)
            return area
        self.eyes = []
        for i in range(2):
            base = 0xA1000000 + i * 0x40000
            addr = 0x34000000 + i * 0x400000
            self.eyes.append((region(base), region(base+0x10000), region(base+0x20000),
                              region(addr, 0x400000), addr))
        self.reset()

    @staticmethod
    def write(area, offset, value):
        struct.pack_into("<I", area, offset, value)

    @staticmethod
    def read(area, offset):
        return struct.unpack_from("<I", area, offset)[0]

    def reset(self):
        for cfg, _, dma, _, _ in self.eyes:
            self.write(cfg, 8, 2)
            self.write(dma, 0x30, 4)
        time.sleep(.001)
        for cfg, _, dma, _, _ in self.eyes:
            deadline = time.monotonic() + .1
            while self.read(dma, 0x30) & 4:
                if time.monotonic() > deadline:
                    raise RuntimeError("Monitor S2MM reset timeout")
            self.write(cfg, 8, 0)
        self.toggle = 0

    def pair(self, views, stop):
        size = views[0].width * views[0].height
        self.toggle ^= 1
        for (cfg, _, dma, _, addr), view in zip(self.eyes, views):
            self.write(cfg, 0, view.x | (view.y << 16))
            self.write(dma, 0x34, 0x7000)
            self.write(dma, 0x30, 1)
            self.write(dma, 0x48, addr)
            self.write(dma, 0x58, size)
        for (cfg, *_), view in zip(self.eyes, views):
            mode = self.toggle | ((view.width == 2048) << 2) | ((view.step.bit_length()-1) << 3)
            self.write(cfg, 8, mode)
        deadline = time.monotonic() + 1
        while not stop.is_set() and time.monotonic() < deadline:
            finished = []
            for _, info, dma, _, _ in self.eyes:
                status = self.read(info, 0)
                ds = self.read(dma, 0x34)
                ready = status & 7 == self.toggle * 5
                if ds & 0x770 or (ready and status & 8):
                    self.reset()
                    return None
                finished.append(ready and ds & 0x1000 and ds & 2)
            if all(finished):
                ids = [self.read(info, 8) for _, info, _, _, _ in self.eyes]
                if ids[0] != ids[1] or any(self.read(dma,0x58) != size for _,_,dma,_,_ in self.eyes):
                    return None
                return ids[0], [data[:size] for _,_,_,data,_ in self.eyes]
            time.sleep(.001)
        self.reset()
        return None

    def close(self):
        try:
            self.reset()
        finally:
            for area in self.maps:
                area.close()
            os.close(self.fd)
