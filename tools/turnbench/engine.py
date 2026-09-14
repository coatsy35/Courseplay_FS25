"""Offline CP algorithm harness with an explicitly approximate planar movement model."""

from dataclasses import asdict, dataclass, replace
import hashlib
import math
import xml.etree.ElementTree as ET
from pathlib import Path

from lupa.lua52 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    'scripts/ai/turns/TurnManeuver.lua', 'scripts/ai/turns/TurnContext.lua',
    'scripts/ai/turns/AITurn.lua', 'scripts/ai/turns/WorkStartHandler.lua',
    'scripts/ai/turns/WorkEndHandler.lua', 'scripts/pathfinder/ReedsShepp.lua',
    'scripts/pathfinder/ReedsSheppSolver.lua',
    'scripts/ai/util/AIUtil.lua', 'scripts/pathfinder/State3D.lua',
    'scripts/pathfinder/Dubins.lua', 'scripts/pathfinder/PathfinderUtil.lua',
    'scripts/Course.lua', 'scripts/Waypoint.lua',
    'scripts/CpObject.lua', 'scripts/util/CpMathUtil.lua', 'scripts/geometry/Vector.lua',
    'scripts/courseGenerator/WaypointAttributes.lua', 'scripts/pathfinder/AnalyticSolution.lua',
    'tools/turnbench/engine.py', 'tools/turnbench/bridge.lua', 'tools/turnbench/requirements.txt',
    'scripts/courseGenerator/RowPattern.lua', 'config/VehicleConfigurations.xml',
    'scripts/ai/AIReverseDriver.lua',
    'tools/turnbench/full_course.py', 'scripts/ai/turns/Corner.lua',
    'tools/turnbench/alignment.py', 'tools/turnbench/aligned_turn.py',
    'tools/turnbench/aligned_pattern.py',
]


@dataclass(frozen=True)
class Scenario:
    width: float = 6
    length: float = 9
    radius: float = 9
    generatorRadius: float = 5
    hitch: float = 2
    front: float = 11
    back: float = 12
    clearance: float = 13
    headland: float = 38
    speed: float = 3
    lowerSeconds: float = 2
    raiseSeconds: float = 1
    raiseLate: bool = True
    turnType: str = 'dubins'
    lookahead: float = 3
    extension: float = 0
    side: int = 1
    entryAngle: float = 45
    entry: bool = False
    drill: bool = True
    lowerEarly: bool = True
    tight: bool = True
    tightDistance: float = 0
    articulated: bool = False
    pattern: bool = False
    passes: int = 4
    fieldLength: float = 160
    headlandRows: int = 0  # Legacy single-turn setups specify depth directly.
    rowPattern: str = 'alternating'
    rowsPerLand: int = 6
    circles: int = 3
    enforceBoundary: bool = False
    rowSpacing: float = 0  # Internal target separation; zero uses working width.
    fieldShape: str = 'rectangle'
    reverseCourse: bool = False
    irregularInset: float = 36
    slopeSide: str = 'left'
    edgeAngle: float = 25
    courseLayout: bool = False
    fieldWidth: float = 220
    rowAngle: float = 90
    headlandOverlap: float = 5
    roundHeadlands: int = 0
    headlandFirst: bool = True
    clockwise: bool = True
    custom: bool = False
    mounted: bool = False
    targetZ: float = 0  # Internal incoming row endpoint in the outgoing row frame.
    targetExplicit: bool = False  # Internal: zero lateral displacement is a real target.
    targetX: float = 0
    targetHeading: float = 180
    allowReverse: bool = False  # Legacy API default; enabled explicitly by the UI.
    reverseSpeed: float = 1.5
    fullCourse: bool = False
    rowsToSkip: int = 0
    centreClockwise: bool = False
    spiralFromInside: bool = False
    fieldMargin: float = 0
    sharpenCorners: bool = True
    loopTurnsOnHeadland: bool = False
    autoRowAngle: bool = False
    evenRowWidth: bool = False
    useBaseline: bool = False
    startX: float = 5
    startZ: float = 5
    vehicles: int = 1
    vehicleIndex: int = 1
    sameTurnWidth: bool = False
    narrowField: bool = False
    islandCount: int = 0
    islandSize: float = 15
    bypassIslands: bool = True
    alignedPlanner: bool = False
    alignedPattern: bool = False
    approachLength: float = 0  # Experimental final straight; zero preserves CP.
    boundarySlope: float = 0  # Local inner boundary z = slope*x.
    turnBias: float = 0  # Lateral placement of the final curved pull-in.
    finalStraight: float = 4
    islandHeadlands: int = 1
    islandClockwise: bool = True

    @classmethod
    def parse(cls, data):
        if not isinstance(data, dict):
            raise ValueError('Scenario must be an object')
        if set(data) - set(cls.__dataclass_fields__):
            raise ValueError('Unknown scenario field')
        if data.get('fieldShape') == 'sloping' and 'rowAngle' not in data:
            data = dict(data, rowAngle=0)
        p = cls(**data)
        bounds = {'width': (.5, 57), 'length': (1, 25), 'radius': (2, 25), 'generatorRadius': (2, 25),
                  'targetX': (-2000,2000), 'targetHeading': (-360,360),
                  'reverseSpeed': (.3,4), 'fieldMargin': (-5,6), 'startX': (0,100),
                  'startZ': (0,100), 'islandSize': (2,100),
                  'hitch': (0, 6), 'front': (0.1, 35), 'back': (0.1, 45),
                  'clearance': (0, 50), 'headland': (0, 2400), 'speed': (0.5, 8),
                  'fieldLength': (100, 1000), 'fieldWidth': (100, 1000), 'rowSpacing': (0, 2000),
                  'irregularInset': (10, 55), 'rowAngle': (0, 180), 'edgeAngle': (5, 45), 'headlandOverlap': (0, 25), 'targetZ': (-2000, 2000),
                  'lowerSeconds': (0, 10), 'raiseSeconds': (0, 10), 'lookahead': (1, 10),
                  'extension': (0, 40), 'entryAngle': (-70, 70), 'tightDistance': (0, 100),
                  'approachLength': (0, 150), 'boundarySlope': (-1, 1), 'turnBias': (-12, 12),
                  'finalStraight': (1, 30)}
        for key, (lo, hi) in bounds.items():
            value = getattr(p, key)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not lo <= value <= hi:
                raise ValueError(f'{key} must be between {lo} and {hi}')
        for key in ('entry', 'drill', 'lowerEarly', 'raiseLate', 'tight', 'articulated', 'pattern', 'enforceBoundary','courseLayout','headlandFirst','clockwise','custom','mounted'):
            if type(getattr(p, key)) is not bool:
                raise ValueError(f'{key} must be boolean')
        for key in ('alignedPlanner','alignedPattern','targetExplicit','reverseCourse','allowReverse','fullCourse','centreClockwise','spiralFromInside','sharpenCorners','loopTurnsOnHeadland',
                    'autoRowAngle','evenRowWidth','useBaseline','sameTurnWidth','narrowField','bypassIslands','islandClockwise'):
            if type(getattr(p,key)) is not bool:
                raise ValueError(f'{key} must be boolean')
        for key,lo,hi in (('rowsToSkip',0,6),('vehicles',1,5),('vehicleIndex',1,5),('islandCount',0,3),('islandHeadlands',1,10)):
            if type(getattr(p,key)) is not int or not lo <= getattr(p,key) <= hi:
                raise ValueError(f'{key} must be a whole number between {lo} and {hi}')
        if p.vehicleIndex > p.vehicles:
            raise ValueError('Selected vehicle exceeds the number of vehicles')
        if p.fullCourse and not p.courseLayout:
            raise ValueError('Complete playback requires a generated course')
        if p.fullCourse and p.fieldWidth*p.fieldLength/p.width>120000:
            raise ValueError('Course exceeds the interactive playback limit; reduce field size or increase working width')
        if p.narrowField and (p.vehicles>1 or not p.headlandFirst or p.headlandRows==0):
            raise ValueError('Two-sided headlands require one vehicle, headlands first and at least one headland')
        if type(p.side) is not int or p.side not in (-1, 1):
            raise ValueError('side must be -1 or 1')
        if p.back < p.front:
            raise ValueError('Rear marker distance must be at least the front marker distance')
        if p.turnType not in ('dubins', 'reedsShepp', 'headlandLoop'):
            raise ValueError('Unsupported turn type')
        if p.entry and p.turnType != 'dubins':
            raise ValueError('The synthetic entry case has no turn-type selection')
        if p.entry and p.mounted:
            raise ValueError('The angled trailer entry case requires a trailed implement')
        for key, lo, hi in (('passes', 1, 32), ('headlandRows', 0, 40), ('rowsPerLand', 1, 24), ('circles', 1, 12), ('roundHeadlands',0,50)):
            if type(getattr(p, key)) is not int or not lo <= getattr(p, key) <= hi:
                raise ValueError(f'{key} must be a whole number between {lo} and {hi}')
        if p.headlandRows or p.courseLayout:
            p = replace(p, headland=p.headlandRows*p.width)
        if p.pattern and (p.entry or p.turnType != 'dubins'):
            raise ValueError('Field runs currently support lightbulb turns only')
        if p.rowPattern not in ('alternating','lands','racetrack','spiral'):
            raise ValueError('Unsupported working-row pattern')
        if p.fieldShape not in ('rectangle','irregular','sloping'):
            raise ValueError('Unsupported field shape')
        if p.slopeSide not in ('left', 'right'):
            raise ValueError('Sloping side must be left or right')
        if p.fieldShape == 'sloping' and not p.alignedPlanner and p.fieldLength*math.tan(math.radians(p.edgeAngle)) >= p.fieldWidth:
            raise ValueError('The sloping side reaches the opposite boundary. Increase field width, reduce field length or reduce the side angle.')
        if p.pattern and not p.courseLayout and p.fieldLength-2*p.headland < 40:
            raise ValueError('Leave at least 40 m between the headlands for the two 20 m coverage samples')
        if p.pattern and not p.courseLayout and p.fieldShape == 'rectangle' and p.fieldWidth+1e-8 < 2*p.headland+p.passes*p.width:
            raise ValueError(f'Field width must be at least {2*p.headland+p.passes*p.width:.1f} m for these passes and side headlands')
        return p


def wrap(a):
    return math.atan2(math.sin(a), math.cos(a))


def point(x, z, t, across=0, along=0):
    return [x + across * math.cos(t) + along * math.sin(t),
            z - across * math.sin(t) + along * math.cos(t)]


class Bridge:
    def __init__(self, p, turn_z=None, turn_pose=None):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().ROOT = ROOT.as_posix()
        self.lua.execute(Path(__file__).with_name('bridge.lua').read_text(encoding='utf-8'))
        params = asdict(p)
        if turn_z is not None:
            params['turnZ'] = turn_z
        if turn_pose is not None:
            params.update(turnX=turn_pose['x'], turnZ=turn_pose['z'], turnTheta=turn_pose['theta'])
        if params['tightDistance'] == 0:
            del params['tightDistance']
        self.g = self.lua.globals()
        self.rig = self.g.makeRig(self.lua.table_from(params))
        raw = self.g.readPath(self.rig)
        self.path = [dict(raw[i]) for i in range(1, len(raw) + 1)]
        end=len(self.path)-1
        for i in range(len(self.path)-1,-1,-1):
            w=self.path[i]
            if i==len(self.path)-1 or bool(w.get('reverse'))!=bool(self.path[i+1].get('reverse')):
                end=i
            w['legEnd']=end
            w['navPoint']=point(w['x'],w['z'],w['t'],across=0 if w.get('reverse') else -w.get('offset',0))


def inside(x, z, poly):
    sign = []
    for a, b in zip(poly, poly[1:] + poly[:1]):
        sign.append((b[0]-a[0])*(z-a[1]) - (b[1]-a[1])*(x-a[0]))
    return all(v >= -1e-9 for v in sign) or all(v <= 1e-9 for v in sign)


class Coverage:
    """Cell-centre raster of the first 20 m; swept work-envelope polygons, not tyre marks."""
    resolution = 0.25

    def __init__(self, width, target):
        r = self.resolution
        self.x0 = target - width / 2
        self.nx = math.ceil(width / r)
        self.nz = int(20 / r)
        self.cells = set()
        self.width = width
        self.remaining = [set(range(self.nz)) if (i+.5)*r < width else set() for i in range(self.nx)]

    def stamp(self, poly):
        r = self.resolution
        xmin, xmax = min(p[0] for p in poly), max(p[0] for p in poly)
        zmin, zmax = min(p[1] for p in poly), max(p[1] for p in poly)
        if zmax < -self.nz*r or zmin > 0 or xmax < self.x0 or xmin > self.x0+self.width:
            return
        for i in range(max(0, int(math.floor((xmin-self.x0)/r))), min(self.nx, int(math.ceil((xmax-self.x0)/r)))):
            x = self.x0 + (i+0.5)*r
            if x > self.x0+self.width:
                continue
            lo,hi=max(0, int(math.floor(-zmax/r))), min(self.nz, int(math.ceil(-zmin/r)))
            for j in tuple(self.remaining[i]):
                if lo <= j < hi and inside(x,-(j+0.5)*r,poly):
                    self.cells.add((i,j))
                    self.remaining[i].remove(j)

    def gaps(self):
        r = self.resolution
        return [[round(self.x0+(i+0.5)*r,3), -(j+0.5)*r]
                for i in range(self.nx) if (i+0.5)*r < self.width
                for j in range(self.nz) if (i,j) not in self.cells]


def simulate_exit(p, bridge, dt, start=None, final=False):
    """Straight outgoing row; real CP raise predicate, approximate work-off timer.

    The timer keeps the entire rectangular envelope active until it expires.
    This is not a simulation of progressive hydraulic lifting or individual shares.
    """
    frames, events = [], []
    coverage = Coverage(p.width, 0)
    x, z, theta, phi = (0, p.front-20, 0, 0) if start is None else (
        start['x'], start['z'], start['theta'], start['phi'])
    requested_at = None
    inactive = False
    overshoot = 0
    previous_bar = None
    previous_entry_pose = None
    for tick in range(int((180+max(0,-z)/p.speed)/dt)):
        now = tick*dt
        hitch = point(x,z,theta,along=-p.hitch)
        axle = point(*hitch,phi,along=0 if p.mounted else -p.length)
        work = point(*axle,phi,along=(0 if p.mounted else p.length)+p.hitch-p.front)
        rear_edges = [point(*work,phi,across=a,along=-(p.back-p.front)) for a in (-p.width/2,p.width/2)]
        clear = (min(v[1]-p.boundarySlope*v[0] for v in rear_edges) >= 0
                 if p.alignedPlanner else bridge.g.shouldRaise(bridge.rig,*work,phi,p.width,p.back-p.front))
        if requested_at is None and clear:
            requested_at = now
            events.append({'time':round(now,2),'kind':'Raise requested','angle':0,'error':0})
        if requested_at is not None and not inactive and now-requested_at >= p.raiseSeconds:
            inactive = True
            events.append({'time':round(now,2),'kind':'Working envelope inactive','angle':0,'error':0})
        left, right = point(*work,phi,across=p.width/2), point(*work,phi,across=-p.width/2)
        rear_left = point(*left,phi,along=-(p.back-p.front))
        rear_right = point(*right,phi,along=-(p.back-p.front))
        if not inactive:
            coverage.stamp([left,right,rear_right,rear_left])
            if previous_bar:
                coverage.stamp([previous_bar[0],previous_bar[1],right,left])
            previous_bar = [left,right]
            overshoot = max(overshoot,work[1])
        if tick % max(1,round(.1/dt)) == 0:
            frames.append({'time':round(now,2),'x':x,'z':z,'theta':theta,'phi':phi,
                           'hitch':hitch,'axle':axle,
                           'work':work,'left':left,'right':right,
                           'rearLeft':rear_left,'rearRight':rear_right,'lowered':not inactive,
                           'state':'Exit clearance' if inactive else ('Raising' if requested_at is not None else 'Exit working'),
                           'phase':'exit','offset':0,'ix':0,'angle':math.degrees(phi),'error':work[0]})
            # Keep the join on the playback sample grid; the model waits for lifting.
            if inactive and (final or z >= p.clearance+p.extension):
                if final:
                    frames[-1]['state'] = 'Finished'
                events.append({'time':round(now,2),'kind':'Field run finished' if final else 'Turn started','angle':0,'error':0})
                return frames, events, coverage, overshoot
        # Continue tracking the outgoing row without resetting residual implement yaw.
        gx, gz = 0, z+p.lookahead
        lateral = (gx-x)*math.cos(theta)-(gz-z)*math.sin(theta)
        curvature = max(-1/p.radius,min(1/p.radius,2*lateral/((gx-x)**2+(gz-z)**2)))
        distance = p.speed*dt
        mid = theta+curvature*distance/2
        x += distance*math.sin(mid)
        z += distance*math.cos(mid)
        theta = wrap(theta+curvature*distance)
        next_hitch = point(x,z,theta,along=-p.hitch)
        hx,hz = next_hitch[0]-hitch[0],next_hitch[1]-hitch[1]
        phi = theta if p.mounted else wrap(bridge.g.nextTrailerHeading(phi,math.atan2(hx,hz),math.hypot(hx,hz),p.length))
    raise ValueError('Exit did not complete within the model time limit')


def route_preview(p, bridge):
    """No invented reversing controller or implement-coverage claims."""
    z = bridge.path[0]['z']
    x = bridge.path[0]['x']
    f = {'time':0,'x':x,'z':z,'theta':0,'phi':0,'hitch':[x,z-p.hitch],
         'axle':[x,z-p.hitch-(0 if p.mounted else p.length)],'work':[x,z-p.front],
         'left':[x+p.width/2,z-p.front],'right':[x-p.width/2,z-p.front],
         'rearLeft':[x+p.width/2,z-p.back],'rearRight':[x-p.width/2,z-p.back],
         'lowered':False,'state':'Route preview only','phase':'preview',
         'offset':0,'ix':1,'angle':0,'error':0}
    return {'path':bridge.path,'frames':[f],'events':[],'gaps':[],'exitGaps':[],
            'resolution':Coverage.resolution,'preview':True,
            'target':dict(bridge.rig.workStart),
            'metrics':{'complete':False,'entry':None,'missedArea':None,'exitMissedArea':None,
                       'envelopeDepth':None,'headlandShortfall':None,'duration':0},
            'scenario':asdict(p)}


def drive_guidance(p,bridge,path,ix,x,z,theta,phi,axle):
    """Bounded-curvature pursuit with gear-local progress and CP trailer reverse correction."""
    reverse=bool(path[ix].get('reverse'))
    tractor_path = p.approachLength and p.turnType == 'reedsShepp'
    end=path[ix].get('legEnd',ix)
    while 'legEnd' not in path[ix] and end+1<len(path) and bool(path[end+1].get('reverse'))==reverse:
        end+=1
    def nav(w):
        cached=w.get('navPoint')
        return cached if cached is not None else point(w['x'],w['z'],w['t'],across=0 if w.get('reverse') else -w.get('offset',0))
    rx,rz=axle if reverse and not p.mounted and not tractor_path else (x,z)
    ix=min(range(ix,min(ix+15,end+1)),key=lambda i:(nav(path[i])[0]-rx)**2+(nav(path[i])[1]-rz)**2)
    reached=math.hypot(path[end]['x']-rx,path[end]['z']-rz)<.75
    if end>0 and bool(path[end-1].get('reverse'))==reverse:
        ex,ez=path[end]['x']-path[end-1]['x'],path[end]['z']-path[end-1]['z']
        length=math.hypot(ex,ez)
        if length>1e-8:
            along=((rx-path[end]['x'])*ex+(rz-path[end]['z'])*ez)/length
            across=abs((rx-path[end]['x'])*ez-(rz-path[end]['z'])*ex)/length
            # CP detects a passed waypoint, not only proximity to its centre.
            # The controlled axle can already be beyond a short reverse leg
            # when the previous forward section finishes.
            reached=reached or (along>=0 and across<max(1,p.lookahead) and ix>=end-2)
    if end+1<len(path) and reached:
        ix=end+1
        reverse=bool(path[ix].get('reverse'))
        end=path[ix].get('legEnd',ix)
        while 'legEnd' not in path[ix] and end+1<len(path) and bool(path[end+1].get('reverse'))==reverse:
            end+=1
        rx,rz=axle if reverse and not p.mounted and not tractor_path else (x,z)
    goal=ix
    while goal<end and math.hypot(nav(path[goal])[0]-rx,nav(path[goal])[1]-rz)<p.lookahead:
        goal+=1
    wp=path[goal]
    # CP Waypoint:getOffsetPosition uses (-directionZ, directionX) for
    # positive lateral offsets; point(across=...) uses the opposite normal.
    gx,gz=point(wp['x'],wp['z'],wp['t'],across=0 if reverse else -wp.get('offset',0))
    dx,dz=gx-x,gz-z
    curvature=2*(dx*math.cos(theta)-dz*math.sin(theta))/max(.01,dx*dx+dz*dz)
    if reverse and not p.mounted and not tractor_path:
        ref=path[ix]
        if ix<end:
            path_angle=math.atan2(path[ix+1]['x']-ref['x'],path[ix+1]['z']-ref['z'])
        elif ix>0 and bool(path[ix-1].get('reverse'))==reverse:
            path_angle=math.atan2(ref['x']-path[ix-1]['x'],ref['z']-path[ix-1]['z'])
        else:
            path_angle=ref['t']
        cross=(rx-ref['x'])*math.cos(path_angle)-(rz-ref['z'])*math.sin(path_angle)
        correction=bridge.g.reverseCorrection(p.hitch+p.length,cross,wrap(path_angle-phi-math.pi),wrap(phi-theta))
        correction=max(-math.radians(75),min(math.radians(75),correction))
        curvature=-2*math.sin(correction)/p.lookahead
    return ix,max(-1/p.radius,min(1/p.radius,curvature)),reverse


def simulate(p, dt=0.025, start=None, stop_distance=25):
    from alignment import assess_envelope
    if p.approachLength:
        # The coverage sample extends 20 m from every point on the sloping
        # edge, not just its centre. Drive far enough to finish its longest side.
        stop_distance=max(stop_distance,21+abs(p.boundarySlope)*p.width/2)
    bridge = Bridge(p)
    exit_frames, exit_events, exit_gaps = [], [], []
    exit_overshoot, time_offset = 0, 0
    if not p.entry:
        exit_frames, exit_events, exit_coverage, exit_overshoot = simulate_exit(p,bridge,dt,start=start)
        exit_gaps = exit_coverage.gaps()
        time_offset = exit_frames[-1]['time']
        bridge = Bridge(p,turn_pose=exit_frames[-1])
    if not p.entry and p.turnType != 'dubins' and not p.approachLength:
        from full_course import drive_course
        target=dict(bridge.rig.workStart)
        nav=[dict(w,working=False,phase='Turn',row=0,headland=0,offset=bridge.g.changeWaypoint(bridge.rig,i+1),
                  lowerTarget=[target['x'],target['z'],target['t']]) for i,w in enumerate(bridge.path)]
        run=drive_course(p,nav,1,start=exit_frames[-1])
        run['frames']=exit_frames[:-1]+[transform_frame(f,(0,0),0,time_offset) for f in run['frames']]
        run['events']=exit_events+[{**e,'time':round(e['time']+time_offset,2)} for e in run['events']]
        run['metrics']['duration']=run['frames'][-1]['time']
        run.update(scenario=asdict(p),preview=False,target=target,gaps=[],exitGaps=exit_gaps,resolution=Coverage.resolution)
        return run
    path = bridge.path
    x, z, theta = path[0]['x'], path[0]['z'], path[0]['t']
    if exit_frames:
        x,z,theta,phi = (exit_frames[-1][k] for k in ('x','z','theta','phi'))
    else:
        phi = wrap(theta + (math.radians(p.entryAngle) if p.entry else 0))
    target = p.side*(p.rowSpacing or p.width)
    hitch = point(x,z,theta,along=-p.hitch)
    axle = point(*hitch,phi,along=0 if p.mounted else -p.length)
    work = point(*axle,phi,along=(0 if p.mounted else p.length)+p.hitch-p.front)
    # Controlled counterexample: tractor on line, implement angled, front 0.3 m before work.
    if p.entry:
        shift = 0.3-work[1]
        z += shift
        hitch[1] += shift
        axle[1] += shift
        work[1] += shift
    frames, events = [], []
    ix, last_ix, offset = 0, -1, 0
    commanded, lowered, lower_at = False, False, None
    contact_started = False
    previous_entry_pose = None
    entry_error = None
    coverage = Coverage(p.width, target)
    max_z, max_articulation = -math.inf, 0
    sample_every = 1 if p.approachLength else max(1, round(.1/dt))
    previous_bar = None
    complete = False
    for tick in range(int((240+stop_distance/p.speed)/dt)):
        now = time_offset+tick*dt
        # Test-only bounded-curvature pursuit. This is not the GIANTS steering controller.
        ix, curvature, reverse = drive_guidance(p,bridge,path,ix,x,z,theta,phi,axle)
        if ix != last_ix:
            offset = bridge.g.changeWaypoint(bridge.rig,ix+1)
            last_ix = ix
        goal = ix
        while goal < len(path)-1 and bool(path[goal+1].get('reverse'))==reverse and math.hypot(path[goal]['x']-x,path[goal]['z']-z) < p.lookahead:
            goal += 1
        wp = path[goal]
        gx,gz = point(wp['x'],wp['z'],wp['t'],across=-offset)
        dx,dz = gx-x,gz-z
        lateral = dx*math.cos(theta)-dz*math.sin(theta)
        curvature = max(-1/p.radius,min(1/p.radius,2*lateral/max(dx*dx+dz*dz,0.01)))
        if reverse:
            _,curvature,_ = drive_guidance(p,bridge,path,ix,x,z,theta,phi,axle)
        speed = 0 if p.drill and commanded and not lowered else (-p.reverseSpeed if reverse else p.speed)
        if p.approachLength:
            speed = -p.reverseSpeed if reverse else p.speed
        rear = point(*work,phi,along=-(p.back-p.front))
        alignment = assess_envelope(work,rear,phi,p.width,(target,p.targetZ),math.pi)
        front_edges = [point(*work,phi,across=a) for a in (-p.width/2,p.width/2)]
        boundary_distance = min(v[1]-p.boundarySlope*v[0] for v in front_edges)
        should_lower, _ = bridge.g.shouldLower(bridge.rig,*work,phi,p.width,p.back-p.front,abs(speed))
        if p.approachLength:
            should_lower = not reverse and alignment.aligned and 0 <= boundary_distance <= p.speed*p.lowerSeconds+.5
            if commanded and not alignment.aligned and not contact_started:
                commanded,lowered,lower_at = False,False,None
                events.append({'time':round(now,2),'kind':'Lowering cancelled: alignment lost',
                               'angle':math.degrees(alignment.angle),'error':alignment.edge_error})
        if not commanded and path[ix]['lower'] and should_lower:
            commanded, lower_at = True, now
            events.append({'time':round(now,2),'kind':'Lower requested',
                           'angle':round(math.degrees(wrap(phi-math.pi)),2),
                           'error':round(work[0]-target,3),
                           'edgeError':alignment.edge_error,'aligned':alignment.aligned})
        if commanded and not lowered and now-lower_at >= p.lowerSeconds:
            lowered = True
            events.append({'time':round(now,2),'kind':'Implement lowered' if p.approachLength else 'Working envelope active',
                           'angle':round(math.degrees(wrap(phi-math.pi)),2),
                           'error':round(work[0]-target,3)})
        left = point(*work,phi,across=p.width/2)
        right = point(*work,phi,across=-p.width/2)
        rear_left = point(*left,phi,along=-(p.back-p.front))
        rear_right = point(*right,phi,along=-(p.back-p.front))
        if p.approachLength and commanded and not lowered:
            # Brake before first contact if hydraulic travel would overrun it.
            speed = min(speed,max(0,(boundary_distance-.02)/dt))
        working = lowered and (not p.approachLength or boundary_distance <= 0)
        if p.approachLength and working and not contact_started:
            contact_started = True
            events.append({'time':round(now,2),'kind':'Working envelope active',
                           'angle':math.degrees(alignment.angle),'error':alignment.edge_error})
        if working:
            coverage.stamp([[a,b-(p.boundarySlope*a if p.approachLength else p.targetZ)]
                            for a,b in [left,right,rear_right,rear_left]])
            if previous_bar:
                coverage.stamp([[a,b-(p.boundarySlope*a if p.approachLength else p.targetZ)]
                                for a,b in [previous_bar[0],previous_bar[1],right,left]])
            previous_bar = [left,right]
        if entry_error is None and (not p.approachLength or (not reverse and path[ix]['lower'])) and (boundary_distance <= 0 if p.approachLength else work[1] <= p.targetZ) and math.cos(theta) < -0.5:
            entry_x,entry_phi=work[0],phi
            if not p.approachLength and previous_entry_pose and previous_entry_pose[1]>p.targetZ:
                px,pz,pphi=previous_entry_pose
                fraction=(pz-p.targetZ)/(pz-work[1])
                entry_x=px+fraction*(work[0]-px)
                entry_phi=wrap(pphi+fraction*wrap(phi-pphi))
            entry_error = {'angle':round(math.degrees(wrap(entry_phi-math.pi)),2),
                           'lateral':round(entry_x-target,3),'lowered':working,
                           'edgeError':alignment.edge_error,'aligned':alignment.aligned}
        previous_entry_pose=(work[0],work[1],phi)
        articulation = abs(math.degrees(wrap(theta-phi)))
        max_articulation = max(max_articulation,articulation)
        tractor_corners = [point(x,z,theta,across=a,along=b) for a in (-1.5,1.5) for b in (-2,4)]
        max_z = max(max_z,*[v[1] for v in tractor_corners],left[1],right[1],rear_left[1],rear_right[1],axle[1])
        if tick % sample_every == 0:
            frames.append({'time':round(now,2),'x':x,'z':z,'theta':theta,'phi':phi,
                           'hitch':hitch[:],'axle':axle[:],'work':work[:], 'left':left,'right':right,
                           'rearLeft':rear_left,'rearRight':rear_right,'lowered':working,
                           'hydraulicallyLowered':lowered,'envelopeAligned':alignment.aligned,
                           'edgeError':alignment.edge_error,
                           'state':'Reversing' if reverse else ('Working' if working else ('Lowering' if commanded and not lowered else 'Approach')),
                           'reverse':reverse,
                           'phase':'entry' if commanded else 'turn',
                           'offset':offset,'ix':ix+1,'angle':math.degrees(wrap(phi-math.pi)),
                           'error':work[0]-target})
        if tick % sample_every == 0 and (not p.approachLength or (not reverse and path[ix]['lower'])) and work[1] < p.targetZ-stop_distance and math.cos(theta) < -0.5:
            complete = True
            break
        old_hitch = hitch
        distance = speed*dt
        mid = theta + curvature*distance/2
        x += distance*math.sin(mid)
        z += distance*math.cos(mid)
        theta = wrap(theta+curvature*distance)
        hitch = point(x,z,theta,along=-p.hitch)
        hx,hz = hitch[0]-old_hitch[0],hitch[1]-old_hitch[1]
        if math.hypot(hx,hz) > 1e-10:
            phi = theta if p.mounted else wrap(bridge.g.nextTrailerHeading(phi,math.atan2(hx,hz),math.hypot(hx,hz),p.length))
        axle = point(*hitch,phi,along=0 if p.mounted else -p.length)
        work = point(*axle,phi,along=(0 if p.mounted else p.length)+p.hitch-p.front)
    gaps = [[x,z+(p.boundarySlope*x if p.approachLength else p.targetZ)] for x,z in coverage.gaps()]
    return {'path':path,'frames':exit_frames[:-1]+frames,'events':exit_events+events,
            'gaps':gaps,'exitGaps':exit_gaps,'resolution':coverage.resolution,'preview':False,
            'target':dict(bridge.rig.workStart),
            'metrics':{'complete':complete,'entry':entry_error,'missedArea':round(len(gaps)*coverage.resolution**2,2),
                       'exitMissedArea':round(len(exit_gaps)*coverage.resolution**2,2) if not p.entry else None,
                       'exitOvershoot':round(exit_overshoot,2) if not p.entry else None,
                       'envelopeDepth':round(max_z,2),'headlandShortfall':round(max(0,max_z-p.headland),2),
                       'maxArticulation':round(max_articulation,1),'duration':round(now,2)},
            'scenario':asdict(p)}


def transform_frame(frame, origin, angle, time_offset=0):
    """Rigid coordinate change only; preserve the actual tractor and trailer state."""
    result = dict(frame)
    result['x'], result['z'] = point(*origin,angle,across=frame['x'],along=frame['z'])
    for key in ('hitch','axle','work','left','right','rearLeft','rearRight'):
        result[key] = point(*origin,angle,across=frame[key][0],along=frame[key][1])
    for key in ('theta','phi'):
        result[key] = wrap(frame[key]+angle)
    result['time'] = round(frame['time']+time_offset,2)
    return result


def simulate_field(p, dt=0.05):
    """Continuous adjacent passes; local CP turn problems alternate between field ends.

    The first pass starts aligned and working. All subsequent poses are carried
    through the middle of each row, including residual yaw and lateral error.
    Coverage measurements remain the 20 m entry/exit samples, not the whole field.
    """
    if p.fieldShape != 'rectangle':
        return simulate_polygon_field(p, dt)
    row_length = p.fieldLength-2*p.headland
    bridge = Bridge(p)
    raw_order = bridge.g.rowSequence(p.rowPattern,p.passes,p.rowsPerLand,p.circles,p.rowsToSkip,p.centreClockwise,p.spiralFromInside)
    order = [int(raw_order[i])-1 for i in range(1,len(raw_order)+1)]
    if sorted(order) != list(range(p.passes)):
        raise ValueError('Courseplay returned an invalid row sequence')
    frames, events, paths, gaps, exit_gaps, turns = [], [], [], [], [], []
    start = dict(x=0,z=p.front-row_length,theta=0,phi=0)
    time_offset, complete = 0, True
    for row in range(p.passes):
        angle = math.pi if row % 2 else 0
        origin = (p.side*order[row]*p.width, -p.fieldLength+p.headland if row % 2 else -p.headland)
        delta = (order[row+1]-order[row])*p.width if row+1 < p.passes else p.width
        local_side = p.side*(-1 if row % 2 else 1)*(1 if delta > 0 else -1)
        local = replace(p,pattern=False,side=local_side,rowSpacing=abs(delta))
        final = row == p.passes-1
        if final:
            segment_frames, segment_events, coverage, overshoot = simulate_exit(
                local,Bridge(local),dt,start=start,final=True)
            segment_gaps, segment_exit_gaps = [], coverage.gaps()
            paths.append([point(*origin,angle,across=f['x'],along=f['z']) for f in
                          (segment_frames[0],segment_frames[-1])])
        else:
            segment = simulate(local,dt,start=start,stop_distance=row_length/2)
            segment_frames, segment_events = segment['frames'],segment['events']
            segment_gaps, segment_exit_gaps = segment['gaps'],segment['exitGaps']
            turns.append({'pass':row+1,'end':'South' if row % 2 else 'North',
                          'direction':'Left' if local.side < 0 else 'Right',**segment['metrics']})
            paths.append([point(*origin,angle,across=segment_frames[0]['x'],along=segment_frames[0]['z'])]+
                         [point(*origin,angle,across=w['x'],along=w['z'])
                          for w in segment['path'][:segment_frames[-1]['ix']]])
            complete = segment['metrics']['complete'] and segment_frames[-1]['lowered']
        for f in segment_frames:
            mapped = transform_frame(f,origin,angle,time_offset)
            mapped['pass'] = row+1 if f['phase'] == 'exit' else row+2
            if not frames or mapped['time'] > frames[-1]['time']:
                frames.append(mapped)
        for e in segment_events:
            events.append({**e,'time':round(e['time']+time_offset,2),
                           'pass':row+1 if e['kind'] not in ('Lower requested','Working envelope active') else row+2,
                           'end':'South' if row % 2 else 'North'})
        gaps.extend(point(*origin,angle,across=x,along=z) for x,z in segment_gaps)
        exit_gaps.extend(point(*origin,angle,across=x,along=z) for x,z in segment_exit_gaps)
        time_offset = frames[-1]['time']
        if not complete:
            break
        if not final:
            # Incoming row becomes the next outgoing row, in the opposite frame.
            start = transform_frame(segment_frames[-1],(local.side*local.rowSpacing,-row_length),math.pi)
            start['time'] = 0
    north, south, articulation = 0, 0, 0
    for f in frames:
        corners = [point(f['x'],f['z'],f['theta'],across=a,along=b)
                   for a in (-1.5,1.5) for b in (-2,4)]
        corners += [f[k] for k in ('left','right','rearLeft','rearRight','axle')]
        north = max(north,max(v[1] for v in corners)+p.headland)
        south = max(south,-p.fieldLength+p.headland-min(v[1] for v in corners))
        articulation = max(articulation,abs(math.degrees(wrap(f['theta']-f['phi']))))
    depth = max(north,south)
    entries = [t['entry'] for t in turns if t['entry']]
    worst = {'angle':max((abs(e['angle']) for e in entries),default=0),
             'lateral':max((abs(e['lateral']) for e in entries),default=0)} if entries else None
    return {'frames':frames,'events':events,'paths':paths,'path':[],
            'gaps':gaps,'exitGaps':exit_gaps,'resolution':Coverage.resolution,'preview':False,
            'scenario':asdict(p),'turns':turns,
            'field':{'north':0,'south':-p.fieldLength,'northWork':-p.headland,
                     'southWork':-p.fieldLength+p.headland,'rowLength':row_length,
                     'west':-p.width/2-p.headland if p.side==1 else p.width/2+p.headland-p.fieldWidth,
                     'east':p.fieldWidth-p.width/2-p.headland if p.side==1 else p.width/2+p.headland,
                     'order':[i+1 for i in order],
                     'rows':[p.side*i*p.width for i in range(p.passes)]},
            'metrics':{'complete':complete,'entry':worst,
                       'missedArea':round(len(gaps)*Coverage.resolution**2,2),
                       'exitMissedArea':round(len(exit_gaps)*Coverage.resolution**2,2),
                       'exitOvershoot':round(max([t['exitOvershoot'] for t in turns]+([overshoot] if final else [])),2),
                       'envelopeDepth':round(depth,2),'northDepth':round(north,2),'southDepth':round(south,2),
                       'headlandShortfall':round(max(0,depth-p.headland),2),
                       'maxArticulation':round(articulation,1),'duration':frames[-1]['time']}}


def simulate_polygon_field(p, dt=.05):
    """Run CP-generated straight rows with their individual entry/exit endpoints.

    Row ordering and turns use CP; steering and trailer motion retain the bench's
    planar model. The requested count selects consecutive usable generated rows.
    """
    layout = generate_layout(replace(p, courseLayout=True))['layout']
    if len(layout['headlands']) < p.headlandRows:
        raise ValueError(f"CP generated only {len(layout['headlands'])} of {p.headlandRows} requested headlands. "
                         'Set rounded headlands to 0 in CP field generation settings, or adjust the field/headland size.')
    rows = [r for r in layout['rows'] if math.dist(r[0], r[-1]) >= 40]
    if len(rows) < p.passes:
        raise ValueError(f'Only {len(rows)} rows have at least 40 m of working length; reduce passes or enlarge the field')
    # Start with the longest group, avoiding short corner remnants. Keep CP's
    # spacing and endpoints, and preserve the chosen row pattern within the group.
    index = max(range(len(rows)-p.passes+1),
                key=lambda i: min(math.dist(r[0],r[-1]) for r in rows[i:i+p.passes]))
    rows = rows[index:index+p.passes]
    if p.side < 0:
        rows.reverse()
    bridge = Bridge(p)
    raw = bridge.g.rowSequence(p.rowPattern,p.passes,p.rowsPerLand,p.circles,p.rowsToSkip,p.centreClockwise,p.spiralFromInside)
    order = [int(raw[i])-1 for i in range(1,len(raw)+1)]
    directed = [(rows[i][-1],rows[i][0]) if n%2 else (rows[i][0],rows[i][-1])
                for n,i in enumerate(order)]
    frames,events,paths,gaps,exit_gaps,turns = [],[],[],[],[],[]
    last_world, elapsed, complete, overshoots = None,0,True,[]
    for n,(entry,end) in enumerate(directed):
        angle = math.atan2(end[0]-entry[0],end[1]-entry[1])
        length = math.dist(entry,end)
        def to_local(v):
            return point(0,0,-angle,across=v[0]-end[0],along=v[1]-end[1])
        if last_world is None:
            start = dict(x=0,z=p.front-length,theta=0,phi=0)
        else:
            x,z = to_local((last_world['x'],last_world['z']))
            start = dict(x=x,z=z,theta=wrap(last_world['theta']-angle),phi=wrap(last_world['phi']-angle))
        final = n == len(directed)-1
        if final:
            local = replace(p,pattern=False,courseLayout=False,targetZ=0)
            fs,es,coverage,overshoot = simulate_exit(local,Bridge(local),dt,start=start,final=True)
            gs,egs = [],coverage.gaps()
            path = [[f['x'],f['z']] for f in (fs[0],fs[-1])]
        else:
            next_entry,next_end = directed[n+1]
            dx,dz = to_local(next_entry)
            next_angle = math.atan2(next_end[0]-next_entry[0],next_end[1]-next_entry[1])
            if abs(wrap(next_angle-angle-math.pi)) > .01 or abs(dx) < .1:
                raise ValueError('These rows need a block-transfer manoeuvre; choose another row angle or fewer passes')
            local = replace(p,pattern=False,courseLayout=False,side=1 if dx>0 else -1,
                            rowSpacing=abs(dx),targetZ=dz)
            segment = simulate(local,dt,start=start,stop_distance=math.dist(next_entry,next_end)/2)
            fs,es,gs,egs = (segment[k] for k in ('frames','events','gaps','exitGaps'))
            overshoot = segment['metrics']['exitOvershoot']
            path = [[fs[0]['x'],fs[0]['z']]]+[[w['x'],w['z']] for w in segment['path'][:fs[-1]['ix']]]
            complete = segment['metrics']['complete'] and fs[-1]['lowered']
            turns.append({'pass':n+1,'end':f'Row {n+1}',
                          'direction':'Right' if dx>0 else 'Left',**segment['metrics']})
        overshoots.append(overshoot)
        paths.append([point(*end,angle,across=x,along=z) for x,z in path])
        for f in fs:
            mapped = transform_frame(f,end,angle,elapsed)
            mapped['pass'] = n+1 if f['phase']=='exit' else n+2
            if not frames or mapped['time']>frames[-1]['time']:
                frames.append(mapped)
        for e in es:
            events.append({**e,'time':round(e['time']+elapsed,2),'pass':n+1,
                           'end':f'Row {n+1}'})
        gaps.extend(point(*end,angle,across=x,along=z) for x,z in gs)
        exit_gaps.extend(point(*end,angle,across=x,along=z) for x,z in egs)
        last_world,elapsed = frames[-1],frames[-1]['time']
        if not complete:
            break
    entries = [t['entry'] for t in turns if t['entry']]
    worst = {'angle':max(abs(e['angle']) for e in entries),
             'lateral':max(abs(e['lateral']) for e in entries)} if entries else None
    return {'scenario':asdict(p),'frames':frames,'events':events,'paths':paths,'path':[],
            'gaps':gaps,'exitGaps':exit_gaps,'resolution':Coverage.resolution,'preview':False,
            'turns':turns,'field':{'boundary':layout['boundary'],'headlands':layout['headlands'],
                'rowSegments':[[r[0],r[-1]] for r in rows], 'order':[i+1 for i in order],
                'rows':[r[0][0] for r in rows], 'west':0,'east':p.fieldWidth,
                'south':0,'north':p.fieldLength,'northWork':p.fieldLength-p.headland,
                'southWork':p.headland},
            'metrics':{'complete':complete,'entry':worst,
                'missedArea':round(len(gaps)*Coverage.resolution**2,2),
                'exitMissedArea':round(len(exit_gaps)*Coverage.resolution**2,2),
                'exitOvershoot':max(overshoots), 'envelopeDepth':None,'headlandShortfall':None,
                'maxArticulation':max(abs(math.degrees(wrap(f['theta']-f['phi']))) for f in frames),
                'duration':elapsed}}


def polygon_contains(x,z,poly):
    inside_polygon = False
    for a,b in zip(poly,poly[1:]+poly[:1]):
        if (a[1]>z)!=(b[1]>z) and x < (b[0]-a[0])*(z-a[1])/(b[1]-a[1])+a[0]:
            inside_polygon = not inside_polygon
    return inside_polygon


def distance_to_segment(v,a,b):
    dx,dz=b[0]-a[0],b[1]-a[1]
    t=max(0,min(1,((v[0]-a[0])*dx+(v[1]-a[1])*dz)/max(1e-12,dx*dx+dz*dz)))
    return math.hypot(v[0]-a[0]-t*dx,v[1]-a[1]-t*dz)


def polygon_clearance(v,poly):
    contained = polygon_contains(*v,poly)
    distance = math.inf
    for a,b in zip(poly,poly[1:]+poly[:1]):
        distance=min(distance,distance_to_segment(v,a,b))
    return distance if contained else -distance


def segment_clearance(a,b,c,d):
    def cross(p,q,r):
        return (q[0]-p[0])*(r[1]-p[1])-(q[1]-p[1])*(r[0]-p[0])
    if cross(a,b,c)*cross(a,b,d)<0 and cross(c,d,a)*cross(c,d,b)<0:
        return 0
    return min(distance_to_segment(a,c,d),distance_to_segment(b,c,d),
               distance_to_segment(c,a,b),distance_to_segment(d,a,b))


def compare(data):
    p = Scenario.parse(data)
    if p.alignedPlanner and p.alignedPattern:
        from aligned_pattern import compare_pattern
        return compare_pattern(p)
    if p.alignedPlanner:
        from aligned_turn import compare_aligned
        return compare_aligned(p)
    if p.courseLayout:
        generated=generate_layout(p)
        if p.fullCourse:
            from full_course import simulate_complete
            baseline=simulate_complete(replace(p,extension=0),generated)
            experiment=simulate_complete(p,generated) if p.extension else None
        else:
            baseline,experiment=generated,None
        return {'baseline':baseline,'experiment':experiment,
                'sources':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in
                           SOURCES+[str(f.relative_to(ROOT)).replace('\\','/') for f in
                                    (ROOT/'scripts/courseGenerator').rglob('*.lua') if 'test' not in f.parts]+
                           ['tools/turnbench/field_layout.lua']},
                'model':'Production CP Course Generator and analytic turns; planar rig playback with CP trailer reverse correction' if p.fullCourse else 'Production CP Course Generator; route layout only'}
    runner = simulate_field if p.pattern else simulate
    return {'baseline':check_boundary(runner(replace(p,extension=0))),
            'experiment':check_boundary(runner(p)) if p.extension and not p.entry else None,
            'sources':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in
                SOURCES+(['tools/turnbench/field_layout.lua']+
                    [str(f.relative_to(ROOT)).replace('\\','/') for f in
                     (ROOT/'scripts/courseGenerator').rglob('*.lua') if 'test' not in f.parts]
                    if p.pattern and p.fieldShape!='rectangle' else [])},
            'model':'CP Lua 5.2 turn/offset/raising/lowering + planar single-trailer kinematics; not GIANTS physics'}


def check_boundary(run):
    """Check the modelled footprint separately from course tracking completion.

    This is a bench rejection, not CP's reversing fallback. The sampled model
    footprints have a 0.5 m reserve; this is not a GIANTS collision guarantee.
    """
    p = run['scenario']
    if not p['enforceBoundary'] or run['preview'] or p['entry']:
        return run
    field = run.get('field')
    islands=field.get('islands',[]) if field else []
    west,east,south,north = ((field['west'],field['east'],field['south'],field['north'])
                              if field else (-math.inf,math.inf,-math.inf,p['headland']))
    polygon = field.get('boundary') if field else None
    if polygon and not islands:
        # For a convex field the inward-offset half-planes are convex too.
        # Every body vertex inside them proves all body edges retain the reserve.
        area=sum(a[0]*b[1]-b[0]*a[1] for a,b in zip(polygon,polygon[1:]+polygon[:1]))
        direction=1 if area>0 else -1
        planes=[]
        for a,b in zip(polygon,polygon[1:]+polygon[:1]):
            dx,dz=b[0]-a[0],b[1]-a[1]
            length=math.hypot(dx,dz)
            if length>1e-9:
                nx,nz=-dz*direction/length,dx*direction/length
                planes.append((nx,nz,-nx*a[0]-nz*a[1]))
        convex=planes and all(nx*x+nz*z+c>=-1e-8 for x,z in polygon for nx,nz,c in planes)
        if convex:
            safe=True
            for f in run['frames']:
                corners=[point(f['x'],f['z'],f['theta'],across=a,along=b)
                         for a in (-1.9,1.9) for b in (-2,4)]
                corners += [f[k] for k in ('left','right','rearLeft','rearRight','axle','hitch')]
                if any(nx*x+nz*z+c<.5 for x,z in corners for nx,nz,c in planes):
                    safe=False
                    break
            if safe:
                run['boundaryChecked']=True
                return run
    violation = False
    for f in run['frames']:
        corners = [point(f['x'],f['z'],f['theta'],across=a,along=b)
                   for a in (-1.9,1.9) for b in (-2,4)]
        corners += [f[k] for k in ('left','right','rearLeft','rearRight','axle','hitch')]
        polygon = field.get('boundary') if field else None
        if (any(polygon_clearance(v,polygon)<.5 or any(-polygon_clearance(v,island)<.5 for island in islands) for v in corners) if polygon else
            any(x < west+.5 or x > east-.5 or z < south+.5 or z > north-.5 for x,z in corners)):
            violation = True
            break
        if polygon:
            tractor=[point(f['x'],f['z'],f['theta'],across=a,along=b)
                     for a,b in ((-1.9,-2),(1.9,-2),(1.9,4),(-1.9,4))]
            implement=[f[k] for k in ('left','right','rearRight','rearLeft')]
            if any(polygon_contains(v[0],v[1],body) for island in islands for v in island
                   for body in (tractor,implement)):
                violation=True
                break
            edges=list(zip(tractor,tractor[1:]+tractor[:1]))+list(zip(implement,implement[1:]+implement[:1]))
            edges.append((f['hitch'],f['axle']))
            if any(segment_clearance(a,b,c,d)<.5 for a,b in edges for boundary in [polygon]+islands
                   for c,d in zip(boundary,boundary[1:]+boundary[:1])):
                violation=True
                break
    run['boundaryChecked'] = True
    if violation:
        # Offline inspection remains available even when the footprint fails.
        # Playback is explicitly diagnostic and does not change the verdict.
        run['rejectedPath'] = [[f['x'],f['z']] for f in run['frames']]
        # Preserve gear changes in the rejected preview. Joining every driven
        # pose in one colour disguises sharp-corner reversing manoeuvres as
        # continuous rounded headlands.
        segments=[]
        for f in run['frames']:
            reverse=bool(f.get('reverse',False))
            if not segments or segments[-1]['reverse']!=reverse:
                points=[segments[-1]['points'][-1]] if segments else []
                segments.append(dict(reverse=reverse,points=points))
            segments[-1]['points'].append([f['x'],f['z']])
        run['rejectedSegments']=segments
        envelopes, shortfall = [], 0
        for i,f in enumerate(run['frames']):
            tractor=[point(f['x'],f['z'],f['theta'],across=a,along=b)
                     for a,b in ((-1.9,-2),(1.9,-2),(1.9,4),(-1.9,4))]
            implement=[f[k] for k in ('left','right','rearRight','rearLeft')]
            points=tractor+implement+[f['hitch'],f['axle']]
            clearance=min(polygon_clearance(v,polygon) for v in points) if polygon else min(
                min(x-west,east-x,z-south,north-z) for x,z in points)
            if islands:
                clearance=min(clearance,min(-polygon_clearance(v,island) for v in points for island in islands))
                clearance=min(clearance,min(-polygon_clearance(v,body) for island in islands for v in island
                                            for body in (tractor,implement)))
            shortfall=max(shortfall,.5-clearance)
            if clearance < .5 and i%5==0:
                envelopes.extend([tractor,implement])
        run['rejectedEnvelopes'] = envelopes[::max(1,math.ceil(len(envelopes)/200))]
        run['boundaryClearanceNeeded'] = round(shortfall,2)
        if run.get('completeCourse'):
            # A CP baseline is a reproduction, not a boundary-constrained
            # planner. This approximate body test must not turn successful
            # playback into a fictitious CP execution error. Retain every
            # diagnostic, and retain the actual tracking completion verdict.
            run['boundaryWarning'] = (f'Estimated footprint extends beyond the field clearance reserve by {shortfall:.1f} m. '
                'This includes a 0.5 m reserve and a simplified implement body; it is not a CP execution error or a required headland increase.')
            run['blocked'] = False
            return run
        run['blocked'] = True
        run['diagnosticPlayback'] = len(run['frames'])>1 and not run.get('preview',False)
        run['preview'] = not run['diagnosticPlayback']
        run['reason'] = (f'Offline footprint check: {shortfall:.1f} m maximum boundary deficit, including the bench’s 0.5 m reserve. '
                         'Estimated implement geometry and simplified driving are used; this is not a required headland increase or an in-game feasibility result.'
                         if run.get('completeCourse') else
                         f'Turn rejected: this modelled route needs {shortfall:.1f} m more boundary clearance, including the 0.5 m reserve. Adjust the field margin, headlands or turn settings; this is not an in-game feasibility result.')
        run['paths'],run['gaps'],run['exitGaps'] = [],[],[]
        if not run['diagnosticPlayback']:
            run['path'],run['events'] = [],[]
            run['frames'] = [dict(run['frames'][0],state='Turn rejected',time=0)]
        run['metrics'].update(complete=False,entry=None,missedArea=None,exitMissedArea=None,exitOvershoot=None)
    return run


def implement_catalogue():
    """CP XML contains overrides, not a complete machinery dimensions database."""
    root = ET.parse(ROOT/'config/VehicleConfigurations.xml').getroot()
    records = []
    for index, node in enumerate(root.iter()):
        if node.tag.lower() == 'vehicle' and node.get('name'):
            records.append({'id':str(index),'name':node.get('name'),
                            'overrides':dict(node.attrib),
                            'configurations':[dict(c.attrib) for c in node]})
    return {'source':'config/VehicleConfigurations.xml','implements':records}


def generate_layout(p):
    w,h=p.fieldWidth,p.fieldLength
    normalised = ([(0,0),(1,0),(1,1),(0,1)] if p.fieldShape == 'rectangle' else
                  [(0,.1),(1,0),(1,.33),(.83,.42),(1,.65),(1,1),(.23,.80),(.17,.40),(.08,.23)])
    if p.fieldShape == 'irregular':
        inset=p.irregularInset/100
        normalised=[(0,.1),(1,0),(1,.33),(.83,.42),(1,.65),(1,1),
                    (inset,.80),(inset*17/23,.40),(inset*8/23,.23)]
    boundary=[[x*w,z*h] for x,z in normalised]
    if p.fieldShape == 'sloping':
        inset=h*math.tan(math.radians(p.edgeAngle))
        boundary=([[0,0],[w,0],[w,h],[inset,h]] if p.slopeSide == 'left' else
                  [[0,0],[w,0],[w-inset,h],[0,h]])
    bridge=Bridge(p)
    bridge.lua.execute((ROOT/'tools/turnbench/field_layout.lua').read_text())
    islands=[]
    for i in range(p.islandCount):
        cx,cz=w*(.4+.2*(i%2)),h*(.45+.15*(i//2))
        island=[[cx+p.islandSize/2*math.cos(t*math.pi/12),cz+p.islandSize/2*math.sin(t*math.pi/12)] for t in range(24)]
        if any(polygon_clearance(v,boundary)<p.width for v in island):
            raise ValueError('Island does not fit inside this field with one implement width of clearance')
        if any(math.dist((cx,cz),(sum(v[0] for v in other)/24,sum(v[1] for v in other)/24))<p.islandSize+p.width for other in islands):
            raise ValueError('Islands overlap or leave less than one implement width between them')
        islands.append(island)
    raw=bridge.g.fieldLayout(bridge.lua.table_from([bridge.lua.table_from(v) for v in boundary]),
                             bridge.lua.table_from(asdict(p)),
                             bridge.lua.table_from([bridge.lua.table_from([bridge.lua.table_from(v) for v in island]) for island in islands]))
    def points(table):
        return [[float(table[i][1]),float(table[i][2])] for i in range(1,len(table)+1)]
    path=points(raw['path'])
    headlands=[points(raw['headlands'][i]) for i in range(1,len(raw['headlands'])+1)]
    routes=[{'position':int(raw['routes'][i]['position']),
             'waypoints':[dict(raw['routes'][i]['waypoints'][j]) for j in range(1,len(raw['routes'][i]['waypoints'])+1)]}
            for i in range(1,len(raw['routes'])+1)]
    if not path:
        raise ValueError('CP could not generate a course for this field and headland count')
    frame=route_preview(p,bridge)['frames'][0]
    frame=transform_frame(frame,(path[0][0]-frame['x'],path[0][1]-frame['z']),0)
    frame['state']='CP course layout / no motion simulation'
    errors=[str(raw['errors'][i]) for i in range(1,len(raw['errors'])+1)]
    requested=p.headlandRows*p.vehicles
    if not p.narrowField and len(headlands)<requested:
        errors.append(f'CP generated {len(headlands)} of {requested} requested headland paths; this course uses a reduced headland area')
    return {'scenario':asdict(p),'layout':{'boundary':boundary,'headlands':headlands,'islands':islands,'routes':routes,
                'rows':[points(raw['rows'][i]) for i in range(1,len(raw['rows'])+1)],
                'errors':errors},
            'frames':[frame],'paths':[[[v['x'],v['z']] for v in route['waypoints']] for route in routes],'path':[],'events':[],'gaps':[],'exitGaps':[],
            'preview':True,'resolution':.25,
            'metrics':{'complete':False,'entry':None,'missedArea':None,'exitMissedArea':None,
                       'exitOvershoot':None,'envelopeDepth':None,'headlandShortfall':None}}
