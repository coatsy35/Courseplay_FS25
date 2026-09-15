"""Run the shipped envelope Lua against a planar replacement for GIANTS physics.

The Lua snapshot is versioned and hash-checked. No Python turn search or lowering
fallback is used here: failure from the runtime remains a failed bench turn.
"""
import math
from pathlib import Path
from engine import Bridge, point, distance_to_segment


class RuntimeDriver:
    def __init__(self, p, layout):
        from sync_runtime import validate
        self.manifest=validate()
        self.p, self.layout = p, layout
        self.bridge = Bridge(p)
        self.lua = self.bridge.lua
        folder = Path(__file__).with_name('runtime')
        self.lua.execute("g_updateLoopIndex=1; function getName() return 'bench node' end; require('PurePursuitController')")
        for name in ('EnvelopeTurnPlanner', 'EnvelopeTurnGeometry', 'EnvelopeCourseTurn', 'planar-host', 'drive'):
            self.lua.execute((folder / (name + '.lua')).read_text(encoding='utf-8-sig'))

    def table(self, value):
        if isinstance(value, dict):
            return self.lua.table_from({k:self.table(v) for k,v in value.items()})
        if isinstance(value, (list,tuple)):
            return self.lua.table_from([self.table(v) for v in value])
        return value

    def run(self, pose, target, origin, initial=False):
        p = self.p
        t = target[2]
        dx, dz = origin[0]-target[0], origin[1]-target[1]
        across = dx*math.cos(t)-dz*math.sin(t)
        along = dx*math.sin(t)+dz*math.cos(t)
        slope = along/across if abs(across)>.1 else 0
        if initial:
            # Entry uses the local inner headland edge, not a diagonal line
            # from a section connector to the next row's start.
            edges=[]
            for polygon in self.layout.get('headlands',[])[-1:]:
                for a,b in zip(polygon,polygon[1:]+polygon[:1]):
                    vx,vz=b[0]-a[0],b[1]-a[1]
                    across=vx*math.cos(t)-vz*math.sin(t)
                    if abs(across)>.1:
                        edges.append((distance_to_segment(target[:2],a,b),
                                      (vx*math.sin(t)+vz*math.cos(t))/across))
            if edges: slope=min(edges)[1]
        params = dict(width=p.width, length=None if p.mounted else p.length,
            radius=p.radius, vehicleRadius=p.radius, hitchX=0, hitchZ=-p.hitch,
            front=-p.front, back=p.back, slope=slope, headland=p.headland,
            loweringSeconds=p.lowerSeconds, speed=p.speed, lookahead=p.lookahead,
            start=dict(x=pose['x'],z=pose['z'],t=pose['theta'],phi=pose['phi']),
            goal=dict(x=target[0],z=target[1],t=t),
            boundary=[dict(x=x,z=z) for x,z in self.layout['boundary']],
            islands=[[dict(x=x,z=z) for x,z in island] for island in self.layout['islands']],
            work=[], footprint=[], initial=initial)
        params.pop('length') if p.mounted else None
        for rear in (False,True):
            for side in (-1,1):
                params['work'].append(dict(x=side*p.width/2,
                    z=(p.hitch if not p.mounted else 0)-(p.back if rear else p.front),
                    towed=not p.mounted,rear=rear))
        result = self.lua.globals().driveBenchEnvelope(self.table(params))
        frames = [dict(v) for v in result['frames'].values()]
        for f in frames:
            for key in ('hitch','axle','work','left','right','rearLeft','rearRight'):
                f[key] = list(f[key].values())
        if not frames:
            h=point(pose['x'],pose['z'],pose['theta'],along=-p.hitch)
            a=point(*h,pose['phi'],along=0 if p.mounted else -p.length)
            w=point(*h,pose['phi'],along=p.hitch-p.front)
            left,right=point(*w,pose['phi'],across=-p.width/2),point(*w,pose['phi'],across=p.width/2)
            frames=[dict(pose,time=0,hitch=h,axle=a,work=w,left=left,right=right,
                rearLeft=point(*left,pose['phi'],along=p.front-p.back),
                rearRight=point(*right,pose['phi'],along=p.front-p.back),lowered=False,
                state='Envelope runtime stopped',phase='Envelope turn',reverse=False,offset=0,ix=1,angle=0,error=0)]
        return dict(ok=result['ok'],reason=result['reason'],frames=frames,
                    path=[dict(v) for v in result['path'].values()],
                    events=[dict(v) for v in result['events'].values()],
                    version=self.lua.globals().EnvelopeCourseTurn.TEST_VERSION)
