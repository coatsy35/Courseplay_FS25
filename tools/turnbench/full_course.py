"""Complete CP courses driven by the bench's bounded-curvature planar rig.

CP supplies field routes, row turns and trailer reverse correction. This module
does not emulate GIANTS suspension, hydraulics or inter-vehicle traffic control.
"""
import math
from dataclasses import replace, asdict
from engine import Bridge, point, wrap, drive_guidance, polygon_contains, check_boundary
from field_coverage import FieldCoverage


def heading(a,b):
    return math.atan2(b['x']-a['x'],b['z']-a['z'])


def forward_space(origin,angle,boundary):
    # Match CP's field probing principle with sub-metre samples.
    for n in range(1,1601):
        x,z=point(*origin,angle,along=n*.25)
        if not polygon_contains(x,z,boundary):
            return (n-1)*.25
    return 400


def compile_route(p,raw,layout):
    source=[]
    for v in raw:
        v=dict(v)
        if source and math.hypot(v['x']-source[-1]['x'],v['z']-source[-1]['z'])<1e-7:
            previous=source.pop()
            for key in ('connecting','rowStart','rowEnd','headlandTurn'):
                v[key]=bool(v.get(key) or previous.get(key))
        source.append(v)
    if len(source)<2:
        raise ValueError('CP returned fewer than two course waypoints')
    for i,v in enumerate(source):
        v['t']=heading(v,source[i+1]) if i+1<len(source) else heading(source[i-1],v)
        v['reverse']=False
        v['working']=not v['connecting']
        v['phase']='Connecting sections' if v['connecting'] else ('Island headland' if v['island'] else ('Island bypass' if v.get('islandBypass') else ('Headland' if v['headland'] else 'Central row')))
    # CP starts a sharp-corner turn at the waypoint immediately before its
    # headland-turn marker (Course:isTurnStartAtIx), not at the corner itself.
    corner_bridge=Bridge(p)
    offsets=corner_bridge.g.workingCourseOffsets(corner_bridge.lua.table_from(asdict(p)),
        corner_bridge.lua.table_from([corner_bridge.lua.table_from([v['x'],v['z']]) for v in source]))
    for i,v in enumerate(source):
        v['offset']=offsets[i+1] if p.tight else 0
    corner_source=[]
    i=0
    while i<len(source):
        if i+2<len(source) and source[i+1].get('headlandTurn') and not source[i+2]['connecting']:
            start,corner,after=source[i:i+3]
            incoming=heading(start,corner)
            outgoing=heading(corner,after)
            if abs(wrap(outgoing-incoming))>math.radians(10):
                work=dict(corner_bridge.g.headlandWork(corner_bridge.lua.table_from(asdict(p)),
                    corner['x'],corner['z'],incoming,outgoing))
                spec=dict(x=corner['x'],z=corner['z'],incoming=incoming,outgoing=outgoing,
                          lowerTarget=[work['startX'],work['startZ'],outgoing])
                finishing=dict(start,t=incoming,phase='Finishing headland',headlandTurn=False,
                               rowStart=False,rowEnd=False,working=True,cornerSpec=spec,offset=0,
                               raiseTarget=[work['endX'],work['endZ'],incoming])
                corner_source.append(finishing)
                corner_source.append(dict(finishing,x=work['finishX'],z=work['finishZ']))
                turn=corner_waypoints(p,corner_bridge,start,spec,
                                      work['finishX'],work['finishZ'],incoming)
                corner_source.extend(turn)
                # Resume the outgoing headland. The final reverse leg is cut
                # short by the runtime work-start/alignment controls, as in CP.
                resume=turn[-1] if p.loopTurnsOnHeadland else corner
                corner_source.append(dict(corner,x=resume['x'],z=resume['z'],t=outgoing,headlandTurn=False,reverse=False,
                                          phase='Headland resume',working=True))
                i+=2
                if p.loopTurnsOnHeadland:
                    # CP's loop includes its straight working approach. Do not
                    # send the tractor back to the corner after driving it.
                    advance=(resume['x']-corner['x'])*math.sin(outgoing)+(resume['z']-corner['z'])*math.cos(outgoing)
                    while i<len(source) and not source[i].get('headlandTurn') and not source[i]['connecting']:
                        progress=(source[i]['x']-corner['x'])*math.sin(outgoing)+(source[i]['z']-corner['z'])*math.cos(outgoing)
                        if progress>advance: break
                        i+=1
                continue
        corner_source.append(source[i])
        i+=1
    source=corner_source
    # CP connects to the first working waypoint after the complete connecting
    # section. Intermediate connecting points describe a preferred path, not
    # independent turn goals (AIDriveStrategyFieldWorkCourse:startConnectingPath).
    i=1
    while i<len(source)-1:
        if source[i]['connecting']:
            j=i
            while j<len(source) and source[j]['connecting']:
                j+=1
            if j>=len(source)-1:
                i=j
                continue
            start=source[i]
            out=heading(source[i-1],start)
            target=source[j]
            incoming=heading(target,source[j+1])
            # TurnContext:getTurnEndNodeAndOffsets: rear trailed implements
            # receive a straight approach before the work-start marker.
            goal_x,goal_z=corner_bridge.g.connectionGoal(corner_bridge.lua.table_from(asdict(p)),
                                                       target['x'],target['z'],incoming)
            raw_link=corner_bridge.g.connectingPath(corner_bridge.lua.table_from(asdict(p)),
                start['x'],start['z'],out,goal_x,goal_z,incoming)
            link=[dict({**start,**dict(raw_link[k])},working=False,phase='Connecting turn',
                       rowStart=False,rowEnd=False,connecting=False)
                  for k in range(1,len(raw_link)+1)]
            if p.runtimeEnvelope and not target['headland']:
                link.append(dict(link[-1],envelopeTarget=[target['x'],target['z'],incoming],
                    envelopeOrigin=[target['x'],target['z'],incoming],envelopeInitial=True,
                    phase='Envelope entry',row=target.get('row',0),offset=0))
            link.append(dict(target,t=incoming,working=False,phase='Connecting turn',
                             rowStart=False,rowEnd=False,connecting=False,offset=0,
                             lower=True,lowerTarget=[target['x'],target['z'],incoming]))
            source[i:j]=link
            i+=len(link)+1
        else:
            i+=1
    result=[]
    i=0
    while i<len(source):
        v=source[i]
        result.append(dict(v))
        if v['rowEnd'] and i>0:
            j=i+1
            while j<len(source) and not source[j]['rowStart'] and j-i<500:
                j+=1
            # CP's explicit block connectors remain intact. Adjacent row ends
            # need the same analytic turn insertion performed at runtime in game.
            if j<len(source)-1 and j==i+1:
                target=source[j]
                out=heading(source[i-1],v)
                incoming=heading(target,source[j+1])
                dx,dz=point(0,0,-out,across=target['x']-v['x'],along=target['z']-v['z'])
                end=(v['x'],v['z'])
                exit_distance=max(p.clearance+p.extension,
                    (p.back if p.raiseLate else p.front)+p.speed*p.raiseSeconds+.2)
                available=forward_space(end,out,layout['boundary'])
                if p.runtimeEnvelope:
                    # Defer planning until playback reaches the actual raised
                    # exit pose. The shipped Lua must see trailer lag from the
                    # preceding work, not a freshly straightened synthetic rig.
                    raise_target=[v['x'],v['z'],out]
                    result[-1]['raiseTarget']=raise_target
                    for k in range(1,math.ceil(exit_distance)+1):
                        x,z=point(*end,out,along=min(k,exit_distance))
                        result.append(dict(x=x,z=z,t=out,reverse=False,working=True,
                            phase='Row exit',row=v['row'],headland=0,raiseTarget=raise_target))
                    result.append(dict(result[-1],working=False,phase='Envelope turn',
                        envelopeTarget=[target['x'],target['z'],incoming],
                        envelopeOrigin=raise_target,raiseTarget=None,row=target['row']))
                    i=j
                    result.append(dict(target,t=incoming))
                    i+=1
                    continue
                local=replace(p,pattern=False,courseLayout=False,fullCourse=False,entry=False,
                              targetExplicit=True,targetX=dx,targetZ=dz,targetHeading=math.degrees(wrap(incoming-out)),
                              side=1 if dx>=0 else -1,headland=max(.1,available),turnType=p.turnType)
                bridge=Bridge(local,turn_pose=dict(x=0,z=exit_distance,theta=0))
                lower_target=[target['x'],target['z'],incoming]
                raise_target=[v['x'],v['z'],out]
                result[-1]['raiseTarget']=raise_target
                for k in range(1,math.ceil(exit_distance)+1):
                    x,z=point(*end,out,along=min(k,exit_distance))
                    result.append(dict(x=x,z=z,t=out,reverse=False,working=True,
                        phase='Row exit',row=v['row'],headland=0,raiseTarget=raise_target))
                path=bridge.path
                last_reverse=max((k for k,w in enumerate(path) if w['reverse']),default=-1)
                finish=0
                advance=0
                for k,w in enumerate(path):
                    x,z=point(*end,out,across=w['x'],along=w['z'])
                    t=wrap(w['t']+out)
                    advance=(x-target['x'])*math.sin(incoming)+(z-target['z'])*math.cos(incoming)
                    result.append(dict(x=x,z=z,t=t,reverse=w['reverse'],working=False,
                        lower=w['lower'],lowerTarget=lower_target,phase='Row turn',row=target['row'],headland=0,
                        offset=bridge.g.changeWaypoint(bridge.rig,k+1)))
                    finish=k
                    if k>last_reverse and advance>=p.front+p.lookahead and abs(wrap(t-incoming))<.1:
                        break
                if finish==len(path)-1 and advance<p.front:
                    raise ValueError('CP row turn did not reach its incoming working row')
                # Consume the part of the incoming row already included in CP's
                # ending turn course; avoid travelling backwards to its start.
                while j+1<len(source) and not source[j]['rowEnd']:
                    q=source[j+1]
                    progress=(q['x']-target['x'])*math.sin(incoming)+(q['z']-target['z'])*math.cos(incoming)
                    if progress>advance:
                        break
                    j+=1
                i=j
        i+=1
    return densify_route(result)


def corner_waypoints(p,bridge,template,spec,x,z,theta):
    raw=bridge.g.headlandCorner(bridge.lua.table_from(asdict(p)),
        spec['x'],spec['z'],spec['incoming'],spec['outgoing'],x,z,theta)
    return [dict({**template,**dict(raw[k])},working=False,
                 phase='Headland corner',headlandTurn=False,rowStart=False,rowEnd=False,
                 cornerSpec=None,raiseTarget=None,cornerHeading=spec['outgoing'],
                 lowerTarget=spec['lowerTarget'] if raw[k]['lower'] else None)
            for k in range(1,len(raw)+1)]


def set_leg_ends(path):
    end=len(path)-1
    for i in range(len(path)-1,-1,-1):
        if i==len(path)-1 or path[i]['reverse']!=path[i+1]['reverse'] or path[i].get('envelopeTarget') or path[i+1].get('envelopeTarget'):
            end=i
        path[i]['legEnd']=end


def densify_route(result):
    # Dense interpolation preserves CP geometry and prevents progress jumping
    # between nearby legs. A gear change switches the controlled reference node.
    dense=[]
    for i,v in enumerate(result):
        if i:
            a=result[i-1]
            if a['reverse']==v['reverse'] and not a.get('envelopeTarget') and not v.get('envelopeTarget'):
                distance=math.hypot(v['x']-a['x'],v['z']-a['z'])
                for k in range(1,math.ceil(distance)):
                    f=k/max(distance,1e-9)
                    dense.append(dict(a,x=a['x']+(v['x']-a['x'])*f,z=a['z']+(v['z']-a['z'])*f))
        dense.append(v)
    set_leg_ends(dense)
    return dense


def drive_course(p,path,vehicle_index,start=None,coverage=None,layout=None):
    bridge=Bridge(replace(p,allowReverse=False,enforceBoundary=False))
    x,z=path[0]['x'],path[0]['z']
    theta=wrap(path[0]['t']+(math.pi if path[0]['reverse'] else 0))
    phi=theta
    if start is not None:
        x,z,theta,phi=(start[k] for k in ('x','z','theta','phi'))
    lowered=bool(path[0].get('working'))
    raising=lowering=None
    frames,events=[],[]
    previous_frame=None
    ix=0
    dt=.1
    last_progress=0
    duration_limit=min(30000,400+sum(math.hypot(b['x']-a['x'],b['z']-a['z']) for a,b in zip(path,path[1:]))/min(p.speed,p.reverseSpeed)*2)
    entry_errors=[]
    measured=set()
    previous_entry_along={}
    previous_gear=False
    complete=False
    runtime=None
    time_offset=0
    runtime_failure=None
    runtime_turns=0
    runtime_entries=[]
    initial_entry=p.runtimeEnvelope and path[0]['phase']=='Central row'
    if p.runtimeEnvelope:
        from runtime_driver import RuntimeDriver
        runtime=RuntimeDriver(p,layout)
    for tick in range(math.ceil(duration_limit/dt)):
        now=tick*dt+time_offset
        if runtime and (initial_entry or path[ix].get('envelopeTarget')):
            control=path[ix]
            target=([control['x'],control['z'],control['t']] if initial_entry else control['envelopeTarget'])
            origin=control.get('envelopeOrigin',target)
            run=runtime.run(dict(x=x,z=z,theta=theta,phi=phi),target,origin,
                            initial_entry or control.get('envelopeInitial',False))
            runtime_turns+=1
            for event in run['events']:
                events.append(dict(event,time=round(now+event['time'],3)))
            for frame in run['frames']:
                f=dict(frame,time=round(now+frame['time'],3),vehicle=vehicle_index,
                       row=control.get('row',0),headland=0)
                if coverage is not None: coverage.add_frame(f)
                # Keep every runtime step: the final gate and work transition
                # must be visible in both playback and the coverage raster.
                frames.append(f)
            if not run['ok']:
                runtime_failure=run['reason']
                events.append(dict(time=now,kind='Envelope runtime stopped: '+runtime_failure,angle=0,error=0))
                break
            last=run['frames'][-1]
            time_offset+=last['time']
            now=tick*dt+time_offset
            x,z,theta,phi=(last[k] for k in ('x','z','theta','phi'))
            lowered=True;raising=lowering=None
            previous_frame=None
            runtime_entries.append(dict(angle=last['angle'],lateral=last['error'],lowered=True))
            if initial_entry:
                initial_entry=False
            else:
                # Replace the deferred marker with the path actually executed.
                # Skip only points reached along this row; never consume its
                # row-end marker, even on a very short pike.
                replacement=[dict(x=w['x'],z=w['z'],t=target[2],reverse=False,
                                  working=False,phase='Envelope turn',row=control.get('row',0),headland=0)
                             for w in run['path'][:last['ix']]]
                path[ix:ix+1]=replacement
                ix+=len(replacement)
            # A checked runtime entry may have consumed the old connection's
            # straight buffer. Do not revisit it and request lowering again.
            while ix<len(path)-1 and path[ix]['phase']=='Connecting turn':
                ix+=1
            while ix+1<len(path) and not path[ix].get('rowEnd'):
                q=path[ix+1]
                if q.get('phase')!='Central row': break
                progress=(q['x']-x)*math.sin(target[2])+(q['z']-z)*math.cos(target[2])
                if progress>0: break
                ix+=1
            set_leg_ends(path)
            last_progress=now
        hitch=point(x,z,theta,along=-p.hitch)
        axle=point(*hitch,phi,along=0 if p.mounted else -p.length)
        work=point(*axle,phi,along=(0 if p.mounted else p.length)+p.hitch-p.front)
        old_ix=ix
        control=path[ix]
        if control.get('cornerSpec'):
            target=control['raiseTarget']
            if bridge.g.shouldRaiseAt(bridge.rig,*work,phi,p.width,p.back-p.front,*target):
                if lowered and raising is None:
                    raising=now
                    events.append(dict(time=round(now,2),kind='Raise requested',angle=0,error=0,
                                       phase='Finishing headland',x=x,z=z,work=list(work),phi=phi,
                                       target=target))
                # WorkEndHandler.allRaised means requests have been sent; CP
                # starts the turn without waiting for hydraulic motion to finish.
                resume=next(j for j in range(ix,len(path)) if path[j]['phase']=='Headland resume')
                replacement=densify_route(corner_waypoints(p,bridge,control,
                    control['cornerSpec'],x,z,theta))
                path[ix:resume]=replacement
                set_leg_ends(path)
                events.append(dict(time=round(now,2),kind='Headland turn started',angle=0,error=0,
                                   x=x,z=z,theta=theta))
                control=path[ix]
        if control.get('changeForwardX') is not None and control['reverse']:
            ahead=(control['changeForwardX']-x)*math.sin(theta)+(control['changeForwardZ']-z)*math.cos(theta)
            if ahead>0: ix=min(len(path)-1,control['legEnd']+1)
        elif control.get('changeWhenAligned') and not control['reverse']:
            if abs(wrap(phi-control['cornerHeading']))<math.radians(5):
                ix=min(len(path)-1,control['legEnd']+1)
        ix,curvature,reverse=drive_guidance(p,bridge,path,ix,x,z,theta,phi,axle)
        if control.get('cornerSpec') and path[ix]['phase']=='Headland corner':
            raise ValueError('The finishing course ended before the implement marker crossed its work-end line')
        if ix!=old_ix: last_progress=now
        if now-last_progress>90:
            break
        v=path[ix]
        target=v.get('lowerTarget')
        raise_target=v.get('raiseTarget')
        if reverse!=previous_gear:
            events.append(dict(time=round(now,2),kind='Reverse selected' if reverse else 'Forward selected',angle=0,error=0))
            previous_gear=reverse
        raise_allowed=(raise_target and not v.get('cornerSpec') and
                       bridge.g.shouldRaiseAt(bridge.rig,*work,phi,p.width,p.back-p.front,*raise_target))
        if lowered and raising is None and (raise_allowed or (not v.get('working') and not v.get('lower') and not target)):
            raising=now
            events.append(dict(time=round(now,2),kind='Raise requested',angle=0,error=0))
        if raising is not None and now-raising>=p.raiseSeconds:
            lowered=False
            raising=None
        can_lower=False
        if target and v.get('lower'):
            can_lower=bridge.g.shouldLowerAt(bridge.rig,*work,phi,p.width,p.back-p.front,
                                             p.reverseSpeed if reverse else p.speed,*target,reverse)[0]
        elif v.get('working') and not raise_target:
            can_lower=True
        if can_lower and reverse and v.get('phase')=='Headland corner':
            # CP resumes fieldwork once lowering has been requested in reverse;
            # the remainder of the synthetic reverse buffer is not driven.
            ix=min(len(path)-1,v['legEnd']+1)
        if not lowered and lowering is None and can_lower:
            lowering=now
            events.append(dict(time=round(now,2),kind='Lower requested',angle=0,error=0))
        if lowering is not None and now-lowering>=p.lowerSeconds:
            lowered=True
            lowering=None
        error=angle=0
        if target:
            error=(work[0]-target[0])*math.cos(target[2])-(work[1]-target[1])*math.sin(target[2])
            angle=math.degrees(wrap(phi-target[2]))
            along=(work[0]-target[0])*math.sin(target[2])+(work[1]-target[1])*math.cos(target[2])
            key=tuple(target)
            crossed=previous_entry_along.get(key,along)<0<=along
            previous_entry_along[key]=along
            if crossed and abs(angle)<90 and key not in measured:
                measured.add(key)
                entry_errors.append(dict(angle=angle,lateral=error,lowered=lowered))
        left,right=point(*work,phi,across=p.width/2),point(*work,phi,across=-p.width/2)
        f=dict(time=round(now,2),x=x,z=z,theta=theta,phi=phi,hitch=hitch,axle=axle,work=work,
               left=left,right=right,rearLeft=point(*left,phi,along=-(p.back-p.front)),
               rearRight=point(*right,phi,along=-(p.back-p.front)),lowered=lowered,
               state=('Reversing' if reverse else v['phase']),phase=v['phase'],
               reverse=reverse,headland=v.get('headland',0),row=v.get('row',0),
               vehicle=vehicle_index,offset=v.get('offset',0),ix=ix+1,angle=angle,error=error)
        if coverage is not None:
            coverage.add_frame(f)
        # Preserve transitions between the normal 0.5 s display samples. This
        # prevents playback drawing work across a lifted section, or omitting
        # the first/last fraction of a pass.
        changed=previous_frame is not None and previous_frame['lowered'] != lowered
        if changed and frames[-1]['time'] < previous_frame['time']:
            frames.append(previous_frame)
        if tick%5==0 or changed:
            frames.append(f)
        previous_frame=f
        rx,rz=axle if reverse and not p.mounted else (x,z)
        end=path[-1]
        dx,dz=rx-end['x'],rz-end['z']
        reached=math.hypot(dx,dz)<1
        if len(path)>1:
            ex,ez=end['x']-path[-2]['x'],end['z']-path[-2]['z']
            distance=math.hypot(ex,ez)
            if distance>1e-8:
                # As at a gear cusp, recognise passing the endpoint within the
                # tracking corridor instead of chasing a point now behind us.
                reached=reached or (dx*ex+dz*ez>=0 and
                    abs(dx*ez-dz*ex)/distance<max(1,p.lookahead))
        if ix>=len(path)-3 and reached:
            complete=True
            f['state']='Finished'
            f['lowered']=False
            if frames[-1]['time']==f['time']: frames[-1]=f
            else: frames.append(f)
            events.append(dict(time=round(now,2),kind='Course finished',angle=0,error=0))
            break
        speed=-p.reverseSpeed if reverse else p.speed
        if p.drill and lowering is not None: speed=0
        distance=speed*dt
        mid=theta+curvature*distance/2
        x+=distance*math.sin(mid)
        z+=distance*math.cos(mid)
        theta=wrap(theta+curvature*distance)
        new_hitch=point(x,z,theta,along=-p.hitch)
        dx,dz=new_hitch[0]-hitch[0],new_hitch[1]-hitch[1]
        phi=theta if p.mounted else wrap(bridge.g.nextTrailerHeading(phi,math.atan2(dx,dz),math.hypot(dx,dz),p.length))
    measured_entries=runtime_entries if p.runtimeEnvelope else entry_errors
    worst=dict(angle=max(abs(e['angle']) for e in measured_entries),lateral=max(abs(e['lateral']) for e in measured_entries)) if measured_entries else None
    return dict(frames=frames,events=events,path=path,paths=[[[v['x'],v['z']] for v in path]],
                runtimeFailure=runtime_failure,runtimeTurns=runtime_turns,
                runtimeVersion=runtime.manifest['version'] if runtime else None,
                metrics=dict(complete=complete,entry=worst,missedArea=None,exitMissedArea=None,
                             exitOvershoot=None,envelopeDepth=None,headlandShortfall=None,
                             duration=frames[-1]['time'],maxArticulation=max(abs(math.degrees(wrap(f['theta']-f['phi']))) for f in frames)))


def simulate_complete(p,generated):
    layout=generated['layout']
    fleet=[]
    coverage=FieldCoverage(layout['boundary'],layout['islands'])
    for i,route in enumerate(layout['routes']):
        path=compile_route(p,route['waypoints'],layout)
        run=drive_course(p,path,i+1,coverage=coverage,layout=layout)
        coverage.finish_vehicle()
        run.update(scenario=asdict(p),preview=False,gaps=[],exitGaps=[],resolution=.25,
                   field=dict(boundary=layout['boundary'],headlands=layout['headlands'],islands=layout['islands'],
                              rows=[],rowSegments=[],order=[],west=0,east=p.fieldWidth,south=0,north=p.fieldLength),
                   coursePath=[[w['x'],w['z']] for w in route['waypoints']],
                   completeCourse=True,position=route['position'])
        fleet.append(check_boundary(run))
    selected=dict(fleet[p.vehicleIndex-1])
    if not selected.get('blocked'):
        selected['frames']=list(selected['frames'])
        end_time=max(vehicle['frames'][-1]['time'] for vehicle in fleet)
        while selected['frames'][-1]['time'] < end_time:
            parked=dict(selected['frames'][-1])
            parked['time']=min(end_time,round(parked['time']+.5,2))
            selected['frames'].append(parked)
    selected['fleet']=fleet
    summary=coverage.result()
    selected['gapRuns']=summary.pop('gapRuns')
    selected['coverage']=summary
    selected['coverageScope']='Whole field / all vehicles'
    selected['resolution']=summary['resolution']
    selected['metrics']=dict(selected['metrics'],missedArea=summary['missedArea'])
    selected['generatorErrors']=layout['errors']
    return selected
