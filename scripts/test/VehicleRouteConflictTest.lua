-- Exercise production geometry, including attachment offsets, rather than mocking an occupancy answer.
MathUtil = {vector2Length = function(x, z) return math.sqrt(x * x + z * z) end}
function getWorldTranslation(n) return n.x, 0, n.z end
function getWorldRotation(n) return 0, n.heading or 0, 0 end
function localToLocal(from, to, x, _, z)
    local fh, th = from.heading or 0, to.heading or 0
    local wx = from.x + math.cos(fh) * x + math.sin(fh) * z - to.x
    local wz = from.z - math.sin(fh) * x + math.cos(fh) * z - to.z
    return math.cos(th) * wx - math.sin(th) * wz, 0, math.sin(th) * wx + math.cos(th) * wz
end
-- Use the production size accessors: GIANTS reports the attached AI agent, not one physical body.
CpUtil = {try = function(fn, ...) return pcall(fn, ...) end}
dofile('scripts/ai/util/AIUtil.lua')
dofile('scripts/ai/util/FieldworkBoundary.lua')
dofile('scripts/ai/util/VehicleRouteConflict.lua')
local function vehicle(x, z, width, length, heading, offset)
    local v = {rootNode = {x = x, z = z, heading = heading or 0},
        size = {width = width, length = length, lengthOffset = offset or 0}, children = {}}
    v.getAIDirectionNode = function() return v.rootNode end
    v.getChildVehicles = function() return v.children end
    return v
end
local combine = vehicle(0, 0, 4, 8)
local header = vehicle(0, 6, 15, 2)
header.getAttacherVehicle = function() return combine end
combine.children = {header}
combine.updateAIAgentAttachments = function() end
combine.getAIAgentSize = function() return 15, 18, 3 end
assert(AIUtil.getWidth(combine) == 15 and AIUtil.getLength(combine) == 18,
        'The fixture must exercise attachment-inclusive GIANTS dimensions through the real accessors')
local captured = FieldworkBoundary.captureRig(combine)
assert(captured[1].box.width == 2.25 and captured[1].box.length == 4.25 and
        captured[2].box.width == 7.75,
        'Represent the chassis and header once each, using per-body dimensions')
local function course(points, reverse)
    return {getNumberOfWaypoints = function() return #points end,
        getWaypointPosition = function(_, ix) return points[ix][1], 0, points[ix][2] end,
        isReverseAt = function() return reverse or false end}
end
local straight = course({{0, 0}, {0, 90}})
local function conflict(route, other)
    return VehicleRouteConflict.findConflict(
        VehicleRouteConflict.createSweep(FieldworkBoundary.captureRig(combine), route, 12),
        FieldworkBoundary.captureRig(other))
end
assert(not conflict(straight, vehicle(12, 20, 4, 9)),
        'A parallel trailer outside the header envelope must not inherit the old extra five-metre margin')
assert(not conflict(straight, vehicle(0, -11, 4, 8)),
        'A trailer behind the departure must not block forward travel via a header-sized end cap')
assert(not conflict(straight, vehicle(8, -3, 3, 4)),
        'Header width belongs at its actual forward offset, not all along the combine body')
assert(not conflict(course({{0, -15}, {0, 90}}), vehicle(0, -11, 4, 8)),
        'Do not roll backwards over the passed part of PPC\'s relevant segment')
local hit = conflict(straight, vehicle(7, 30, 2, 3))
assert(hit and hit.distance > 15 and hit.distance < 25,
        'A corner of the wide header must detect a trailer that clears the combine body')
local initialHit = conflict(straight, vehicle(7, 6, 2, 3))
assert(initialHit and initialHit.distance == 0,
        'An actual header overlap at departure must still be reported immediately')
local tractor = vehicle(25, 25, 3, 5)
local trailer = vehicle(3, 25, 3, 9, math.pi / 3)
trailer.getAttacherVehicle = function() return tractor end
tractor.children = {trailer}
assert(conflict(straight, tractor), 'A clear tractor must not hide its angled trailer across the route')
tractor.updateAIAgentAttachments = function() end
tractor.getAIAgentSize = function() return 30, 25, -10 end
local tractorRig = FieldworkBoundary.captureRig(tractor)
assert(tractorRig[1].box.width == 1.75 and tractorRig[1].box.length == 2.75,
        'An angled trailer must not inflate the tractor body as well as its own box')
assert(conflict(straight, vehicle(14, 25, 2, 10, math.pi / 2, -6)),
        'A rotated long body with an offset centre must use all four corners')
assert(not conflict(straight, vehicle(14, 25, 2, 10, math.pi / 2, 6)),
        'The same offset towards the clear side must not produce a false hold')
local hairpin = course({{0, 0}, {0, 30}, {8, 38}, {20, 40}, {32, 36}, {40, 24}, {40, -10}, {20, -20}})
assert(conflict(hairpin, vehicle(22, -20, 3, 6)),
        'A trailer currently behind us can still obstruct a later bend; do not globally ignore rear vehicles')
assert(conflict(course({{0, 0}, {0, 90}}), vehicle(0, 43.125, 0.05, 0.05)),
        'Sparse waypoints must not miss an obstruction between endpoints')
assert(conflict(course({{0, 0}, {0, -30}}, true), vehicle(0, -15, 3, 6)),
        'A reverse leg must still detect an actual obstruction behind the combine')
local sweep = VehicleRouteConflict.createSweep(FieldworkBoundary.captureRig(combine), straight, 12)
local before = sweep[1].parts[1].z
VehicleRouteConflict.findConflict(sweep, FieldworkBoundary.captureRig(vehicle(0, 60, 3, 5)))
assert(sweep[1].parts[1].z == before, 'Several rig checks must share an immutable sweep')

local shifted = vehicle(0, 0, 4, 8, 0, 2)
shifted.size.widthOffset = 1
shifted.getAIDirectionNode = function() return {x = 2, z = 3, heading = math.pi} end
local shiftedBox = FieldworkBoundary.captureRig(shifted)[1].box
assert(math.abs(shiftedBox.xOffset - 1) < 0.0001 and math.abs(shiftedBox.zOffset - 1) < 0.0001 and
        math.abs(shiftedBox.width - 2.25) < 0.0001,
        'Body offsets must transform into a shifted, reversed AI reference frame')
local shiftedHeader = vehicle(0, 6, 15, 2)
shiftedHeader.getAttacherVehicle = function() return shifted end
shifted.children = {shiftedHeader}
local reversedSweep = VehicleRouteConflict.createSweep(FieldworkBoundary.captureRig(shifted),
        course({{2, 3}, {2, -30}}), 12)
assert(VehicleRouteConflict.findConflict(reversedSweep, FieldworkBoundary.captureRig(vehicle(7, -10, 2, 3))) and
        not VehicleRouteConflict.findConflict(reversedSweep, FieldworkBoundary.captureRig(vehicle(12, -10, 2, 3))),
        'A shifted, reversed AI node must carry its actual attached header through the sweep')
WorkWidthUtil = {getAIMarkers = function(v) return v:getAIMarkers() end}
header.getAIMarkers = function() return {x = -9, z = 7}, {x = 9, z = 7}, {x = 0, z = 5} end
assert(FieldworkBoundary.captureRig(combine)[2].box.width == 9.25,
        'A deployed header must retain its marker width if its stored dimensions are folded')
header.getAIMarkers = nil

-- Search context -> completed-route validation -> live movement, with production geometry and size accessors.
-- The GIANTS engine and course container are supplied here; no boundary/footprint/occupancy result is mocked.
function CpObject(base) return setmetatable({}, {__index = base}) end
AIDriveStrategyCourse = {}
AIDriveStrategyFieldCourse = {}
VariableWorkWidth = {}
Utils = {overwrittenFunction = function(_, fn) return fn end}
dofile('scripts/ai/strategies/AIDriveStrategyFieldWorkCourse.lua')
dofile('scripts/util/CpMathUtil.lua')
PathfinderContext = function() return {
    allowReverse = function(self) return self end,
    mustBeAccurate = function(self) return self end,
    ignoreFruit = function(self, value) self.ignoreFruitValue = value; return self end,
    preferredPath = function(self, value) self._preferredPath = value; return self end,
} end
combine.spec_combine = {}
combine.cpGetFieldPolygon = function()
    return {{x = -8, z = -10}, {x = 100, z = -10}, {x = 100, z = 100}, {x = -8, z = 100}}
end
local nearby = vehicle(8, -3, 3, 4)
local requests, speedLimit = 0, nil
nearby.getCpDriveStrategy = function() return {
    getCombineToUnload = function() return nil end,
    isAvailableForStaging = function() return true end,
    isConnectorClearancePending = function() return true end,
    requestToMoveOutOfWay = function() requests = requests + 1 end,
} end
CpUtil.getName = function() return 'test unloader' end
g_currentMission = {time = 1000, vehicleSystem = {vehicles = {nearby}}}
straight.copy = function() return straight end
straight.getCurrentWaypointIx = function() return 1 end
straight.getNextWaypointIxWithinDistance = function() return 2 end
StartRowOnly = function(_, _, _, _, route) return {getCourse = function() return route end} end
local strategy = setmetatable({vehicle = combine, turningRadius = 12,
    settings = {avoidFruit = {getValue = function() return true end}},
    states = {DRIVING_TO_WORK_START_WAYPOINT = 'travel', WAITING_FOR_PATHFINDER = 'search'}, state = 'search',
    connectingPathStartIx = 722, debug = function() end,
    getWorkWidth = function() return 15 end, getAllowReversePathfinding = function() return true end,
    ppc = {setShortLookaheadDistance = function() end, getRelevantWaypointIx = function() return 1 end},
    proximityController = {registerBlockingObjectListener = function() end},
    raiseImplements = function() end, startCourse = function(self, route) self.course = route end,
    setMaxSpeed = function(_, speed) speedLimit = speed end,
}, {__index = AIDriveStrategyFieldWorkCourse})
local context = strategy:createConnectingPathContext()
assert(context._fieldworkBoundary.margin == 2 and not context._preferFieldworkBoundary and
        not context.ignoreFruitValue,
        'A legal headland departure must start in the body corridor, without a global soft-boundary search or crop exception')
assert(not FieldworkBoundary.contains(FieldworkBoundary.forVehicle(combine, AIUtil.getWidth(combine) + 4), 0, 0),
        'This fixture must reproduce the first-search oversized margin that the successful retry removed')
strategy:onPathfindingDoneToConnectingPathEnd(nil, true, straight)
strategy:checkWorkerOnConnectingPath()
assert(strategy.state == 'travel' and strategy.course == straight and speedLimit == nil and requests == 0,
        'The accepted path must start on its first update with a clear trailer beside the chassis, without another wait')
nearby.rootNode.x, nearby.rootNode.z = 7, 30
g_currentMission.time = 2000
strategy:checkWorkerOnConnectingPath()
assert(speedLimit == 0 and requests == 1 and strategy.connectingWorkerWaitFor == nearby,
        'The same trailer crossing the header must still trigger a clearance request and hold')
nearby.rootNode.x, nearby.rootNode.z = 8, -3
g_currentMission.time, speedLimit = 3000, nil
strategy:checkWorkerOnConnectingPath()
assert(speedLimit == nil and strategy.connectingWorkerWaitFor == nil and requests == 1,
        'Removing a real obstruction must release the accepted route on the next scan')
combine.spec_combine = nil
local otherContext = strategy:createConnectingPathContext()
assert(otherContext._fieldworkBoundary.margin == 9.5,
        'Non-combine fieldwork retains its existing implement corridor')
print('VehicleRouteConflictTest: OK')
