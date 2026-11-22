"""Fixed-size live JPEG and client-side crop, all rectangles are end-exclusive."""
from dataclasses import dataclass

W, H = 1024, 768


def centered(center, extent, limit):
    return max(0, min(limit - extent, round(center - extent / 2)))


@dataclass(frozen=True)
class EyeView:
    level: int = 0
    x: int = 0
    y: int = 0
    local_x: int = 0
    local_y: int = 0

    @property
    def step(self):
        return 1 << max(0, 2 - self.level)

    @property
    def local_size(self):
        shift = max(0, self.level - 2)
        return W >> shift, H >> shift

    def wheel(self, inward, u, v):
        level = max(0, min(10, self.level + (1 if inward else -1)))
        if level == self.level:
            return self
        w, h = self.local_size
        cx = self.local_x + u*w
        cy = self.local_y + v*h
        if level > 2:
            # Once native, work exclusively inside the JPEG already received.
            size_x, size_y = W >> (level-2), H >> (level-2)
            return EyeView(level, self.x, self.y, centered(cx,size_x,W), centered(cy,size_y,H))
        if self.level > 2:
            return EyeView(level, self.x, self.y)
        step = 1 << (2-level)
        return EyeView(level, centered(self.x + cx*self.step,W*step,4096),
                       centered(self.y + cy*self.step,H*step,3072))

    def wire(self):
        return self.step,self.x,self.y
