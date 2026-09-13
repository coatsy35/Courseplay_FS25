"""Geometry for experimental aligned entries; independent of CP's baseline.

Angles are radians, distances metres, and heading zero points along positive z.
The settling estimate applies to one passive trailer behind a straight tractor.
It is a candidate seed, not a swept-boundary or joint-limit feasibility result.
"""

from dataclasses import dataclass
import math


@dataclass(frozen=True)
class Alignment:
    angle: float
    centre_offset: float
    edge_error: float
    aligned: bool


def _finite(*values):
    if any(isinstance(v, bool) or not isinstance(v, (int, float)) or
           not math.isfinite(v) for v in values):
        raise ValueError('Geometry must contain finite numbers')


def assess_envelope(front, rear, heading, width, row_origin, row_heading,
                    angle_tolerance=math.radians(2), edge_tolerance=.1):
    """Compare both ends of the working envelope with the intended row edges.

    front/rear are the centres of the actual soil-engaging edges, not body or
    hitch markers. Evaluate every attached working implement independently.
    Facing backwards fails even when its footprint occupies the correct lane.
    Tolerances here are experimental bench criteria, not agricultural standards.
    """
    _finite(*front, *rear, heading, width, *row_origin, row_heading,
            angle_tolerance, edge_tolerance)
    if width <= 0 or not 0 < angle_tolerance < math.pi / 2 or edge_tolerance <= 0:
        raise ValueError('Width and tolerances must be positive; angle must be below 90 degrees')
    angle = math.atan2(math.sin(heading-row_heading), math.cos(heading-row_heading))
    across = (math.cos(row_heading), -math.sin(row_heading))
    offsets = [(p[0]-row_origin[0])*across[0] +
               (p[1]-row_origin[1])*across[1] for p in (front, rear)]
    # Project each physical edge endpoint, then compare it with its own target
    # edge. Checking only the centre or tractor angle misses long angled tools.
    edge_error = max(abs(offset + side*width/2*(math.cos(angle)-1))
                     for offset in offsets for side in (-1, 1))
    return Alignment(angle, offsets[0], edge_error,
                     abs(angle) <= angle_tolerance and edge_error <= edge_tolerance)


def straightening_distance(length, hitch, front_setback, rear_setback, width,
                           initial_angle, angle_tolerance=math.radians(2),
                           edge_tolerance=.1):
    """Straight tractor travel needed for a passive trailer to meet both limits.

    Tractor is already on the target line and heading. The hitch-to-axle length
    is length; work marker setbacks are measured from the tractor reference in
    the aligned state. Off-centre hitches, steering trailers and chained joints
    require their own propagation model and must not use this estimate blindly.
    """
    _finite(length, hitch, front_setback, rear_setback, width, initial_angle,
            angle_tolerance, edge_tolerance)
    if length <= 0 or hitch < 0 or front_setback < 0 or rear_setback < front_setback:
        raise ValueError('Invalid trailer length, hitch or working marker setbacks')
    angle = abs(math.atan2(math.sin(initial_angle), math.cos(initial_angle)))
    if angle >= math.pi/2:
        raise ValueError('Straightening seed requires articulation below 90 degrees')

    def aligned(a):
        # Hitch stays on the row. A work marker's lateral displacement is its
        # signed distance from that hitch multiplied by sin(trailer heading).
        front = ((hitch-front_setback)*math.sin(a), 0)
        rear = ((hitch-rear_setback)*math.sin(a), 0)
        return assess_envelope(front, rear, a, width, (0, 0), 0,
                               angle_tolerance, edge_tolerance).aligned

    if aligned(angle):
        return 0.0
    lo, hi = 0.0, angle
    for _ in range(60):
        mid = (lo+hi)/2
        if aligned(mid):
            lo = mid
        else:
            hi = mid
    # Exact passive-trailer solution for a hitch travelling on a straight line:
    # tan(phi(s)/2) = tan(phi(0)/2) * exp(-s/length).
    return length * math.log(math.tan(angle/2)/math.tan(lo/2))
