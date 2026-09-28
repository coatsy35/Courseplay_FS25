dofile('scripts/CpObject.lua')
dofile('scripts/geometry/Vector.lua')
dofile('scripts/pathfinder/AnalyticSolution.lua')
dofile('scripts/pathfinder/State3D.lua')
dofile('scripts/pathfinder/Dubins.lua')
dofile('scripts/util/CpMathUtil.lua')
dofile('scripts/ai/util/VehicleRouteConflict.lua')
AIUtil = {
    getWidth = function(vehicle) return vehicle.width end,
    getLength = function(vehicle) return vehicle.length end,
}
MathUtil = {vector2Length = function(x, z) return math.sqrt(x * x + z * z) end}
CpUtil = {getName = function() return 'combine' end}
PathfinderUtil = {hasFruit = function() return false end, dubinsSolver = DubinsSolver(),
    getVehiclePositionAsState3D = function(vehicle)
        local node = vehicle.rootNode
        return State3D(node.x, -node.z, CpMathUtil.angleFromGame(node.heading or 0))
    end}
FieldworkBoundary = {contains = function(_, _, z) return z >= 0 and z < 80 end,
    containsCourse = function() return true end}
Waypoint = function(point) return point end
function getWorldTranslation(node) return node.x, 0, node.z end
function localToWorld(node, _, _, offset) return node.x, 0, node.z + offset end
dofile('scripts/ai/strategies/AIDriveStrategyUnloadCombine.lua')

local trailer = {width = 5, length = 9, rootNode = {x = 10, z = 0}}
local tractor = {width = 4, length = 6, rootNode = {x = 20, z = 0},
    getChildVehicles = function() return {trailer} end,
    getAIDirectionNode = function(self) return self.rootNode end}
local parkedTrailer = {width = 5, rootNode = {x = 20, z = 27.5}}
local parkedTractor = {width = 4, rootNode = {x = 20, z = 28},
    getChildVehicles = function() return {parkedTrailer} end}
g_currentMission = {vehicleSystem = {vehicles = {tractor, parkedTractor}}}
local driver = {getWorkWidth = function() return 15 end}
local combine = {getCpDriveStrategy = function() return driver end}
AIDriveStrategyCombineCourse = {isActiveCpCombine = function(vehicle) return vehicle == combine end}
local strategy = setmetatable({vehicle = tractor, standbyAssignment = {}, turningRadius = 9,
    states = {WAITING_IN_STANDBY = {}, WAITING_FOR_STANDBY_PATHFINDER = {}, DRIVING_TO_STANDBY = {}},
    state = {}, debug = function() end, setMaxSpeed = function() end}, {__index = AIDriveStrategyUnloadCombine})
strategy.getFieldworkBoundaryForRig = function() return {} end
strategy.getHarvesterTurnClearanceDistance = function() return 30 end
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

-- A parked rig must not chase clearance for a segment the combine has already passed.
local futureIntersects = false
local pastCourse = {getNumberOfWaypoints = function() return 3 end,
    getWaypointPosition = function(_, ix)
        local points = {{20, 0}, {20, -20}, futureIntersects and {20, 0} or {50, -20}}
        return points[ix][1], 0, points[ix][2]
    end,
    getNextWaypointIxWithinDistance = function() return 3 end}
driver.ppc = {getCourse = function() return pastCourse end,
    getRelevantWaypointIx = function() return 2 end}
combine.rootNode = {x = 20, z = -20}
combine.width, combine.length = 15, 8
combine.getAIDirectionNode = function(self) return self.rootNode end
function localToLocal(node, reference) return node.x - reference.x, 0, node.z - reference.z end
strategy.getHarvesterTurnClearanceDistance = function() return 30 end
strategy.connectorClearance = nil
target = nil
g_currentMission.vehicleSystem.vehicles = {tractor, parkedTractor, combine}
assert(strategy:isRigClearOfCourse(pastCourse, 12, 2, 3) and
        not strategy:moveOutOfApproachingHarvesterPath() and not target,
    'A combine turning away must not send a parked trailer across its route')
futureIntersects = true
assert(not strategy:isRigClearOfCourse(pastCourse, 12, 2, 3) and
        strategy:moveOutOfApproachingHarvesterPath() and strategy.connectorClearance,
    'An imminent route overlap must still trigger collision-aware clearance')
local activeEscape = strategy.connectorClearance
activeEscape.reverseAttempts = 1
strategy.state = strategy.states.DRIVING_TO_STANDBY
local secondHarvester = {getCpDriveStrategy = function() return driver end}
target = nil
strategy:requestToMoveOutOfWay(secondHarvester, nil, course)
assert(strategy.connectorClearance == activeEscape and activeEscape.harvester == combine and
        activeEscape.reverseAttempts == 1 and not target,
    'A second combine must not interrupt and restart an unfinished reverse/clearance manoeuvre')
driver.ppc.getCourse = function() return {} end
strategy:updateStandbyCoordinator()
assert(strategy.connectorClearance == activeEscape and strategy.state == strategy.states.DRIVING_TO_STANDBY,
    'Replacing the combine PPC course must not declare a physically obstructing trailer clear')
driver.ppc.getCourse = function() return pastCourse end
futureIntersects = false
strategy.state = strategy.states.DRIVING_TO_STANDBY
strategy:updateStandbyCoordinator()
assert(not strategy.connectorClearance and strategy.state == strategy.states.WAITING_IN_STANDBY and
        strategy.standbyYieldingToHarvester == combine,
    'A clearing trailer must stop when the combine turns away from its remaining connector')
strategy.connectorClearance = {harvester = combine, course = pastCourse, distance = 12}
combine.getIsCpActive = function() return false end
strategy:updateStandbyCoordinator()
assert(not strategy.connectorClearance,
    'A parked trailer must discard an obsolete clearance request when the combine job ends')
combine.getIsCpActive = nil
g_currentMission.vehicleSystem.vehicles = {tractor, parkedTractor}
combine.rootNode = nil

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
local nearLimitCourse = {getNumberOfWaypoints = function() return 3 end,
    getWaypointPosition = function(_, ix) return ({0, 149.995, 300})[ix], 0, 0 end}
driver.ppc = {getCourse = function() return nearLimitCourse end,
    getCurrentWaypointIx = function() return 1 end}
assert(not strategy:isStandbyTargetOnHarvesterRoute({x = 300, z = 100}),
    'A sub-decimetre route segment at the 150 m lookahead limit must not divide by zero')
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
strategy.standbyYieldingToHarvester = combine
strategy:updateStandbyCoordinator()
assert(strategy.state == strategy.states.IDLE and not strategy.connectorClearance,
    'An idle rig may rejoin the pool only after its full train clears the connector')
assert(strategy.standbyYieldingToHarvester == combine,
    'Clearing the route must not send the trailer back while the combine is still approaching')
combine.getIsCpActive = function() return true end
driver.states = {DRIVING_TO_WORK_START_WAYPOINT = {}}
driver.state = driver.states.DRIVING_TO_WORK_START_WAYPOINT
target = nil
strategy:setStandbyAssignment({harvester = combine, role = 'STANDBY', waypoint = {x = 20, z = 0}})
assert(strategy.state == strategy.states.WAITING_IN_STANDBY and not target,
    'A safe standby trailer must remain parked until the combine finishes its connector')
driver.states.TURNING = {}
driver.state = driver.states.TURNING
driver.aiTurn = {isDistantPathfinderTurn = true}
strategy:setStandbyAssignment({harvester = combine, role = 'STANDBY', waypoint = {x = 20, z = 0}})
assert(strategy.state == strategy.states.WAITING_IN_STANDBY and not target and
        strategy.standbyYieldingToHarvester == combine,
    'Clearing a distant CourseTurn must not send the trailer back while the combine retries or travels')
driver.aiTurn = nil
driver.state = driver.states.DRIVING_TO_WORK_START_WAYPOINT

-- If forward-only pathfinding cannot turn past a combine header, a clear straight reverse makes
-- enough room for another route search. An occupied rear corridor must never be used.
tractor.rootNode.z, trailer.rootNode.z = 30, 20
combine.rootNode, combine.width, combine.length = {x = 20, z = 55}, 15, 8
g_currentMission.vehicleSystem.vehicles = {tractor, combine}
function localToLocal(node, reference) return node.x - reference.x, 0, node.z - reference.z end
FieldworkBoundary.captureRig = function(vehicle)
    return {{x = vehicle.rootNode.x, z = vehicle.rootNode.z, heading = 0,
        box = {width = vehicle.width / 2, length = vehicle.length / 2}}}
end
FieldworkBoundary.rigOutsideDistance = function(_, rig) return rig[1].z < 0 and 1 or 0 end
FieldworkBoundary.advanceRig = function(rig, x, z) rig[1].x, rig[1].z = x, z end
Course = {createStraightReverseCourse = function(vehicle, distance)
    return {reverseDistance = distance, getNumberOfWaypoints = function() return 2 end,
        getWaypointPosition = function(_, ix) return vehicle.rootNode.x, 0, vehicle.rootNode.z - (ix - 1) * distance end,
        isReverseAt = function() return true end}
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

-- A real proximity stop on an accepted escape is different from another caller's repeated request.
-- Exercise the live callback and real reverse-corridor check, retaining the original clearance owner.
g_time = 100000
tractor.getIsCpActive = function() return true end
strategy.connectorClearance = {harvester = combine, course = course, reverseAttempts = 0}
strategy.state = strategy.states.DRIVING_TO_STANDBY
strategy.standbyTargetX, strategy.standbyTargetZ = 40, 60
local blockedEscape = strategy.connectorClearance
g_currentMission.vehicleSystem.vehicles = {tractor, combine}
strategy:onBlockingVehicle(combine, false)
assert(strategy.connectorClearance == blockedEscape and blockedEscape.reverseAttempts == 1 and
        strategy.course.reverseDistance == 20 and blockedEscape.harvester == combine,
    'A physically blocked escape must reverse through verified free space without giving priority to the trailer')
strategy:onBlockingVehicle(combine, false)
assert(blockedEscape.reverseAttempts == 1, 'Repeated callbacks must not restart the recovery every frame')
g_time = 111000
g_currentMission.vehicleSystem.vehicles = {tractor, combine, rearVehicle}
strategy:onBlockingVehicle(combine, false)
assert(strategy.state == strategy.states.WAITING_IN_STANDBY and strategy.standbyRetryAt == 111500 and
        blockedEscape.reverseAttempts == 1 and blockedEscape.failedTargets[1].x == 40,
    'If the rear is occupied, hold and retry another checked route instead of reversing blindly or deadlocking')
g_time = 112000
local previousAttempt = blockedEscape.attempt
strategy:startConnectorClearance(combine, course)
blockedEscape = strategy.connectorClearance
assert(blockedEscape.blockedRecoveryAt == 121000, 'A new target must preserve the same owner\'s recovery throttle')
strategy.state = strategy.states.DRIVING_TO_STANDBY
strategy:onBlockingVehicle(combine, false)
assert(blockedEscape.attempt == previousAttempt and strategy.state == strategy.states.DRIVING_TO_STANDBY,
    'A completed target search must not bypass throttling against the same persistent blocker')
strategy.state = strategy.states.DRIVING_TO_STANDBY
g_time = 122000
g_currentMission.vehicleSystem.vehicles = {tractor, combine}
strategy:onBlockingVehicle(combine, true)
assert(strategy.state == strategy.states.WAITING_IN_STANDBY and blockedEscape.reverseAttempts == 1,
    'A rear proximity blocker must never trigger a further reverse')
-- Use the real Dubins solver to verify travel, rather than only checking that some goal was selected.
-- Rotate/mirror the same clear departure: a tractor already facing away needs no loops or final turn.
local simpleCourse = {getNumberOfWaypoints = function() return 2 end}
local selected
local simple = setmetatable({vehicle = tractor, turningRadius = 9, debug = function() end,
    getFieldworkBoundaryForRig = function() return {} end,
    getHarvesterTurnClearanceDistance = function() return 30 end,
    isRigClearOfConnectorClearance = function() return false end,
    startPathfindingToStandby = function(_, _, waypoint, avoidHarvester)
        assert(avoidHarvester, 'Shorter goals must still include the combine in collision checking')
        selected = waypoint
    end}, {__index = AIDriveStrategyUnloadCombine})
g_currentMission.vehicleSystem.vehicles = {tractor}
PathfinderUtil.hasFruit = function() return false end
FieldworkBoundary.contains = function() return true end
for _, degrees in ipairs({0, 37, 90, 180, 217, 270}) do
    for _, mirror in ipairs({-1, 1}) do
        local a = math.rad(degrees)
        local function rotate(x, z)
            return x * math.cos(a) + z * math.sin(a), -x * math.sin(a) + z * math.cos(a)
        end
        simpleCourse.getWaypointPosition = function(_, ix)
            local x, z = rotate(mirror * (ix == 1 and -100 or 100), 0)
            return x, 0, z
        end
        tractor.rootNode = {x = 0, z = 0, heading = a}
        simple.connectorClearance = nil
        simple:startConnectorClearance(combine, simpleCourse)
        local start = PathfinderUtil.getVehiclePositionAsState3D(tractor)
        local goal = State3D(selected.x, -selected.z, CpMathUtil.angleFromGameDeg(selected.angle))
        local pathLength = PathfinderUtil.dubinsSolver:solve(start, goal, 9):getLength(9)
        local direct = MathUtil.vector2Length(selected.x, selected.z)
        assert(pathLength < direct + 0.001 and pathLength < 40,
            'A clear straight departure must not acquire a loop to match the connector heading')
        assert(math.abs(math.sin(math.rad(selected.angle) - a)) < 0.001,
            'Arrival heading must retain its quadrant at every compass bearing')
    end
end

-- At a corner the old first-valid search chose the far along-course point (60,27.5)
-- before trying a slightly wider but much shorter move straight ahead (0,39.5).
tractor.rootNode = {x = 0, z = 0, heading = 0}
simpleCourse.getWaypointPosition = function(_, ix) return ix == 1 and -100 or 100, 0, 0 end
FieldworkBoundary.contains = function(_, x, z) return x >= 50 or z >= 32 end
simple.connectorClearance = nil
simple:startConnectorClearance(combine, simpleCourse)
assert(math.abs(selected.x) < 0.001 and selected.z < 55,
    'Compare all available goals before sending the trailer far along the headland')

-- Facing away at a marginal target would leave the rear in the combine's path. A different
-- arrival heading is acceptable; a tractor-only clearance check is not.
FieldworkBoundary.contains = function() return true end
local goal = simple:getConnectorClearanceGoal(State3D(0, 0, CpMathUtil.angleFromGame(0)),
        0, 23, math.pi / 2, {}, math.huge)
assert(goal, 'A parallel holding orientation should still fit')
local rear = 3 - 15
local rearX, rearZ = goal.x + math.sin(math.rad(goal.angle)) * rear,
        goal.z + math.cos(math.rad(goal.angle)) * rear
assert(simple.getDistanceFromConnectingCourse(simpleCourse, rearX, rearZ) >= simple.connectorClearance.distance,
    'An accepted parking pose must leave room for the trailer rear, not only the tractor')
print('UnloaderConnectorClearanceTest: OK')
