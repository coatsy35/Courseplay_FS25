"""Bounded experimental row-turn search using CP's Dubins solver and bench rig.

This deliberately does not replace in-game CP or full-course corner playback.
Candidates must pass the modelled footprint and working-entry checks. Failure
is retained explicitly; no least-bad candidate is presented as a safe turn.
"""

from dataclasses import asdict, replace
import hashlib
import math

from engine import simulate, check_boundary, point, ROOT, SOURCES


def field_for(p):
    slope = p.boundarySlope
    target=p.side*(p.rowSpacing or p.width)
    west, east = -p.fieldWidth/2, p.fieldWidth/2
    top = p.headland*math.hypot(1,slope)
    # Keep the far end level: a sloping headland then produces genuinely short
    # and long working rows. The highest outer corner sets overall field length.
    bottom = top+max(slope*west,slope*east)-p.fieldLength
    if bottom > -max(p.back+25,p.front+30):
        raise ValueError('Increase field length to leave room for the working sample and the whole combination')
    row_steps=round(abs(target)/p.width)
    skipped=([[[p.side*i*p.width,bottom],[p.side*i*p.width,slope*p.side*i*p.width]]
              for i in range(1,row_steps)] if abs(row_steps*p.width-abs(target))<1e-6 else [])
    return dict(west=west,east=east,south=bottom,north=top,
                rows=[0,target],order=[1,2],
                skippedRowSegments=skipped,
                boundary=[[west,bottom],[east,bottom],
                          [east,top+slope*east],[west,top+slope*west]],
                headlands=[[[west,slope*west],[east,slope*east]]],
                rowSegments=[[[x,bottom],[x,slope*x]]
                             for x in (0,target)], islands=[])


def attach_field(run,p):
    run['field']=field_for(p)
    # The analytic adapter appends a long tracking buffer. It is not driven in
    # this row-end test and must not appear as a route through the far boundary.
    run['paths']=[[[w['x'],w['z']] for w in run['path'][:run['frames'][-1]['ix']+1]]]
    # Depth is perpendicular to the sloping inner boundary, not world z.
    depth=max((v[1]-p.boundarySlope*v[0])/math.hypot(1,p.boundarySlope)
              for f in run['frames'] for v in
              [*[point(f['x'],f['z'],f['theta'],across=a,along=b)
                 for a in (-1.9,1.9) for b in (-2,4)],
               *[f[k] for k in ('left','right','rearLeft','rearRight','axle','hitch')]])
    run['metrics']['envelopeDepth']=round(depth,2)
    run['metrics']['headlandShortfall']=round(max(0,depth-p.headland),2)
    return check_boundary(run)


def accepted(run):
    entry=run['metrics'].get('entry') or {}
    contact=[e for e in run['events'] if e['kind']=='Working envelope active']
    commands=[e for e in run['events'] if e['kind']=='Lower requested']
    # Model articulation ceiling is provisional, pending captured joint limits.
    return (not run.get('blocked') and run['metrics']['complete'] and
            entry.get('aligned',False) and entry.get('lowered',False) and
            run['metrics']['maxArticulation'] < 85 and bool(contact) and bool(commands) and
            all(f['envelopeAligned'] for f in run['frames']
                if f['phase']!='exit' and f['lowered']))


def compare_aligned(p, include_baseline=True, start=None):
    if p.fieldShape not in ('rectangle','sloping') or p.entry or p.pattern or p.courseLayout:
        raise ValueError('Aligned entry comparison supports isolated rectangle or sloping row ends')
    slope=(math.tan(math.radians(p.edgeAngle)) * (1 if p.slopeSide=='left' else -1)
           if p.fieldShape=='sloping' else 0)
    target=p.side*(p.rowSpacing or p.width)
    base=replace(p,alignedPlanner=True,boundarySlope=slope,targetZ=slope*target,
                 targetHeading=180,targetX=0,targetExplicit=False,turnType='dubins',
                 extension=0,approachLength=0,enforceBoundary=True,allowReverse=False,
                 fullCourse=False,pattern=False,courseLayout=False)
    baseline=(attach_field(simulate(replace(base,alignedPlanner=False,allowReverse=p.allowReverse),dt=.05),base)
              if include_baseline else None)
    sources={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES}
    # Search final straight and outgoing distance together. The requested radius
    # is a minimum; larger radii offer gentler sideways sweeps without exceeding
    # the model's steering capability. Keep the search finite and reproducible.
    # Short steering-led pull-in first. Extra headland permits a modestly longer
    # final straight and an outward placement, rather than imposing a 20 m tail.
    straight=round(max(4,min(12,(p.headland-2*p.radius)*.1)),1)
    approaches=[straight+bend for bend in (8,12,16,20,28,36)]
    extensions=([8,16,0,4,24] if straight>6 else [0,4,8,16])
    best=None
    attempted=0
    feasible=0
    for approach in approaches:
        for radius in (p.radius*1.1,p.radius*1.25,p.radius):
            for extension in extensions:
                if p.clearance+extension+radius+4 > p.headland*math.hypot(1,slope)+abs(slope)*p.width:
                    continue
                candidate=replace(base,approachLength=approach,extension=extension,
                                  radius=radius,tight=False,finalStraight=straight)
                # A cubic lateral pull-in has |curvature| <= 6*|bias|/bend^2.
                # Limit it before simulation, rather than asking the tracker to
                # follow a path tighter than the selected turning radius.
                limit=min(6,(approach-straight)**2/(6*radius)*.95)

                def trial(bias):
                    nonlocal attempted,feasible,best
                    q=replace(candidate,turnBias=bias)
                    run=simulate(q,dt=.05,start=start)
                    attempted+=1
                    if accepted(run):
                        attach_field(run,q)
                        if accepted(run):
                            fine=attach_field(simulate(q,dt=.025,start=start),q)
                            if accepted(fine):
                                feasible+=1
                                best=fine
                    entry=next((f for f in run['frames'] if f['phase']!='exit' and not f.get('reverse') and
                                run['path'][min(f['ix']-1,len(run['path'])-1)]['lower'] and
                                min(v[1]-slope*v[0] for v in (f['left'],f['right']))<=0),None)
                    if entry is None:
                        return None
                    return (entry['rearLeft'][0]+entry['rearRight'][0])/2-target

                trial(0)
                if best is not None:
                    break
                low,high=-limit,limit
                a,b=trial(low),trial(high)
                if best is not None:
                    break
                # Solve the coupled rear-edge displacement, not tractor heading.
                if a is not None and b is not None and a*b<0:
                    for _ in range(4):
                        bias=low-a*(high-low)/(b-a)
                        error=trial(bias)
                        if best is not None or error is None:
                            break
                        if a*error<=0:
                            high,b=bias,error
                        else:
                            low,a=bias,error
                if best is not None:
                    break
            if best is not None:
                break
        if best is not None:
            break
    k_attempted=0
    if p.allowReverse:
        # Reeds–Shepp supplies genuine forward/reverse K-type alternatives.
        # These paths describe the tractor; propagate the trailer explicitly.
        # A short tractor path that jackknifes its implement is rejected.
        for approach in (4,8,12,16):
            for radius in (p.radius,p.radius*1.25):
                q=replace(base,approachLength=approach,finalStraight=approach,
                          turnType='reedsShepp',radius=radius,tight=False)
                run=simulate(q,dt=.05,start=start)
                k_attempted+=1
                attempted+=1
                if not any(f.get('reverse') for f in run['frames']) or not accepted(run):
                    continue
                attach_field(run,q)
                if not accepted(run):
                    continue
                fine=attach_field(simulate(q,dt=.025,start=start),q)
                if not accepted(fine):
                    continue
                feasible+=1
                def footprint_score(r):
                    return (r['metrics']['envelopeDepth'],sum(math.hypot(b['x']-a['x'],b['z']-a['z'])
                            for a,b in zip(r['frames'],r['frames'][1:])))
                if best is None or footprint_score(fine)<footprint_score(best):
                    best=fine
    if best is None:
        # Keep CP playback available, but do not manufacture an aligned result.
        return dict(baseline=baseline,experiment=None,sources=sources,scenario=asdict(p),
                    planner=dict(feasible=False,attempted=attempted,
                                 message='No aligned turn fits this modelled headland. Change the headland or equipment geometry.'),
                    model='Experimental envelope planner; no feasible candidate')
    fine=best
    fine['planner']=dict(feasible=True,attempted=attempted,candidates=feasible,
                         manoeuvre='K-type' if fine['scenario']['turnType']=='reedsShepp' else 'Steering-led forward turn',
                         reversingCandidates=k_attempted,
                         rowEndDifference=round(slope*target,2),
                         approachLength=fine['scenario']['approachLength'],
                         finalStraight=fine['scenario']['finalStraight'] if fine['scenario']['turnBias'] else fine['scenario']['approachLength'],
                         turnBias=round(fine['scenario']['turnBias'],3),
                         outgoingExtension=fine['scenario']['extension'])
    return dict(baseline=baseline,experiment=fine,planner=fine['planner'],sources=sources,scenario=asdict(p),
                model='CP Dubins solver with experimental envelope alignment and bounded planar trailer search')
