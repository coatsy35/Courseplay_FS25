-- Reproduce two opposing standby rigs with actual articulated route footprints and Dubins goal costs.
-- Engine transforms, job services and pathfinder completion are adapted; no vehicle physics are simulated.
dofile('scripts/CpObject.lua')
dofile('scripts/geometry/Vector.lua')
dofile('scripts/pathfinder/AnalyticSolution.lua')
dofile('scripts/pathfinder/State3D.lua')
dofile('scripts/pathfinder/Dubins.lua')
MathUtil = {vector2Length = function(x, z) return math.sqrt(x * x + z * z) end}
CpUtil = {try = function(fn, ...) return pcall(fn, ...) end, getName = function(v) return v.name or 'rig' end}
function getWorldTranslation(n) return n.x, 0, n.z end
function localDirectionToWorld(n, x, y, z)
    local h = n.heading or 0
    return math.cos(h) * x + math.sin(h) * z, y, -math.sin(h) * x + math.cos(h) * z
end
function localToWorld(n, x, y, z)
    local dx, dy, dz = localDirectionToWorld(n, x, y, z)
    return n.x + dx, dy, n.z + dz
end
function localToLocal(from, to, x, y, z)
    local wx, wy, wz = localToWorld(from, x, y, z)
    local h = to.heading or 0
    wx, wz = wx - to.x, wz - to.z
    return math.cos(h) * wx - math.sin(h) * wz, wy, math.sin(h) * wx + math.cos(h) * wz
end
dofile('scripts/ai/util/AIUtil.lua')
dofile('scripts/util/CpMathUtil.lua')
dofile('scripts/ai/util/FieldworkBoundary.lua')
dofile('scripts/ai/util/VehicleRouteConflict.lua')
dofile('scripts/ai/strategies/AIDriveStrategyUnloadCombine.lua')
AIUtil.getDirectionNodeToReverserNodeOffset = function() return 0 end
PathfinderUtil = {hasFruit = function() return false end, dubinsSolver = DubinsSolver(),
    getVehiclePositionAsState3D = function(v)
        local n = v.rootNode
        return State3D(n.x, -n.z, CpMathUtil.angleFromGame(n.heading))
    end}
Waypoint = function(p) return p end
AIDriveStrategyCombineCourse = {isActiveCpCombine = function() return false end}
UnloaderCoordinator = {rebalanceIntervalMs=1000}
local function route(points, reverse)
    local c = {points = points, reverse = reverse}
    function c:getNumberOfWaypoints() return #self.points end
    function c:getWaypointPosition(i) return self.points[i][1], 0, self.points[i][2] end
    function c:isReverseAt() return self.reverse end
    function c:adjustForReversing() end
    function c:getNextWaypointIxWithinDistance(ix, distance)
        local length = 0
        for i = ix + 1, #self.points do
            length = length + MathUtil.vector2Length(self.points[i][1] - self.points[i-1][1],
                    self.points[i][2] - self.points[i-1][2])
            if length >= distance then return i end
        end
        return #self.points
    end
    function c:copy(_, first, last)
        local result = {}
        for i = first, last do result[#result+1] = self.points[i] end
        return route(result, self.reverse)
    end
    return c
end
local function straight(v, distance, reverse)
    local n = v.rootNode
    local points = {{n.x, n.z}}
    for i = 1, math.ceil(distance) do
        local x, _, z = localToWorld(n, 0, 0, math.min(distance, i) * (reverse and -1 or 1))
        points[#points+1] = {x, z}
    end
    return route(points, reverse)
end
Course = {createStraightForwardCourse = function(v, d) return straight(v, d, false) end,
    createStraightReverseCourse = function(v, d, _, node)
        return straight(node and {rootNode=node} or v.children[#v.children] or v,d,true)
    end}
local boundary = {polygon = {{x=-200,z=-200},{x=200,z=-200},{x=200,z=200},{x=-200,z=200}}, margin=2, islands={}}
local harvester = {name = 'combine'}
local function body(x, z, heading, width, length)
    local v = {rootNode = {x=x,z=z,heading=heading}, size={width=width,length=length}, children={}}
    function v:getChildVehicles() return self.children end
    function v:getAIDirectionNode() return self.rootNode end
    function v:getIsCpActive() return self.active ~= false end
    return v
end
local function driver(x, z, heading, parked)
    local v = body(x,z,heading,3,6)
    local trailer = body(x-math.sin(heading)*8,z-math.cos(heading)*8,heading,3,9)
    trailer.getAttacherVehicle = function() return v end
    v.children = {trailer}
    local s = setmetatable({vehicle=v, turningRadius=9, standbyAssignment={harvester=harvester,role='POOL'},
        states={DRIVING_TO_STANDBY='drive',WAITING_IN_STANDBY='wait',WAITING_FOR_STANDBY_PATHFINDER='search',IDLE='idle'},
        state=parked and 'wait' or 'drive', debug=function() end, debugSparse=function() end,
        getCombineToUnload=function(self) return self.combineToUnload end,
        getFieldworkBoundaryForRig=function() return boundary end,
        isAvailableForStaging=function() return true end,
        setMaxSpeed=function(self, speed) self.speed = math.min(self.speed or math.huge,speed) end,
        setNewState=function(self,state) self.state=state end,
        startCourse=function(self,c) self.course=c end,
        pathfinderController={cancel=function() end},
        settings={fullThreshold={getValue=function() return 85 end}},
        checkStandbyPosition={get=function() return false end, set=function() end},
        isDriveUnloadNowRequested=function() return false end, getAllTrailersFull=function() return false end,
    }, {__index=AIDriveStrategyUnloadCombine})
    s.course = straight(v,60,false)
    s.ppc = {getCourse=function() return s.course end, getRelevantWaypointIx=function() return 1 end}
    v.getCpDriveStrategy = function() return s end
    s.startPathfindingToStandby = function(self,h,target,avoid,emergency)
        assert(h == harvester and avoid, 'Traffic escape must include the waiting rig and combine as obstacles')
        self.target, self.emergency = target, emergency
        self.standbyTargetX,self.standbyTargetZ=target.x,target.z
        self.standbyBoundary=boundary
        self.state='search'
    end
    return s
end
local function pair(gap)
    g_time = 1000
    local a,b=driver(0,0,0),driver(0,gap or 30,math.pi)
    g_currentMission={time=g_time,vehicleSystem={vehicles={a.vehicle,b.vehicle}}}
    return a,b
end
local function move(s,x,z)
    local dx,dz=x-s.vehicle.rootNode.x,z-s.vehicle.rootNode.z
    for _,v in ipairs({s.vehicle,s.vehicle.children[1]}) do
        v.rootNode.x,v.rootNode.z=v.rootNode.x+dx,v.rootNode.z+dz
    end
end

-- Use the existing public callbacks, not a new helper, to demonstrate the recorded mutual wait.
local stuckA,stuckB=pair(7.5)
stuckA:onBlockingVehicle(stuckB.vehicle,false)
stuckB:onBlockingVehicle(stuckA.vehicle,false)
stuckA:updateStandbyCoordinator()
stuckB:updateStandbyCoordinator()
assert((stuckA.state=='search' and stuckB.state=='wait') or (stuckB.state=='search' and stuckA.state=='wait'),
    'After the head-on callbacks exactly one rig must plan its escape; both must not remain waiting')

local a,b=pair()
a:checkStandbyTraffic()
local encounter=a.standbyTrafficEncounter
assert(encounter and encounter==b.standbyTrafficEncounter and a.state=='wait' and b.state=='wait',
    'An impending head-on conflict must stop both rigs while there is still manoeuvring space')
local yielding,waiting=encounter.yielding,encounter.waiting
yielding:releaseStandbyTraffic()
a.state,b.state='drive','drive'
b:checkStandbyTraffic()
assert(a.standbyTrafficEncounter.yielding==yielding, 'Callback order must not swap the yielding rig')
encounter=a.standbyTrafficEncounter
yielding:updateStandbyTrafficYield()
assert(yielding.state=='search' and yielding.target, 'A deterministic yielder must receive a local escape goal')
assert(yielding.getDistanceFromConnectingCourse(encounter.passage,yielding.target.x,yielding.target.z)>encounter.distance,
    'Do not retry the original standby goal on the reserved passage')
for i=1,30 do
    g_time=g_time+16
    waiting.speed=24
    assert(waiting:updateStandbyTrafficYield() and waiting.speed==0, 'Hold on every frame, not just each scan')
end
-- Failed forward search at a 1.5 m bumper gap must create space, with no free reverse pathfinding.
a,b=pair(7.5)
a:onBlockingVehicle(b.vehicle,false)
encounter=a.standbyTrafficEncounter
yielding,waiting=encounter.yielding,encounter.waiting
yielding.state='search'
assert(yielding:onPathfindingDoneToStandby(nil,false,nil) and yielding.state=='drive' and yielding.course.reverse,
    'A failed head-on escape must start the checked straight reverse instead of mutual retries')
local _,_,endZ=yielding.course:getWaypointPosition(yielding.course:getNumberOfWaypoints())
assert(math.abs(endZ-yielding.vehicle.children[1].rootNode.z)==6, 'Use the shortest verified reverse first')
yielding:onLastWaypointPassed()
yielding:updateStandbyTrafficYield()
assert(yielding.target and yielding.state=='search', 'Completing the reverse must retry a collision-aware forward escape')

-- Assignment churn must neither cancel an unfinished escape nor release the other tractor.
yielding:clearStandbyAssignment()
assert(not yielding.standbyAssignment and yielding.standbyTrafficEncounter==encounter and yielding.state=='search')
yielding:setStandbyAssignment({harvester={},role='STANDBY'})
assert(yielding.standbyTrafficEncounter==encounter and yielding.state=='search')
yielding:clearStandbyAssignment()
local accepted=straight(yielding.vehicle,6,true)
assert(yielding:onPathfindingDoneToStandby(nil,true,accepted) and yielding.state=='drive',
    'A successful local escape still owns its callback after allocation removal')

-- The tractor clearing sideways is insufficient while its trailer still crosses the passage.
move(yielding,35,waiting.vehicle.rootNode.z)
yielding.vehicle.children[1].rootNode.x=0
g_time=10000
waiting:updateStandbyTrafficYield()
assert(waiting.standbyTrafficEncounter==encounter, 'The complete trailer must clear before passage is released')
yielding.vehicle.children[1].rootNode.x=35
g_time=12000
waiting:updateStandbyTrafficYield()
assert(not waiting.standbyTrafficEncounter and not yielding.standbyTrafficEncounter and yielding.state=='wait',
    'Release once physically clear and stop the escape; do not resume either obsolete approach')

-- A third arriving rig keeps its stop between scans and rechecks after the pair releases.
a,b=pair()
a:checkStandbyTraffic()
local third=driver(0,-25,0)
third:startStandbyTrafficYield(a)
for i=1,20 do
    third.speed=24
    assert(third:updateStandbyTrafficYield() and third.speed==0 and third.standbyTrafficQueue)
end
a:releaseStandbyTraffic()
third.speed=24
assert(third:updateStandbyTrafficYield() and not third.standbyTrafficQueue and third.speed==0,
    'The queued tractor must remain stopped for the release update and rescan before moving')

-- A stopped job releases its partner without resurrecting the old route.
a,b=pair()
a:checkStandbyTraffic()
b.vehicle.active=false
a:updateStandbyTrafficYield()
assert(not a.standbyTrafficEncounter and a.state=='wait')

-- No encounter for clear parallel lanes; a parked rig keeps priority, and harvester clearance wins over parking.
a,b=pair()
move(b,15,30)
a:checkStandbyTraffic()
assert(not a.standbyTrafficEncounter, 'Nearby parallel rigs must not be shuffled unnecessarily')
move(b,0,30)
b.state='wait'
g_time=3000
a:checkStandbyTraffic()
assert(a.standbyTrafficEncounter.yielding==a, 'An arrival must yield to a parked rig')
a:releaseStandbyTraffic()
a.state='drive'
a.connectorClearance={harvester=harvester,course=a.course,distance=10}
a.isRigClearOfConnectorClearance=function() return false end -- isolate encounter priority from harvester geometry
harvester.getIsCpActive=function() return true end
a:startStandbyTrafficYield(b)
assert(a.standbyTrafficEncounter.yielding==b, 'A rig clearing a harvester must have passage priority')

-- A short reverse must still reject another trailer behind and a field-edge exit.
a,b=pair(7.5)
local behind=driver(0,-20,0)
table.insert(g_currentMission.vehicleSystem.vehicles,behind.vehicle)
assert(not a:startVerifiedStandbyReverse({}, {6,12,20}), 'Never reverse into the rig parked behind')
local angled=body(10,-16,math.pi/2,3,22)
angled.getAIDirectionNode=nil -- non-AI trailer in the mission vehicle list: the reported runtime failure
g_currentMission.vehicleSystem.vehicles={a.vehicle,b.vehicle,angled}
assert(not a:startVerifiedStandbyReverse({}, {6,12,20}),
    'A long angled obstacle whose centre is beside the corridor can still obstruct the trailer rear')
g_currentMission.vehicleSystem.vehicles={a.vehicle,b.vehicle}
local originalBoundary=boundary
boundary={polygon={{x=-50,z=-13},{x=50,z=-13},{x=50,z=100},{x=-50,z=100}},margin=2,islands={}}
assert(not a:startVerifiedStandbyReverse({}, {6,12,20}), 'The trailer rear must not reverse out of the field')
boundary=originalBoundary

-- A queued third rig can block the chosen reverse. Elect the other rig only after verifying
-- that it can actually move, and preserve the queue while that alternative clears the passage.
a,b=pair(7.5)
b.state='wait'
a:startStandbyTrafficYield(b)
encounter=a.standbyTrafficEncounter
third=driver(0,-20,0)
table.insert(g_currentMission.vehicleSystem.vehicles,third.vehicle)
third:startStandbyTrafficYield(a)
a.state='search'
assert(a:onPathfindingDoneToStandby(nil,false,nil) and encounter.yielding==b and b.state=='drive' and b.course.reverse,
    'A third rig blocking the first reverse must not deadlock the pair and its queue')
assert(encounter.waiting==a and a.state=='wait' and not b:tryAlternateStandbyYield(encounter),
    'A verified alternative must not oscillate priority on later failures')
third.speed=24
third:updateStandbyTrafficYield()
assert(third.speed==0 and third.standbyTrafficQueue==encounter)

-- Exercise the actual standby pathfinder dispatch after the harvester's job/strategy has ended.
a,b=pair()
a:startStandbyTrafficYield(b)
yielding=a.standbyTrafficEncounter.yielding
yielding.startPathfindingToStandby=nil
yielding.getMaxFruitPercent=function() return 10 end
yielding.vehicle.cpGetFieldPolygon=function() return boundary.polygon end
PathfinderUtil.getMaxIterationsForFieldPolygon=function() return 100 end
PathfinderUtil.getWaypointAsState3D=function(p) return p end
CpFieldUtil={getFieldNumUnderVehicle=function(v)
    assert(v==yielding.vehicle, 'An ended harvester job must not own the traffic escape field lookup')
    return 11
end}
PathfinderContext=setmetatable({defaultOffFieldPenalty=7.5}, {__call=function()
    local context={}
    for _,key in ipairs({'maxFruitPercent','offFieldPenalty','useFieldNum','areaToAvoid','vehiclesToIgnore','maxIterations'}) do
        context[key]=function(self,value) self['_'..key]=value; return self end
    end
    return context
end})
harvester.getIsCpActive=function() return false end
harvester.getCpDriveStrategy=function() error('Ended combine strategy was accessed') end
yielding.pathfinderController.registerListeners=function() end
local dispatched
yielding.pathfinderController.findPathToGoal=function(_,context) dispatched=context end
yielding:startPathfindingToStandby(harvester,{x=45,z=40},true)
assert(dispatched and dispatched._useFieldNum==11 and #dispatched._vehiclesToIgnore==0 and
        dispatched._offFieldPenalty==7.5 and dispatched._areaToAvoid==nil and dispatched._allowReverse~=true,
    'Keep collision checking and forward-only search when the old harvester job has ended')
print('UnloaderStandbyTrafficTest: OK')
