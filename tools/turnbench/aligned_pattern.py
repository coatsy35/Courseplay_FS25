"""Continuous CP skipped-row block using the experimental aligned turn planner."""
from dataclasses import asdict, replace
from functools import lru_cache
import copy
import hashlib
import math
import time

from engine import (Bridge, Scenario, ROOT, SOURCES, point, wrap, simulate,
                    simulate_exit, transform_frame, check_boundary)
from aligned_turn import compare_aligned, accepted, attach_field

_seeds = {}


@lru_cache(maxsize=64)
def turn_template(p):
    """Cache geometry, never substitute cached poses for the live coupled state."""
    family=replace(p,edgeAngle=25,boundarySlope=0)
    seed=_seeds.get(family)
    if seed is not None:
        old,metadata=seed
        slope=math.tan(math.radians(p.edgeAngle))*(1 if p.slopeSide=='left' else -1) if p.fieldShape=='sloping' else 0
        q=replace(p,boundarySlope=slope,targetZ=slope*p.side*p.rowSpacing,
                  approachLength=old.approachLength,finalStraight=old.finalStraight,
                  turnBias=old.turnBias,extension=old.extension,radius=old.radius,
                  turnType=old.turnType,tight=False,allowReverse=False,enforceBoundary=True)
        coarse=simulate(q,dt=.05)
        if accepted(coarse) and accepted(attach_field(coarse,q)):
            fine=attach_field(simulate(q,dt=.025),q)
            if accepted(fine):
                metadata=dict(metadata,attempted=2,warmStarted=True,rowEndDifference=round(q.targetZ,2))
                _seeds[family]=(q,metadata)
                return q,metadata
    result = compare_aligned(p, include_baseline=False)
    if not result['planner']['feasible']:
        raise ValueError('No aligned turn fits this skipped-row block: '+result['planner']['message'])
    value=Scenario(**result['experiment']['scenario']), result['planner']
    _seeds[family]=value
    return value


class BlockCoverage:
    """Whole-block cell-centre coverage; convex work polygons rasterised by column."""
    resolution = .25

    def __init__(self, west, east, bottom, slope):
        self.west, self.bottom, self.slope = west, bottom, slope
        r = self.resolution
        self.columns = [bytearray(max(0, math.ceil((slope*(west+(i+.5)*r)-bottom)/r-.5)))
                        for i in range(round((east-west)/r))]

    def stamp(self, poly):
        r = self.resolution
        lo = max(0, math.ceil((min(p[0] for p in poly)-self.west)/r-.5))
        hi = min(len(self.columns), math.floor((max(p[0] for p in poly)-self.west)/r-.5)+1)
        for i in range(lo,hi):
            x = self.west+(i+.5)*r
            crossings = []
            for a,b in zip(poly,poly[1:]+poly[:1]):
                if abs(a[0]-b[0]) < 1e-12:
                    if abs(x-a[0]) < 1e-9:
                        crossings.extend((a[1],b[1]))
                elif min(a[0],b[0])-1e-9 <= x <= max(a[0],b[0])+1e-9:
                    crossings.append(a[1]+(b[1]-a[1])*(x-a[0])/(b[0]-a[0]))
            if crossings:
                column = self.columns[i]
                low = max(0,math.ceil((min(crossings)-self.bottom)/r-.5-1e-8))
                high = min(len(column),math.floor((max(crossings)-self.bottom)/r-.5+1e-8)+1)
                if high > low:
                    column[low:high] = b'\1'*(high-low)

    def gaps(self):
        r = self.resolution
        return [[self.west+(i+.5)*r,self.bottom+(j+.5)*r]
                for i,column in enumerate(self.columns) for j,worked in enumerate(column) if not worked]


def compare_pattern(p):
    started = time.perf_counter()
    before = calculate_pattern.cache_info().hits
    result = copy.deepcopy(calculate_pattern(p))
    result['planner']['cached'] = calculate_pattern.cache_info().hits > before
    result['planner']['calculationSeconds'] = round(time.perf_counter()-started,2)
    return result


@lru_cache(maxsize=4)
def calculate_pattern(p):
    started = time.perf_counter()
    if p.fieldShape not in ('rectangle','sloping') or p.entry or p.pattern or p.courseLayout:
        raise ValueError('Aligned skipped-row blocks support rectangle and sloping fields')
    skip = round((p.rowSpacing or p.width)/p.width)-1
    if abs((skip+1)*p.width-(p.rowSpacing or p.width))>1e-6:
        raise ValueError('Rows across must be a whole number of implement widths')
    if not 0 <= skip <= 6:
        raise ValueError('Complete skipped-row blocks support zero to six skipped rows')
    count = 2*(skip+1)
    if count*p.width+1 > p.fieldWidth:
        raise ValueError('Increase field width to fit the complete working block and boundary reserve')
    slope = math.tan(math.radians(p.edgeAngle))*(1 if p.slopeSide=='left' else -1) if p.fieldShape=='sloping' else 0
    rows = [(i-(count-1)/2)*p.width for i in range(count)]
    if p.side < 0:
        rows.reverse()
    west,east = -p.fieldWidth/2,p.fieldWidth/2
    top = p.headland*math.hypot(1,slope)
    bottom = top+abs(slope)*p.fieldWidth/2-p.fieldLength
    work_bottom = bottom+p.headland
    if min(slope*x-work_bottom for x in rows) < 45:
        raise ValueError('Increase field length: the shortest row needs at least 45 m between headlands')
    bridge = Bridge(p)
    raw = bridge.g.rowSequence('alternating',count,p.rowsPerLand,p.circles,skip,False,False)
    order = [int(raw[i])-1 for i in range(1,len(raw)+1)]
    if sorted(order) != list(range(count)):
        raise ValueError('CP returned an incomplete skipped-row order')
    boundary = [[west,bottom],[east,bottom],[east,top+slope*east],[west,top+slope*west]]
    frames,events,paths,turns = [],[],[],[]
    last = None
    elapsed = 0
    for n,index in enumerate(order):
        x = rows[index]
        angle = math.pi if n%2 else 0
        origin = (x,work_bottom if n%2 else slope*x)
        if last is None:
            start = dict(x=0,z=work_bottom-slope*x+p.front,theta=0,phi=0)
        else:
            sx,sz = point(0,0,-angle,across=last['x']-origin[0],along=last['z']-origin[1])
            start = dict(x=sx,z=sz,theta=wrap(last['theta']-angle),phi=wrap(last['phi']-angle))
        local = replace(p,alignedPattern=False,pattern=False,courseLayout=False,fullCourse=False,
                        boundarySlope=0 if n%2 else slope,fieldShape='rectangle' if n%2 else p.fieldShape)
        if n == count-1:
            fs,es,_,overshoot = simulate_exit(local,Bridge(local),.025,start=start,final=True)
            path = [[f['x'],f['z']] for f in (fs[0],fs[-1])]
        else:
            dx = (rows[order[n+1]]-x)*(-1 if n%2 else 1)
            template = replace(local,side=1 if dx>0 else -1,rowSpacing=abs(dx),
                               fieldLength=1000,fieldWidth=1000,alignedPattern=False,
                               edgeAngle=25 if n%2 else p.edgeAngle,
                               slopeSide='left' if n%2 else p.slopeSide)
            q,planner = turn_template(template)
            segment = simulate(q,dt=.025,start=start)
            if not accepted(segment):
                # The arriving state and physics sampling phase can differ
                # from a cached template. Re-evaluate the coupled motion; never
                # reset the vehicle/implement to the template's initial pose.
                original=q
                limit=min(6,(q.approachLength-q.finalStraight)**2/(6*q.radius)*.95)
                for delta in (-.025,.025,-.05,.05,-.1,.1):
                    if abs(original.turnBias+delta)>limit:
                        continue
                    q=replace(original,turnBias=original.turnBias+delta)
                    segment=simulate(q,dt=.025,start=start)
                    if accepted(segment):
                        planner=dict(planner,turnBias=q.turnBias,arrivalRefined=True)
                        break
                if not accepted(segment):
                    fresh=compare_aligned(template,include_baseline=False,start=start)
                    if not fresh['planner']['feasible']:
                        raise ValueError(f'No aligned turn fits the actual arriving state after row {index+1}')
                    segment=fresh['experiment']
                    q=Scenario(**segment['scenario'])
                    planner=dict(fresh['planner'],arrivalReplanned=True)
            fs,es = segment['frames'],segment['events']
            path = [[fs[0]['x'],fs[0]['z']]]+[[w['x'],w['z']] for w in segment['path'][:fs[-1]['ix']]]
            turns.append(dict(passNumber=n+1,row=index+1,**segment['metrics'],planner=planner,
                              scenario=asdict(q)))
        paths.append([point(*origin,angle,across=a,along=b) for a,b in path])
        for f in fs:
            mapped = transform_frame(f,origin,angle,elapsed)
            mapped['pass'] = n+1 if f['phase']=='exit' else n+2
            if not frames or mapped['time']>frames[-1]['time']:
                frames.append(mapped)
        events.extend({**e,'time':round(e['time']+elapsed,2),
                       'pass':n+2 if e['kind'].startswith('Lower') or e['kind'] in ('Implement lowered','Working envelope active') else n+1,
                       'end':'Pike' if not n%2 and slope else 'Straight end'} for e in es)
        last,elapsed = frames[-1],frames[-1]['time']
    coverage = BlockCoverage(min(rows)-p.width/2,max(rows)+p.width/2,work_bottom,slope)
    previous = None
    for f in frames:
        if f['lowered']:
            coverage.stamp([f[k] for k in ('left','right','rearRight','rearLeft')])
            if previous is not None:
                coverage.stamp([previous['left'],previous['right'],f['right'],f['left']])
            previous = f
        else:
            previous = None
    gaps = coverage.gaps()
    entries = [t['entry'] for t in turns]
    metrics = dict(complete=True,entry=dict(angle=max(abs(e['angle']) for e in entries),
                    lateral=max(abs(e['lateral']) for e in entries),aligned=True,lowered=True),
                   missedArea=round(len(gaps)*coverage.resolution**2,2),exitMissedArea=None,
                   exitOvershoot=max(t['exitOvershoot'] for t in turns),headlandShortfall=0,
                   envelopeDepth=None,
                   maxArticulation=max(t['maxArticulation'] for t in turns),duration=elapsed)
    run = dict(scenario=asdict(replace(p,enforceBoundary=True)),frames=frames,events=events,
               paths=paths,path=[],gaps=gaps,exitGaps=[],resolution=coverage.resolution,preview=False,
               turns=turns,metrics=metrics,coverageScope='Complete working-row block',
               field=dict(boundary=boundary,headlands=[[[west,work_bottom],[east,work_bottom]],
                    [[west,slope*west],[east,slope*east]]],rowSegments=[[[x,work_bottom],[x,slope*x]] for x in rows],
                    order=[i+1 for i in order],rows=rows,west=west,east=east,south=bottom,north=top,islands=[]))
    check_boundary(run)
    # Boundary and coverage checks above retain every simulated turn pose.
    # Browser playback needs only 10 Hz; preserve state transitions and the end.
    kept = [frames[0]]
    for f in frames[1:]:
        if f['time']-kept[-1]['time'] >= .099 or f['lowered']!=kept[-1]['lowered']:
            kept.append(f)
    if kept[-1] is not frames[-1]:
        kept.append(frames[-1])
    run['frames'] = kept
    planner = dict(feasible=not run.get('blocked',False),pattern=True,rows=count,turns=len(turns),
                   order=[i+1 for i in order],calculationSeconds=round(time.perf_counter()-started,2),
                   message=f'{count} rows / {len(turns)} turns; complete working-block coverage')
    run['planner'] = planner
    return dict(baseline=run,experiment=None,planner=planner,scenario=asdict(p),
                sources={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES},
                model='Continuous experimental aligned skipped-row block; CP row ordering')
