-- Production geometry and strategy lifecycle: never give AD an unchecked in-field exit.
coroutine=nil
MathUtil={vector2Length=function(x,z) return math.sqrt(x*x+z*z) end}
function entityExists(n) return n~=nil end
function getWorldTranslation(n) return n.x,0,n.z end
function localDirectionToWorld(n,x,y,z)
    return math.cos(n.heading)*x+math.sin(n.heading)*z,y,-math.sin(n.heading)*x+math.cos(n.heading)*z
end
function localToWorld(n,x,y,z) local a,b,c=localDirectionToWorld(n,x,y,z); return n.x+a,b,n.z+c end
function localToLocal(a,b,x,y,z)
    local wx,_,wz=localToWorld(a,x,y,z); local dx,dz=wx-b.x,wz-b.z
    return math.cos(b.heading)*dx-math.sin(b.heading)*dz,0,math.sin(b.heading)*dx+math.cos(b.heading)*dz
end
dofile('scripts/CpObject.lua')
CpUtil={createNode=function() return {} end,try=function(f,...) return pcall(f,...) end,
    getDefaultCollisionFlags=function() return 2 end,getName=function() return 'test' end}
dofile('scripts/ai/util/AIUtil.lua')
dofile('scripts/util/CpMathUtil.lua')
dofile('scripts/ai/util/FieldworkBoundary.lua')
dofile('scripts/ai/util/VehicleRouteConflict.lua')
local field={{x=-100,z=0},{x=100,z=0},{x=100,z=300},{x=-100,z=300}}
local function body(x,z,w,l,h)
    local v={rootNode={x=x,z=z,heading=h or 0},size={width=w,length=l},children={}}
    function v:getAIDirectionNode() return self.rootNode end
    function v:getChildVehicles() return self.children end
    function v:getAttacherVehicle() return self.parent end
    function v:getRootVehicle() return self.parent and self.parent:getRootVehicle() or self end
    function v:cpGetFieldPolygon() return field end
    return v
end
local function train(x,z,h)
    local v=body(x,z,3,6,h)
    local t=body(x-math.sin(h)*8,z-math.cos(h)*8,3,9,h)
    t.parent,t.spec_wheels=v,{}
    t.getActiveInputAttacherJoint=function() return {node={x=x-math.sin(h)*4,z=z-math.cos(h)*4,heading=h}} end
    v.children={t}; return v
end
local function course(v,points)
    local c={points=points}
    function c:getNumberOfWaypoints() return #self.points end
    function c:getWaypointPosition(i) return self.points[i].x,0,self.points[i].z end
    function c:isReverseAt(i) return self.points[i].rev or false end
    function c:append(other) for _,p in ipairs(other.points) do self.points[#self.points+1]=p end end
    function c:getNextWaypointIxWithinDistance(i) return math.min(#points,i+4) end
    function c:copy(_,first,last) local p={}; for i=first or 1,last or #points do p[#p+1]=points[i] end; return course(v,p) end
    return c
end
Course=setmetatable({}, {__call=function(_,...) return course(...) end})
Course.createFromTwoWorldPositions=function(v,x,z,gx,gz)
    local p={}; local n=math.max(1,math.ceil(MathUtil.vector2Length(gx-x,gz-z)))
    for i=1,n do p[#p+1]={x=x+(gx-x)*i/n,z=z+(gz-z)*i/n} end
    return course(v,p)
end
Waypoint=function(p) p.getIsReverse=function() return false end; return p end
local crop=false
PathfinderUtil={hasFruit=function() return crop,100 end,
    setWorldPositionAndRotationOnTerrain=function(n,x,z,h) n.x,n.z,n.heading=x,z,h end,
    getMaxIterationsForFieldPolygon=function() return 10000 end,
    getWaypointAsState3D=function(p,_,offset)
        local h=math.rad(p.angle); return {x=p.x+math.sin(h)*offset,y=-p.z-math.cos(h)*offset,t=h}
    end}
PathfinderCollisionDetector=function() return {findCollidingShapes=function() return 0 end} end
UnloaderCoordinator={assignments={},release=function() end}
g_currentMission={vehicleSystem={vehicles={}}}
AIUtil.getTurningRadius=function() return 10 end
CpFieldUtil={getFieldNumUnderVehicle=function() return 1 end}
HybridAStar={defaultMaxIterations=10000}; CollisionFlag={TERRAIN_DELTA=1}
dofile('scripts/pathfinder/PathfinderContext.lua')
dofile('scripts/ai/util/UnloaderParkingPlanner.lua')
dofile('scripts/ai/util/UnloaderFieldDeparture.lua')
AIDriveStrategyCourse={}
dofile('scripts/ai/strategies/AIDriveStrategyUnloadCombine.lua')
local D,P=UnloaderFieldDeparture,UnloaderParkingPlanner
local v=train(7.6,200,0)
local run={}
function run:getNumberOfWaypoints() return 21 end
function run:getWaypointPosition(i) return 7.6,0,10+(i-1)*10 end -- actual working offset
function run:getWaypointYRotation() return 0 end
function run:isOnHeadland() return false end
function run:isOnConnectingPath() return false end
function run:isReverseAt() return false end
function run:isTurnStartAtIx() return false end
function run:getWaypoint(i) return {isRowStart=function() return i==1 end} end
function run:getHeadland() return {{x=-90,y=-10},{x=90,y=-10},{x=90,y=-290},{x=-90,y=-290}} end
local states={WAITING_FOR_FULL_TRAILER_EXIT='waiting',DRIVING_BACK_TO_START_POSITION_WHEN_FULL='driving'}
local handovers,searches=0,0
local driver=setmetatable({vehicle=v,turningRadius=10,states=states,state='waiting',
    lastUnloadFieldRun={course=run,ix=20},invertedStartPositionMarkerNode={x=0,z=10,heading=math.pi},
    invertedGoalPositionOffset=0,debug=function() end,setNewState=function(self,s) self.state=s end,
    setMaxSpeed=function(self,s) self.speed=s end,startCourse=function(self,c) self.course=c end,
    getAllowReversePathfinding=function() return true end,getFieldSpeed=function() return 20 end,
    onTrailerFull=function() handovers=handovers+1 end}, {__index=AIDriveStrategyUnloadCombine})
driver.pathfinderController={registerListeners=function(self,owner,done,failed,obstacle)
    self.owner,self.done,self.failed,self.obstacle=owner,done,failed,obstacle end,
    findPathToGoal=function(_,context,goal) searches=searches+1; driver.context,driver.goal=context,goal end}
g_currentMission.vehicleSystem.vehicles={v}
local departure=D.create(driver)
assert(departure and #departure.goals>4)
for _,goal in ipairs(departure.goals) do
    if goal.z>10 and goal.z<200 and math.abs(goal.x-7.6)<0.01 then
        assert(math.abs(goal.heading-math.pi)<0.001,'Row exits must use the actual combine lane in the opposite direction')
    end
end
assert(departure.goals[1].z<200 and departure.goals[1].x==7.6,
    'A full trailer must first return down its harvested row, before travelling to the AD access')
local exit=departure.goals[#departure.goals]
assert(exit.x==0 and exit.z==10 and exit.heading==math.pi,
    'The configured CP marker must remain the actual handover pose without a fabricated extension')
local forward,reverseHeadings=0,0
for _,goal in ipairs(departure.goals) do
    if goal.path and #goal.path>1 and math.abs(goal.x-7.6)>1 and not goal.exit and not goal.headlandJoin then
        local a,b=goal.path[#goal.path-1],goal.path[#goal.path]
        local h=math.atan2(b.x-a.x,b.z-a.z)
        assert(math.abs((goal.heading-h+math.pi)%(2*math.pi)-math.pi)<0.01,
            'Headland checkpoints must use the incoming tangent of the selected traversal')
        reverseHeadings=reverseHeadings+1
    end
end
assert(reverseHeadings>0)
driver.fullTrailerDeparture=departure
local boundary=D.legBoundary(driver,departure)
assert(not FieldworkBoundary.contains(boundary,75,150),'A row exit must reject a diagonal shortcut across harvested ground')
assert(FieldworkBoundary.contains(boundary,7.6,170))
-- The long gate overlap must contain the whole train before any part crosses the field edge.
for z=20,-30,-1 do
    local rig=P.alignedRig(v,0,z,math.pi)
    assert(FieldworkBoundary.rigOutsideDistance(departure.boundary,rig)==0,
        'A complete rig must be able to straddle the surveyed field gate without an artificial boundary deadlock')
end
-- A valid marker may be deep inside the field, or tangent to the headland.
local originalMarker=driver.invertedStartPositionMarkerNode
driver.invertedStartPositionMarkerNode={x=0,z=150,heading=math.pi/2}
local internal=D.create(driver)
assert(internal and internal.goals[#internal.goals].z==150,
    'An inside-field marker must not be rejected for being more than 40 m from the edge')
driver.invertedStartPositionMarkerNode={x=-138,z=100,heading=0}
driver.invertedGoalPositionOffset=-4.5
local external=D.create(driver)
assert(external and external.goals[#external.goals].x==-142.5,
    'A validated outside marker must not be rejected because its normal lateral offset exceeds 40 m')
driver.invertedStartPositionMarkerNode=originalMarker; driver.invertedGoalPositionOffset=0
-- Reproduce the logged checkpoint: 0.017 m away with an 11 degree heading difference.
local originalVehicle,originalDeparture=driver.vehicle,driver.fullTrailerDeparture
local checkpoint={x=71.03,z=322.23,heading=math.rad(347),path={{x=71.03,z=322.23}}}
local nextGoal={x=71.03,z=280,heading=math.rad(347),path={{x=71.03,z=322.23},{x=71.03,z=280}}}
driver.vehicle=train(71.02,322.22,math.rad(336))
driver.fullTrailerDeparture={goals={checkpoint,nextGoal,exit},ix=1,boundary=departure.boundary,corridorWidth=20}
assert(D.atGoal(driver,checkpoint),'Intermediate navigation checkpoints do not require a final parking heading')
driver:searchFullTrailerDeparture()
assert(driver.fullTrailerDeparture.ix==2 and searches==1,
    'An already reached checkpoint must be consumed before requesting another path')
driver.vehicle,driver.fullTrailerDeparture=originalVehicle,originalDeparture

driver:searchFullTrailerDeparture()
assert(driver.state=='waiting' and driver.context._protectRigBoundary and driver.context._avoidStandingCrop and
    #driver.context._vehiclesToIgnore==0 and driver.context._fieldworkBoundary.travelBoundary,
    'Exit searches must protect the harvested corridor, crop and every other vehicle')
driver.pathfinderController.failed(driver)
assert(handovers==0 and driver.state=='waiting' and driver.fullTrailerExitRetryAt==5000,
    'Path failure must keep CP active and braked instead of giving AD an unchecked exit')
local oldDone=driver.pathfinderController.done
driver:searchFullTrailerDeparture()
oldDone(driver,nil,false,nil)
assert(driver.fullTrailerExitSearching,'A stale pathfinder callback must not replace a newer departure search')
driver.fullTrailerExitWork={job={step=function() return false end},kind='traffic',departure=departure}
driver.ppc={getCourse=function() return course(v,{{x=7.6,z=200},{x=7.6,z=150}}) end}
driver:driveFullTrailerDeparture()
assert(driver.speed==0,'A paused traffic check must brake the full train')
driver.fullTrailerExitWork=nil
-- Validate a forward exit with a real articulated train, including the added straight tail.
v=train(0,35,math.pi); driver.vehicle=v
departure.ix=#departure.goals; departure.legBoundary=D.legBoundary(driver,departure)
g_currentMission.vehicleSystem.vehicles={v}
assert(FieldworkBoundary.contains(departure.legBoundary,exit.x-math.sin(exit.heading)*departure.alignmentLength,
    exit.z-math.cos(exit.heading)*departure.alignmentLength),
    'The final alignment target must lie within the checked travel corridor')
local checked=P.run(D.validationJob(driver,course(v,{{x=0,z=35},{x=exit.x,z=exit.z}}),departure))
assert(checked,'A harvested field access must pass the complete articulated route check')
local obstacle=body(0,15,4,8,0)
g_currentMission.vehicleSystem.vehicles={v,obstacle}
assert(not P.run(D.validationJob(driver,course(v,{{x=0,z=35},{x=exit.x,z=exit.z}}),departure)),
    'A second combine in the alignment tail must prevent the exit course from starting')
g_currentMission.vehicleSystem.vehicles={v}; crop=true
assert(not P.run(D.validationJob(driver,course(v,{{x=0,z=35},{x=exit.x,z=exit.z}}),departure)),
    'A checked exit must not drive through standing crop')
crop=false
local exact=course(v,{{x=0,z=35},{x=exit.x,z=exit.z}})
P.run(D.validationJob(driver,exact,departure))
assert(exact:getNumberOfWaypoints()==2,
    'An accurate checkpoint must not append a zero-length waypoint with an unrelated heading')
-- Arrival is verified against the actual whole rig, not only the PPC last-waypoint callback.
driver.fullTrailerDeparture=departure
assert(not D.atGoal(driver,exit))
v=train(exit.x,exit.z,exit.heading); driver.vehicle=v
g_currentMission.vehicleSystem.vehicles={v}
assert(D.atGoal(driver,exit))
v.children[1].rootNode.heading=exit.heading+math.rad(20)
assert(not D.atGoal(driver,exit),'A jackknifed trailer must not qualify for final handover')
v.children[1].rootNode.heading=exit.heading
driver:finishFullTrailerDepartureLeg(); driver:continueFullTrailerExitWork()
assert(handovers==1,'AD handover must occur once, only after the full rig reaches and aligns at the checked access')
driver:searchFullTrailerDeparture()
assert(handovers==1 and driver.fullTrailerHandoverRequested)

-- Search-time rejection uses the towed body, while standard CP entry retains its original soft fruit policy.
dofile('scripts/pathfinder/PathfinderConstraints.lua')
v=train(0,30,0)
local constraints=setmetatable({vehicle=v,avoidStandingCrop=true,ignoreTrailerAtStartRange=0,
    collisionNodeCount=0,trailerCollisionNodeCount=0,
    collisionDetector={findCollidingShapes=function() return 0 end},
    vehicleData={getVehicle=function() return v end,getTowedImplement=function() return v.children[1] end,
        getVehicleOverlapBoxParams=function() return {width=1.75,length=3.25,xOffset=0,zOffset=0} end,
        getTowedImplementOverlapBoxParams=function() return {width=1.75,length=4.75,xOffset=0,zOffset=-4} end,
        getHitchOffset=function() return -4 end}}, {__index=PathfinderConstraints})
local fruit=PathfinderUtil.hasFruit
PathfinderUtil.hasFruit=function(x,z,l,w) return math.abs(x)<w/2 and math.abs(z-18)<l/2,100 end
local node={x=0,y=-30,t=CpMathUtil.angleFromGame(0),tTrailer=CpMathUtil.angleFromGame(0),d=0}
assert(not constraints:isValidNode(node,true,true),
    'A staging/exit destination must be rejected when crop is under its trailer, even if the tractor centre is clear')
constraints.avoidStandingCrop=false
assert(constraints:isValidNode(node,true,true),'Ordinary CP unloading entry must retain its existing fruit/collision rules')
PathfinderUtil.hasFruit=fruit

-- A hard native goal rejection selects a bounded alternative on the same checked
-- corridor, without recursive searches or early AD handover. Analytic-only failure
-- is not evidence that the endpoint itself is obstructed.
driver.fullTrailerHandoverRequested=nil
driver.vehicle=train(0,100,0)
driver.state=states.WAITING_FOR_FULL_TRAILER_EXIT
g_currentMission.vehicleSystem.vehicles={driver.vehicle}
local navigation={x=0,z=30,heading=0,path={{x=0,z=100},{x=0,z=30}}}
local retryDeparture={goals={navigation,exit},ix=1,boundary=departure.boundary,
    corridorWidth=20,alignmentLength=25}
driver.fullTrailerDeparture=retryDeparture
driver:searchFullTrailerDeparture()
local beforeSearches,beforeHandovers=searches,handovers
constraints.vehicle=driver.vehicle
constraints.avoidStandingCrop=true
constraints.departureGoalDiagnostics=driver.context._departureGoalDiagnostics
PathfinderUtil.hasFruit=function(x,z,l,w) return math.abs(x)<w/2 and math.abs(z-18)<l/2,100 end
node={x=0,y=-30,t=CpMathUtil.angleFromGame(0),tTrailer=CpMathUtil.angleFromGame(0),d=0}
assert(not constraints:isValidNode(node,true,true))
assert(driver.fullTrailerExitGoalDiagnostics.reason=='standing crop under goal rig')
driver.pathfinderController.done(driver,nil,false,nil,true)
assert(searches==beforeSearches and handovers==beforeHandovers and driver.fullTrailerExitRetryAt==0,
    'Goal recovery must defer its search to the next update and retain CP control')
assert(navigation.x==0 and retryDeparture.activeGoal.x==-2 and retryDeparture.ix==1,
    'An alternative navigation pose must not mutate or consume the original planned checkpoint')
driver:searchFullTrailerDeparture()
constraints.departureGoalDiagnostics=driver.context._departureGoalDiagnostics
node.x=driver.goal.x
assert(constraints:isValidNode(node,true,true),'The neighbouring endpoint must still pass native crop checks')
assert(driver.context._avoidStandingCrop and driver.context._protectRigBoundary and
    #driver.context._vehiclesToIgnore==0 and driver.context._fieldworkBoundary.travelBoundary)
driver.vehicle=train(retryDeparture.activeGoal.x,retryDeparture.activeGoal.z,0)
g_currentMission.vehicleSystem.vehicles={driver.vehicle}
driver:finishFullTrailerDepartureLeg()
assert(retryDeparture.ix==2 and not retryDeparture.activeGoal and handovers==beforeHandovers,
    'Only actual validated checkpoint arrival can advance to the next leg; handover remains deferred')
PathfinderUtil.hasFruit=fruit
driver.pathfinderController.done(driver,nil,false,nil,true)
assert(not retryDeparture.activeGoal and driver.fullTrailerExitRetryAt==5000,
    'Analytic-only invalidity must retain the normal hold rather than cycle endpoint poses')

-- Reproduce a physical object at the default run-in. Native goal validity, not
-- proximity to the marker, determines whether a shorter run-in may be searched.
driver:searchFullTrailerDeparture()
constraints.avoidStandingCrop=false
constraints.departureGoalDiagnostics=driver.context._departureGoalDiagnostics
local originalDetector=constraints.collisionDetector
constraints.collisionDetector={findCollidingShapes=function(_,n) return math.abs(n.z-35)<0.1 and 1 or 0 end}
node={x=driver.goal.x,y=driver.goal.y,t=CpMathUtil.angleFromGame(math.pi),d=0}
assert(not constraints:isValidNode(node,true,true) and
    driver.fullTrailerExitGoalDiagnostics.reason=='physical shape at goal')
driver.pathfinderController.done(driver,nil,false,nil,true)
assert(retryDeparture.activeGoal.runInLength==18.75 and
    retryDeparture.activeGoal.x==exit.x and retryDeparture.activeGoal.z==exit.z and
    retryDeparture.activeGoal.heading==exit.heading,
    'Run-in recovery must preserve the exact configured handover position and heading')
driver:searchFullTrailerDeparture()
assert(math.abs(-driver.goal.y-28.75)<0.001)
constraints.departureGoalDiagnostics=driver.context._departureGoalDiagnostics
node.x,node.y=driver.goal.x,driver.goal.y
assert(constraints:isValidNode(node,true,true))
constraints.collisionDetector=originalDetector

constraints.protectRigBoundary=true
constraints.fieldworkBoundary={polygon={{x=-1,z=0},{x=1,z=0},{x=1,z=100},{x=-1,z=100}},margin=0,islands={}}
constraints.departureGoalDiagnostics={x=0,z=30}
node={x=0,y=-30,t=CpMathUtil.angleFromGame(0),d=0}
assert(not constraints:isValidNode(node,true,true) and
    constraints.departureGoalDiagnostics.reason=='goal rig outside checked boundary' and
    constraints.departureGoalDiagnostics.protrusion>0,
    'A full native goal footprint outside the permitted corridor must retain its boundary rejection')
constraints.departureGoalDiagnostics={x=50,z=30}
assert(not constraints:isValidNode(node,true,true) and not constraints.departureGoalDiagnostics.reason,
    'An invalid intermediate search goal must not be misreported as the requested departure endpoint')
constraints.protectRigBoundary=false
constraints.fieldworkBoundary=nil

-- The analytic flag alone is ambiguous. Diagnose its actual endpoint check:
-- the scalar fruit sample and trailer collision are independent of the initial
-- native tractor-shape check and must retain their original rejection policy.
constraints.maxFruitPercent=0
constraints.logger={debug=function() end}
constraints.avoidStandingCrop=true
constraints.departureGoalDiagnostics={x=0,z=30}
node.tTrailer=node.t
PathfinderUtil.hasFruit=function(_,_,l,w) return l==3 and w==3,100 end
assert(constraints:isValidNode(node,true,true))
assert(not constraints:isValidAnalyticSolutionNode(node,true) and
    constraints.departureGoalDiagnostics.reason=='standing crop in analytic goal sample',
    'The scalar analytic fruit rejection must be diagnosed without weakening its policy')
PathfinderUtil.hasFruit=fruit
constraints.collisionDetector={findCollidingShapes=function(_,n) return math.abs(n.z-26)<0.1 and 1 or 0 end}
constraints.departureGoalDiagnostics={x=0,z=30}
assert(constraints:isValidNode(node,true,true))
assert(not constraints:isValidAnalyticSolutionNode(node,true) and
    constraints.departureGoalDiagnostics.reason=='physical shape at goal',
    'A physical trailer collision at the analytic endpoint must be reported and remain solid')
constraints.collisionDetector=originalDetector
driver.fullTrailerExitGoalDiagnostics=constraints.departureGoalDiagnostics
driver.pathfinderController.done(driver,nil,false,nil,true)
assert(retryDeparture.activeGoal and driver.fullTrailerExitRetryAt==0,
    'A diagnosed analytic endpoint obstruction may use the same bounded checked recovery')

-- All endpoints obstructed: five attempts per final leg, then back off; never
-- recurse or relax collision/crop constraints to force a handover.
D.clearGoalCandidate(retryDeparture)
for attempt=1,5 do
    driver:searchFullTrailerDeparture()
    local count=searches
    driver.fullTrailerExitGoalDiagnostics.reason='physical shape at goal'
    driver.pathfinderController.done(driver,nil,false,nil,true)
    assert(searches==count and handovers==beforeHandovers)
    if attempt<5 then assert(driver.fullTrailerExitRetryAt==0)
    else assert(driver.fullTrailerExitRetryAt==5000 and not retryDeparture.activeGoal) end
end
retryDeparture.ix=1
driver.vehicle=train(0,100,0)
g_currentMission.vehicleSystem.vehicles={driver.vehicle}
for attempt=1,7 do
    driver:searchFullTrailerDeparture()
    driver.fullTrailerExitGoalDiagnostics.reason='standing crop under goal rig'
    driver.pathfinderController.done(driver,nil,false,nil,true)
end
assert(driver.fullTrailerExitRetryAt==5000 and not retryDeparture.activeGoal and
    retryDeparture.ix==1 and handovers==beforeHandovers,
    'All blocked navigation candidates must leave the leg unconsumed under CP control')

-- A general route obstruction must not cycle run-ins. A demonstrated final
-- alignment failure may, and both simulated and live train alignment are required.
retryDeparture.ix=2
driver.fullTrailerExitWork={job={step=function() return true end},kind='validate',departure=retryDeparture}
driver:continueFullTrailerExitWork()
assert(not retryDeparture.activeGoal and driver.fullTrailerExitRetryAt==5000,
    'Crop, boundary or traffic earlier on the route must not cause a burst of endpoint searches')
driver.vehicle=train(0,20,math.pi/2)
g_currentMission.vehicleSystem.vehicles={driver.vehicle}
retryDeparture.legBoundary=D.legBoundary(driver,retryDeparture)
local misaligned=D.validationJob(driver,course(driver.vehicle,{{x=0,z=20},{x=0,z=10}}),retryDeparture)
assert(not P.run(misaligned) and misaligned.rejectionReason=='final alignment',
    'A short approach with an unaligned simulated train must fail before driving starts')
driver.fullTrailerExitWork={job=misaligned,kind='validate',departure=retryDeparture}
driver:continueFullTrailerExitWork()
assert(retryDeparture.activeGoal and driver.fullTrailerExitRetryAt==0)

-- The object behind the shorter approach remains solid: the complete route may
-- pass only when the tractor, trailer and final alignment all clear that object.
local originalShapes=PathfinderCollisionDetector
PathfinderCollisionDetector=function() return {findCollidingShapes=function(_,n,_,box)
    return math.abs(n.x)<box.width and math.abs(n.z-35)<box.length and 1 or 0
end} end
driver.vehicle=train(0,20,math.pi)
g_currentMission.vehicleSystem.vehicles={driver.vehicle}
retryDeparture.activeGoal={x=exit.x,z=exit.z,heading=exit.heading,exit=true,runInLength=0}
retryDeparture.legBoundary=D.legBoundary(driver,retryDeparture)
local safe=P.run(D.validationJob(driver,course(driver.vehicle,{{x=0,z=20},{x=0,z=10}}),retryDeparture))
assert(safe,'A shorter, physically clear and fully aligned approach must pass whole-train validation')
local blocked=P.run(D.validationJob(driver,course(driver.vehicle,{{x=0,z=20},{x=0,z=40},{x=0,z=10}}),retryDeparture))
assert(not blocked,'Alternative endpoints must never permit a route through the obstructing shape')
PathfinderCollisionDetector=originalShapes
print('UnloaderFieldDepartureTest: row/headland corridors, articulated access, traffic holds and deferred AD handover OK')
