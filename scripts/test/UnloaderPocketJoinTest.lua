-- Recorded 28 September failure: a parked tractor completed a valid approach, then jumped onto
-- the combine's earlier waypoint with 14.2 m cross-track error and eventually stopped off course.
function CpObject() return {} end
AIDriveStrategyCourse = {}
CpUtil = {getName = function(vehicle) return vehicle.name end}
MathUtil = {vector2Length = function(x, z) return math.sqrt(x * x + z * z) end}
function getWorldTranslation(node) return node.x, 0, node.z end
function localDirectionToWorld(node) return math.sin(node.heading), 0, math.cos(node.heading) end
dofile('scripts/ai/strategies/AIDriveStrategyUnloadCombine.lua')

local node = {x = 14.2, z = 15, heading = 0}
local flags = {}
local course = {}
function course:getNumberOfWaypoints() return 10 end
function course:getWaypointPosition(ix) return 0, 0, (ix - 1) * 10 end
function course:getWaypoint(ix) return {x = 0, z = (ix - 1) * 10, dx = 0, dz = 1, ix = ix} end
function course:getPreviousWaypointIxWithinDistance(ix, distance)
    for i = ix - 1, 1, -1 do if (ix - i) * 10 > distance then return i end end
end
function course:isTurnStartAtIx(ix) return flags[ix] == 'turnStart' end
function course:isTurnEndAtIx(ix) return flags[ix] == 'turnEnd' end
function course:isReverseAt(ix) return flags[ix] == 'reverse' end
function course:isOnConnectingPath(ix) return flags[ix] == 'connector' end
function course:setOffset(x, z) assert(x == 0 and z == 0) end
local waiting = false
local combine = {name = 'CR11', getCpDriveStrategy = function() return {
    isWaitingForUnload = function() return waiting end,
} end}
UnloaderCoordinator = {getStandbyDistance = function() return 20 end}
local referenceIx, followedIx, pathTarget, released, unloading = 6
local strategy = setmetatable({
    vehicle = {getAIDirectionNode = function() return node end}, combineToUnload = combine,
    states = {WAITING_FOR_PATHFINDER = {}, FOLLOWING_COMBINE_TO_POCKET = {}, DRIVING_TO_MOVING_COMBINE = {}},
    debug = function() end,
    setupFollowCourse = function() return course, referenceIx end,
    startCourse = function(_, value, ix) assert(value == course); followedIx = ix end,
    startPathfindingToMovingCombine = function(_, target, x, z) assert(x == 0 and z == 0); pathTarget = target end,
    startWaitingForSomethingToDo = function() released = true end,
    startUnloadingCombine = function() unloading = true end,
    setNewState = function(self, state) self.state = state end,
}, {__index = AIDriveStrategyUnloadCombine})

strategy:startFollowingCombineToPocket()
assert(pathTarget and pathTarget.ix == 3 and not followedIx and not released and
        strategy.state == strategy.states.WAITING_FOR_PATHFINDER and strategy.combineToUnload == combine,
        'A 14.2 m sideways handover must retain the call and pathfind onto a travelled segment')

-- Exercise the actual last-waypoint handover after the checked approach. The combine has moved on;
-- PPC must start on the segment under the tractor, not rewind according to the combine's new position.
node.x, node.z, referenceIx = 0, 25, 8
pathTarget = nil
strategy.state = strategy.states.DRIVING_TO_MOVING_COMBINE
strategy.approachingPocketStandby = true
strategy:onLastWaypointPassed()
assert(followedIx == 3 and not pathTarget and not strategy.approachingPocketStandby and
        strategy.state == strategy.states.FOLLOWING_COMBINE_TO_POCKET,
        'A checked join must hand over from the tractor position even after the combine advances')

node.z, followedIx = 20, nil
strategy:startFollowingCombineToPocket()
assert(followedIx == 3 and not pathTarget,
        'An exact endpoint with no extension must join the following normal segment without a repeated search')
node.x, node.z = 14.2, 65
followedIx, pathTarget = nil, nil
strategy:startFollowingCombineToPocket()
assert(pathTarget and pathTarget.z < 70 - 20,
        'An unaligned rig near the combine must join behind the configured standby gap, not at its current waypoint')
node.x, node.z = 0, 25

followedIx, pathTarget = nil, nil
node.heading = math.pi
strategy:startFollowingCombineToPocket()
assert(pathTarget and not followedIx, 'An opposite-facing tractor needs a checked alignment path')
node.heading = 0
for ix = 1, 10 do flags[ix] = 'connector' end
released, pathTarget = false, nil
strategy:startFollowingCombineToPocket()
assert(released and not pathTarget, 'No normal travelled segment must release the call without stopping the job')
flags = {}
flags[3] = 'reverse'
local ix = strategy:getPocketFollowJoin(course, referenceIx)
assert(ix ~= 2 and ix ~= 3, 'A reverse segment must never be selected for a forward pocket-course join')
flags[3] = 'turnStart'
ix = strategy:getPocketFollowJoin(course, referenceIx)
assert(ix ~= 2 and ix ~= 3, 'A turn marker must not be selected as a direct pocket-course join')

waiting, unloading, pathTarget = true, false, nil
strategy:startFollowingCombineToPocket()
assert(unloading and not pathTarget, 'A pocket becoming ready during approach must go straight to the pipe approach')

-- The shared moving-target pathfinder normally ignores the served combine for pipe alignment.
-- A pocket-course join must include it in collision checks, alongside the other combine and trailers.
local ignored
PathfinderContext = function()
    local context = {}
    for _, name in ipairs({'maxFruitPercent', 'offFieldPenalty', 'useFieldNum', 'areaToAvoid', 'maxIterations'}) do
        context[name] = function(self) return self end
    end
    context.vehiclesToIgnore = function(self, vehicles) ignored = vehicles; return self end
    return context
end
CpFieldUtil = {getFieldNumUnderVehicle = function() return 11 end}
PathfinderUtil = {getMaxIterationsForFieldPolygon = function() return 1000 end,
    getWaypointAsState3D = function(point) return point end}
strategy.vehicle.cpGetFieldPolygon = function() return {} end
strategy.getFieldworkBoundaryForCombineApproach = function() return {} end
strategy.getMaxFruitPercent = function() return 10 end
strategy.getOffFieldPenalty = function() return 7.5 end
strategy.registerCombinePathfinderListeners = function() end
strategy.pathfinderController = {findPathToGoal = function() end}
strategy.startPathfindingToMovingCombine = nil
strategy.approachingPocketStandby = true
strategy:startPathfindingToMovingCombine({}, 0, 0)
assert(#ignored == 0, 'A pocket join must not ignore the served combine as an obstacle')
strategy.approachingPocketStandby = nil
strategy:startPathfindingToMovingCombine({}, 0, 0)
assert(#ignored == 1 and ignored[1] == combine, 'Ordinary moving pipe approaches retain their existing collision policy')

local extensions = 0
strategy.extendCombineApproachWithinField = function() extensions = extensions + 1 end
strategy.startCourse = function() end
strategy.approachingPocketStandby = true
strategy.state = strategy.states.WAITING_FOR_PATHFINDER
assert(strategy:onPathfindingDoneToMovingCombine(nil, true, {}) and extensions == 0,
        'A checked pocket join must be driven as searched, without an unchecked extension towards the combine')
strategy.approachingPocketStandby = nil
strategy.state = strategy.states.WAITING_FOR_PATHFINDER
assert(strategy:onPathfindingDoneToMovingCombine(nil, true, {}) and extensions == 1,
        'Ordinary pipe approaches must retain their original alignment extension')
print('UnloaderPocketJoinTest: OK')
