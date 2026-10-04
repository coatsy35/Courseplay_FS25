-- Match the FS25 runtime: the standard Lua coroutine library is absent.
coroutine = nil
-- Whole-rig bays, ordered reservations and short manoeuvres with real articulated geometry.
MathUtil = {vector2Length = function(x, z) return math.sqrt(x*x + z*z) end}
function entityExists(node) return node ~= nil end
function getWorldTranslation(n) return n.x, 0, n.z end
function localDirectionToWorld(n, x, y, z)
    local h = n.heading or 0
    return math.cos(h)*x + math.sin(h)*z, y, -math.sin(h)*x + math.cos(h)*z
end
function localToWorld(n, x, y, z)
    local dx, dy, dz = localDirectionToWorld(n,x,y,z); return n.x+dx,dy,n.z+dz
end
function localToLocal(from,to,x,y,z)
    local wx,_,wz = localToWorld(from,x,y,z)
    local h,dx,dz = to.heading or 0,wx-to.x,wz-to.z
    return math.cos(h)*dx-math.sin(h)*dz,0,math.sin(h)*dx+math.cos(h)*dz
end
dofile('scripts/CpObject.lua')
CpUtil = {try=function(fn,...) return pcall(fn,...) end, createNode=function() return {} end}
dofile('scripts/ai/util/AIUtil.lua')
dofile('scripts/util/CpMathUtil.lua')
dofile('scripts/ai/util/FieldworkBoundary.lua')
dofile('scripts/ai/util/VehicleRouteConflict.lua')
AIUtil.getTurningRadius=function() return 10 end
local polygon={{x=-250,z=-250},{x=250,z=-250},{x=250,z=250},{x=-250,z=250}}
local function body(x,z,w,l,h)
    local v={rootNode={x=x,z=z,heading=h or 0},size={width=w,length=l},children={}}
    function v:getAIDirectionNode() return self.rootNode end
    function v:getChildVehicles() return self.children end
    function v:getRootVehicle() return self.parent and self.parent:getRootVehicle() or self end
    function v:getAttacherVehicle() return self.parent end
    function v:cpGetFieldPolygon() return polygon end
    return v
end
local function train(x,z)
    local v=body(x,z,3,6)
    local t=body(x,z-8,3,9)
    t.parent,t.spec_wheels=v,{}
    t.getActiveInputAttacherJoint=function() return {node={x=x,z=z-4,heading=0}} end
    v.children={t}
    return v
end
local function course(vehicle,points)
    local c={points=points}
    function c:getNumberOfWaypoints() return #self.points end
    function c:getWaypointPosition(ix) local p=self.points[ix]; return p.x,0,p.z end
    function c:isReverseAt(ix) return self.points[ix].rev or false end
    function c:adjustForReversing() end
    function c:getNextWaypointIxWithinDistance(ix,distance)
        local d=0
        for i=ix+1,#points do
            d=d+MathUtil.vector2Length(points[i].x-points[i-1].x,points[i].z-points[i-1].z)
            if d>=distance then return i end
        end
    end
    function c:copy(_,first,last)
        local p={}; for i=first or 1,last or #points do p[#p+1]=points[i] end; return course(vehicle,p)
    end
    return c
end
Course=course
Waypoint=function(p) p.getIsReverse=function(self) return self.rev or false end; return p end
local crop, wall
local shapeProbes=0
PathfinderUtil={
    hasFruit=function(x,z,l,w)
        return crop and math.abs(x-crop.x)<w/2+crop.w/2 and math.abs(z-crop.z)<l/2+crop.l/2 or false
    end,
    setWorldPositionAndRotationOnTerrain=function(n,x,z,h,yOffset)
        assert(type(yOffset)=='number','Parking shape probes must supply the terrain height offset')
        n.x,n.z,n.heading=x,z,h
    end,
}
PathfinderCollisionDetector=function()
    return {findCollidingShapes=function(_,n,_,box)
        shapeProbes=shapeProbes+1
        if not wall then return 0 end
        local rig={{x=n.x,z=n.z,heading=n.heading,box=box}}
        local sweep=VehicleRouteConflict.createSweep(rig,course(nil,{{x=n.x,z=n.z}}),1)
        return VehicleRouteConflict.findConflict(sweep,FieldworkBoundary.captureRig(wall)) and 1 or 0
    end}
end
g_currentMission={time=1000,vehicleSystem={vehicles={}}}
dofile('scripts/ai/util/UnloaderParkingPlanner.lua')
local P=UnloaderParkingPlanner
local v=train(0,-100)
local h=body(0,100,4,8)
local headland=false
local hDriver={getWorkWidth=function() return 15 end,
    getFieldworkCourse=function() return {isOnHeadland=function() return headland end} end}
h.getCpDriveStrategy=function() return hDriver end
local states={WAITING_IN_STANDBY='wait',DRIVING_TO_STANDBY='drive',WAITING_FOR_STANDBY_PATHFINDER='search'}
local driver={vehicle=v,states=states,state='wait',turningRadius=10,
    isInStandbyState=function() return true end}
local function assignment(x,z) return {harvester=h,waypoint={x=x,z=z,angle=0},waypointIx=10,role='STANDBY',reserved=true} end
g_currentMission.vehicleSystem.vehicles={v,h}
local boundary=P.getBoundary(v)
local aligned=P.alignedRig(v,20,30,math.pi/2)
assert(math.abs(aligned[2].x-12)<0.001 and math.abs(aligned[2].z-30)<0.001 and
    math.abs(aligned[2].heading-math.pi/2)<0.001,'An aligned bay must place the trailer from its hitch, not its old world position')
local bay=P.makeBay(v,{x=0,z=0},0,boundary,'ROW')
assert(bay.length>15 and bay.length<17 and bay.runIn.z < -15,'Measure physical train length without double-counting AI attachments')
local plan=P.newPlan({})
assert(P.bayClear(plan,v,bay),'An empty harvested bay with an arrival and departure lane must be usable')
crop={x=0,z=-10,w=1,l=1}
assert(not P.bayClear(plan,v,bay),'Standing crop under the trailer rear must reject a clear tractor-centre target')
crop=nil
wall=body(0,11,0.1,0.1)
assert(not P.bayClear(plan,v,bay),'A non-vehicle shape in the forward exit must reject a reachable parking bay')
wall=nil
local narrow=P.makeBay(v,{x=245,z=0},math.pi/2,boundary,'ROW')
assert(not P.bayClear(plan,v,narrow),'A trailer/run-in crossing the field edge must reject the entire bay')

local a=assignment(0,0)
P.allocate(plan,driver,a)
assert(a.parkingBay and a.waypoint==a.parkingBay.waypoint,'Lead assignment must publish an oriented bay')
local rear=train(80,-100)
local rearDriver={vehicle=rear,states=states,state='wait',turningRadius=10,isInStandbyState=function() return true end}
g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles+1]=rear
local b=assignment(0,0); b.role,b.reserved='POOL',false
P.allocate(plan,rearDriver,b)
assert(b.parkingBay and (b.waypoint.x~=a.waypoint.x or b.waypoint.z~=a.waypoint.z),
    'A following trailer must not claim the lead bay or its reserved run-in/exit lane')
for _,sample in ipairs(b.parkingBay.corridor) do
    local bodies={}
    for _,box in ipairs(sample.parts) do bodies[#bodies+1]={x=box.x,z=box.z,heading=box.heading,
        box={width=box.width,length=box.length,xOffset=0,zOffset=0}} end
    assert(not VehicleRouteConflict.findConflict(a.parkingBay.corridor,bodies),'Queue bays must reserve disjoint whole-rig manoeuvring space')
end

local old={waypoint=a.waypoint,parkingBay=a.parkingBay,harvester=h,role='STANDBY'}
local retained=assignment(a.waypoint.x,a.waypoint.z); retained.waypoint=old.waypoint
P.allocate(P.newPlan({}),driver,retained,old)
assert(retained.parkingBay==old.parkingBay,'A safe stabilised bay must retain its orientation and target')
driver.state='drive'
local inflight=assignment(150,0)
P.allocate(P.newPlan({[driver]=old}),driver,inflight,old)
assert(inflight.waypoint==old.waypoint and inflight.parkingBay==old.parkingBay,'A new prediction must not cancel a checked parking approach')
driver.state='wait'
local access=assignment(0,0); access.waitUntilHarvesterPasses=true
P.allocate(P.newPlan({}),driver,access)
assert(not access.parkingBay and access.waypoint.x==0,'A protected AD access-point hold must not be moved into a bay')

headland=true
local outer=assignment(0,0)
P.allocate(P.newPlan({}),driver,outer)
assert(outer.parkingBay and outer.parkingBay.kind=='HEADLAND' and math.abs(outer.waypoint.x)>9,
    'A harvested outer headland must prefer a parallel side bay over the working centreline')
headland=false
local actual=P.alignedRig(v,0,0,0)
v.rootNode.x,v.rootNode.z=actual[1].x,actual[1].z
v.children[1].rootNode.x,v.children[1].rootNode.z=actual[2].x,actual[2].z
assert(P.hasArrived(driver,bay),'A straight whole-rig arrival must be recognised')
v.rootNode.x,v.children[1].rootNode.x=1.5,1.5
wall=body(3,0,0.1,0.1)
assert(P.bayClear(plan,v,bay) and not P.hasArrived(driver,bay),
    'A displaced but nominally arrived rig must be checked against actual world shapes before parking')
wall=nil
v.rootNode.x,v.children[1].rootNode.x=0,0
v.children[1].rootNode.heading=math.rad(30)
assert(not P.hasArrived(driver,bay),'A tractor at the target with a skewed trailer must not count as parked')
v.children[1].rootNode.heading=0

-- A newly allocated lead must not claim the short exit reserved by an already parked trailer.
local parkedBayPlan=P.newPlan({[driver]={harvester=h,role='STANDBY',parkingBay=bay,waypoint=bay.waypoint}})
local exitOverlap=P.makeBay(rear,{x=0,z=35},0,boundary,'ROW')
assert(P.bayClear(P.newPlan({}),rear,exitOverlap) and not P.bayClear(parkedBayPlan,rear,exitOverlap),
    'A currently empty exit lane must stay reserved for its parked owner during fleet reallocation')

-- Future combine travel is reserved before a waiting rig reaches it.
local incoming=body(0,40,4,8,math.pi)
local incomingCourse=course(incoming,{{x=0,z=40},{x=0,z=-40}})
incoming.getCpDriveStrategy=function() return {callUnloader=true,turningRadius=10,
    ppc={getCourse=function() return incomingCourse end,getRelevantWaypointIx=function() return 1 end}} end
g_currentMission.vehicleSystem.vehicles={v,incoming}
assert(not P.bayClear(P.newPlan({}),v,bay),'An imminent combine crossing must invalidate an otherwise empty waiting bay')
g_currentMission.vehicleSystem.vehicles={v}
UnloaderCoordinator={assignments={}}
local path=course(v,{{x=0,z=0},{x=0,z=20}})
crop={x=0,z=14,w=1,l=1}
assert(not P.validateCourse(driver,path,P.newPlan({}),boundary),'A short manoeuvre must check crop swept by the whole train')
crop=nil
wall=body(0,10,1,1)
assert(not P.validateCourse(driver,path,P.newPlan({}),boundary),'A short manoeuvre must retain physical shape collision checks')
wall=nil
assert(P.validateCourse(driver,path,P.newPlan({}),boundary),'A clear straight departure must pass the same whole-rig checks')
assert(shapeProbes>0,'The fixture must exercise the world-shape adapter')


-- Production density queries use oriented rectangles, not the enclosing axis-aligned box.
local densityProbes=0
FruitType={POTATO=2,GRASS=3,MEADOW=4}
g_fruitTypeManager={fruitTypes={{index=1},{index=2},{index=3},{index=4}}}
FSDensityMapUtil={getFruitArea=function(_,ax,az,bx,bz,cx,cz)
    densityProbes=densityProbes+1
    if not crop then return 0 end
    local w,l=MathUtil.vector2Length(bx-ax,bz-az),MathUtil.vector2Length(cx-ax,cz-az)
    local rig={{x=(bx+cx)/2,z=(bz+cz)/2,heading=math.atan2(cx-ax,cz-az),
        box={width=w/2,length=l/2,xOffset=0,zOffset=0}}}
    local sweep=VehicleRouteConflict.createSweep(rig,course(nil,{{x=rig[1].x,z=rig[1].z}}),1)
    return VehicleRouteConflict.findConflict(sweep,FieldworkBoundary.captureRig(body(crop.x,crop.z,crop.w,crop.l))) and 1 or 0
end}
local diagonal=P.alignedRig(v,0,0,math.pi/4)
crop={x=3,z=-3,w=0.1,l=0.1}
assert(not P.rigHasFruit(diagonal),'Crop outside a diagonal rig must not be mistaken for occupied body space')
crop={x=0,z=0,w=0.1,l=0.1}
assert(P.rigHasFruit(diagonal),'Native density queries must reject crop inside the oriented tractor body')
crop=nil
local before=densityProbes
assert(P.bayClear(P.newPlan({}),v,bay))
assert(densityProbes-before==2,'A straight two-body bay must query its swept union once per body')

incoming.getCpDriveStrategy=function() return {getCombineToUnload=function() return h end,turningRadius=10,
    ppc={getCourse=function() return incomingCourse end,getRelevantWaypointIx=function() return 1 end}} end
g_currentMission.vehicleSystem.vehicles={v,incoming}
assert(not P.bayClear(P.newPlan({}),v,bay),'Active unloading traffic must reserve its imminent route too')
g_currentMission.vehicleSystem.vehicles={v}

-- Paused physical clearance must be included before the new parking plan is allocated.
driver.isConnectorClearancePending=function() return true end
driver.standbyTargetX,driver.standbyTargetZ,driver.standbyTargetHeading=80,0,math.pi/2
local clearingPlan=P.newPlan({[driver]=old})
assert(#clearingPlan.reservations==2 and clearingPlan.reservations[2].bay.waypoint.x==80,
    'A paused clearance must reserve both its retained bay and outstanding escape destination')
driver.isConnectorClearancePending=nil

-- Root and AI nodes can differ: repeated current-position holds must not walk the tractor forwards.
dofile('scripts/ai/UnloaderCoordinator.lua')
local offset=train(0,-80)
offset.aiNode={x=0,z=-78,heading=0}
offset.getAIDirectionNode=function(self) return self.aiNode end
local offsetDriver={vehicle=offset,states=states,state='wait',turningRadius=10,isInStandbyState=function() return true end}
local point=UnloaderCoordinator:getWaypointAtUnloader(offsetDriver)
assert(point.z==-78,'A present-position hold must use the same reference as parking geometry and steering')
local held=assignment(point.x,point.z); held.waypoint=point; held.waypointIx=nil; held.role='POOL'
g_currentMission.vehicleSystem.vehicles={offset}
P.allocate(P.newPlan({}),offsetDriver,held)
assert(held.parkingBay and P.hasArrived(offsetDriver,held.parkingBay))
for i=1,5 do
    local refreshed=assignment(point.x,point.z); refreshed.waypoint=UnloaderCoordinator:getWaypointAtUnloader(offsetDriver)
    refreshed.waypointIx=nil; refreshed.role='POOL'
    P.allocate(P.newPlan({}),offsetDriver,refreshed,held)
    assert(refreshed.parkingBay==held.parkingBay and refreshed.waypoint==held.parkingBay.waypoint,
        'Fresh table identity must not move a safely aligned parked trailer')
    held=refreshed
end

-- Exercise actual Dubins generation and pathfinder context with production strategy dispatch.
dofile('scripts/geometry/Vector.lua')
dofile('scripts/pathfinder/AnalyticSolution.lua')
dofile('scripts/pathfinder/State3D.lua')
dofile('scripts/pathfinder/Dubins.lua')
Logger=setmetatable({level={debug=1}},{__call=function() return {debug=function() end} end})
CpDebug={DBG_PATHFINDER=1,DBG_UNLOAD_COMBINE=1}
ReedsSheppSolver=function() return {} end
local engineAdapter=PathfinderUtil
dofile('scripts/pathfinder/PathfinderUtil.lua')
PathfinderUtil.hasFruit=engineAdapter.hasFruit
-- Keep the real terrain transform helper; adapt only the native terrain/node APIs.
MathUtil.getYRotationFromDirection=function(x,z) return math.atan2(x,z) end
function getTerrainNormalAtWorldPos() return 0,1,0 end
function getTerrainHeightAtWorldPos() return 35 end
function setTranslation(n,x,y,z) n.x,n.y,n.z=x,y,z end
function setRotation(n,x,y,z) n.rx,n.heading,n.rz=x,y,z end
function localRotationToWorld(n,x,y,z) return n.rx+x,n.heading+y,n.rz+z end
local terrainProbe={}
PathfinderUtil.setWorldPositionAndRotationOnTerrain(terrainProbe,12,24,math.pi/2,2)
assert(terrainProbe.y==37 and terrainProbe.heading==math.pi/2,
    'The production terrain transform must preserve a supplied height offset and heading')
AIUtil.getDirectionNode=function(vehicle) return vehicle:getAIDirectionNode() end
AIUtil.getDirectionNodeToReverserNodeOffset=function() return 0 end
HybridAStar={defaultMaxIterations=10000}
CollisionFlag={TERRAIN_DELTA=1}
CpUtil.getDefaultCollisionFlags=function() return 2 end
CpUtil.getName=function() return 'test vehicle' end
CpFieldUtil={getFieldNumUnderVehicle=function() return 1 end}
dofile('scripts/pathfinder/PathfinderContext.lua')
dofile('scripts/ai/strategies/AIDriveStrategyUnloadCombine.lua')
CpUtil.isStateOneOf=function(state,list) for _,s in pairs(list) do if s==state then return true end end; return false end
v=train(0,0)
driver=setmetatable({vehicle=v,states=states,state='wait',turningRadius=10,debug=function() end,
    setNewState=function(self,state) self.state=state end,setMaxSpeed=function() end,
    startCourse=function(self,c) self.course=c end, getOffFieldPenalty=function() return 7.5 end,
    getNearbyDepartingUnloader=function() end,getNearbyManoeuvringHarvester=function() end,
    getNearbyStagingDeparture=function() end,isAvailableForStaging=function() return true end,
    settings={avoidFruit={getValue=function() return true end}}},
    {__index=AIDriveStrategyUnloadCombine})
local searched,searchContext,searchGoal=0
PathfinderUtil.getMaxIterationsForFieldPolygon=function() return 10000 end
driver.pathfinderController={cancel=function() end,registerListeners=function() end,
    findPathToGoal=function(_,context,goal) searched=searched+1; searchContext,searchGoal=context,goal end}
hDriver.getAreaToAvoid=function() end
g_currentMission.vehicleSystem.vehicles={v}
local straightBay=P.makeBay(v,{x=0,z=40},0,boundary,'ROW')
local lateralBay=P.makeBay(v,{x=25,z=40},0,boundary,'ROW')
local turnBay=P.makeBay(v,{x=30,z=-10},math.pi,boundary,'ROW')
for _,target in ipairs({straightBay,lateralBay,turnBay}) do
    local c=P.simpleApproach(driver,target)
    assert(c,'Clear forward, cross-row and U-turn approaches must use the checked analytic route')
    local tx,_,tz=c:getWaypointPosition(c:getNumberOfWaypoints())
    assert(MathUtil.vector2Length(tx-target.waypoint.x,tz-target.waypoint.z)<0.01,
        'A short approach must finish at the aligned parking target')
end
local wanted={harvester=h,role='STANDBY',waypoint=straightBay.waypoint,parkingBay=straightBay}
driver.standbyAssignment=wanted
driver:startPathfindingToStandby(h,wanted.waypoint)
assert(searched==0 and driver.state=='drive' and driver.course,'A clear short approach must drive without a grid search')
wall=body(0,20,1,1)
driver:startPathfindingToStandby(h,wanted.waypoint)
assert(searched==1 and driver.state=='search' and searchContext._mustBeAccurate and
    searchContext._protectRigBoundary and searchContext._avoidStandingCrop and searchContext._maxFruitPercent==0 and
    #searchContext._vehiclesToIgnore==0 and
    math.abs(searchGoal.y+straightBay.runIn.z)<0.01,
    'A blocked short approach must use the unchanged search with an accurate run-in and no ignored combine')
local result=course(v,{{x=0,z=0},{x=0,z=straightBay.runIn.z}})
assert(not driver:onPathfindingDoneToStandby(driver.pathfinderController,true,result),
    'A searched approach must be rejected if an obstacle entered its route or alignment lane')
assert(driver.state=='wait' and driver.parkingBayFailed==straightBay)
wall=nil
driver.parkingBayFailed=nil
driver.state='search'; driver.parkingApproachBay=straightBay
assert(driver:onPathfindingDoneToStandby(driver.pathfinderController,true,result) and driver.state=='drive',
    'A clear searched approach must add and validate the alignment before driving')
v.rootNode.z=40; v.children[1].rootNode.z=32; v.children[1].rootNode.heading=math.rad(30)
driver:onLastWaypointPassed()
assert(driver.state=='wait' and driver.parkingBayFailed==straightBay and UnloaderCoordinator.nextRebalanceAt==0,
    'The strategy must request another bay if the tractor arrives with its trailer skewed')
v.children[1].rootNode.heading=0
driver.state='drive'; driver:onLastWaypointPassed()
assert(not driver.parkingBayFailed and driver:hasReachedStandbyPosition(),
    'An aligned whole-rig arrival must park and remain eligible for a real unload call')

-- Promotion from pool to lead preserves a checked approach to the same bay.
v.rootNode.z=0; v.children[1].rootNode.z=-8
driver.standbyAssignment={harvester=h,role='POOL',waypoint=straightBay.waypoint,parkingBay=straightBay}
driver.state='drive'
local beforeSearch=searched
driver:setStandbyAssignment(wanted)
assert(driver.state=='drive' and searched==beforeSearch,
    'Promoting an en-route pool trailer must not cancel and restart its already checked parking manoeuvre')
driver.state='search'; driver.parkingApproachBay=straightBay
driver:onPathfindingDoneToStandby(driver.pathfinderController,false,nil,true)
assert(driver.parkingBayFailed==straightBay and UnloaderCoordinator.nextRebalanceAt==0,
    'An unsuccessful ordinary bay search must request a different bay rather than retrying the same inaccessible pose')
local alternative={harvester=h,role='STANDBY',waypoint=straightBay.waypoint,waypointIx=10}
P.allocate(P.newPlan({}),driver,alternative,wanted)
assert(alternative.parkingBay and alternative.parkingBay~=straightBay and
    MathUtil.vector2Length(alternative.waypoint.x-straightBay.waypoint.x,
        alternative.waypoint.z-straightBay.waypoint.z)>4,
    'A rejected bay must be excluded when the coordinator chooses the next safe waiting position')
driver.parkingBayFailed=nil

-- Execute the actual incremental strategy path, including shared frame budget, interruption and
-- fresh physical occupancy at handover. Native probes have deterministic simulated elapsed costs.
local clock = 0
function openIntervalTimer() return clock end
function readIntervalTimerMs(timer) return clock - timer end
function closeIntervalTimer() end
local detectorFactory = PathfinderCollisionDetector
PathfinderCollisionDetector = function(...)
    local detector = detectorFactory(...)
    local probe = detector.findCollidingShapes
    detector.findCollidingShapes = function(...)
        clock = clock + 1.1
        return probe(...)
    end
    return detector
end
local function frame()
    g_updateLoopIndex = (g_updateLoopIndex or 100) + 1
    local before = clock
    driver:continueParkingWork()
    assert(clock - before <= P.frameBudgetMs + 1.11,
        'Parking validation may finish one native probe, but must yield before exceeding the shared frame allowance again')
end
v.rootNode.x,v.rootNode.z=0,0; v.children[1].rootNode.x,v.children[1].rootNode.z=0,-8
v.children[1].rootNode.heading=0
wall=nil; driver.course=nil; driver.state='wait'; driver.standbyAssignment=wanted
UnloaderCoordinator.assignments={}
g_currentMission.vehicleSystem.vehicles={v}
g_updateLoopIndex=100
local searchesBefore=searched
driver:startPathfindingToStandby(h,wanted.waypoint)
assert(driver.parkingWork and driver.state=='search' and not driver.course,
    'An incremental parking check must keep the rig stopped, without starting a route or redundant grid search')
local frames=0
while driver.parkingWork do frame(); frames=frames+1; assert(frames<2000) end
assert(frames>1 and driver.state=='drive' and driver.course and searched==searchesBefore,
    'A clear short route must finish its incremental checks and start automatically')

-- Two jobs cannot each claim the frame allowance.
g_updateLoopIndex=g_updateLoopIndex+1
local function work()
    local index = 0
    return {step = function()
        index = index + 1
        if index > 10 then return true, true end
        clock = clock + 1
        return false
    end}
end
local first,second=P.createJob(work()),P.createJob(work())
assert(not P.resumeJob(first))
local spent=clock
assert(not P.resumeJob(second) and clock==spent,'Other trailers must share the already consumed frame budget')

-- A real call/changed bay must discard paused work without executing the old handover.
driver.state='search'; driver.course=nil
driver:startParkingWork(straightBay,work(),function() error('An interrupted parking job must never drive') end)
driver.state='active'; driver.combineToUnload=h
frame()
assert(not driver.parkingWork and not driver.course,'An active call must interrupt parking validation immediately')
driver.combineToUnload=nil

-- Occupancy can change after the first section was checked. The departure is rechecked at handover.
driver.state='search'; driver.parkingApproachBay=straightBay; driver.standbyAssignment=wanted
g_updateLoopIndex=g_updateLoopIndex+1
driver:onPathfindingDoneToStandby(driver.pathfinderController,true,result)
assert(driver.parkingWork and driver.state=='search')
wall=body(0,0,0.1,0.1)
frames=0
while driver.parkingWork do frame(); frames=frames+1; assert(frames<2000) end
assert(driver.state=='wait' and not driver.course and driver.parkingBayFailed==straightBay,
    'An obstacle entering an already checked departure must reject the paused result before driving')
wall=nil; driver.parkingBayFailed=nil
-- A vehicle entering the middle can be outside both the departure and the bay's reserved lane.
driver.state='search'; driver.course=nil; driver.parkingApproachBay=straightBay
g_updateLoopIndex=g_updateLoopIndex+1
driver:onPathfindingDoneToStandby(driver.pathfinderController,true,result)
assert(driver.parkingWork)
local middle=body(0,10,1,1)
g_currentMission.vehicleSystem.vehicles={v,middle}
frames=0
while driver.parkingWork do frame(); frames=frames+1; assert(frames<2000) end
assert(driver.state=='wait' and not driver.course and driver.parkingBayFailed==straightBay,
    'Fresh departure/bay checks are insufficient: an occupied intermediate section must also reject handover')
g_currentMission.vehicleSystem.vehicles={v}
wall=nil; driver.parkingBayFailed=nil
g_updateLoopIndex=nil
PathfinderCollisionDetector=detectorFactory
print('Incremental parking: shared frame allowance, interrupted calls and live departure rejection OK')

-- A curved forecast mutates its rollout rig, never the separately captured live obstacle.
do
    local actor = train(100, -80)
    local route = course(actor, {{x=100,z=-80},{x=100,z=-50},{x=140,z=-20}})
    local actorDriver = {callUnloader=true,turningRadius=10,
        ppc={getCourse=function() return route end,getRelevantWaypointIx=function() return 1 end}}
    actor.getCpDriveStrategy=function() return actorDriver end
    g_currentMission.vehicleSystem.vehicles={actor}
    local captured = FieldworkBoundary.captureRig(actor)
    local plan = P.newPlan({})
    assert(#plan.traffic == 1 and #plan.traffic[1].sweep > 1, 'The fixture must use sampled curved traffic')
    for i, part in ipairs(plan.obstacles[1].rig) do
        assert(part.x == captured[i].x and part.z == captured[i].z and part.heading == captured[i].heading,
            'Forecast rollout must not move the physical current-obstacle snapshot to its future endpoint')
    end
    g_currentMission.vehicleSystem.vehicles={v}
end
print('Curved traffic forecast and current physical snapshot isolation: OK')

-- Field entry accepts an AD handover outside only while the entire rig approaches the field monotonically.
v.rootNode.x,v.rootNode.z=0,-260; v.children[1].rootNode.x,v.children[1].rootNode.z=0,-268
local entry=course(v,{{x=0,z=-260},{x=0,z=-200}})
assert(P.validateCourse(driver,entry,P.newPlan({}),boundary),'A clear AD entry must not be rejected merely for starting outside')
local leave=course(v,{{x=0,z=-260},{x=0,z=-280},{x=0,z=-200}})
assert(not P.validateCourse(driver,leave,P.newPlan({}),boundary),'An outside entry must not first move further from the field')

-- Fleet planning integrates ordered whole-rig allocations before any driver sees the published plan.
local fleet={train(-80,-100),train(0,-100),train(80,-100)}
local fleetDrivers={}
local otherHarvester=body(130,160,4,8)
otherHarvester.getCpDriveStrategy=function() return hDriver end
local observations=0
for i,vehicle in ipairs(fleet) do
    fleetDrivers[i]={vehicle=vehicle,states=states,state='wait',turningRadius=10,
        isInStandbyState=function() return true end,
        setStandbyAssignment=function(self,a)
            observations=observations+1
            assert(a.parkingBay and UnloaderCoordinator.assignments[self]==a,
                'The complete fleet parking plan must be published before driver notification')
            self.assigned=a
        end}
end
g_currentMission.vehicleSystem.vehicles={fleet[1],fleet[2],fleet[3],h,otherHarvester}
UnloaderCoordinator.assignments={}
UnloaderCoordinator.getAvailableUnloaders=function() return {fleetDrivers[1],fleetDrivers[2],fleetDrivers[3]} end
UnloaderCoordinator.getDemands=function() return {{harvester=h,x=0},{harvester=otherHarvester,x=130}} end
UnloaderCoordinator.selectReservedUnloaderIndex=function() return 1 end
UnloaderCoordinator.createReservedAssignment=function(_,_,d)
    return {harvester=d.harvester,role='STANDBY',reserved=true,secondsUntilNeeded=50,
        waypoint={x=d.x,z=50,angle=0},waypointIx=10}
end
UnloaderCoordinator.createPoolAssignment=function()
    return {harvester=h,role='POOL',reserved=false,secondsUntilNeeded=100,
        waypoint={x=0,z=50,angle=0},waypointIx=10}
end
UnloaderCoordinator:rebalance(true)
assert(observations==3 and fleetDrivers[1].assigned.parkingBay and fleetDrivers[2].assigned.parkingBay,
    'Independent combine clusters must each obtain a lead bay while the successor remains in its pool')
local leadBay,poolBay=fleetDrivers[1].assigned.parkingBay,fleetDrivers[3].assigned.parkingBay
assert(not VehicleRouteConflict.findConflict(leadBay.corridor,poolBay.laneRig),
    'Fleet integration must allocate the lead before its pool and prevent overlapping reserved lanes')
-- A paused fleet allocation keeps the old published reservations, and publishes the complete
-- replacement before any driver notification. A real release invalidates unfinished fleet work.
local oldMap=UnloaderCoordinator.assignments
local oldBudget=P.frameStepBudget
P.frameStepBudget=1; g_updateLoopIndex=10000
local countBefore=observations
UnloaderCoordinator:rebalance(true)
assert(UnloaderCoordinator.parkingPlanJob and UnloaderCoordinator.assignments==oldMap and observations==countBefore)
local ticks=0
while UnloaderCoordinator.parkingPlanJob do
    g_updateLoopIndex=g_updateLoopIndex+1
    UnloaderCoordinator:continueParkingPlan(); ticks=ticks+1; assert(ticks<2000)
    if UnloaderCoordinator.parkingPlanJob then
        assert(UnloaderCoordinator.assignments==oldMap and observations==countBefore,
            'A partly checked fleet plan must never be published or sent to individual drivers')
    end
end
assert(observations==countBefore+3 and UnloaderCoordinator.assignments~=oldMap)
g_updateLoopIndex=g_updateLoopIndex+1
UnloaderCoordinator:rebalance(true)
assert(UnloaderCoordinator.parkingPlanJob)
UnloaderCoordinator:release(fleetDrivers[1])
g_updateLoopIndex=g_updateLoopIndex+1
UnloaderCoordinator:continueParkingPlan()
assert(not UnloaderCoordinator.parkingPlanJob and not UnloaderCoordinator.assignments[fleetDrivers[1]],
    'An active-call release must invalidate a paused fleet plan instead of restoring the released reservation')
P.frameStepBudget=oldBudget; g_updateLoopIndex=nil
print('Incremental fleet allocation: atomic publication and active-call invalidation OK')

-- The physical train clears the edge by 0.25 m. A fixed half-metre step's symmetric
-- collision padding protrudes sideways even though this parallel movement is contained.
crop, wall = nil, nil
local edgeVehicle = train(0, 0)
local edgeWidth = FieldworkBoundary.captureRig(edgeVehicle)[1].box.width
local edgeX = edgeWidth + 0.25
edgeVehicle.rootNode.x, edgeVehicle.children[1].rootNode.x = edgeX, edgeX
g_currentMission.vehicleSystem.vehicles = {edgeVehicle}
local edgeBoundary = {polygon={{x=0,z=-100},{x=100,z=-100},{x=100,z=100},{x=0,z=100}}, islands={}, margin=0}
local edgeDriver = {vehicle=edgeVehicle, turningRadius=10}
local parallel = course(edgeVehicle, {{x=edgeX,z=0},{x=edgeX,z=4}})
assert(FieldworkBoundary.rigOutsideDistance(edgeBoundary,FieldworkBoundary.captureRig(edgeVehicle))==0)
assert(P.validateCourse(edgeDriver,parallel,P.newPlan({}),edgeBoundary),
    'A contained edge-parallel departure must refine conservative sweep steps instead of rejecting padding')
local reversing = course(edgeVehicle, {{x=edgeX,z=0},{x=edgeX,z=-4,rev=true}})
assert(P.validateCourse(edgeDriver,reversing,P.newPlan({}),edgeBoundary),
    'Reverse clearance must retain its actual body headings when a trial is refined')
crop = {x=edgeX,z=4,w=0.1,l=0.1}
assert(not P.validateCourse(edgeDriver,parallel,P.newPlan({}),edgeBoundary),
    'A refined boundary interval must still reject standing crop')
crop, wall = nil, body(edgeX,4,0.2,0.2)
assert(not P.validateCourse(edgeDriver,parallel,P.newPlan({}),edgeBoundary),
    'A refined boundary interval must still reject native physical shapes')
wall = nil
g_currentMission.vehicleSystem.vehicles = {edgeVehicle,body(edgeX,4,0.2,0.2)}
assert(not P.validateCourse(edgeDriver,parallel,P.newPlan({}),edgeBoundary),
    'A refined departure must retain other vehicles in its occupancy checks')
g_currentMission.vehicleSystem.vehicles = {edgeVehicle}
local refinedJob = P.validateCourseJob(edgeDriver,parallel,P.newPlan({}),edgeBoundary)
local savedBudget, complete, checked, frames = P.frameStepBudget, false, nil, 0
P.frameStepBudget = 2
while not complete do
    frames = frames + 1
    assert(frames < 1000, 'A refined route must finish in bounded work')
    g_updateLoopIndex = 20000 + frames
    complete, checked = P.resumeJob(refinedJob)
    assert(P.frameSteps <= 2, 'Refinement must share the existing per-frame job allowance')
end
assert(checked and frames > 1, 'Refinement must resume safely across multiple frames')
P.frameStepBudget, g_updateLoopIndex = savedBudget, nil
local across = course(edgeVehicle, {{x=edgeX,z=0},{x=-2,z=4}})
assert(not P.validateCourse(edgeDriver,across,P.newPlan({}),edgeBoundary),
    'Refining a swept envelope must never permit the actual tractor or trailer to cross the field edge')
edgeBoundary.travelBoundary = {polygon={{x=0,z=-100},{x=2*edgeX,z=-100},
    {x=2*edgeX,z=100},{x=0,z=100}},islands={},margin=0}
assert(P.validateCourse(edgeDriver,parallel,P.newPlan({}),edgeBoundary),
    'The same conservative refinement must retain a narrow harvested travel corridor')
edgeBoundary.travelBoundary = nil
edgeBoundary.exitGate = {polygon={{x=0,z=80},{x=2*edgeX,z=80},
    {x=2*edgeX,z=140},{x=0,z=140}},islands={},margin=0}
edgeVehicle.rootNode.z,edgeVehicle.children[1].rootNode.z = 110,102
local throughGate = course(edgeVehicle, {{x=edgeX,z=110},{x=edgeX,z=120}})
assert(P.validateCourse(edgeDriver,throughGate,P.newPlan({}),edgeBoundary),
    'A fully contained access-lane departure must not be blocked by lateral sweep padding')
local outOfGate = course(edgeVehicle, {{x=edgeX,z=110},{x=10,z=120}})
assert(not P.validateCourse(edgeDriver,outOfGate,P.newPlan({}),edgeBoundary),
    'An outside-field departure must remain inside the surveyed access lane')
print('Conservative sweep refinement at field, harvested-corridor and access-lane edges: OK')
print('UnloaderParkingPlannerTest: whole-rig geometry, native crop queries, queue ownership and strategy/Dubins integration OK')
