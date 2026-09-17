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
                f.initialPlanningDuration=g_currentMission.time-t.planningStarted
                f.initialDeploymentOffset=t.geometry.deploymentOffset or 0
                return assert(t.result,table.concat(log,'\n'))
            end
        end
        error('deployment planning did not finish')
    end
    return p,f
end


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

-- v0.30 21:43:26 measured pose, folded footprint and detected field polygon.
-- The logged footprint is already in the implement direction frame, so this
-- replay scanner supplies that frame directly. Later deployment remains the
-- existing measured working-state proxy; terrain dynamics are still synthetic.
function configureV030Exit(p,f,field)
    configureV027Exit(p,f,field)
    p.start={x=-235.316,z=-26.241,t=math.rad(-.033),phi=math.rad(9.815)}
    p.goal={x=-240.912,z=-40.060,t=-math.pi}
    p.hitchX=.009;p.hitchZ=-1.633;p.length=11.259;p.axleOffsetX=.003
    p.work={{x=-.006,z=-2.799,towed=true},{x=.008,z=-1.663,towed=true},
        {x=-.006,z=-15.227,towed=true,rear=true},{x=.008,z=-15.227,towed=true,rear=true}}
    p.slope=math.tan(math.rad(-41.7));p.headland=44.7
    f.turn.entrySlope=p.slope;f.turn.headlandSeed=p.headland
    for _,node in ipairs({f.context.workStartNode,f.context.turnEndWpNode.node}) do
        node.x,node.z,node.t=p.goal.x,p.goal.z,p.goal.t
    end
    if not f.internalPivotFixture then
        addEnvelopeInternalPivotFixture(f,p,1.294)
        f.internalPivotFixture=true
    end
    f.object.componentJoints[1].rotLimit[2]=math.pi/2
    f.vehicle.size={length=4.95,width=2.8,lengthOffset=1.419}
    local originalScanner=VehicleSizeScanner
    VehicleSizeScanner=function()
        local scanner=originalScanner()
        scanner._measureDimension=function(self,object,reference,distance,ending,axis)
            self.scannedVehicleFound=true
            if axis=='x' then return distance>0 and 3.830 or -3.977 end
            return distance>0 and 11.166 or -5.311
        end
        return scanner
    end
    f:setPose(p.start)
end

-- v0.31 failed exit, with the actual CP settings from savegame18.
function configureV031Exit(p,f,field)
    configureV030Exit(p,f,field)
    p.start={x=-235.316,z=-26.295,t=math.rad(-.041),phi=math.rad(9.816)}
    p.headland=44.6;f.turn.headlandSeed=p.headland
    p.turnSpeed=20;p.fieldSpeed=27
    f:setPose(p.start)
end

-- v0.32 row 269 -> 270: logged folded and working geometry, 16 September.
-- The deployment heading change is reconstructed; dynamics remain synthetic.
function configureV032Exit(p,f,field)
    configureV030Exit(p,f,field)
    p.start={x=-274.518,z=-173.903,t=math.rad(179.882),phi=math.rad(170.776)}
    p.goal={x=-280.128,z=-156.450,t=0}
    p.hitchX=-.037;p.hitchZ=-1.672;p.length=11.305;p.axleOffsetX=-.103
    p.work={{x=.243,z=-2.598,towed=true},{x=-.100,z=-1.787,towed=true},
        {x=.243,z=-15.459,towed=true,rear=true},{x=-.100,z=-15.459,towed=true,rear=true}}
    p.slope=math.tan(math.rad(12.7));p.headland=46.6
    p.turnSpeed=20;p.fieldSpeed=27;p.steeringTimeConstant=.212397
    f.turn.entrySlope=p.slope;f.turn.headlandSeed=p.headland
    for _,node in ipairs({f.context.workStartNode,f.context.turnEndWpNode.node}) do
        node.x,node.z,node.t=p.goal.x,p.goal.z,p.goal.t
    end
    local folded=true
    local originalScanner=VehicleSizeScanner
    VehicleSizeScanner=function()
        local scanner=originalScanner()
        scanner._measureDimension=function(self,object,reference,distance,ending,axis)
            self.scannedVehicleFound=true
            if axis=='x' then return distance>0 and (folded and 3.956 or 5.203) or (folded and -3.937 or -7.158) end
            return distance>0 and (folded and 11.483 or 12.901) or (folded and -5.352 or -5.405)
        end
        return scanner
    end
    p.stateFixture=function(current,state)
        if current.object.playing and g_currentMission.time>=current.object.animationEnd then
            current.object.animation=current.object.targetAnimation;current.object.playing=false;folded=false
            p.work={{x=-3.256,z=-2.151,towed=true},{x=2.290,z=-2.469,towed=true},
                {x=-3.256,z=-16.132,towed=true,rear=true},{x=2.290,z=-16.132,towed=true,rear=true}}
            p.length=11.102;p.hitchX=.037;p.hitchZ=-1.653;p.axleOffsetX=.017
            state.phi=EnvelopeTurnPlanner.wrap(state.phi-math.rad(9.5))
        end
    end
    -- Seed the previously observed working-side state for this later-row replay.
    local saved={};for k,v in pairs(p) do saved[k]=v end
    local state={};for k,v in pairs(p.start) do state[k]=v end
    f.object.targetAnimation=0;f.object.playing=true;f.object.animationEnd=0;p.stateFixture(f,state)
    f:setPose(state)
    local model=EnvelopeTurnGeometry.turnModel(assert(EnvelopeTurnGeometry.capture(f.turn)))
    model.deploymentAngle=math.rad(-9.5);model.steeringResponseTime=.212397
    f.strategy.envelopeWorkingModels={[f.context:shouldPlowBeOnTheLeft() and 'left' or 'right']=model}
    for k,v in pairs(saved) do p[k]=v end
    folded=true;f.object.animation=.5
    f:setPose(p.start)
end

-- v0.33 second exit, 17 September 00:07:59. No working cache is supplied.
-- Dimensions and field are recorded; the hydraulic yaw change is reconstructed
-- from the last centred TRACK and subsequent working snapshot, not GIANTS physics.
function configureV033Exit(p,f,field)
    configureV030Exit(p,f,field)
    p.start={x=-240.913,z=-164.749,t=math.rad(179.893),phi=math.rad(170.635)}
    p.goal={x=-246.515,z=-147.870,t=0}
    p.hitchX=-.032;p.hitchZ=-1.674;p.length=11.306;p.axleOffsetX=-.086
    p.work={{x=.203,z=-2.588,towed=true},{x=-.082,z=-1.793,towed=true},
        {x=.203,z=-15.469,towed=true,rear=true},{x=-.082,z=-15.469,towed=true,rear=true}}
    p.slope=math.tan(math.rad(17.4));p.headland=46.4
    p.turnSpeed=20;p.fieldSpeed=27;p.steeringTimeConstant=.159405
    f.context.shouldPlowBeOnTheLeft=function() return false end
    f.turn.entrySlope=p.slope;f.turn.headlandSeed=p.headland
    for _,node in ipairs({f.context.workStartNode,f.context.turnEndWpNode.node}) do
        node.x,node.z,node.t=p.goal.x,p.goal.z,p.goal.t
    end
    VehicleSizeScanner=function()
        return {scan=function(_,object)
            if object==f.object then return 12.897,-5.407,5.213,-7.152 end
            return 3.894,-1.057,1.399,-1.399
        end,_measureDimension=function(self,object,reference,distance,ending,axis)
            self.scannedVehicleFound=true
            if axis=='x' then return distance>0 and 3.953 or -3.948 end
            return distance>0 and 11.491 or -5.353
        end}
    end
    p.stateFixture=function(current,state)
        if current.object.playing and g_currentMission.time>=current.object.animationEnd then
            current.object.animation=current.object.targetAnimation;current.object.playing=false
            p.work={{x=-3.260,z=-2.150,towed=true},{x=2.288,z=-2.468,towed=true},
                {x=-3.260,z=-16.128,towed=true,rear=true},{x=2.288,z=-16.128,towed=true,rear=true}}
            p.length=11.100;p.hitchX=.031;p.hitchZ=-1.651;p.axleOffsetX=.020
            state.phi=EnvelopeTurnPlanner.wrap(state.phi-math.rad(9.5))
        end
    end
    f:setPose(p.start)
end

-- v0.34 row 292 -> 293, 17 September 08:48:58. Recorded centred geometry
-- and the last measured right-side geometry; animation/tyre dynamics synthetic.
function configureV034Exit(p,f,field)
    configureV030Exit(p,f,field)
    p.start={x=-280.146,z=12.083,t=math.rad(.040),phi=math.rad(9.228)}
    p.goal={x=-285.728,z=-2.890,t=-math.pi}
    p.hitchX=.048;p.hitchZ=-1.634;p.length=11.255;p.axleOffsetX=.094
    p.work={{x=-.220,z=-2.809,towed=true},{x=.100,z=-1.657,towed=true},
        {x=-.220,z=-15.213,towed=true,rear=true},{x=.100,z=-15.213,towed=true,rear=true}}
    p.slope=math.tan(math.rad(-34.8));p.headland=43.4
    p.turnSpeed=20;p.fieldSpeed=27
    f.context.shouldPlowBeOnTheLeft=function() return false end
    f.turn.entrySlope=p.slope;f.turn.headlandSeed=p.headland
    for _,node in ipairs({f.context.workStartNode,f.context.turnEndWpNode.node}) do
        node.x,node.z,node.t=p.goal.x,p.goal.z,p.goal.t
    end
    VehicleSizeScanner=function()
        return {scan=function(_,object)
            if object==f.object then return 12.268,-5.620,5.917,-3.536 end
            return 3.894,-1.056,1.397,-1.397
        end,_measureDimension=function(self,object,reference,distance,ending,axis)
            self.scannedVehicleFound=true
            if axis=='x' then return distance>0 and 3.792 or -4.015 end
            return distance>0 and 11.150 or -5.302
        end}
    end
    p.stateFixture=function(current,state)
        if current.object.playing and g_currentMission.time>=current.object.animationEnd then
            current.object.animation=current.object.targetAnimation;current.object.playing=false
            p.work={{x=3.264,z=-2.174,towed=true},{x=-2.282,z=-2.472,towed=true},
                {x=3.264,z=-16.154,towed=true,rear=true},{x=-2.282,z=-16.154,towed=true,rear=true}}
            p.length=11.117;p.hitchX=-.039;p.hitchZ=-1.690;p.axleOffsetX=-.013
            state.phi=EnvelopeTurnPlanner.wrap(state.phi+math.rad(9.49))
        end
    end
    local saved={};for k,v in pairs(p) do saved[k]=v end
    local state={};for k,v in pairs(p.start) do state[k]=v end
    f.object.targetAnimation=0;f.object.playing=true;f.object.animationEnd=0;p.stateFixture(f,state)
    f:setPose(state)
    local model=EnvelopeTurnGeometry.turnModel(assert(EnvelopeTurnGeometry.capture(f.turn)))
    model.deploymentAngle=math.rad(9.49)
    f.strategy.envelopeWorkingModels={right=model}
    for k,v in pairs(saved) do p[k]=v end
    f.object.animation=.5
    f:setPose(p.start)
end

-- v0.35, 17 September 09:53:38: actual stopped pose AFTER stock turnover.
-- Replay this independently of the synthetic animation/arrival approximation.
function configureV035WorkingArrival(p,f,field)
    configureV034Exit(p,f,field)
    p.start={x=-286.501,z=5.772,t=math.rad(179.324),phi=math.rad(-168.941)}
    p.goal={x=-285.727,z=-2.890,t=-math.pi}
    p.hitchX=-.056;p.hitchZ=-1.690;p.length=11.116;p.axleOffsetX=-.005
    p.work={{x=3.252,z=-2.182,towed=true},{x=-2.285,z=-2.471,towed=true},
        {x=3.252,z=-16.152,towed=true,rear=true},{x=-2.285,z=-16.152,towed=true,rear=true}}
    for _,node in ipairs({f.context.workStartNode,f.context.turnEndWpNode.node}) do
        node.x,node.z,node.t=p.goal.x,p.goal.z,p.goal.t
    end
    VehicleSizeScanner=function() return {scan=function(_,object)
        if object==f.object then return 12.271,-5.611,5.923,-3.506 end
        return 3.890,-1.062,1.396,-1.396
    end} end
    p.stateFixture=nil;f.object.animation=0
    f.turn.needsWorkingGeometry=false
    f.turn.measuredSteeringResponse=.7039764115324976
    f:setPose(p.start)
    p.planFixture=function()
        local remaining={{x=p.start.x,z=p.start.z}}
        for d=-8,20,.5 do remaining[#remaining+1]=EnvelopeTurnPlanner.point(p.goal.x,p.goal.z,p.goal.t,0,d) end
        f.turn:startPlanning(remaining)
        for i=1,10000 do
            g_currentMission.time=g_currentMission.time+50;f.turn:updatePlanner()
            if not f.turn.planner then return assert(f.turn.result,table.concat(f.logs,'\n')) end
        end
        error('recorded working arrival did not finish planning')
    end
end

-- v0.36 stopped run: required working side has not been measured yet.
function configureV036Exit(p,f,field)
    configureV034Exit(p,f,field)
    f.strategy.envelopeWorkingModels=nil
    p.start={x=-280.206,z=12.038,t=math.rad(.105),phi=math.rad(8.546)}
    p.goal={x=-285.780,z=-2.890,t=-math.pi}
    p.hitchX=.048;p.hitchZ=-1.634;p.length=11.256;p.axleOffsetX=.095
    p.work={{x=-.223,z=-2.806,towed=true},{x=.101,z=-1.658,towed=true},
        {x=-.223,z=-15.216,towed=true,rear=true},{x=.101,z=-15.216,towed=true,rear=true}}
    for _,node in ipairs({f.context.workStartNode,f.context.turnEndWpNode.node}) do
        node.x,node.z,node.t=p.goal.x,p.goal.z,p.goal.t
    end
    f:setPose(p.start)
end

-- Independent snapshot replay. Earlier staging translates this measured
-- arrival upstream; it does not pretend the synthetic turn reproduces tyres
-- or hydraulic motion. The full turn must pass its own execution test too.
function configureV036WorkingArrival(p,f,field,leadDelta)
    configureV035WorkingArrival(p,f,field)
    p.start={x=-285.789,z=6.176+(leadDelta or 0),t=math.rad(179.283),phi=math.rad(-168.912)}
    p.goal={x=-285.780,z=-2.890,t=-math.pi}
    p.hitchZ=-1.689;p.length=11.115;p.axleOffsetX=-.006
    p.work[1].x=3.253;p.work[3].x=3.253
    f.turn.measuredSteeringResponse=.6083763711210152
    for _,node in ipairs({f.context.workStartNode,f.context.turnEndWpNode.node}) do
        node.x,node.z,node.t=p.goal.x,p.goal.z,p.goal.t
    end
    f:setPose(p.start)
end

-- v0.37 opposite-end exit. The geometry is recorded; the pre-centring
-- calibration is varied independently because its final live pose was not logged.
function configureV037Exit(p,f,field,angle)
    configureV032Exit(p,f,field)
    p.start={x=-285.719,z=-176.227,t=math.rad(179.905),phi=math.rad(170.806)}
    p.goal={x=-291.319,z=-158.600,t=0};p.slope=math.tan(math.rad(10.8));p.headland=46.8
    p.length=11.304;p.axleOffsetX=-.109
    p.work={{x=.257,z=-2.600,towed=true},{x=-.106,z=-1.786,towed=true},
        {x=.257,z=-15.457,towed=true,rear=true},{x=-.106,z=-15.457,towed=true,rear=true}}
    local model=f.strategy.envelopeWorkingModels.left or f.strategy.envelopeWorkingModels.right
    f.strategy.envelopeWorkingModels={left=model};model.deploymentAngle=math.rad(angle)
    f.context.shouldPlowBeOnTheLeft=function() return true end
    f.turn.entrySlope=p.slope;f.turn.headlandSeed=p.headland
    for _,node in ipairs({f.context.workStartNode,f.context.turnEndWpNode.node}) do
        node.x,node.z,node.t=p.goal.x,p.goal.z,p.goal.t
    end
    f:setPose(p.start)
end

function configureV037WorkingArrival(p,f,field,offset)
    configureV035WorkingArrival(p,f,field)
    f.object.animation=1;f.context.shouldPlowBeOnTheLeft=function() return true end
    p.start={x=-291.354+(offset or 0),z=-167.027,t=math.rad(.738),phi=math.rad(-11.372)}
    p.goal={x=-291.319,z=-158.600,t=0};p.slope=math.tan(math.rad(10.8));p.headland=46.8
    p.length=11.103;p.hitchX=.039;p.hitchZ=-1.652;p.axleOffsetX=.017
    p.work={{x=-3.256,z=-2.151,towed=true},{x=2.290,z=-2.469,towed=true},
        {x=-3.256,z=-16.132,towed=true,rear=true},{x=2.290,z=-16.132,towed=true,rear=true}}
    VehicleSizeScanner=function() return {scan=function(_,object)
        if object==f.object then return 12.902,-5.405,5.203,-7.158 end
        return 3.895,-1.058,1.398,-1.398
    end} end
    f.turn.entrySlope=p.slope;f.turn.headlandSeed=p.headland
    f.turn.measuredSteeringResponse=.19582105012941153
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
