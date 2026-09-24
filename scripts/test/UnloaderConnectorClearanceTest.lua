function CpObject() return {} end
AIUtil = {
    getWidth = function(vehicle) return vehicle.width end,
    getLength = function(vehicle) return vehicle.length end,
}
MathUtil = {vector2Length = function(x, z) return math.sqrt(x * x + z * z) end}
CpUtil = {getName = function() return 'combine' end}
PathfinderUtil = {hasFruit = function() return false end}
FieldworkBoundary = {contains = function(_, _, z) return z >= 0 and z < 80 end,
    containsCourse = function() return true end}
Waypoint = function(point) return point end
function getWorldTranslation(node) return node.x, 0, node.z end
function localToWorld(node, _, _, offset) return node.x, 0, node.z + offset end
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
local target, emergency
strategy.startPathfindingToStandby = function(_, harvester, waypoint, avoidHarvester, emergencyClearance)
    assert(harvester == combine and avoidHarvester)
    target = waypoint
    emergency = emergencyClearance
end
local course = {getNumberOfWaypoints = function() return 3 end,
    getWaypointPosition = function(_, ix) return (ix - 1) * 50, 0, 0 end}
assert(not strategy:isRigClearOfCourse(course, 15))
strategy:requestToMoveOutOfWay(combine, nil, course)
assert(target and strategy:isConnectorClearanceTargetFree(target.x, target.z, 5,
        strategy.getTrainLength(tractor)) and strategy.connectorClearance.course == course,
    'The clearance target must avoid both the connector and another parked trailer')
local rejectedX, rejectedZ = target.x, target.z
strategy.connectorClearance.failedTargets = {{x = target.x, z = target.z}}
target = nil
strategy:startConnectorClearance(combine, course)
assert(target and MathUtil.vector2Length(target.x - rejectedX, target.z - rejectedZ) >= 8,
    'A rejected pathfinder goal must not be selected again')
tractor.rootNode.z, trailer.rootNode.z = target.z, target.z
assert(strategy:isRigClearOfCourse(course, strategy.connectorClearance.distance),
    'Both tractor and trailer must clear the route before the combine proceeds')
trailer.rootNode.z = 0
assert(not strategy:isRigClearOfCourse(course, strategy.connectorClearance.distance),
    'Tractor clearance alone must not hide a trailer still occupying the route')

local originalContains = FieldworkBoundary.contains
FieldworkBoundary.contains = function(_, x, z) return x > 35 and x < 90 and z >= 0 and z < 80 end
strategy.connectorClearance = nil
target = nil
tractor.rootNode.z, trailer.rootNode.z = 0, 0
strategy:startConnectorClearance(combine, course)
assert(target and target.x > 35,
    'Clearance must search along the route when a sideways holding point is unavailable')
FieldworkBoundary.contains = originalContains

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
local ownCourse = {getNumberOfWaypoints = function() return 3 end,
    getWaypointPosition = function(_, ix) return (ix - 1) * 50, 0, 35 end}
driver.ppc = {getCourse = function() return ownCourse end,
    getCurrentWaypointIx = function() return 1 end}
g_currentMission.vehicleSystem.vehicles = {tractor, parkedTractor, combine, otherCombine}
AIDriveStrategyCombineCourse.isActiveCpCombine = function(vehicle)
    return vehicle == combine or vehicle == otherCombine
end
assert(strategy:isStandbyTargetOnHarvesterRoute({x = 80, z = 0}),
    'A spare must not park on another combine\'s imminent alignment route')
assert(not strategy:isStandbyTargetOnHarvesterRoute({x = 800, z = 0}),
    'A distant future row must not reject a useful standby position')
assert(not strategy:isStandbyTargetOnHarvesterRoute({x = 80, z = 60}),
    'A separate parking area must remain available')
assert(strategy:isStandbyTargetOnHarvesterRoute({x = 40, z = 35}),
    'The assigned combine\'s upcoming connector must also be protected')
held = false
AIDriveStrategyUnloadCombine.startPathfindingToStandby(strategy, combine, {x = 80, z = 0})
assert(held, 'An occupied standby target must be rejected before pathfinding')

PathfinderUtil.hasFruit = function() return true end
strategy.settings = {avoidFruit = {getValue = function() return true end}}
target = nil
strategy:startConnectorClearance(combine, course)
assert(target and emergency and FieldworkBoundary.contains({}, target.x, target.z),
    'A blocked combine must get a field-contained emergency route when no harvested target exists')

-- A rig can lose its standby assignment while still blocking the connector. It must keep
-- the obstacle-aware clearance route until both tractor and trailer have moved aside.
strategy.standbyAssignment = nil
strategy.state = strategy.states.WAITING_IN_STANDBY
strategy.connectorClearance = nil
strategy:setMaxSpeed(0)
target = nil
strategy:requestToMoveOutOfWay(combine, nil, course)
assert(target and strategy.connectorClearance,
    'An unassigned idle unloader must also receive a connector-specific clearance route')
strategy.states.IDLE = {}
strategy.setNewState = function(self, state) self.state = state end
strategy.startCourse = function(self, path) self.course = path end
AIUtil.getDirectionNodeToReverserNodeOffset = function() return -2 end
local clearancePath = {adjustForReversing = function() end}
strategy.state = strategy.states.WAITING_FOR_STANDBY_PATHFINDER
strategy.standbyBoundary = {}
FieldworkBoundary.containsCourse = function() return false end
assert(not strategy:onPathfindingDoneToStandby(nil, true, clearancePath) and
        strategy.state == strategy.states.WAITING_IN_STANDBY,
    'A clearance route leaving the field corridor must be rejected before driving')
FieldworkBoundary.containsCourse = function() return true end
strategy.state = strategy.states.WAITING_FOR_STANDBY_PATHFINDER
assert(strategy:onPathfindingDoneToStandby(nil, true, clearancePath) and
        strategy.state == strategy.states.DRIVING_TO_STANDBY,
    'Successful clearance pathfinding must not require a standby assignment')
tractor.rootNode.z, trailer.rootNode.z = 70, 70
strategy:updateStandbyCoordinator()
assert(strategy.state == strategy.states.IDLE and not strategy.connectorClearance,
    'An idle rig may rejoin the pool only after its full train clears the connector')

-- If forward-only pathfinding cannot turn past a combine header, a clear straight reverse makes
-- enough room for another route search. An occupied rear corridor must never be used.
tractor.rootNode.z, trailer.rootNode.z = 30, 20
combine.rootNode, combine.width, combine.length = {x = 20, z = 55}, 15, 8
g_currentMission.vehicleSystem.vehicles = {tractor, combine}
function localToLocal(node, reference) return node.x - reference.x, 0, node.z - reference.z end
FieldworkBoundary.captureRig = function(vehicle)
    return {{x = vehicle.rootNode.x, z = vehicle.rootNode.z, heading = 0}}
end
FieldworkBoundary.rigOutsideDistance = function(_, rig) return rig[1].z < 0 and 1 or 0 end
FieldworkBoundary.advanceRig = function(rig, x, z) rig[1].x, rig[1].z = x, z end
Course = {createStraightReverseCourse = function(_, distance)
    return {reverseDistance = distance}
end}
strategy.connectorClearance = {reverseAttempts = 0}
assert(strategy:startConnectorReverseEscape() and strategy.course.reverseDistance == 20 and
        strategy.connectorClearance.reverseAttempts == 1 and strategy.state == strategy.states.DRIVING_TO_STANDBY,
    'A field-contained clear reverse must break the failed forward-pathfinding loop')
strategy.state = strategy.states.WAITING_FOR_STANDBY_PATHFINDER
strategy.connectorClearance = {reverseAttempts = 0, failedTargets = {}}
assert(strategy:onPathfindingDoneToStandby(nil, false, nil) and
        strategy.state == strategy.states.DRIVING_TO_STANDBY,
    'A failed standby search must actually start the checked reverse escape')
local rearVehicle = {rootNode = {x = 10, z = 12}, width = 4, length = 6}
g_currentMission.vehicleSystem.vehicles = {tractor, combine, rearVehicle}
strategy.connectorClearance = {reverseAttempts = 0}
assert(not strategy:startConnectorReverseEscape(),
    'The emergency reverse must not drive the trailer into another vehicle')
print('UnloaderConnectorClearanceTest: OK')
