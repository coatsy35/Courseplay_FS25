"""Bounded cell-centre coverage of the field, excluding islands.

Stamp actual lowered work envelopes and their swept edges, never course lines.
The grid is approximate (normally 0.25 m); large fields use a coarser declared
resolution to bound memory. Horizontal spans avoid testing every cell in Python.
"""
import math


class FieldCoverage:
    def __init__(self, boundary, islands=(), resolution=.25, max_cells=2_000_000):
        self.x0 = min(x for x, z in boundary)
        self.z0 = min(z for x, z in boundary)
        width = max(x for x, z in boundary) - self.x0
        height = max(z for x, z in boundary) - self.z0
        while math.ceil(width / resolution) * math.ceil(height / resolution) > max_cells:
            resolution *= 2
        self.resolution = resolution
        self.nx, self.nz = math.ceil(width / resolution), math.ceil(height / resolution)
        self.rows = [bytearray(self.nx) for _ in range(self.nz)]
        self._fill(boundary, 1)
        for island in islands:
            self._fill(island, 0)
        self.required = sum(row.count(1) for row in self.rows)
        self.previous = None

    def _fill(self, polygon, value):
        if len(polygon) < 3:
            return
        edges = list(zip(polygon, polygon[1:] + polygon[:1]))
        a = polygon[0]
        b = next((q for q in polygon[1:] if q != a), a)
        if all(abs((b[0]-a[0])*(q[1]-a[1])-(b[1]-a[1])*(q[0]-a[0])) < 1e-10 for q in polygon):
            return
        r = self.resolution
        first = max(0, math.ceil((min(z for x, z in polygon) - self.z0) / r - .5))
        last = min(self.nz, math.ceil((max(z for x, z in polygon) - self.z0) / r - .5))
        for j in range(first, last):
            z = self.z0 + (j + .5) * r
            crosses = sorted(a[0] + (z-a[1])*(b[0]-a[0])/(b[1]-a[1])
                             for a, b in edges if (a[1] <= z < b[1]) or (b[1] <= z < a[1]))
            for low, high in zip(crosses[::2], crosses[1::2]):
                lo = max(0, math.ceil((low-self.x0)/r-.5))
                hi = min(self.nx, math.ceil((high-self.x0)/r-.5))
                if hi > lo:
                    self.rows[j][lo:hi] = bytes([value]) * (hi-lo)

    def add_frame(self, frame):
        if not frame['lowered']:
            self.previous = None
            return
        polygon = [frame[k] for k in ('left', 'right', 'rearRight', 'rearLeft')]
        if self.previous is None:
            self._fill(polygon, 0)
        else:
            # Rear and side edges matter during reverse motion and rotation;
            # sweeping the front bar alone can leave artificial sampling gaps.
            # The previous envelope is already covered: only its swept edges
            # add new cells. Avoid repainting a long plough's entire rectangle
            # at every 0.1 s tick, especially along straight working rows.
            for i in range(4):
                n = (i+1) % 4
                self._fill([self.previous[i], self.previous[n], polygon[n], polygon[i]], 0)
        self.previous = polygon

    def finish_vehicle(self):
        # A new vehicle is a separate trajectory, not a sweep from the last one.
        self.previous = None

    def result(self):
        r = self.resolution
        rectangles, active = [], {}
        missing = 0
        for j, row in enumerate(self.rows):
            current = {}
            lo = row.find(b'\x01')
            while lo >= 0:
                hi = row.find(b'\x00', lo)
                if hi < 0:
                    hi = self.nx
                missing += hi-lo
                key = (lo, hi)
                if key in active:
                    rect = active[key]
                    rect[3] += 1
                else:
                    rect = [lo, j, hi-lo, 1]
                    rectangles.append(rect)
                current[key] = rect
                lo = row.find(b'\x01', hi)
            active = current
        return dict(resolution=r, requiredArea=self.required*r*r,
                    workedArea=(self.required-missing)*r*r, missedArea=missing*r*r,
                    gapRuns=[[self.x0+x*r, self.z0+z*r, w*r, h*r] for x, z, w, h in rectangles])
