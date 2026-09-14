-- Test-only GIANTS boundary. The planner, geometry adapter, PPC, work-start
-- handler and turn state machine are the production source files shipped in ZIP.
function makeEnvelopeLiveFixture(p)
    local E=EnvelopeTurnPlanner
    local function setting(value) return {getValue=function() return value end} end
    local settings={turnSpeed=setting(8),fieldSpeed=setting(12),reverseSpeed=setting(4),
        envelopeAlignedTurns=setting(true),lowerImplementEarly=setting(true)}
    local node={x=p.start.x,z=p.start.z,t=p.start.t}
    local axle={x=0,z=0,t=0}
    local hitch={x=0,z=0,t=0}
    local object={rootNode=axle,steeringAxleNode=axle,left={},right={},back={},
        size={length=8,width=p.width,lengthOffset=0},wheeled=p.length~=nil,
        input={node=hitch,upperRotLimitScale={1,1,1}},lowerCount=0}
    object.getAttachedImplements=function() return {} end
    object.getActiveInputAttacherJoint=function(self) return self.input end
    object.aiImplementStartLine=function(self) self.lowerCount=self.lowerCount+1 end
    local v={rootNode=node,trailer=p.length and object or nil,speed=0,lastSpeed=0,
        size={length=6,width=3.8,lengthOffset=1},maxTurningRadius=p.vehicleRadius or 9,stopped=false,
        spec_attacherJoints={attacherJoints={{upperRotLimit={0,math.rad(88),0}}}}}
    v.getAIDirectionNode=function() return node end
    v.getAISteeringNode=function() return node end
    v.getName=function() return 'Live mock' end
    v.getCpSettings=function() return settings end
    v.getLastSpeed=function(self) return self.speed end
    v.getAttachedImplements=function() return {{object=object,jointDescIndex=1}} end
    v.getChildVehicles=function() return {v,object} end
    v.stopCurrentAIJob=function(self) self.stopped=true end
    v.raiseStateChange=function() end
    v.cpGetFieldPolygon=function() return {{x=-200,z=-450},{x=200,z=-450},
        {x=200,z=p.headland+p.slope*200},{x=-200,z=p.headland-p.slope*200}} end
    v.cpGetIslandPolygons=function() return {} end
    local context={workStartNode={x=p.goal.x,z=p.goal.z,t=p.goal.t},
        workEndNode={x=0,z=0,t=0},turnEndWpNode={node={x=p.goal.x,z=p.goal.z,t=p.goal.t}},
        turnStartWpIx=20,turnEndWpIx=21}
    context.isHeadlandCorner=function() return false end
    context.shouldPlowBeOnTheLeft=function() return false end
    context.getDistanceToFieldEdge=function() return p.headland-p.start.z end
    local strategy={controllers={},events=0,raised=0,resumed=0}
    strategy.raiseControllerEvent=function(self) self.events=self.events+1 end
    strategy.raiseImplements=function(self) self.raised=self.raised+1 end
    strategy.getLoweringDurationMs=function() return 2500 end
    strategy.getCanContinueWork=function() return true end
    strategy.isWorking=function() return false end
    strategy.getImplementLowerEarly=function() return true end
    strategy.resumeFieldworkAfterTurn=function(self) self.resumed=self.resumed+1 end
    AIDriveStrategyCourse={onTurnEndProgressEvent=1,onLoweringEvent=2}
    AIMessageCpErrorNoPathFound={new=function() return {} end}
    VehicleStateChange={AI_START_LINE=1}
    Logging={info=function() end}
    ImplementUtil={isWheeledImplement=function(o) return o.wheeled or false end}
    AIUtil.getFirstReversingImplementWithWheels=function(vehicle) return vehicle.trailer end
    AIUtil.getTurningRadius=function() return p.radius end
    VehicleSizeScanner=function() return {scan=function(_,o)
        return o.size.length/2+o.size.lengthOffset,-o.size.length/2+o.size.lengthOffset,
            o.size.width/2,-o.size.width/2
    end} end
    CpFieldUtil={isOnField=function() return true end}
    local f={vehicle=v,object=object,context=context,strategy=strategy}
    function f:setPose(s)
        node.x,node.z,node.t=s.x,s.z,s.t
        local h=E.point(s.x,s.z,s.t,p.hitchX,p.hitchZ)
        hitch.x,hitch.z,hitch.t=h.x,h.z,s.phi
        local a=E.point(h.x,h.z,s.phi,-(p.axleOffsetX or 0),-(p.length or 0))
        axle.x,axle.z,axle.t=a.x,a.z,s.phi
        for i,key in ipairs({'left','right'}) do
            local q=E.marker(p,s,p.work[i])
            object[key].x,object[key].z,object[key].t=q.x,q.z,s.phi
        end
        local a=E.marker(p,s,p.work[3])
        local b=E.marker(p,s,p.work[4])
        object.back.x,object.back.z,object.back.t=(a.x+b.x)/2,(a.z+b.z)/2,s.phi
    end
    f:setPose(p.start)
    local turn=setmetatable({vehicle=v,turnContext=context,driveStrategy=strategy,
        workWidth=p.width,settings=settings,ppc={shortLookaheadDistance=3},
        states={ENDING_TURN={name='ENDING_TURN'},TURNING={name='TURNING'},ENVELOPE_STOPPED={name='STOPPED'}},name='test'},EnvelopeCourseTurn)
    turn.state=turn.states.ENDING_TURN
    turn.workStartHandler=WorkStartHandler(v,strategy,context)
    turn.getLowerImplementNode=function() return context.workStartNode end
    turn.resumeFieldworkAfterTurn=function() strategy.resumed=strategy.resumed+1 end
    turn.workStartHandler.shouldLowerThisImplement=function() return turn.lowerRequested or false,turn.lastContact or -100 end
    f.turn=turn
    return f
end

-- Drive production PPC + production turn state machine with finite acceleration
-- and hydraulic delay. Only GIANTS' vehicle physics are replaced by a planar
-- bicycle/passive-trailer update. This catches hand-off and early-stop bugs that
-- checking a list of successful candidate waypoints cannot reveal.
function driveEnvelopeLiveFixture(p)
    local E=EnvelopeTurnPlanner
    local f=makeEnvelopeLiveFixture(p)
    local t=f.turn
    t.geometry=assert(EnvelopeTurnGeometry.capture(t))
    local result=EnvelopeTurnPlanner.plan(t.geometry)
    assert(result.ok,result.reason)
    t.ppc=PurePursuitController(f.vehicle)
    t.ppc:setShortLookaheadDistance()
    t.planner={update=function() return result end}
    function getTimeSec() return os.clock() end
    t:updatePlanner()
    local s={x=p.start.x,z=p.start.z,t=p.start.t,phi=p.start.phi}
    local speed=0
    for tick=1,16000 do
        local dt=0.05
        g_currentMission.time=tick*dt*1000
        f.vehicle.speed=speed*3.6
        f.vehicle.lastSpeed=speed/1000
        f:setPose(s)
        t.ppc:update()
        local gx,gz,forward,limit=t:getDriveData(dt*1000)
        if f.vehicle.stopped then error('runtime stopped at contact '..tostring(t.lastContact)) end
        if f.strategy.resumed>0 then
            assert(f.object.lowerCount==1)
            t.ppc:delete()
            return result
        end
        if not gx then gx,_,gz=t.ppc:getGoalPointPosition() end
        local target=(limit or 0)/3.6
        speed=math.max(0,speed+math.max(-2*dt,math.min(dt,target-speed)))
        local distance=speed*dt
        local dx,dz=gx-s.x,gz-s.z
        -- Physical steering lock belongs to the tractor, not the combination's
        -- planned radius. The production driveGoal must enforce the latter.
        local physicalRadius=p.vehicleRadius or p.radius
        local k=math.max(-1/physicalRadius,math.min(1/physicalRadius,
            2*(dx*math.cos(s.t)-dz*math.sin(s.t))/math.max(0.01,dx*dx+dz*dz)))
        local old=E.point(s.x,s.z,s.t,p.hitchX,p.hitchZ)
        s.x,s.z=s.x+distance*math.sin(s.t+k*distance/2),s.z+distance*math.cos(s.t+k*distance/2)
        s.t=E.wrap(s.t+k*distance)
        if p.length and distance>0 then
            local h=E.point(s.x,s.z,s.t,p.hitchX,p.hitchZ)
            local hx,hz=h.x-old.x,h.z-old.z
            local direction=math.atan2(hx,hz)
            s.phi=E.wrap(direction+2*math.atan(math.tan(E.wrap(s.phi-direction)/2)*
                math.exp(-math.sqrt(hx*hx+hz*hz)/p.length)))
        elseif not p.length then s.phi=s.t end
    end
    error('runtime did not finish; contact '..tostring(t.lastContact))
end
