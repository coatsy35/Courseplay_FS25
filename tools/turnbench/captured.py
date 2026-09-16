"""Import measured machines and attachment chains without inventing rigid trailers.

Motion is replay evidence, not a new physics prediction. Original geometry and
source hashes remain available for future solver calibration.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

LIBRARY = Path(__file__).with_name('fixtures') / 'captured'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def world(pose, local):
    """Root-local to world using the captured orthonormal 3D basis, then X/Z."""
    f, u, origin = pose['forward'], pose['up'], pose['position']
    r = [u[1]*f[2]-u[2]*f[1], u[2]*f[0]-u[0]*f[2], u[0]*f[1]-u[1]*f[0]]
    return [origin[i]+r[i]*local[0]+u[i]*local[1]+f[i]*local[2] for i in (0, 2)]


def xz(node):
    return [node['position'][0], node['position'][2]] if node else None


def frame_machine(machine, profile):
    pose = machine['pose']
    polygons = []
    for area in machine['workAreas']:
        if area.get('disabled') is True:
            continue
        if not all(area.get(k) for k in ('start', 'width', 'height')):
            continue
        a,b,c = [area[k]['position'] for k in ('start','width','height')]
        d = [b[i]+c[i]-a[i] for i in range(3)]
        polygons.append([world(pose,q) for q in (a,b,d,c)])
    size = profile['declaredSize']
    w,l = size.get('width'),size.get('length')
    body = []
    if w and l:
        ox,oz = size.get('widthOffset') or 0,size.get('lengthOffset') or 0
        body = [world(pose,[ox+x,0,oz+z]) for x,z in
                ((-w/2,-l/2),(w/2,-l/2),(w/2,l/2),(-w/2,l/2))]
    return dict(instance=machine['instance'],position=xz(pose),body=body,
                axle=xz(machine['steeringAxle']),hitch=xz(machine['inputCoupling']),
                markers={k:xz(v) for k,v in machine['markers'].items()},
                work=polygons,state=machine['state'],
                heading=math.atan2(pose['forward'][0],pose['forward'][2]))


def import_captures(source, output=LIBRARY):
    source,output=Path(source),Path(output)
    output.mkdir(parents=True,exist_ok=True)
    profiles={}
    for path in sorted(source.glob('*.json')):
        d=json.loads(path.read_text(encoding='utf-8'))
        if d.get('schema')=='fs25-geometry-capture':
            profiles[path.name]=dict(source=path.name,sha256=digest(path),geometry=d)
    catalogue=dict(schemaVersion=1,machines=list(profiles.values()),recordings=[])
    for path in sorted(source.glob('*.jsonl')):
        rows=[json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        header=rows[0]
        if header.get('schema')!='fs25-geometry-motion':
            continue
        if rows[-1].get('type')!='end':
            raise ValueError('Recording is still open: '+path.name)
        members=header['members'];ids={m['instance'] for m in members}
        if len(ids)!=len(members): raise ValueError('Duplicate machine instance')
        member_profiles={}
        for m in members:
            if m['parentInstance'] is not None and m['parentInstance'] not in ids:
                raise ValueError('Missing attachment parent')
            member_profiles[m['instance']]=profiles[m['profileFile']]['geometry']
        frames=[]
        for row in rows[1:-1]:
            if row['type']!='sample': continue
            if {m['instance'] for m in row['machines']}!=ids:
                raise ValueError('Attachment chain changed within recording')
            frames.append(dict(time=row['elapsedMs']/1000,machines=[
                frame_machine(m,member_profiles[m['instance']]) for m in row['machines']]))
        if not frames or len(frames)!=rows[-1]['samples']:
            raise ValueError('Missing recording samples')
        if any(b['time']<=a['time'] for a,b in zip(frames,frames[1:])):
            raise ValueError('Non-monotonic recording')
        summary=dict(id=path.stem,title=' → '.join(m['identity']['name'] for m in members),
                     source=path.name,sha256=digest(path),samples=len(frames),
                     duration=frames[-1]['time'],stopReason=rows[-1]['reason'],
                     members=members,widths=[member_profiles[m['instance']]['aiMarkers']['reportedWidth'] for m in members],
                     loweredSamples={},loweringTransitions={})
        for instance in sorted(ids):
            states=[next(m for m in f['machines'] if m['instance']==instance)['state'].get('lowered') for f in frames]
            summary['loweredSamples'][str(instance)]=sum(v is True for v in states)
            summary['loweringTransitions'][str(instance)]=sum(a is not None and b is not None and a!=b for a,b in zip(states,states[1:]))
        (output/(path.stem+'.json')).write_text(json.dumps(dict(summary=summary,frames=frames),allow_nan=False,separators=(',',':')))
        catalogue['recordings'].append(summary)
    (output/'catalogue.json').write_text(json.dumps(catalogue,allow_nan=False,separators=(',',':')))
    return catalogue


def catalogue():
    return json.loads((LIBRARY/'catalogue.json').read_text())


def recording(identifier):
    if identifier not in {r['id'] for r in catalogue()['recordings']}:
        raise ValueError('Unknown recording')
    return json.loads((LIBRARY/(identifier+'.json')).read_text())


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path)
    args=parser.parse_args()
    result=import_captures(args.source)
    print(f"Imported {len(result['machines'])} dimension snapshots and {len(result['recordings'])} complete recordings")
