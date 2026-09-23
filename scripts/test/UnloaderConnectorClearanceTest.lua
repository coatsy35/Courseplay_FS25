function CpObject() return {} end
AIUtil = {
    getWidth = function(vehicle) return vehicle.width end,
    getLength = function(vehicle) return vehicle.length end,
}
MathUtil = {vector2Length = function(x, z) return math.sqrt(x * x + z * z) end}
CpUtil = {getName = function() return 'combine' end}
PathfinderUtil = {hasFruit = function() return false end}
FieldworkBoundary = {contains = function(_, _, z) return z >= 0 and z < 80 end}
Waypoint = function(point) return point end
function getWorldTranslation(node) return node.x, 0, node.z end
dofile('scripts/ai/strategies/AIDriveStrategyUnloadCombine.lua')

local trailer = {width = 5, length = 9, rootNode = {x = 10, z = 0}}
local tractor = {width = 4, length = 6, rootNode = {x = 20, z = 0},
    getChildVehicles = function() return {trailer} end}
local parkedTrailer = {width = 5, rootNode = {x = 20, z = 27.5}}
local parkedTractor = {width = 4, rootNode = {x = 20, z = 28},
    getChildVehicles = function() return {parkedTrailer} end}
g_currentMission = {vehicleSystem = {vehicles = {tractor, parkedTractor}}}
local driver = {getWorkWidth = function() return 15 end}
local combine = {getCpDriveStrategy = function() return driver end}
AIDriveStrategyCombineCourse = {isActiveCpCombine = function(vehicle) return vehicle == combine end}
local strategy = setmetatable({vehicle = tractor, standbyAssignment = {},
    states = {WAITING_IN_STANDBY = {}, WAITING_FOR_STANDBY_PATHFINDER = {}, DRIVING_TO_STANDBY = {}},
    state = {}, debug = function() end, setMaxSpeed = function() end}, {__index = AIDriveStrategyUnloadCombine})
strategy.getFieldworkBoundaryForRig = function() return {} end
strategy.isAvailableForStaging = function() return true end
local target
strategy.startPathfindingToStandby = function(_, harvester, waypoint, avoidHarvester)
    assert(harvester == combine and avoidHarvester)
    target = waypoint
end
local course = {getNumberOfWaypoints = function() return 3 end,
    getWaypointPosition = function(_, ix) return (ix - 1) * 50, 0, 0 end}
assert(not strategy:isRigClearOfCourse(course, 15))
strategy:requestToMoveOutOfWay(combine, nil, course)
assert(target and target.z > 45 and strategy.connectorClearance.course == course,
    'The clearance target must avoid both the connector and another parked trailer')
local rejectedZ = target.z
strategy.connectorClearance.failedTargets = {{x = target.x, z = target.z}}
target = nil
strategy:startConnectorClearance(combine, course)
assert(target and math.abs(target.z - rejectedZ) >= 8,
    'A rejected pathfinder goal must not be selected again')
tractor.rootNode.z, trailer.rootNode.z = target.z, target.z
assert(strategy:isRigClearOfCourse(course, strategy.connectorClearance.distance),
    'Both tractor and trailer must clear the route before the combine proceeds')
trailer.rootNode.z = 0
assert(not strategy:isRigClearOfCourse(course, strategy.connectorClearance.distance),
    'Tractor clearance alone must not hide a trailer still occupying the route')

-- A combine approaching a parked standby rig must use its actual route and the obstacle-aware
-- clearance pathfinder, rather than commanding a blind 25 m reverse into the next trailer.
strategy.state = strategy.states.WAITING_IN_STANDBY
driver.ppc = {getCourse = function() return course end}
tractor.rootNode.z, trailer.rootNode.z = 0, 0
strategy.connectorClearance = nil
target = nil
strategy:requestToMoveOutOfWay(combine)
assert(target and strategy.connectorClearance.course == course,
    'A blocked standby rig must pathfind clear of the combine course')

-- Another standby arrival should stop and replan; the parked rig must stay where it is.
tractor.getIsCpActive = function() return true end
parkedTractor.getCpDriveStrategy = function()
    return {isInStandbyState = function() return true end}
end
strategy.debugSparse = function() end
strategy.state = strategy.states.WAITING_IN_STANDBY
target = nil
strategy:onBlockingVehicle(parkedTractor, false)
assert(strategy.state == strategy.states.WAITING_IN_STANDBY and not target,
    'A parked standby rig must not back away from another standby rig')

local held = false
strategy.state = strategy.states.DRIVING_TO_STANDBY
strategy.holdAtStandbyPosition = function(self)
    held = true
    self.state = self.states.WAITING_IN_STANDBY
end
strategy:onBlockingVehicle(parkedTractor, false)
assert(held and strategy.standbyRetryAt > 0,
    'The approaching standby rig must stop and retry its route')

local otherCourse = {getNumberOfWaypoints = function() return 3 end,
    getWaypointPosition = function(_, ix) return (ix - 1) * 400, 0, 0 end}
local otherDriver = {getWorkWidth = function() return 15 end,
    ppc = {getCourse = function() return otherCourse end,
        getCurrentWaypointIx = function() return 1 end}}
local otherCombine = {getCpDriveStrategy = function() return otherDriver end}
g_currentMission.vehicleSystem.vehicles = {tractor, parkedTractor, otherCombine}
AIDriveStrategyCombineCourse.isActiveCpCombine = function(vehicle)
    return vehicle == combine or vehicle == otherCombine
end
assert(strategy:isStandbyTargetOnAnotherHarvesterRoute(combine, {x = 800, z = 0}),
    'A spare must not park on another combine\'s upcoming alignment route')
assert(not strategy:isStandbyTargetOnAnotherHarvesterRoute(combine, {x = 800, z = 60}),
    'A separate parking area must remain available')
held = false
AIDriveStrategyUnloadCombine.startPathfindingToStandby(strategy, combine, {x = 800, z = 0})
assert(held, 'An occupied standby target must be rejected before pathfinding')

PathfinderUtil.hasFruit = function() return true end
strategy.settings = {avoidFruit = {getValue = function() return true end}}
target = nil
strategy:startConnectorClearance(combine, course)
assert(not target, 'Avoid fruit must forbid an emergency clearance target in standing crop')
print('UnloaderConnectorClearanceTest: OK')
