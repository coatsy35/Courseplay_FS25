-- Exercise production geometry, including attachment offsets, rather than mocking an occupancy answer.
MathUtil = {vector2Length = function(x, z) return math.sqrt(x * x + z * z) end}
function entityExists(node) return node ~= nil end
function getWorldTranslation(n) return n.x, 0, n.z end
function getWorldRotation(n) return 0, n.heading or 0, 0 end
function localDirectionToWorld(n, x, y, z)
    local h = n.heading or 0
    return math.cos(h) * x + math.sin(h) * z, y, -math.sin(h) * x + math.cos(h) * z
end
function localToWorld(n, x, y, z)
    local dx, dy, dz = localDirectionToWorld(n, x, y, z)
    return n.x + dx, dy, n.z + dz
end
function localToLocal(from, to, x, _, z)
    local fh, th = from.heading or 0, to.heading or 0
    local wx = from.x + math.cos(fh) * x + math.sin(fh) * z - to.x
    local wz = from.z - math.sin(fh) * x + math.cos(fh) * z - to.z
    return math.cos(th) * wx - math.sin(th) * wz, 0, math.sin(th) * wx + math.cos(th) * wz
end
-- Use the production size accessors: GIANTS reports the attached AI agent, not one physical body.
CpUtil = {try = function(fn, ...) return pcall(fn, ...) end}
dofile('scripts/ai/util/AIUtil.lua')
dofile('scripts/util/CpMathUtil.lua')
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
local detached = vehicle(7, 30, 3, 9)
detached.getAIDirectionNode, detached.getChildVehicles = nil, nil
local detachedRig = FieldworkBoundary.captureRig(detached)
assert(#detachedRig == 1 and detachedRig[1].node == detached.rootNode and detachedRig[1].box.width == 1.75,
        'Detached implements without AI or attachment APIs must remain checked obstacles, without a Lua error')
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

-- GIANTS may decompose a heading beyond 90 degrees into Euler X/Z = 180 degrees and a folded Y.
-- The old engine stub returned heading as Y at every bearing, concealing an initial attachment jump.
local foldedEuler = true
function getWorldRotation(n)
    local h = ((n.heading or 0) + math.pi) % (2 * math.pi) - math.pi
    if foldedEuler then
        if h > math.pi / 2 then return math.pi, math.pi - h, math.pi end
        if h < -math.pi / 2 then return math.pi, -math.pi - h, math.pi end
    end
    return 0, h, 0
end
local function near(a, b) return math.abs(a - b) < 0.000001 end
local function angleNear(a, b) return near((a - b + math.pi) % (2 * math.pi) - math.pi, 0) end
local function cr11(x, z, heading)
    local v = vehicle(x, z, 3.95, 10.5, heading, -0.65)
    local cutter = vehicle(x + math.sin(heading) * 4.4, z + math.cos(heading) * 4.4,
            16.6, 4, heading, 0.7)
    cutter.getAttacherVehicle = function() return v end
    v.children = {cutter}
    return v
end
-- Real CR11/FD250/NC dimensions and the logged combine bearing; the trailer pose is a nearby-clear
-- reproduction, not a complete replay of the game. The bad heading moves the header 8.44 m in a 0.25 m step.
local bearing = math.rad(171)
local rowCombine = cr11(31.4, -357.06, bearing)
local rowRoute = course({{31.4, -357.06},
    {31.4 + math.sin(bearing) * 25, -357.06 + math.cos(bearing) * 25}})
local clearTrailer = vehicle(47.5, -345, 2.62, 8.36, math.rad(60), 0.4)
local rowSweep = VehicleRouteConflict.createSweep(FieldworkBoundary.captureRig(rowCombine), rowRoute, 12)
assert(not VehicleRouteConflict.findConflict(rowSweep, FieldworkBoundary.captureRig(clearTrailer)),
        'A folded Euler heading must not create a zero-distance obstruction from a clear neighbouring trailer')
local overlap, bodies = VehicleRouteConflict.findConflict(rowSweep, FieldworkBoundary.captureRig(
        vehicle(rowCombine.children[1].rootNode.x + 6 * math.cos(bearing),
                rowCombine.children[1].rootNode.z - 6 * math.sin(bearing), 2, 2, bearing)))
assert(overlap and overlap.distance == 0 and bodies.ownIndex == 2 and bodies.otherIndex == 1 and
        bodies.own.node == rowCombine.children[1].rootNode,
        'A real initial header overlap must still stop and identify the actual conflicting body pair')

local function rotatedCourse(points, h, reverse)
    local world = {}
    for i, p in ipairs(points) do
        world[i] = {math.cos(h) * p[1] + math.sin(h) * p[2],
            -math.sin(h) * p[1] + math.cos(h) * p[2]}
    end
    return course(world, reverse)
end
local function sameSweep(a, b)
    assert(#a == #b, 'Equivalent rotations must produce the same number of route samples')
    for i, sample in ipairs(a) do
        assert(near(sample.distance, b[i].distance))
        for j, body in ipairs(sample.parts) do
            local other = b[i].parts[j]
            for _, key in ipairs({'x', 'z', 'ux', 'uz', 'vx', 'vz', 'width', 'length', 'padding'}) do
                assert(near(body[key], other[key]), 'Euler representation changed swept geometry: ' .. key)
            end
        end
    end
end
for degrees = -180, 180, 15 do
    local h = math.rad(degrees)
    local v = cr11(0, 0, h)
    for _, sign in ipairs({-1, 1}) do
        foldedEuler = true
        local rig = FieldworkBoundary.captureRig(v)
        assert(angleNear(rig[1].heading, h) and angleNear(rig[2].heading, h),
                'Every captured body must retain its true forward bearing in all quadrants')
        local x, z = rig[2].x, rig[2].z
        local dx, dz = sign * 0.25 * math.sin(h), sign * 0.25 * math.cos(h)
        FieldworkBoundary.advanceRig(rig, dx, dz, h, sign * 0.25)
        assert(near(rig[2].x - x, dx) and near(rig[2].z - z, dz),
                'The first forward/reverse quarter-metre must translate the header without a hitch jump')
        local routes = {
            rotatedCourse({{0, 0}, {0, sign * 25}}, h, sign < 0),
            rotatedCourse({{0, 0}, {0, sign * 5}, {3, sign * 12}, {8, sign * 18}}, h, sign < 0),
        }
        for _, route in ipairs(routes) do
            foldedEuler = false
            local normal = VehicleRouteConflict.createSweep(FieldworkBoundary.captureRig(v), route, 12)
            foldedEuler = true
            local folded = VehicleRouteConflict.createSweep(FieldworkBoundary.captureRig(v), route, 12)
            sameSweep(normal, folded)
        end
    end
    -- A wheeled implement with a real drawbar must keep its hitch connected across heading wrap, too.
    local tow = vehicle(0, 0, 3, 6, h)
    local th = h + math.rad(12)
    local pivot = {x = -4 * math.sin(h), z = -4 * math.cos(h), heading = th}
    local towed = vehicle(pivot.x - 6 * math.sin(th), pivot.z - 6 * math.cos(th), 3, 10, th)
    towed.spec_wheels = {}
    towed.getAttacherVehicle = function() return tow end
    towed.getActiveInputAttacherJoint = function() return {node = pivot} end
    tow.children = {towed}
    for _, sign in ipairs({-1, 1}) do
        local rig = FieldworkBoundary.captureRig(tow)
        local beforeX, beforeZ = rig[2].x, rig[2].z
        FieldworkBoundary.advanceRig(rig, sign * 0.25 * math.sin(h), sign * 0.25 * math.cos(h),
                h + sign * 0.01, sign * 0.25)
        local body, parent = rig[2], rig[1]
        local childX = body.x + math.cos(body.heading) * body.hx + math.sin(body.heading) * body.hz
        local childZ = body.z - math.sin(body.heading) * body.hx + math.cos(body.heading) * body.hz
        local parentX = parent.x + math.cos(parent.heading) * body.px + math.sin(parent.heading) * body.pz
        local parentZ = parent.z - math.sin(parent.heading) * body.px + math.cos(parent.heading) * body.pz
        assert(near(childX, parentX) and near(childZ, parentZ) and
                MathUtil.vector2Length(body.x - beforeX, body.z - beforeZ) < 0.5,
                'Forward/reverse articulated motion must stay continuous and preserve the common hitch')
    end
end
print('VehicleRouteConflict heading, continuity and Euler-equivalence regressions: OK')

-- Search context -> completed-route validation -> live movement, with production geometry and size accessors.
-- The GIANTS engine and course container are supplied here; no boundary/footprint/occupancy result is mocked.
function CpObject(base) return setmetatable({}, {__index = base}) end
AIDriveStrategyCourse = {}
AIDriveStrategyFieldCourse = {}
VariableWorkWidth = {}
Utils = {overwrittenFunction = function(_, fn) return fn end}
dofile('scripts/ai/strategies/AIDriveStrategyFieldWorkCourse.lua')
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
local requests, speedLimit, geometryLogs = 0, nil, 0
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
    connectingPathStartIx = 722, debug = function(_, format)
        if format:find('Live connector hold', 1, true) then geometryLogs = geometryLogs + 1 end
    end,
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
assert(speedLimit == 0 and requests == 1 and strategy.connectingWorkerWaitFor == nearby and geometryLogs == 1,
        'The same trailer crossing the header must still trigger a clearance request and hold')
g_currentMission.time = 2500
strategy:checkWorkerOnConnectingPath()
assert(geometryLogs == 1, 'Between-scan holds must not repeat the body diagnostics')
g_currentMission.time = 3000
strategy:checkWorkerOnConnectingPath()
assert(geometryLogs == 1, 'Repeated scans of the same blocking body pair must not flood diagnostics')
nearby.rootNode.x, nearby.rootNode.z = 0, 0
g_currentMission.time = 4000
strategy:checkWorkerOnConnectingPath()
assert(geometryLogs == 2 and speedLimit == 0,
        'Changing from a header obstruction to a chassis obstruction must identify the new body pair')
nearby.rootNode.x, nearby.rootNode.z = 8, -3
g_currentMission.time, speedLimit = 5000, nil
strategy:checkWorkerOnConnectingPath()
assert(speedLimit == nil and strategy.connectingWorkerWaitFor == nil and requests == 3,
        'Removing a real obstruction must release the accepted route on the next scan')
nearby.rootNode.x, nearby.rootNode.z = 7, 30
g_currentMission.time = 6000
strategy:checkWorkerOnConnectingPath()
assert(geometryLogs == 3 and speedLimit == 0, 'A renewed hold must report geometry again after a clear scan')
nearby.rootNode.x, nearby.rootNode.z = 8, -3
g_currentMission.time, speedLimit = 7000, nil
strategy:checkWorkerOnConnectingPath()
combine.spec_combine = nil
local otherContext = strategy:createConnectingPathContext()
assert(otherContext._fieldworkBoundary.margin == 9.5,
        'Non-combine fieldwork retains its existing implement corridor')
-- The reproduced bearing must also pass the real live movement gate, not merely a standalone SAT test.
clearTrailer.getCpDriveStrategy = nearby.getCpDriveStrategy
g_currentMission.vehicleSystem.vehicles = {clearTrailer}
rowRoute.copy = function() return rowRoute end
rowRoute.getCurrentWaypointIx = function() return 1 end
rowRoute.getNextWaypointIxWithinDistance = function() return 2 end
strategy.vehicle, strategy.course = rowCombine, rowRoute
g_currentMission.time, speedLimit = 8000, nil
strategy:checkWorkerOnConnectingPath()
assert(speedLimit == nil and strategy.connectingWorkerWaitFor == nil and requests == 4,
        'The combine must proceed towards row entry immediately with the distant trailer clear')
print('VehicleRouteConflictTest: OK')

-- End-to-end connector dispatch: real context/boundary/rig/sweep/clearance decisions. The course
-- container, engine transforms and driver commands are supplied; no occupancy answer is stubbed.
do
    local function route(points)
        local r = course(points)
        function r:getLength()
            local distance = 0
            for i = 2, #points do
                distance = distance + MathUtil.vector2Length(points[i][1] - points[i - 1][1],
                        points[i][2] - points[i - 1][2])
            end
            return distance
        end
        function r:getCurrentWaypointIx() return 1 end
        function r:isLastWaypointIx(ix) return ix == #points end
        function r:getNextWaypointIxWithinDistance(ix, distance)
            for i = ix + 1, #points do
                distance = distance - MathUtil.vector2Length(points[i][1] - points[i - 1][1],
                        points[i][2] - points[i - 1][2])
                if distance <= 0 then return i end
            end
            return #points
        end
        function r:copy(_, first, last)
            local copy = {}
            for i = first or 1, last or #points do copy[#copy + 1] = points[i] end
            return route(copy)
        end
        function r:isOnConnectingPath(ix) return ix >= 2 and ix < #points end
        function r:isTurnStartAtIx() return false end
        function r:shouldUsePathfinderToNextWaypoint() return false end
        return r
    end
    Course = function(_, points)
        local converted = {}
        for i, p in ipairs(points) do converted[i] = {p.x, p.z} end
        return route(converted)
    end
    RowStartOrFinishContext = function() return {getTurnEndNodeAndOffsets = function() return {}, 0 end} end
    local function departure(points, obstacles, v)
        v = v or cr11(0, 0, 0)
        v.spec_combine = {}
        v.cpGetFieldPolygon = v.cpGetFieldPolygon or function()
            return {{x = -100, z = -100}, {x = 100, z = -100}, {x = 100, z = 800}, {x = -100, z = 800}}
        end
        local s = setmetatable({vehicle = v, turningRadius = 4.7, workWidth = 15.2,
            settings = {avoidFruit = {getValue = function() return true end}},
            states = {WORKING = 'work', TURNING = 'turn', DRIVING_TO_WORK_START_WAYPOINT = 'travel',
                WAITING_FOR_PATHFINDER = 'search'}, state = 'turn', debug = function() end,
            getWorkWidth = function() return 15.2 end,
            getAllowReversePathfinding = function() return true end,
            getFrontAndBackMarkers = function() return 5.6, 5 end,
            getTurnEndSideOffset = function() return 0 end, getTurnEndForwardOffset = function() return 0 end,
            raiseImplements = function() end,
            ppc = {setShortLookaheadDistance = function() end, getRelevantWaypointIx = function() return 1 end},
            proximityController = {unregisterBlockingObjectListener = function() end,
                registerBlockingObjectListener = function() end},
            fieldWorkCourse = route(points), searches = 0, speed = nil, moves = 0,
            startCourse = function(self, c) self.course = c end,
            setMaxSpeed = function(self, speed) self.speed = speed end,
            pathfinderController = {registerListeners = function() end},
        }, {__index = AIDriveStrategyFieldWorkCourse})
        s.pathfinderController.findPathToNode = function() s.searches = s.searches + 1 end
        s.pathfinderController.findPathToWaypoint = s.pathfinderController.findPathToNode
        for _, other in ipairs(obstacles) do
            other.getCpDriveStrategy = function() return {
                getCombineToUnload = function() return nil end,
                isAvailableForStaging = function() return true end,
                isConnectorClearancePending = function() return true end,
                requestToMoveOutOfWay = function() s.moves = s.moves + 1 end,
            } end
        end
        g_currentMission = {time = 1000, vehicleSystem = {vehicles = obstacles}}
        s.course = s.fieldWorkCourse
        return s
    end
    local points = {{0, -5}}
    for z = 0, 700, 10 do points[#points + 1] = {0, z} end
    points[#points + 1] = {0, 705}
    local clear = departure(points, {vehicle(12, -3, 3, 5), vehicle(0, 270, 3, 9)})
    clear.connectingPathRejoinIx, clear.connectingPathWorkerDetourAt, clear.connectingPathWorkerLastSearchAt = 5, 60000, 1000
    clear:startConnectingPath(1)
    assert(clear.state == 'travel' and clear.searches == 0 and clear.speed == nil and clear.moves == 0,
            'A clear departure with an adjacent rig and a distant trailer must launch without a timer or search')
    assert(clear.connectingPathRejoinIx == nil and clear.connectingPathWorkerDetourAt == nil and
            clear.connectingPathWorkerLastSearchAt == nil,
            'A clear generated departure must clear stale detour targets and retry timers')
    local remote = departure(points, {vehicle(0, 80, 3, 9)})
    remote:startConnectingPath(1)
    assert(remote.state == 'travel' and remote.searches == 0 and remote.speed == nil and remote.moves == 1,
            'A trailer inside the scout horizon must receive notice while the combine approaches')
    local worker = cr11(0, 100, 0)
    worker.spec_combine = {}
    worker.lastSpeedReal = 0.003
    worker.getIsCpFieldWorkActive = function() return true end
    local crossing = departure(points, {worker})
    crossing.fieldWorkerProximityController = {hasSameCourse = function() return true end,
        getPhysicalTurnClearance = function() return 50 end}
    crossing:startConnectingPath(1)
    assert(crossing.state == 'search' and crossing.searches == 1,
            'A genuine combine crossing must still use checked local detour planning')
    worker.rootNode.z = 300
    for _, child in ipairs(worker.children) do child.rootNode.z = child.rootNode.z + 200 end
    local remoteWorker = departure(points, {worker})
    remoteWorker.fieldWorkerProximityController = crossing.fieldWorkerProximityController
    remoteWorker:startConnectingPath(1)
    assert(remoteWorker.state == 'travel' and remoteWorker.searches == 0 and remoteWorker.speed == nil,
            'A worker 300 m along the connector must not hold a clear departure for a global detour search')
    worker.rootNode.z = 30
    for _, child in ipairs(worker.children) do child.rootNode.z = child.rootNode.z - 270 end
    g_currentMission.time = 3000
    remoteWorker.nextConnectingWorkerCheckAt = nil
    local recoveries = 0
    remoteWorker.startBlockedConnectorRecovery = function(self)
        assert(self.connectorRecoveryActive and self.connectorRecoveryResumeIx,
                'The existing checked local recovery must own the detour')
        recoveries = recoveries + 1
    end
    remoteWorker:checkWorkerOnConnectingPath()
    assert(remoteWorker.speed == 0, 'The same remote worker must brake the header when it enters the local horizon')
    g_currentMission.time = 9000
    remoteWorker:checkWorkerOnConnectingPath()
    assert(recoveries == 1, 'A persistent nearby combine must receive a checked local detour, not indefinite waiting')
    for _, blocker in ipairs({vehicle(0, 25, 3, 9), vehicle(6, 4.4, 3, 3)}) do
        local held = departure(points, {blocker})
        held.nextConnectingWorkerCheckAt = 99999
        held:startConnectingPath(1)
        assert(held.state == 'travel' and held.searches == 0 and held.speed == 0 and held.moves == 1,
                'Accepting a generated route must brake for near/header obstruction in that same update')
        local accepted = held.course
        blocker.rootNode.x = 30
        held.speed, g_currentMission.time = nil, 2000
        held:checkWorkerOnConnectingPath()
        assert(held.speed == nil and held.course == accepted and held.searches == 0,
                'Clearance must release the existing route without another path search')
    end
    local harvesting = departure(points, {vehicle(0, 60, 3, 9)})
    harvesting.state = 'work'
    harvesting.course.isOnConnectingPath = function(_, ix) return ix >= 6 and ix < #points end
    local workingRoute, turnContext = harvesting.course, {}
    harvesting.turnContext = turnContext
    harvesting.calculateTightTurnOffset = function() end
    harvesting:onWaypointChange(1, workingRoute)
    assert(harvesting.moves == 1 and harvesting.state == 'work' and harvesting.speed == nil and
            harvesting.course == workingRoute and harvesting.turnContext == turnContext and harvesting.searches == 0,
            'Pre-row-end clearance must preserve harvesting, PPC course and turn context')
    harvesting.course.isTurnStartAtIx = function(_, ix) return ix == 2 end
    harvesting.course.isOnConnectingPath = function(_, ix) return ix >= 4 end
    harvesting:scoutUpcomingConnectingPath(1)
    assert(harvesting.moves == 1, 'An intervening turn must retain ownership of its own clearance geometry')

    -- One-waypoint recovery exhaustion is a pending join, never the end of fieldwork. Both an active
    -- asynchronous search and a scheduled retry retain ownership; the replacement route still hands over.
    local pending = departure(points, {})
    pending.connectingPathStartIx, pending.connectorRecoveryActive = 1, true
    pending.course, pending.state = route({{0, 0}}), 'search'
    local finished, handovers = 0, 0
    pending.finishFieldWork = function() finished = finished + 1 end
    pending:onWaypointPassed(1, pending.course)
    pending.connectingPathRetryAt = 31000
    pending:onWaypointPassed(1, pending.course)
    assert(finished == 0 and pending.state == 'search' and pending.connectingPathRetryAt == 31000,
            'PPC reaching the temporary endpoint must neither finish the job nor erase its retry')
    local steeringParameters = AIUtil.getSteeringParameters
    AIUtil.getSteeringParameters = function() return false, 6 end
    pending.activeConnectingPathCourse = route({{0, 0}})
    pending.retreatFromBlockingTurningWorker = function() return false end
    pending.turnContext = RowStartOrFinishContext()
    pending.pathfinderController.findPathToNode = function(controller, context)
        pending:onPathfindingFailedToConnectingPathEnd(controller, context, true, 1)
    end
    pending.connectingPathRetryAt = nil
    pending:startBlockedConnectorRecovery()
    pending:onWaypointPassed(1, pending.course)
    assert(finished == 0 and pending.state == 'search' and pending.connectingPathRetryAt == 31000,
            'Synchronous failure followed by PPC endpoint notification must preserve the real recovery retry')
    AIUtil.getSteeringParameters = steeringParameters
    pending.state = 'travel'
    pending.workStarter = {onLastWaypoint = function() handovers = handovers + 1 end}
    pending:onWaypointPassed(1, pending.course)
    assert(handovers == 1 and finished == 0, 'The replacement approach must still own its final waypoint')
    pending.state, pending.connectingPathStartIx = 'work', nil
    pending:onLastWaypointPassed()
    assert(finished == 1, 'Normal fieldwork completion must remain enabled')

    -- Build 2968 savegame20: CR11/318, original waypoints 660..907. Actual connector 696..906 is
    -- 211 points/709 m. Field11's static map outline is used; CP's live detected polygon is not persisted.
    -- Logged trailer/root positions are snapshots; drawbar poses below are reconstructed approximations.
    local recordedPoints = {
        {-384.17, -274.96}, {-386.78, -275.37}, {-389.61, -275.81}, {-392.38, -276.23},
        {-395.05, -276.61}, {-397.74, -277.02}, {-400.49, -277.44}, {-403.22, -277.86},
        {-405.93, -278.26}, {-408.64, -278.67}, {-411.36, -279.08}, {-414.09, -279.49},
        {-416.80, -279.90}, {-419.52, -280.31}, {-422.24, -280.73}, {-424.96, -281.13},
        {-427.68, -281.55}, {-430.97, -282.05}, {-434.26, -282.53}, {-433.56, -285.95},
        {-432.85, -289.38}, {-432.38, -292.36}, {-431.92, -294.92}, {-431.43, -297.62},
        {-430.94, -300.32}, {-430.45, -303.03}, {-429.46, -308.44}, {-428.97, -311.15},
        {-428.48, -313.86}, {-427.99, -316.56}, {-427.50, -319.26}, {-427.01, -321.98},
        {-426.52, -324.68}, {-425.54, -330.09}, {-425.05, -332.79}, {-424.56, -335.50},
        {-439.49, -335.41}, {-439.98, -332.70}, {-440.96, -327.30}, {-441.45, -324.58},
        {-441.94, -321.88}, {-442.43, -319.17}, {-442.92, -316.48}, {-443.41, -313.76},
        {-443.90, -311.05}, {-444.88, -305.64}, {-445.37, -302.94}, {-445.86, -300.23},
        {-446.35, -297.52}, {-446.84, -294.81}, {-447.28, -292.01}, {-447.86, -289.23},
        {-448.42, -286.73}, {-448.72, -284.55}, {-448.87, -282.46}, {-448.67, -275.55},
        {-445.76, -270.98}, {-441.74, -268.94}, {-438.07, -268.27}, {-435.31, -267.86},
        {-432.59, -267.44}, {-429.87, -267.03}, {-427.15, -266.62}, {-424.43, -266.21},
        {-421.71, -265.80}, {-418.99, -265.39}, {-416.27, -264.98}, {-413.55, -264.58},
        {-410.83, -264.17}, {-408.11, -263.75}, {-405.40, -263.36}, {-402.67, -262.94},
        {-399.95, -262.52}, {-397.24, -262.11}, {-394.53, -261.71}, {-391.80, -261.30},
        {-389.04, -260.88}, {-386.36, -260.46}, {-383.71, -260.07}, {-380.91, -259.69},
        {-378.06, -259.23}, {-376.16, -258.88}, {-373.45, -258.40}, {-370.74, -257.92},
        {-365.33, -256.95}, {-359.91, -255.98}, {-354.50, -255.01}, {-351.79, -254.53},
        {-349.08, -254.05}, {-343.67, -253.08}, {-338.26, -252.11}, {-335.55, -251.63},
        {-332.84, -251.15}, {-330.13, -250.66}, {-327.42, -250.18}, {-324.61, -249.74},
        {-321.84, -249.18}, {-319.43, -248.62}, {-316.75, -248.00}, {-314.07, -247.37},
        {-311.39, -246.75}, {-308.71, -246.12}, {-303.36, -244.87}, {-298.00, -243.63},
        {-292.65, -242.38}, {-289.98, -241.75}, {-287.30, -241.13}, {-281.93, -239.88},
        {-276.58, -238.63}, {-273.90, -238.01}, {-271.23, -237.38}, {-268.55, -236.76},
        {-265.87, -236.14}, {-263.19, -235.46}, {-260.50, -234.88}, {-257.65, -234.32},
        {-254.86, -233.55}, {-253.70, -233.19}, {-251.09, -232.32}, {-248.46, -231.44},
        {-245.85, -230.57}, {-243.25, -229.70}, {-240.64, -228.83}, {-238.03, -227.96},
        {-232.81, -226.22}, {-230.20, -225.35}, {-227.59, -224.48}, {-222.38, -222.75},
        {-219.77, -221.88}, {-217.16, -221.01}, {-211.94, -219.27}, {-209.33, -218.40},
        {-206.72, -217.53}, {-201.50, -215.79}, {-198.90, -214.92}, {-196.29, -214.05},
        {-193.68, -213.18}, {-191.07, -212.31}, {-185.85, -210.57}, {-183.24, -209.70},
        {-180.63, -208.83}, {-178.02, -207.96}, {-175.42, -207.09}, {-172.81, -206.22},
        {-170.20, -205.35}, {-167.59, -204.48}, {-164.98, -203.61}, {-159.76, -201.87},
        {-157.15, -201.00}, {-154.54, -200.14}, {-151.94, -199.27}, {-149.34, -198.40},
        {-144.12, -196.66}, {-141.50, -195.79}, {-138.89, -194.92}, {-136.28, -194.05},
        {-133.67, -193.18}, {-131.06, -192.31}, {-128.45, -191.44}, {-123.14, -189.67},
        {-118.17, -188.38}, {-114.09, -188.63}, {-109.26, -191.43}, {-107.12, -195.17},
        {-106.25, -198.81}, {-105.68, -201.44}, {-105.22, -203.95}, {-104.44, -208.79},
        {-103.56, -214.22}, {-102.68, -219.65}, {-101.81, -225.08}, {-101.37, -227.79},
        {-100.93, -230.51}, {-100.05, -235.94}, {-99.61, -238.65}, {-99.17, -241.36},
        {-98.73, -244.08}, {-98.29, -246.79}, {-97.41, -252.22}, {-96.54, -257.65},
        {-95.66, -263.08}, {-94.78, -268.51}, {-93.90, -273.94}, {-93.02, -279.37},
        {-92.15, -284.80}, {-91.27, -290.23}, {-90.39, -295.67}, {-89.95, -298.37},
        {-89.51, -301.09}, {-88.63, -306.52}, {-87.76, -311.95}, {-86.88, -317.38},
        {-86.44, -320.09}, {-86.00, -322.80}, {-85.56, -325.52}, {-85.12, -328.26},
        {-84.69, -330.96}, {-84.25, -333.65}, {-83.79, -336.38}, {-83.37, -339.10},
        {-82.96, -341.82}, {-82.49, -344.52}, {-81.98, -347.24}, {-81.61, -349.97},
        {-81.27, -352.96}, {-80.61, -355.86}, {-79.70, -358.94}, {-78.94, -361.77},
        {-77.82, -364.84}, {-76.55, -367.88}, {-75.33, -370.40}, {-74.39, -372.98},
        {-73.39, -375.94}, {-71.57, -378.70}, {-69.98, -380.60}, {-68.03, -382.24},
        {-66.27, -383.48}, {-64.35, -384.30}, {-60.20, -385.61}, {-57.66, -386.02},
        {-53.99, -386.81}, {-52.12, -386.95}, {-50.10, -386.72}, {-46.37, -385.95},
        {-43.53, -385.34}, {-40.74, -384.52}, {-38.01, -383.58}, {-35.28, -382.63},
        {-32.67, -381.72}, {-30.08, -380.81}, {-27.48, -379.91}, {-24.88, -379.00},
        {-19.70, -377.18}, {-17.11, -376.28}, {-14.50, -375.37}, {-11.90, -374.46},
        {-9.31, -373.55}, {-4.39, -371.84}, {-1.46, -371.00}, {1.89, -369.56},
        {5.45, -367.62}, {7.85, -366.28}, {10.25, -364.95}, {12.66, -363.61},
        {15.06, -362.27}, {19.64, -359.74}, {22.96, -358.11}, {34.27, -375.47},
    }
    local recordedOutline = {
        {x = -390.85300, z = -603.38700}, {x = -392.26245, z = -614.95330}, {x = -396.88901, z = -630.14840},
        {x = -402.27880, z = -643.08160}, {x = -405.96080, z = -656.71090}, {x = -405.96080, z = -991.21700},
        {x = -401.36260, z = -1001.71700}, {x = -396.32358, z = -1005.29300}, {x = -388.89164, z = -1007.07600},
        {x = -74.89300, z = -1007.07600}, {x = -61.88800, z = -1004.65800}, {x = -50.58200, z = -997.78300},
        {x = -40.17000, z = -994.11900}, {x = -13.71700, z = -989.10700}, {x = -3.64000, z = -986.44000},
        {x = 7.78800, z = -978.32900}, {x = 24.58100, z = -960.21900}, {x = 30.60400, z = -952.39800},
        {x = 34.28200, z = -944.76700}, {x = 36.44500, z = -932.88500}, {x = 34.72100, z = -923.88500},
        {x = 10.49200, z = -871.24400}, {x = -0.57600, z = -839.99700}, {x = -5.41800, z = -821.06700},
        {x = -5.50700, z = -811.99600}, {x = -2.48500, z = -806.21700}, {x = 4.83800, z = -798.57600},
        {x = 58.81700, z = -745.98500}, {x = 109.22100, z = -686.29410}, {x = 124.42800, z = -661.26500},
        {x = 129.52700, z = -636.64290}, {x = 127.46600, z = -567.58620}, {x = 127.46600, z = -419.51100},
        {x = 125.92600, z = -400.19600}, {x = 118.59900, z = -368.15100}, {x = 111.35500, z = -352.29500},
        {x = 106.42500, z = -343.05800}, {x = 96.76700, z = -322.80100}, {x = 93.91000, z = -319.88600},
        {x = 81.70900, z = -314.92600}, {x = 74.58200, z = -314.33000}, {x = 66.06000, z = -316.46100},
        {x = 60.00500, z = -319.95700}, {x = 40.89600, z = -335.31800}, {x = 19.77400, z = -352.89700},
        {x = 1.41100, z = -362.68200}, {x = -47.78200, z = -380.25200}, {x = -57.04300, z = -380.63300},
        {x = -66.06100, z = -376.38700}, {x = -70.60000, z = -367.46500}, {x = -74.36100, z = -355.45500},
        {x = -100.44800, z = -194.21600}, {x = -101.91300, z = -188.44100}, {x = -109.18600, z = -182.87400},
        {x = -114.60600, z = -181.69000}, {x = -121.57300, z = -182.08300}, {x = -150.90500, z = -192.35900},
        {x = -202.96300, z = -209.90600}, {x = -249.85100, z = -225.51200}, {x = -333.73220, z = -245.04400},
        {x = -380.90720, z = -252.89400}, {x = -441.15640, z = -262.12500}, {x = -449.79620, z = -264.47800},
        {x = -453.14330, z = -266.99400}, {x = -456.31380, z = -273.63800}, {x = -455.37290, z = -283.46300},
        {x = -416.88520, z = -495.98500}, {x = -410.91840, z = -521.12990}, {x = -408.90740, z = -526.43310},
        {x = -404.19750, z = -533.41640}, {x = -392.80936, z = -546.22120}, {x = -390.85300, z = -553.85610},
    }
    local lead = cr11(-425.41, -330.86, math.rad(169))
    lead.cpGetFieldPolygon = function() return recordedOutline end
    local function tractorTrailer(x, z, heading, trailerHeading)
        local v = vehicle(x, z, 2.8, 5.4, heading)
        local th = trailerHeading or heading
        local trailer = vehicle(x - math.sin(th) * 6, z - math.cos(th) * 6, 2.62, 8.36, th, 0.4)
        trailer.getAttacherVehicle = function() return v end
        v.children = {trailer}
        return v
    end
    local rigs = {tractorTrailer(-451.06, -329.05, math.rad(170)),
        tractorTrailer(-183.79, -210.19, math.rad(115), math.rad(63))}
    local recorded = departure(recordedPoints, rigs, lead)
    local startedAt = os.clock()
    recorded.fieldWorkCourse.isOnConnectingPath = function(_, ix) return ix >= 37 and ix < #recordedPoints end
    recorded:startConnectingPath(36)
    local duration = os.clock() - startedAt
    assert(recorded.workStarterCourse:getNumberOfWaypoints() == 211 and
            recorded.workStarterCourse:getLength() > 709 and recorded.workStarterCourse:getLength() < 710,
            'The fixture must retain the complete recorded connector rather than a simplified straight line')
    assert(recorded.state == 'travel' and recorded.searches == 0 and recorded.connectingPathRetryAt == nil,
            'The recorded connector must be retained immediately instead of waiting then searching 475 m to its end')
    assert(duration < 2, 'The recorded dispatch must complete without a pathfinder iteration budget')
    print(string.format('Recorded 709 m connector: %.3f s, %d searches, speed limit %s, %d clearance requests',
            duration, recorded.searches, tostring(recorded.speed), recorded.moves))
    local p, nextP = recordedPoints[16], recordedPoints[17]
    local earlyLead = cr11(p[1], p[2], math.atan2(nextP[1] - p[1], nextP[2] - p[2]))
    earlyLead.cpGetFieldPolygon = function() return recordedOutline end
    local early = departure(recordedPoints, rigs, earlyLead)
    early.fieldWorkCourse.isOnConnectingPath = recorded.fieldWorkCourse.isOnConnectingPath
    early.state = 'work'
    early.calculateTightTurnOffset = function() end
    early:onWaypointChange(16, early.fieldWorkCourse)
    assert(early.moves == 1 and early.state == 'work' and early.speed == nil and early.searches == 0 and
            early.course == early.fieldWorkCourse,
            'The recorded row must request nearby-trailer clearance before finishing, without interrupting cutting')
end
print('Connector departure, early clearance and recovery handover regressions: OK')

-- The trailer must use the same physical clearance decision as the combine, not the broad
-- staging target margin. Exercise its real request entry point and reverse-first dispatch.
dofile('scripts/ai/strategies/AIDriveStrategyUnloadCombine.lua')
do
    local harvester = vehicle(0, 0, 4, 8)
    local cutter = vehicle(0, 6, 15, 2)
    cutter.getAttacherVehicle = function() return harvester end
    harvester.children = {cutter}
    local driver = {turningRadius = 12, getWorkWidth = function() return 15 end}
    harvester.getCpDriveStrategy = function() return driver end
    local route = course({{0, 0}, {0, 90}})
    route.copy = function(self) return self end
    local parked = vehicle(12, 20, 3, 5)
    local moves, holds, searches = 0, 0, 0
    local unloader = setmetatable({vehicle = parked, debug = function() end,
        getHarvesterTurnClearanceDistance = function() return 30 end,
        holdAtStandbyPosition = function() holds = holds + 1 end,
        startConnectorReverseEscape = function() moves = moves + 1; return true end,
        findStandbyClearanceGoal = function() searches = searches + 1; error('Reverse must be tried first') end,
    }, {__index = AIDriveStrategyUnloadCombine})
    unloader:startConnectorClearance(harvester, route)
    assert(holds == 1 and moves == 0 and searches == 0,
            'A parked trailer beside the real header sweep must remain still despite the wider staging margin')
    parked.rootNode.x = 7
    unloader:startConnectorClearance(harvester, route)
    assert(moves == 1 and searches == 0,
            'A real header obstruction must immediately try checked reversing before any forward goal search')
    parked.rootNode.x = 12
    assert(not unloader:isRigClearOfConnectorClearance(unloader.connectorClearance),
            'A cached blocked result may retain the hold briefly, but must never authorise unsafe clearance')
    g_currentMission.time = g_currentMission.time + 250
    assert(unloader:isRigClearOfConnectorClearance(unloader.connectorClearance),
            'Physical clearance must release the trailer without forcing an oversized departure')
end
print('Parked trailer physical clearance and reverse-first dispatch: OK')

-- No headland route is needed to dispatch clearance from the real departure footprint. Run the
-- turn caller, live worker scan and unloader request together; only the final reverse driving is adapted.
CpDebug = {DBG_TURN = 1}
dofile('scripts/ai/turns/AITurn.lua')
do
    local harvester = vehicle(0, 0, 4, 8)
    local cutter = vehicle(0, 6, 15, 2)
    cutter.getAttacherVehicle = function() return harvester end
    harvester.children = {cutter}
    local parked = vehicle(7, 6, 3, 5, math.pi / 2)
    local reversed, searches = 0, 0
    local driver = setmetatable({vehicle = harvester, turningRadius = 12, debug = function() end,
        getWorkWidth = function() return 15 end, getFrontAndBackMarkers = function() return 4, -4 end,
        getAllowReversePathfinding = function() return true end, isTurnOnFieldActive = function() return true end,
        setPathfindingDoneCallback = function() end,
    }, {__index = AIDriveStrategyFieldWorkCourse})
    harvester.getCpDriveStrategy = function() return driver end
    local unloader = setmetatable({vehicle = parked, debug = function() end, states = {},
        isAvailableForStaging = function() return true end,
        getHarvesterTurnClearanceDistance = function() return 30 end,
        startConnectorReverseEscape = function() reversed = reversed + 1; return true end,
    }, {__index = AIDriveStrategyUnloadCombine})
    parked.getCpDriveStrategy = function() return unloader end
    g_currentMission.vehicleSystem = {vehicles = {harvester, parked}}
    AIDriveStrategyCombineCourse = {isActiveCpCombine = function(v) return v == harvester end}
    Course = {createStraightForwardCourse = function(_, length)
        assert(length == 0.5)
        local route = course({{0, 0}, {0, length}})
        route.copy = function(self) return self end
        return route
    end}
    PathfinderUtil = {findPathForTurn = function()
        searches = searches + 1; return {}, {done = false}
    end}
    local turn = setmetatable({vehicle = harvester, driveStrategy = driver,
        isDistantPathfinderTurn = true, turningRadius = 12, workWidth = 15,
        states = {WAITING_FOR_TURN_PATH = 'clearance', WAITING_FOR_PATHFINDER = 'search'},
        turnContext = {getTurnEndNodeAndOffsets = function() return {}, 0 end,
            getBoundaryId = function() return nil end},
        debug = function() end, getRaisedHeaderTurnBoundary = function() return nil end,
    }, {__index = CourseTurn})
    turn:generatePathfinderTurn(true)
    assert(reversed == 1 and searches == 0 and turn.state == 'clearance' and
            unloader.connectorClearance.course:getNumberOfWaypoints() == 2,
            'A transverse parked rig at the header must receive an immediate reverse request without a headland course')
    parked.rootNode.x = 12
    g_currentMission.time = turn.distantTurnPathRetryAt
    turn:updateDistantTurnPathRetry()
    assert(reversed == 1 and searches == 1 and turn.state == 'search',
            'A rig which has reversed outside the physical departure must remain parked while normal pathfinding resumes')
end
print('No-headland physical departure clearance: OK')
