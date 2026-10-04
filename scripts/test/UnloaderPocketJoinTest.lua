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
    startPipeApproachFromPocket = function() unloading = true end,
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

-- Reproduce the 30 September handover: recovery finished on the harvested centreline,
-- then PPC was switched directly to a pipe-side course 36 metres away. Exercise the real
-- last-waypoint dispatcher, stopped handover and alignment predicates in rotated geometry.
local searched, started
local pipe = {x = 120, z = -390, heading = 0}
local tractor = {x = 0, z = 0, heading = 0}
local function transform(node, x, z)
    return node.x + math.cos(node.heading) * x + math.sin(node.heading) * z,
        node.z - math.sin(node.heading) * x + math.cos(node.heading) * z
end
localToLocal = function(from, to, x, _, z)
    local wx, wz = transform(from, x, z)
    local dx, dz = wx - to.x, wz - to.z
    return math.cos(to.heading) * dx - math.sin(to.heading) * dz, 0,
        math.sin(to.heading) * dx + math.cos(to.heading) * dz
end
CpMathUtil = {isSameDirection = function(a, b, degrees)
    return math.cos(a.heading - b.heading) >= math.cos(math.rad(degrees))
end}
local pulledBack = false
local autoAim = false
local stopped = {isWaitingForUnload = function() return true end,
    willWaitForUnloadToFinish = function() return true end,
    isReadyToUnload = function() return true end, hasAutoAimPipe = function() return autoAim end,
    isWaitingForUnloadAfterPulledBack = function() return pulledBack end}
local assigned = {rootNode = pipe, lastSpeedReal = 0,
    getAIDirectionNode = function() return pipe end, getCpDriveStrategy = function() return stopped end}
Course = {createFromNode = function() return {} end}
local handover = setmetatable({vehicle = {rootNode = tractor,
    getAIDirectionNode = function() return tractor end}, combineToUnload = assigned, turningRadius = 9,
    states = {DRIVING_TO_MOVING_COMBINE = {}, WAITING_FOR_PATHFINDER = {}, UNLOADING_STOPPED_COMBINE = {}},
    debug = function() end, debugSparse = function() end,
    getPipeOffset = function() return 12.2, -6.4 end,
    getPipeOffsetReferenceNode = function() return pipe end,
    getTargetNode = function(_, target) return target end,
    getCombinesMeasuredBackDistance = function() return 6.4 end,
    ppc = {setShortLookaheadDistance = function() end},
    startCourse = function() started = true end,
    setNewState = function(self, state) self.state = state end,
    startPathfindingToWaitingCombine = function(_, x, z)
        searched = {x = x, z = z}
    end,
}, {__index = AIDriveStrategyUnloadCombine})
local function finishRecovery(x, z, heading, reverse)
    pipe.heading = heading
    tractor.x, tractor.z = transform(pipe, x, z)
    tractor.heading = heading + (reverse and math.pi or 0)
    handover.state = handover.states.DRIVING_TO_MOVING_COMBINE
    handover.approachingPocketStandby = true
    handover.recoveringCombineApproach = true
    searched, started = nil, false
    handover:onLastWaypointPassed()
    assert(handover.combineToUnload == assigned, 'Alignment must retain the called combine')
end
for _, heading in ipairs({0, math.pi / 2, math.pi, -math.pi / 2}) do
    finishRecovery(0, -36.2, heading)
    assert(searched and not started and handover.state == handover.states.WAITING_FOR_PATHFINDER and
        searched.x == 12.2 and math.abs(searched.z + 8.4) < 0.001,
        'A centreline recovery must calculate a pipe approach, not jump 36 metres to the unload course')
    finishRecovery(0, -24, heading)
    assert(handover:isOkToStartUnloadingCombine(), 'Reproduce the widening moving-unload tolerance')
    assert(searched and not started,
        'The moving-unload tolerance must not authorise a stopped handover from the adjacent row')
    finishRecovery(12.2, -20, heading)
    assert(started and not searched and handover.state == handover.states.UNLOADING_STOPPED_COMBINE,
        'A tractor already in the pipe corridor must retain the immediate approach')
    finishRecovery(7.2, -21.4, heading)
    assert(searched and not started, 'A centreline handover must use the normal rear path instead of a lateral correction')
    finishRecovery(12.2, -20, heading, true)
    assert(searched and not started, 'Opposite-facing tractor must calculate its approach')
end
print('Stopped-combine recovery handover geometry regressions: OK')

pulledBack = true
finishRecovery(0, -36.2, 0)
assert(searched and math.abs(searched.z + 16.4) < 0.001,
    'A pulled-back combine must retain its original target further behind the header')
pulledBack, autoAim = false, true
finishRecovery(0, -36.2, 0)
assert(started and not searched, 'Auto-aim harvesters must retain their existing approach behaviour')
autoAim = false
finishRecovery(0, -36.2, 0)
local releasedFinal = false
handover.startWaitingForSomethingToDo = function(self)
    releasedFinal = true
    self:releaseCombine()
end
-- The native registration adapter is mocked; use the real release method to clear call generation and flags.
assigned.getIsCpActive = function() return false end
handover.startPathfindingToMovingCombine = function() error('Failed final alignment must not loop back to staging') end
assert(not handover:onPathfindingDoneToWaitingCombine(nil, false, nil, true))
assert(releasedFinal and handover.combineToUnload == nil and not handover.stoppedCombineAlignmentSearch and
    not handover:canRetryCombineApproach(assigned) and handover.failedApproachStagingUntil == 15000,
    'A blocked final pipe goal must release once and hold through the existing cooldown')
print('Failed final alignment, pulled-back target and auto-aim compatibility: OK')

-- An initial unaligned approach still gets the existing harvested recovery before final failure releases it.
handover.combineToUnload = assigned
handover.combineApproachRecoveryCompleted = nil
handover.recoveringCombineApproach = nil
handover.stoppedCombineAlignmentSearch = nil
searched, started, releasedFinal = nil, false, false
tractor.x, tractor.z = transform(pipe, 0, -36.2)
tractor.heading = pipe.heading
local harvestedRecovery = false
UnloaderCoordinator.getStagingWaypoint = function(_, combine)
    assert(combine == assigned)
    return {x = 110, z = -400}
end
handover.startPathfindingToMovingCombine = function(_, waypoint)
    assert(waypoint.x == 110)
    harvestedRecovery = true
end
handover:startPipeApproachFromPocket()
assert(searched and not started and not handover.stoppedCombineAlignmentSearch)
assert(handover:onPathfindingDoneToWaitingCombine(nil, false, nil, true))
assert(harvestedRecovery and not releasedFinal and handover.combineToUnload == assigned and
    handover.recoveringCombineApproach and not handover.combineApproachRecoveryCompleted,
    'An initial checked approach failure must retain the existing harvested recovery')
-- Finish that actual recovery and fail the final alignment: no second journey to the harvested point.
harvestedRecovery = false
handover.state = handover.states.DRIVING_TO_MOVING_COMBINE
handover:onLastWaypointPassed()
assert(handover.combineApproachRecoveryCompleted and handover.stoppedCombineAlignmentSearch)
assert(not handover:onPathfindingDoneToWaitingCombine(nil, false, nil, true))
assert(releasedFinal and not harvestedRecovery and not handover.recoveringCombineApproach and
    not handover.combineApproachRecoveryCompleted,
    'Final failure must release and clear recovery provenance, without another recovery loop')
print('Initial approach recovery and bounded final retry lifecycle: OK')

-- The ordinary moving entry and offset are base CP's implementation, without a coordinator gate.
local sourceOffset, follow, followIx = 7.6, nil, nil
local fieldCourse = {getOffset = function() return sourceOffset end,
    getCurrentWaypointIx = function() return 100 end}
function fieldCourse:copy()
    return {setOffset = function(self, x, z) self.offsetX, self.offsetZ = x, z end}
end
stopped.getFieldworkCourse = function() return fieldCourse end
stopped.getClosestFieldworkWaypointIx = function() return 100 end
handover.states.UNLOADING_MOVING_COMBINE = {}
handover.startCourse = function(_, c, ix) follow, followIx = c, ix end
handover.combineToUnload = assigned
handover:startCourseFollowingCombine()
assert(follow and followIx == 100 and math.abs(follow.offsetX - (-12.2 + sourceOffset)) < 0.001,
    'Stock moving entry must retain its pipe and combine course offsets')
assert(fieldCourse:getOffset() == 7.6, 'Unloader entry must not alter the combine course offset')
print('Base CP moving entry and course offsets: OK')

-- A route endpoint alone must not authorise the turn onto the combine's copied working course.
do
    local nativeReady, entered, recovered = false, 0, 0
    local endpoint = setmetatable({combineToUnload = assigned, states = {DRIVING_TO_MOVING_COMBINE = {}},
        debug = function() end, isOkToStartUnloadingCombine = function() return nativeReady end,
        startUnloadingCombine = function() entered = entered + 1 end,
        recoverFromFailedCombineApproach = function() recovered = recovered + 1 end},
        {__index = AIDriveStrategyUnloadCombine})
    endpoint.state = endpoint.states.DRIVING_TO_MOVING_COMBINE
    endpoint:onLastWaypointPassed()
    assert(entered == 0 and recovered == 1 and endpoint.combineToUnload == assigned,
        'An unready rendezvous endpoint must retain ownership and recover rather than turn in early')
    nativeReady = true
    endpoint:onLastWaypointPassed()
    assert(entered == 1 and recovered == 1, 'A native-ready endpoint must retain the immediate base CP entry')
end
-- Even an apparently aligned stalled follower must perform the checked rear path after clearance.
handover.combineToUnload = assigned
tractor.x, tractor.z = transform(pipe, 12.2, -20)
tractor.heading = pipe.heading
searched, started = nil, false
handover:startPipeApproachFromPocket(true)
assert(searched and not started and handover.stoppedCombineAlignmentSearch,
    'A stalled recovery must bypass the direct shortcut and mark the checked final alignment as bounded')
print('Rendezvous endpoint native-entry gate and forced rear retry: OK')
