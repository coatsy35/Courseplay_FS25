function CpObject(base)
    local object = {}
    if base then setmetatable(object, {__index = base}) end
    return object
end

AIDriveStrategyCourse = {}
VariableWorkWidth = {onAIFieldWorkerStart = function() end, onAIImplementStart = function() end}
AIDriveStrategyFieldCourse = {onFieldCourseLoadedCallback = function() end, delete = function() end}
Utils = {overwrittenFunction = function(_, replacement) return replacement end}

local connectorIsContained = true
FieldworkBoundary = {
    forVehicle = function(vehicle, width)
        assert(width == 0 or width == 8,
                'The generated route uses the vehicle envelope; pathfinding adds two metres on each side')
        return {vehicle = vehicle, width = width}
    end,
    containsCourse = function(_, course)
        return connectorIsContained and course.contained
    end,
    contains = function() return true end,
}

dofile('scripts/ai/strategies/AIDriveStrategyFieldWorkCourse.lua')

local strategy = setmetatable({
    vehicle = {rootNode = {x = 0, z = 0}},
    turningRadius = 12,
    getWorkWidth = function() return 15 end,
}, {__index = AIDriveStrategyFieldWorkCourse})

CpMathUtil = {getDeltaAngle = function(a, b) return (a - b + math.pi) % (2 * math.pi) - math.pi end}
local angles, reversing = {0, 0, 0, 0}, {}
local lookahead
local connectorStrategy = setmetatable({
    state = 'connecting', states = {DRIVING_TO_WORK_START_WAYPOINT = 'connecting'},
    connectingPathStartIx = 1,
    course = {
        getNumberOfWaypoints = function() return 10 end,
        getNextWaypointIxWithinDistance = function(_, ix) return math.min(ix + 3, 10) end,
        getWaypointAngleDeg = function(_, ix) return angles[ix] or 0 end,
        isReverseAt = function(_, ix) return reversing[ix] or false end,
    },
    ppc = {
        normalLookAheadDistance = 5,
        setLookaheadDistance = function(_, distance) lookahead = distance end,
        setShortLookaheadDistance = function() lookahead = 'short' end,
    },
}, {__index = AIDriveStrategyFieldWorkCourse})
connectorStrategy:updateConnectingPathLookahead(1)
assert(lookahead == 6, 'A long straight connector must not use turn-length steering lookahead')
angles[4] = 12
connectorStrategy:updateConnectingPathLookahead(1)
assert(lookahead == 'short', 'A bend ahead must retain the short steering lookahead')
angles[4] = 0
reversing[3] = true
connectorStrategy:updateConnectingPathLookahead(1)
assert(lookahead == 'short', 'A reversal ahead must retain the short steering lookahead')
reversing[3] = nil
connectorStrategy:updateConnectingPathLookahead(8)
assert(lookahead == 'short', 'The work-start entry must retain precise steering')

local localConnector = {contained = true, getLength = function() return 45 end}
assert(not strategy:canDriveConnectingPathDirectly(localConnector),
        'A local join must retain accurate pathfinding')

local longConnector = {contained = true, getLength = function() return 700 end}
assert(strategy:canDriveConnectingPathDirectly(longConnector),
        'A long contained generated connector must be driven without a duplicate global search')

AIUtil = {getWidth = function() return 4 end, getLength = function() return 6 end,
    isStopped = function() return false end}
MathUtil = {vector2Length = function(x, z) return math.sqrt(x * x + z * z) end}
function getWorldTranslation(node) return node.x, 0, node.z end
function localToWorld(node, _, _, offset) return node.x, 0, node.z + offset end
local follower = {rootNode = {x = 40, z = 0}, getIsCpFieldWorkActive = function() return true end}
g_currentMission = {vehicleSystem = {vehicles = {follower}}}
strategy.fieldWorkerProximityController = {hasSameCourse = function() return true end,
    getPhysicalTurnClearance = function() return 50 end}
strategy.proximityController = {unregisterBlockingObjectListener = function() end,
    registerBlockingObjectListener = function() end,
    checkBlockingVehicleFront = function() return math.huge end,
    checkBlockingVehicleBack = function() return math.huge end}
longConnector.getNumberOfWaypoints = function() return 5 end
longConnector.getWaypointPosition = function(_, ix) return (ix - 1) * 40, 0, 0 end
longConnector.copy = function() return {getNumberOfWaypoints = function() return 1 end,
    getWaypointPosition = function() return 160, 0, 0 end} end
CpUtil = {getName = function() return 'Follower' end}
strategy.debug = function() end
assert(not strategy:canDriveConnectingPathDirectly(longConnector),
        'A connector crossing the following worker must use collision-aware routing')
local blocked, blocker = strategy:isConnectingPathBlockedByWorker(longConnector)
assert(blocked and blocker == 'fieldWorker',
        'A worker on the connector must be distinguished from a trailer that can move aside')
local farWorker = {rootNode = {x = 120, z = 0}, getIsCpFieldWorkActive = function() return true end}
g_currentMission.vehicleSystem.vehicles = {farWorker, follower}
local _, _, firstWorker = strategy:isConnectingPathBlockedByWorker(longConnector)
assert(firstWorker == follower, 'With several combines, the nearest crossing must be cleared first')
g_currentMission.vehicleSystem.vehicles = {follower}
-- The blocked combine must wait before launching the expensive whole-field search.
g_currentMission.time = 1000
strategy.fieldWorkCourse = {
    getNumberOfWaypoints = function() return 4 end,
    isOnConnectingPath = function(_, ix) return ix < 4 end,
    getWaypointPosition = function(_, ix) return ix * 20, 0, 0 end,
}
strategy.getFrontAndBackMarkers = function() return 0, 0 end
strategy.getTurnEndSideOffset = function() return 0 end
strategy.getTurnEndForwardOffset = function() return 0 end
strategy.getAllowReversePathfinding = function() return false end
strategy.settings = {avoidFruit = {getValue = function() return false end}}
strategy.states = {WAITING_FOR_PATHFINDER = {}}
strategy.startCourse = function(_, route) assert(route == longConnector) end
local searches = 0
strategy.pathfinderController = {registerListeners = function() end,
    findPathToNode = function() searches = searches + 1 end,
    findPathToWaypoint = function() searches = searches + 1 end}
RowStartOrFinishContext = function() return {getTurnEndNodeAndOffsets = function() return {}, 0 end} end
AIUtil.getSteeringParameters = function() return false, 6 end
PathfinderContext = function() return {allowReverse = function(self) return self end,
    preferredPath = function(self) return self end,
    mustBeAccurate = function(self) return self end,
    ignoreFruit = function(self, ignore) self.ignoreFruitValue = ignore; return self end} end
Course = function() return longConnector end
strategy:startConnectingPath(1)
assert(strategy.state == strategy.states.WAITING_FOR_PATHFINDER and strategy.connectingPathRetryAt == 6000 and
        searches == 0,
        'The following combine must wait and recheck the occupied connector')
g_currentMission.time = 17000
strategy:startConnectingPath(1)
assert(searches == 1 and strategy.connectingPathWorkerDetourAt == 77000,
        'A persistent blocker must permit a bounded collision-aware detour attempt')
g_currentMission.time = 22000
strategy:startConnectingPath(1)
assert(searches == 1,
        'A failed detour must not turn into repeated whole-field searches while the worker remains')
follower.rootNode.x = 100
g_currentMission.time = 23000
strategy:startConnectingPath(1)
assert(searches == 2,
        'A worker beyond the turn-clearance distance must allow an immediate collision-aware detour')
follower.rootNode.x = 40
g_currentMission.time = 22000
strategy.vehicle.rootNode = {x = 0, z = 0}
strategy.waypointToContinueOnFailedPathfinding = 4
assert(strategy:isNextWaypointBlockedByWorker(),
        'The local direct join must detect another worker on the route')
strategy:onPathfindingFailedToNextWaypoint(nil, {collisionMask = function()
    error('An occupied local join must not disable collisions')
end}, false, 1)
assert(strategy.nextWaypointRetryAt == 27000 and strategy.state == strategy.states.WAITING_FOR_PATHFINDER,
        'A blocked local join must wait for clearance before retrying')
g_currentMission.time = 1000
strategy.workStarterCourse = longConnector
strategy.connectingPathRejoinIx = 3
local retriedWithBoundary = false
strategy:onPathfindingFailedToConnectingPathEnd({retry = function(_, context)
    retriedWithBoundary = context._fieldworkBoundary.width == 0 and context.ignoreFruitValue
end}, {collisionMask = function()
    error('An occupied connector must not disable collision checks')
end, ignoreFruit = function(self, ignore) self.ignoreFruitValue = ignore end}, false, 1)
assert(retriedWithBoundary, 'A local detour may retry through crop while retaining collisions')
strategy:onPathfindingFailedToConnectingPathEnd(nil, {}, true, 2)
assert(strategy.connectingPathRetryAt == 6000 and strategy.state == strategy.states.WAITING_FOR_PATHFINDER,
        'A failed detour must wait and retry rather than drive through the following worker')
follower.rootNode.z = 30
assert(strategy:canDriveConnectingPathDirectly(longConnector),
        'A worker clear of the connector must not force a global search')

local requestedMoves = 0
local parkedStrategy = {
    states = {MOVING_AWAY_FROM_OTHER_VEHICLE = {}},
    state = {},
    getCombineToUnload = function() return nil end,
    isAvailableForStaging = function(self) return self.state ~= self.states.MOVING_AWAY_FROM_OTHER_VEHICLE end,
    requestToMoveOutOfWay = function(self, vehicle, _, course)
        assert(vehicle == strategy.vehicle and course == longConnector,
                'The parked unloader needs the blocked connector to leave its whole route')
        requestedMoves = requestedMoves + 1
        self.state = self.states.MOVING_AWAY_FROM_OTHER_VEHICLE
    end,
}
local trailer = {
    rootNode = {x = 60, z = 0},
    getCpDriveStrategy = function() return parkedStrategy end,
    getChildVehicles = function() return {{rootNode = {x = 48, z = 0}}} end,
}
g_currentMission.vehicleSystem.vehicles = {follower, trailer}
assert(not strategy:canDriveConnectingPathDirectly(longConnector),
        'A parked trailer across the centre-work connector must stop direct driving')
blocked, blocker = strategy:isConnectingPathBlockedByWorker(longConnector)
assert(blocked and blocker == 'unloader',
        'A parked trailer must be asked to move rather than treated as a field worker')
assert(requestedMoves == 1, 'The parked trailer must be asked to clear the combine route')
parkedStrategy.getCombineToUnload = function() return follower end
assert(not strategy:canDriveConnectingPathDirectly(longConnector),
        'An assigned trailer remains a physical obstacle even though its call cannot be cancelled')
strategy:isConnectingPathBlockedByWorker(longConnector)
assert(requestedMoves == 1, 'An assigned trailer must not receive a standby clearance request')
parkedStrategy.getCombineToUnload = function() return nil end
local occupiedRetry = false
strategy:onPathfindingFailedToConnectingPathEnd({retry = function(_, context)
    occupiedRetry = context._fieldworkBoundary.width == 0 and context.ignoreFruitValue
end}, {collisionMask = function()
    error('A trailer-obstructed connector must retain collision checks')
end, ignoreFruit = function(self, ignore) self.ignoreFruitValue = ignore end}, false, 1)
assert(occupiedRetry and requestedMoves == 1,
        'An occupied connector must retry with narrower field clearance and retained collisions')
strategy:onPathfindingFailedToConnectingPathEnd(nil, {}, true, 2)
assert(strategy.connectingPathRetryAt == 6000,
        'The combine waits only after its collision-aware detour retry also fails')
local detour = {getNumberOfWaypoints = function() return 2 end,
    getWaypointPosition = function(_, ix) return ix * 20, 0, 10 end,
    contained = true}
local drivenCourse
strategy.startCourseToWorkStart = function(_, course) drivenCourse = course end
strategy.connectingPathRejoinIx = nil
strategy:onPathfindingDoneToConnectingPathEnd(nil, true, detour, false)
assert(drivenCourse == detour and strategy.connectingPathRetryAt == nil,
        'A collision-free pathfinder detour must proceed when a parked trailer cannot clear the connector')
local function section(first)
    return {getNumberOfWaypoints = function() return 11 - first end,
        getWaypointPosition = function(_, ix) return (first + ix - 2) * 20, 0, 0 end,
        copy = function(_, _, ix) return section(first + ix - 1) end}
end
local extendedConnector = section(1)
trailer.rootNode.x = 100
trailer.getChildVehicles = function() return {{rootNode = {x = 88, z = 0}}} end
local trailerRejoin = strategy:getClearConnectingPathRejoinIx(extendedConnector, 2, follower)
assert(trailerRejoin and trailerRejoin > 4,
        'A parked trailer farther along the connector must move the local rejoin beyond it')
trailer.rootNode.x = 60
trailer.rootNode.z = 40
trailer.getChildVehicles = function() return {{rootNode = {x = 48, z = 40}}} end
assert(strategy:canDriveConnectingPathDirectly(longConnector),
        'The combine may proceed when the full tractor and trailer have cleared its route')

longConnector.contained = false
assert(not strategy:canDriveConnectingPathDirectly(longConnector),
        'A connector that leaves the field must not bypass pathfinding')

-- A stopped lead worker must cause a local collision-aware rejoin, even when this worker is a follower.
longConnector.contained = true
g_currentMission.vehicleSystem.vehicles = {follower}
follower.rootNode.z = 0
strategy.settings.avoidFruit.getValue = function() return true end
local loopingPositions = {0, 20, 40, 60, 80, 40, 100, 120, 140, 160}
local loopingConnector = {
    getNumberOfWaypoints = function() return #loopingPositions end,
    getWaypointPosition = function(_, ix) return loopingPositions[ix], 0, 0 end,
    copy = function(_, _, firstIx)
        return {
            getNumberOfWaypoints = function() return #loopingPositions - firstIx + 1 end,
            getWaypointPosition = function(_, ix) return loopingPositions[firstIx + ix - 1], 0, 0 end,
        }
    end,
}
assert(strategy:getClearConnectingPathRejoinIx(loopingConnector, 2, follower) == 7,
        'A connector that doubles back must rejoin after the worker\'s final crossing')
strategy.workStarterCourse = loopingConnector
strategy.connectingPathRejoinIx = 4
local originalFindPathToNode = strategy.pathfinderController.findPathToNode
local retriedDirectly = false
strategy.pathfinderController.findPathToNode = function(_, context)
    retriedDirectly = context.ignoreFruitValue == false
end
strategy:onPathfindingDoneToConnectingPathEnd(nil, true, {append = function() end}, false)
assert(retriedDirectly and strategy.connectingPathRejoinIx == nil,
        'A moving worker on the remaining route must cause a direct collision-aware detour')
strategy.pathfinderController.findPathToNode = originalFindPathToNode
local leadIsStopped = false
follower.getCpDriveStrategy = function() return {
    proximityController = {isStopped = function() return leadIsStopped end},
    getWorkWidth = function() return 15 end,
} end
AIUtil.isStopped = function() return leadIsStopped end
strategy.fieldWorkerProximityController.otherVehicleAheadOnTrail = {[follower] = true}
strategy.connectingPathWorkerLastSearchAt = nil
local rejoinIx, rejoinBoundary, rejoinIgnoresFruit
strategy.pathfinderController.findPathToWaypoint = function(_, context, _, ix)
    rejoinIx, rejoinBoundary, rejoinIgnoresFruit = ix, context._fieldworkBoundary, context.ignoreFruitValue
    searches = searches + 1
end
g_currentMission.time = 30000
strategy:startConnectingPath(1)
assert(rejoinIx == nil and strategy.state == strategy.states.WAITING_FOR_PATHFINDER,
        'A moving lead worker retains the right of way')
leadIsStopped = true
g_currentMission.time = 35000
strategy:startConnectingPath(1)
assert(rejoinIx == 4 and rejoinBoundary.width == 8 and rejoinIgnoresFruit == false,
        'The first local rejoin search must still prefer a crop-free route')

local innerDetour = {contained = false, getNumberOfWaypoints = function() return 2 end,
    append = function() end,
    getWaypointPosition = function(_, ix) return ix * 20, 0, 0 end}
strategy:onPathfindingDoneToConnectingPathEnd(nil, true, innerDetour, false)
assert(strategy.state == strategy.states.WAITING_FOR_PATHFINDER and strategy.connectingPathRetryAt == 40000,
        'A pathfinder result that cuts the field edge must be rejected')

-- A blocked centre-work approach must replan rather than remain stopped at a tree indefinitely.
local restartedAt
strategy.startBlockedConnectorRecovery = function(self) restartedAt = self.connectorRecoveryResumeIx end
strategy.course = {getCurrentWaypointIx = function() return 723 end}
strategy.state = strategy.states.DRIVING_TO_WORK_START_WAYPOINT
strategy.connectingPathStartIx = 723
strategy.connectingPathObstacleRetryAt = nil
strategy:onBlockedConnectingPath(false)
assert(restartedAt == 723 and strategy.connectorRecoveryActive and
        strategy.connectingPathObstacleRetryAt == 65000,
        'A sustained forward obstruction must restart field-contained connector routing')
strategy.startBlockedConnectorRecovery = AIDriveStrategyFieldWorkCourse.startBlockedConnectorRecovery

local shortConnector = {getNumberOfWaypoints = function() return 3 end,
    getWaypointPosition = function(_, ix) return (ix - 1) * 20, 0, 0 end}
assert(strategy:getConnectingPathRejoinIx(shortConnector, 2, follower) == nil,
        'The end waypoint must not count as a safe rejoin without the required clearance')

local approach = {getNumberOfWaypoints = function() return 10 end,
    getWaypointPosition = function(_, ix) return (ix - 1) * 10, 0, 0 end}
approach.copy = function(_, _, first)
    return {getNumberOfWaypoints = function() return 11 - first end,
        getWaypointPosition = function(_, ix) return (first + ix - 2) * 10, 0, 0 end,
        copy = function() return {getNumberOfWaypoints = function() return 1 end,
            getWaypointPosition = function() return 90, 0, 0 end} end}
end
strategy.activeConnectingPathCourse = approach
strategy.connectorRecoveryResumeIx = 3
follower.rootNode.z = 40
strategy.startCourse = function(_, route)
    assert(route:getWaypointPosition(1) == 20,
            'Obstacle recovery must start from active approach progress, not a spatially close old loop')
end
local recoveryIx
strategy.pathfinderController.findPathToWaypoint = function(_, context, _, ix)
    recoveryIx = ix
    assert(context._fieldworkBoundary.width == 8, 'Recovery must use the hard field corridor')
end
strategy:startBlockedConnectorRecovery()
assert(recoveryIx == 4 and strategy.state == strategy.states.WAITING_FOR_PATHFINDER,
        'An obstructed approach must find a local waypoint ahead of current course progress')
follower.rootNode.z = 0
local directRecovery = false
strategy.pathfinderController.findPathToNode = function() directRecovery = true end
recoveryIx = nil
strategy:startBlockedConnectorRecovery()
assert(directRecovery or (recoveryIx and recoveryIx > 4),
        'A worker occupying the recovery suffix must not cause another search to the fixed local waypoint')
follower.rootNode.z = 40

-- A stopped turning combine immediately ahead needs physical room before either
-- pathfinder can produce a collision-free route. Only the blocked connector
-- worker may retreat, and the back sensor and field corridor remain authoritative.
local turningState = {}
local turningStrategy = {state = turningState, states = {TURNING = turningState},
    getWorkWidth = function() return 15 end}
follower.getCpDriveStrategy = function() return turningStrategy end
follower.rootNode = {x = 0, z = 3}
strategy.vehicle.getAIDirectionNode = function(self) return self.rootNode end
strategy.fieldWorkerProximityController.getPhysicalTurnClearance = function() return 18 end
strategy.proximityController.checkBlockingVehicleFront = function() return 1.3, follower end
strategy.proximityController.checkBlockingVehicleBack = function() return math.huge end
strategy.settings.reverseSpeed = {getValue = function() return 8 end}
strategy.states.REVERSING_FOR_WORKER_CLEARANCE = {}
strategy.raiseImplements = function() end
local reverseCourse, reverseLength
Course = setmetatable({createStraightReverseCourse = function(_, length)
    reverseLength = length
    return {contained = true}
end}, {__call = function() return longConnector end})
strategy.startCourse = function(_, route) reverseCourse = route end
assert(strategy:retreatFromBlockingTurningWorker() and reverseLength > 20 and
        strategy.state == strategy.states.REVERSING_FOR_WORKER_CLEARANCE and reverseCourse,
        'A mutually blocked connector worker must reverse far enough to clear the turning header')
local recoveryResumed = false
strategy.startBlockedConnectorRecovery = function() recoveryResumed = true end
strategy:onLastWaypointPassed()
assert(recoveryResumed, 'After clearing the turn, the worker must replan its approach')
strategy.startBlockedConnectorRecovery = AIDriveStrategyFieldWorkCourse.startBlockedConnectorRecovery
strategy.proximityController.checkBlockingVehicleBack = function() return 2 end
assert(not strategy:retreatFromBlockingTurningWorker(),
        'A blocked rear corridor must prevent the clearance retreat')
strategy.proximityController.checkBlockingVehicleBack = function() return math.huge end
FieldworkBoundary.containsCourse = function() return false end
assert(not strategy:retreatFromBlockingTurningWorker(),
        'A retreat outside the field corridor must be rejected')
FieldworkBoundary.contains = function() return false end
local edgeContext = {}
strategy:setConnectingPathBoundary(edgeContext, 8)
assert(edgeContext._preferFieldworkBoundary,
        'A machine already outside the margin may search inward; the accepted course remains checked')

print('FieldworkConnectingPathTest: OK')
