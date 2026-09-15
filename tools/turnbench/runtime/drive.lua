-- Only the host's movement is simulated. Planning, pursuit, footprint checking,
-- entry admission, hydraulic waiting and fieldwork hand-off run shipped Lua.
function driveBenchEnvelope(p)
    local E,G=EnvelopeTurnPlanner,EnvelopeTurnGeometry
    local f=makeBenchEnvelopeHost(p)
    f.vehicle.cpGetFieldPolygon=function() return p.boundary end
    f.vehicle.cpGetIslandPolygons=function() return p.islands end
    f.object.size.length=p.back+p.front
    f.object.size.lengthOffset=(p.length or 0)-p.hitchZ-(p.back-p.front)/2
    f.strategy.getLoweringDurationMs=function() return p.loweringSeconds*1000 end
    f.strategy.getCanContinueWork=function() return true end
    local t=f.turn
    t.entrySlope=p.slope
    t.headlandSeed=p.headland
    t.ppc=PurePursuitController(f.vehicle)
    t.ppc:setShortLookaheadDistance()
    local geometry,captureReason=G.capture(t)
    if not geometry then
        t.ppc:delete()
        return {ok=false,reason=captureReason,frames={},events={},path={}}
    end
    t.geometry=geometry
    local frames,events={},{}
    local now=0
    t.log=function(_,format,...)
        if not string.find(format,'^TRACK:') then
            events[#events+1]={time=now,kind=string.format(format,...),angle=0,error=0}
        end
    end
    local reason
    local stop=EnvelopeCourseTurn.stopWithReason
    t.stopWithReason=function(self,why) reason=why;stop(self,why) end
    local result
    if p.initial then
        local goal=E.point(p.goal.x,p.goal.z,p.goal.t,0,-p.front+30)
        local simulation=E.newSimulation(t.geometry,{p.start,goal},2,.075,true,true)
        repeat result=simulation:update(500) until result
        if result.ok then
            result.retainedApproach=true;result.attempts=0;result.straight=0
            result.bend=0;result.radius=p.radius;result.extension=0;result.bias=0
        else
            local search=E.newApproachSearch(t.geometry)
            repeat result=search:update(500) until result
        end
        if not result.ok then
            -- Match v0.16's initial-entry recovery: validate the entire turn
            -- with the measured trailer pose before driving, rather than
            -- accepting a tractor-only connection and checking at its end.
            t:log('Initial connection needs complete envelope recovery: %s',result.reason)
            result=E.plan(t.geometry)
        end
    else result=E.plan(t.geometry) end
    if not result.ok then
        t.ppc:delete()
        return {ok=false,reason=result.reason,frames=frames,events=events,path={}}
    end
    t.planner={update=function() return result end}
    t:updatePlanner()
    local s={x=p.start.x,z=p.start.z,t=p.start.t,phi=p.start.phi}
    local speed=0
    for tick=0,24000 do
        local dt=.05
        now=tick*dt
        g_currentMission.time=now*1000
        f.vehicle.speed=speed*3.6;f.vehicle.lastSpeed=speed/1000
        f:setPose(s)
        t.ppc:update()
        local gx,gz,forward,limit=t:getDriveData(dt*1000)
        local active=t.loweringStarted and now*1000-t.loweringStarted>=p.loweringSeconds*1000
        local corners={}
        for _,m in ipairs(p.work) do local q=E.marker(p,s,m);corners[#corners+1]={q.x,q.z} end
        local h=E.point(s.x,s.z,s.t,p.hitchX,p.hitchZ)
        local a=E.point(h.x,h.z,s.phi,0,-(p.length or 0))
        local aligned,error,angle,contact=E.assess(t.geometry or f.savedGeometry,s)
        local frame={time=now,x=s.x,z=s.z,theta=s.t,phi=s.phi,
            hitch={h.x,h.z},axle={a.x,a.z},
            work={(corners[1][1]+corners[2][1])/2,(corners[1][2]+corners[2][2])/2},
            left=corners[1],right=corners[2],rearLeft=corners[3],rearRight=corners[4],
            lowered=active or false,reverse=false,offset=0,ix=t.ppc:getCurrentWaypointIx(),
            angle=math.deg(angle),error=error,state='Envelope turn',phase='Envelope turn'}
        frames[#frames+1]=frame
        if f.vehicle.stopped or f.strategy.resumed>0 then break end
        f.savedGeometry=t.geometry
        if not gx then gx,_,gz=t.ppc:getGoalPointPosition() end
        local target=math.min(p.speed,(limit or 0)/3.6)
        speed=math.max(0,speed+math.max(-2*dt,math.min(dt,target-speed)))
        local distance=speed*dt
        local dx,dz=gx-s.x,gz-s.z
        local k=math.max(-1/p.vehicleRadius,math.min(1/p.vehicleRadius,
            2*(dx*math.cos(s.t)-dz*math.sin(s.t))/math.max(.01,dx*dx+dz*dz)))
        s.x=s.x+distance*math.sin(s.t+k*distance/2)
        s.z=s.z+distance*math.cos(s.t+k*distance/2)
        s.t=E.wrap(s.t+k*distance)
        if p.length and distance>0 then
            local q=E.point(s.x,s.z,s.t,p.hitchX,p.hitchZ)
            local hx,hz=q.x-h.x,q.z-h.z
            local direction=math.atan2(hx,hz)
            s.phi=E.wrap(direction+2*math.atan(math.tan(E.wrap(s.phi-direction)/2)*math.exp(-math.sqrt(hx*hx+hz*hz)/p.length)))
        elseif not p.length then s.phi=s.t end
    end
    t.ppc:delete()
    return {ok=f.strategy.resumed>0,reason=f.strategy.resumed>0 and '' or reason or 'runtime approach did not finish',frames=frames,
        events=events,path=result.path}
end
