"""Sensor coordinates for the two live monitor viewports (exclusive bounds)."""
from dataclasses import dataclass
from math import floor

SENSOR = (4096, 3072)
OUTPUT_SIZES = ((1024, 768), (2048, 1536))


@dataclass(frozen=True)
class Viewport:
    width: int = 1024
    height: int = 768
    x: int = 0
    y: int = 0
    step: int = 4

    def __post_init__(self):
        if (self.width, self.height) not in OUTPUT_SIZES:
            raise ValueError("Unsupported monitor resolution")
        if self.step not in (1, 2, 4):
            raise ValueError("Unsupported pixel step")
        if not (0 <= self.x <= SENSOR[0] - self.width * self.step and
                0 <= self.y <= SENSOR[1] - self.height * self.step):
            raise ValueError("Viewport outside the sensor")

    @classmethod
    def overview(cls, width, height):
        return cls(width, height, step=SENSOR[0] // width)

    @property
    def bounds(self):
        return (self.x, self.y, self.x + self.width * self.step,
                self.y + self.height * self.step)

    def wheel(self, inward, u, v):
        """u,v are fractions of the displayed image, excluding letterbox bars."""
        if not (0 <= u <= 1 and 0 <= v <= 1):
            raise ValueError("Pointer outside the image")
        step = (max(1, self.step // 2) if inward else
                min(SENSOR[0] // self.width, self.step * 2))

        def anchored(origin, fraction, length, limit):
            offset = floor(origin + fraction * length * (self.step - step) + 0.5)
            return max(0, min(limit - length * step, offset))

        return Viewport(self.width, self.height,
                        anchored(self.x, u, self.width, SENSOR[0]),
                        anchored(self.y, v, self.height, SENSOR[1]), step)
