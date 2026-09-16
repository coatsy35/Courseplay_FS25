-- v0.19, 15 September 23:24:26: centred snapshot. Deployment applies the
-- measured working markers and 1.505 m CP goal-offset change from 23:25:18.
function deploymentFixture(side)
    g_currentMission.time=0
    local p=envelopeFixture(5.6,11.27,1.641,3.33,16.931,14.3,1,50.1)
    p.start={x=-168.816*side,z=-142.077,t=math.rad(61.245)*side,phi=math.rad(60.915)*side}
    p.goal={x=-158.266*side,z=-118.820,t=0}
    p.hitchX=.001*side;p.axleOffsetX=-.01*side;p.slope=p.slope*side
    p.lookahead=2.695;p.vehicleRadius=5.389
    p.work={{x=.016*side,z=-2.751,towed=true},{x=-.002*side,z=-1.694,towed=true},
        {x=.016*side,z=-15.290,towed=true,rear=true},{x=-.002*side,z=-15.290,towed=true,rear=true}}
    local f=makeEnvelopeLiveFixture(p);local t=f.turn
    addStockPloughFixture(f)
    f.object.setRotationMax=function(self,whichSide)
        local _,_,_,_,state=EnvelopeTurnGeometry.assessLive(t.geometry,f.vehicle)
        assert(EnvelopeTurnPlanner.canDeploy(t.geometry,state),'rotation before combination alignment')
        for i=math.max(1,t.ppc:getCurrentWaypointIx()),#t.result.path-1 do
            local a,b=t.result.path[i],t.result.path[i+1]
            assert(math.abs(EnvelopeTurnPlanner.wrap(math.atan2(b.x-a.x,b.z-a.z)-t.geometry.goal.t))<=
                EnvelopeTurnPlanner.angleTolerance,'rotation before final straight')
        end
        self.sideCommands=self.sideCommands+1;self.targetAnimation=whichSide and 1 or 0
        self.playing=true;self.animationEnd=g_currentMission.time+7000
    end
    t.needsWorkingGeometry=true;t.entrySlope=p.slope;t.headlandSeed=50.1
    t.ppc=PurePursuitController(f.vehicle);t.ppc.shortLookaheadDistance=2.695
    local log={};f.logs=log
    t.log=function(_,format,...) log[#log+1]=string.format(format,...) end
    p.stateFixture=function(current,s)
        if current.object.playing and g_currentMission.time>=current.object.animationEnd then
            current.object.animation=current.object.targetAnimation;current.object.playing=false
            p.work={{x=-3.264*side,z=-2.155,towed=true},{x=2.287*side,z=-2.469,towed=true},
                {x=-3.264*side,z=-16.136,towed=true,rear=true},{x=2.287*side,z=-16.136,towed=true,rear=true}}
            p.length=11.11;p.hitchX=.018*side;p.hitchZ=-1.645;p.axleOffsetX=.02*side
            current.context.workStartNode.x=-156.761*side
            s.phi=EnvelopeTurnPlanner.wrap(s.phi-math.rad(12.3)*side)
        end
    end
    p.planFixture=function()
        t:startPlanning()
        for i=1,10000 do
            g_currentMission.time=g_currentMission.time+50
            t:updatePlanner()
            if not t.planner then
                f.initialAttempts=t.result and t.result.attempts
                return assert(t.result,table.concat(log,'\n'))
            end
        end
        error('deployment planning did not finish')
    end
    return p,f
end

-- Saved T7 first-pike course: use its outer headland CENTRELINE as a
-- conservative inset boundary. Arrival yaw and hydraulic transform remain
-- synthetic; a separate unit check covers the stock approach's handover
-- policy, not GIANTS' execution of the complete drive-to-work path.
function configureSavedStraightEntry(p,f,field,arrivalAngle)
    f.turn.initialRowGoal={x=p.goal.x,z=p.goal.z,t=p.goal.t}
    f.vehicle.cpGetFieldPolygon=function() return field end
    f.strategy.vehicle=f.vehicle;f.strategy.workWidth=p.width
    f.strategy.frontMarkerDistance=-3.7;f.strategy.backMarkerDistance=-17.4
    local course={getWaypointPosition=function() return p.goal.x,0,p.goal.z end,
        getWaypointYRotation=function() return p.goal.t end,getNumberOfHeadlands=function() return 9 end}
    local offset,fits=EnvelopeTurnGeometry.outerEntryOffset(f.strategy,course,1,-p.length)
    assert(fits and offset < -24)
    p.start={x=p.goal.x,z=p.goal.z+offset,t=0,phi=math.rad(arrivalAngle)}
    f:setPose(p.start)
    p.planFixture=function()
        local path={}
        for z=p.start.z,p.goal.z+12,0.5 do path[#path+1]={x=p.start.x,z=z} end
        f.turn:startPlanning(path)
        for i=1,1000 do
            g_currentMission.time=g_currentMission.time+50
            f.turn:updatePlanner()
            if not f.turn.planner then return assert(f.turn.result,table.concat(f.logs,'\n')) end
        end
        error('straight entry validation did not finish')
    end
end

-- 16 September 08:50:47: measured centred pose after the first short row.
-- Field centreline and subsequent working transform are explicit proxies.
function configureRecordedFirstExit(p,f,field,offsetChange)
    p.start={x=-156.818,z=-97.468,t=math.rad(.036),phi=math.rad(9.652)}
    -- Logged target omitted CP's twice-current-offset correction at the
    -- immediate short-row handover. Offset inferred from saved row -162.87.
    p.goal={x=-163.328-2*(-.458),z=-110.360,t=-math.pi}
    p.hitchX=.03;p.hitchZ=-1.649;p.length=11.28;p.axleOffsetX=.04
    p.slope=math.tan(math.rad(-39.5));p.headland=46.5;p.front=-3.37
    p.work={{x=-.093,z=-2.715,towed=true},{x=.045,z=-1.717,towed=true},
        {x=-.093,z=-15.333,towed=true,rear=true},{x=.045,z=-15.333,towed=true,rear=true}}
    f.vehicle.cpGetFieldPolygon=function() return field end
    for _,node in ipairs({f.context.workStartNode,f.context.turnEndWpNode.node}) do
        node.x,node.z,node.t=p.goal.x,p.goal.z,p.goal.t
    end
    f.context.shouldPlowBeOnTheLeft=function() return true end
    f.turn.entrySlope=p.slope;f.turn.headlandSeed=p.headland
    f:setPose(p.start)
    p.stateFixture=function(current,s)
        if current.object.playing and g_currentMission.time>=current.object.animationEnd then
            current.object.animation=current.object.targetAnimation;current.object.playing=false
            p.work={{x=3.265,z=-2.150,towed=true},{x=-2.286,z=-2.465,towed=true},
                {x=3.265,z=-16.123,towed=true,rear=true},{x=-2.286,z=-16.123,towed=true,rear=true}}
            p.length=11.10
            current.context.workStartNode.x=p.goal.x+offsetChange
            -- Reuse the earlier observed deployment-frame change as a
            -- synthetic assumption; this next turnover has not run in game.
            s.phi=EnvelopeTurnPlanner.wrap(s.phi-math.rad(12.3))
        end
    end
end

-- v0.23 09:39:50 measured approach pose and 09:40:24 working geometry.
-- The remaining stock line and hydraulic heading change are reconstructed:
-- unlike the old cases this arrives bent and changes target 2.131 m LEFT.
function configureV023Entry(p,f)
    p.start={x=-156.892,z=-141.964,t=math.rad(-5.521),phi=math.rad(35.833)}
    p.goal={x=-154.860,z=-118.820,t=0}
    -- Row centre reconstructed from the logged field-detection/course start
    -- (-157.8, -118.8); this is a proxy, not a captured high-precision polygon.
    f.turn.initialRowGoal={x=-157.8,z=-118.820,t=0}
    p.hitchX=.049;p.hitchZ=-1.626;p.length=11.28;p.axleOffsetX=.01
    p.work={{x=-.031,z=-2.732,towed=true},{x=.018,z=-1.705,towed=true},
        {x=-.031,z=-15.312,towed=true,rear=true},{x=.018,z=-15.312,towed=true,rear=true}}
    p.headland=70.6;f.turn.headlandSeed=70.6
    for _,node in ipairs({f.context.workStartNode,f.context.turnEndWpNode.node}) do
        node.x,node.z,node.t=p.goal.x,p.goal.z,0
    end
    f:setPose(p.start)
    p.stateFixture=function(current,s)
        if current.object.playing and g_currentMission.time>=current.object.animationEnd then
            current.object.animation=current.object.targetAnimation;current.object.playing=false
            p.work={{x=-3.267,z=-2.147,towed=true},{x=2.284,z=-2.463,towed=true},
                {x=-3.267,z=-16.114,towed=true,rear=true},{x=2.284,z=-16.114,towed=true,rear=true}}
            p.length=11.09;p.hitchX=.026;p.hitchZ=-1.645;p.axleOffsetX=.02
            current.context.workStartNode.x=-156.991
            s.phi=EnvelopeTurnPlanner.wrap(s.phi-math.rad(12.3))
        end
    end
    p.planFixture=function()
        local path={{x=p.start.x,z=p.start.z}}
        for z=p.start.z+1,p.goal.z+12,.5 do path[#path+1]={x=p.goal.x,z=z} end
        f.turn:startPlanning(path)
        for i=1,1000 do
            g_currentMission.time=g_currentMission.time+50;f.turn:updatePlanner()
            if not f.turn.planner then return assert(f.turn.result,table.concat(f.logs,'\n')) end
        end
        error('v0.23 entry planning did not finish')
    end
end

-- Latest v0.24 arrival, 16 September 11:08:55. Subsequent deployment
-- transform and boundary are the explicitly labelled proxies above.
function configureV024Entry(p,f)
    configureV023Entry(p,f)
    p.start={x=-156.930,z=-141.746,t=math.rad(-6.762),phi=math.rad(35.186)}
    p.goal.x=-154.854
    p.headland=72.7;f.turn.headlandSeed=p.headland
    f.context.workStartNode.x=p.goal.x
    f.context.turnEndWpNode.node.x=p.goal.x
    f:setPose(p.start)
end

-- v0.25 second row exit, 16 September 12:41:01. These raised dimensions
-- are measured; subsequent turnover remains a synthetic working-side change.
function configureV025SecondExit(p,f,field)
    p.start={x=-162.514,z=-138.500,t=math.rad(179.992),phi=math.rad(170.572)}
    p.goal={x=-168.114,z=-121.280,t=0}
    p.hitchX=-.02;p.hitchZ=-1.67;p.length=11.31;p.axleOffsetX=-.07
    p.work={{x=.160,z=-2.593,towed=true},{x=-.064,z=-1.790,towed=true},
        {x=.160,z=-15.464,towed=true,rear=true},{x=-.064,z=-15.464,towed=true,rear=true}}
    p.slope=math.tan(math.rad(10.4));p.headland=47.5
    f.turn.headlandSeed=p.headland;f.turn.entrySlope=p.slope
    if field then f.vehicle.cpGetFieldPolygon=function() return field end end
    for _,node in ipairs({f.context.workStartNode,f.context.turnEndWpNode.node}) do
        node.x,node.z,node.t=p.goal.x,p.goal.z,p.goal.t
    end
    f:setPose(p.start)
    p.stateFixture=function(current,state)
        if current.object.playing and g_currentMission.time>=current.object.animationEnd then
            current.object.animation=current.object.targetAnimation;current.object.playing=false
            p.work={{x=-3.265,z=-2.151,towed=true},{x=2.286,z=-2.467,towed=true},
                {x=-3.265,z=-16.127,towed=true,rear=true},{x=2.286,z=-16.127,towed=true,rear=true}}
            p.length=11.10;p.hitchX=.02;p.hitchZ=-1.66;p.axleOffsetX=.02
            state.phi=EnvelopeTurnPlanner.wrap(state.phi-math.rad(12.3))
        end
    end
end

-- Raised snapshot from the v0.26 row 14 -> 15 failure. Working-position
-- animation remains the measured PW proxy used by the preceding exit case.
function configureV026Exit(p,f,field)
    configureV025SecondExit(p,f,field)
    p.start={x=-173.720,z=-141.247,t=math.rad(-179.997),phi=math.rad(170.510)}
    p.goal={x=-179.317,z=-124.920,t=0}
    p.hitchX=-.024;p.hitchZ=-1.673
    p.work={{x=.163,z=-2.592,towed=true},{x=-.065,z=-1.791,towed=true},
        {x=.163,z=-15.466,towed=true,rear=true},{x=-.065,z=-15.466,towed=true,rear=true}}
    p.slope=math.tan(math.rad(19.1));p.headland=46.6
    f.turn.headlandSeed=p.headland;f.turn.entrySlope=p.slope
    for _,node in ipairs({f.context.workStartNode,f.context.turnEndWpNode.node}) do
        node.x,node.z,node.t=p.goal.x,p.goal.z,p.goal.t
    end
    f:setPose(p.start)
end

-- v0.27 failure at 15:33:02. Raised dimensions and pose are recorded;
-- turnover uses the previous working-side proxy, not an observed failed turn.
function configureV027Exit(p,f,field)
    configureRecordedFirstExit(p,f,field,0)
    p.start={x=-235.315,z=-26.349,t=math.rad(-.050),phi=math.rad(9.829)}
    p.goal={x=-240.911,z=-40.060,t=-math.pi}
    p.hitchX=.009;p.hitchZ=-1.634;p.length=11.26;p.axleOffsetX=0
    p.work={{x=-.006,z=-2.801,towed=true},{x=.008,z=-1.663,towed=true},
        {x=-.006,z=-15.227,towed=true,rear=true},{x=.008,z=-15.227,towed=true,rear=true}}
    p.slope=math.tan(math.rad(-41.7));p.headland=44.6
    f.turn.entrySlope=p.slope;f.turn.headlandSeed=p.headland
    for _,node in ipairs({f.context.workStartNode,f.context.turnEndWpNode.node}) do
        node.x,node.z,node.t=p.goal.x,p.goal.z,p.goal.t
    end
    f:setPose(p.start)
end

function attachFieldworkHandover(p,f)
    local s,t=f.strategy,f.turn
    s.vehicle=f.vehicle;s.settings=f.vehicle:getCpSettings();s.workWidth=p.width;s.ppc=t.ppc
    s.settings.fieldWorkSpeed={getValue=function() return 12 end}
    s.states={TURNING={},WAITING_FOR_LOWER={},WAITING_FOR_LOWER_DELAYED={},WORKING={}}
    s.state=s.states.TURNING;s.aiTurn=t
    s.debug=function() end;s.debugSparse=function() end
    s.plowOffsetUnknown={reset=function() f.offsetResets=(f.offsetResets or 0)+1 end}
    s.haveRotatablePlow=function() return f.controller~=nil end
    s.rotatePlows=function() error('central-row handover must not rotate again') end
    s.startWaitingForLower=AIDriveStrategyFieldWorkCourse.startWaitingForLower
    s.lowerImplements=function()
        assert(t.entryReleased,'fieldwork lowered before envelope release')
        f.fieldworkLowerCalls=(f.fieldworkLowerCalls or 0)+1
    end
    s.startCourse=function(self,course,ix)
        self.course=course;self.ppc:setCourse(course);self.ppc:initialize(ix)
    end
    s.resumeFieldworkAfterTurn=function(self,ix)
        -- Reconstruct the original generated row with its current CP offset.
        local row={};local goal=f.context.workStartNode
        for distance=0,100,2 do
            local q=EnvelopeTurnPlanner.point(goal.x,goal.z,goal.t,0,distance)
            local attr=CourseGenerator.WaypointAttributes();attr.rowStart=distance==0;attr.rowEnd=distance==100
            attr.atBoundaryId='F';q.attributes=attr;row[#row+1]=q
        end
        self.fieldWorkCourse=Course(f.vehicle,row,false)
        self.resumed=self.resumed+1
        AIDriveStrategyPlowCourse.resumeFieldworkAfterTurn(self,1)
        f.entryGeometry=assert(EnvelopeTurnGeometry.capture(t))
        f.handoverSteps=0;f.workedDistance=0
    end
    s.setMaxSpeed=function(self,speed) self.maxSpeed=math.min(self.maxSpeed or math.huge,speed) end
    for _,method in ipairs({'updateFieldworkOffset','updateLowFrequencyImplementControllers',
            'setAITarget','limitSpeed','checkProximitySensors','checkDistanceToOtherFieldWorkers'}) do
        s[method]=function() end
    end
    AIUtil.getSteeringParameters=function() return p.length and f.object,p.length or 0 end
    AIUtil.hasChainedAttachments=function() return false end
    Markers=Markers or {};Markers.refreshMarkerNodes=function() end
    t.resumeFieldworkAfterTurn=AITurn.resumeFieldworkAfterTurn
    p.driveDataFixture=function(_,dt)
        s.maxSpeed=math.huge
        return AIDriveStrategyFieldWorkCourse.getDriveData(s,dt,0,0,0)
    end
    p.afterHandoverFixture=function(_,state)
        f.handoverSteps=f.handoverSteps+(s.state~=s.states.WORKING and 1 or 0)
        local aligned,error,_,contact=EnvelopeTurnGeometry.assessLive(f.entryGeometry,f.vehicle)
        assert(aligned,'fieldwork lost entry alignment after handover: '..tostring(error))
        assert(s.resumed==1 and not f.vehicle.stopped)
        if s.state==s.states.WORKING then f.workedDistance=contact end
        return f.workedDistance>=8
    end
end

-- Synthetic 140 m wide, 1 km long parallelogram; no real map is required.
function narrowAngledDeploymentFixture(angle)
    local p=envelopeFixture(5.6,11.31,1.3,4.6,18.3,angle,angle>0 and 1 or -1,50.4)
    for _,m in ipairs(p.work) do m.x=m.x*.1 end
    local f=makeEnvelopeLiveFixture(p)
    addStockPloughFixture(f);f.turn.needsWorkingGeometry=true
    local edge=p.headland*math.sqrt(1+p.slope*p.slope)
    f.vehicle.cpGetFieldPolygon=function() return {
        {x=-70,z=-1000-70*p.slope},{x=70,z=-1000+70*p.slope},
        {x=70,z=edge+70*p.slope},{x=-70,z=edge-70*p.slope}} end
    p.tickFixture=function(current)
        if current.object.playing and g_currentMission.time>=current.object.animationEnd then
            current.object.animation=current.object.targetAnimation;current.object.playing=false
            for _,m in ipairs(p.work) do m.x=m.x/.1 end
        end
    end
    f.turn.ppc=PurePursuitController(f.vehicle)
    f.logs={}
    f.turn.log=function(_,format,...) f.logs[#f.logs+1]=string.format(format,...) end
    p.stateFixture=function() end
    return p,f
end
