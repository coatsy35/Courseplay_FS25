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
        assert(width == 0, 'A generated connector must use the vehicle envelope, not the header width')
        return {vehicle = vehicle}
    end,
    containsCourse = function(_, course)
        return connectorIsContained and course.contained
    end,
}

dofile('scripts/ai/strategies/AIDriveStrategyFieldWorkCourse.lua')

local strategy = setmetatable({
    vehicle = {},
    turningRadius = 12,
    getWorkWidth = function() return 15 end,
}, {__index = AIDriveStrategyFieldWorkCourse})

local localConnector = {contained = true, getLength = function() return 45 end}
assert(not strategy:canDriveConnectingPathDirectly(localConnector),
        'A local join must retain accurate pathfinding')

local longConnector = {contained = true, getLength = function() return 700 end}
assert(strategy:canDriveConnectingPathDirectly(longConnector),
        'A long contained generated connector must be driven without a duplicate global search')

AIUtil = {getWidth = function() return 4 end}
MathUtil = {vector2Length = function(x, z) return math.sqrt(x * x + z * z) end}
function getWorldTranslation(node) return node.x, 0, node.z end
local follower = {rootNode = {x = 40, z = 0}, getIsCpFieldWorkActive = function() return true end}
g_currentMission = {vehicleSystem = {vehicles = {follower}}}
strategy.fieldWorkerProximityController = {hasSameCourse = function() return true end}
longConnector.getNumberOfWaypoints = function() return 3 end
longConnector.getWaypointPosition = function(_, ix) return (ix - 1) * 40, 0, 0 end
CpUtil = {getName = function() return 'Follower' end}
strategy.debug = function() end
assert(not strategy:canDriveConnectingPathDirectly(longConnector),
        'A connector crossing the following worker must use collision-aware routing')
g_currentMission.time = 1000
strategy.workStarterCourse = longConnector
strategy.states = {WAITING_FOR_PATHFINDER = {}}
strategy:onPathfindingFailedToConnectingPathEnd(nil, {collisionMask = function()
    error('An occupied connector must not disable collision checks')
end}, false, 1)
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
assert(requestedMoves == 1, 'The parked trailer must be asked to clear the combine route')
strategy:onPathfindingFailedToConnectingPathEnd(nil, {collisionMask = function()
    error('A trailer-obstructed connector must retain collision checks')
end}, false, 1)
assert(requestedMoves == 1 and strategy.connectingPathRetryAt == 6000,
        'A moving-away trailer must not receive repeated escape courses while the combine waits')
local detour = {getNumberOfWaypoints = function() return 2 end,
    getWaypointPosition = function(_, ix) return ix * 20, 0, 10 end}
local drivenCourse
strategy.startCourseToWorkStart = function(_, course) drivenCourse = course end
strategy:onPathfindingDoneToConnectingPathEnd(nil, true, detour, false)
assert(drivenCourse == detour and strategy.connectingPathRetryAt == nil,
        'A collision-free pathfinder detour must proceed when a parked trailer cannot clear the connector')
trailer.rootNode.z = 40
trailer.getChildVehicles = function() return {{rootNode = {x = 48, z = 40}}} end
assert(strategy:canDriveConnectingPathDirectly(longConnector),
        'The combine may proceed when the full tractor and trailer have cleared its route')

longConnector.contained = false
assert(not strategy:canDriveConnectingPathDirectly(longConnector),
        'A connector that leaves the field must not bypass pathfinding')

print('FieldworkConnectingPathTest: OK')
