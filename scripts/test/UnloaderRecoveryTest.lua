function CpObject()
    return {}
end

AIDriveStrategyCourse = {}
CpUtil = {
    getName = function(vehicle) return vehicle.name end,
}

dofile('scripts/ai/strategies/AIDriveStrategyUnloadCombine.lua')

local released = false
local strategy = {
    turningRadius = 12,
    debug = function() end,
    createClearanceReverseCourse = function() return nil, 0 end,
    startWaitingForSomethingToDo = function() released = true end,
}
setmetatable(strategy, { __index = AIDriveStrategyUnloadCombine })

strategy:startMovingBackBeforePathfinding({}, {})
assert(released,
        'An unloader unable to reverse inside the field must release its combine instead of retaining a dead assignment')

local combine = { name = 'Waiting combine' }
released = false
strategy.combineToUnload = combine
strategy.state = {}
strategy.states = {
    UNLOADING_MOVING_COMBINE = {},
    UNLOADING_STOPPED_COMBINE = {},
}
assert(strategy:yieldCallToCloserUnloader(combine),
        'An en-route unloader must yield its call to a materially closer eligible trailer')
assert(released, 'Yielding an en-route call must release the old combine registration')

released = false
strategy.combineToUnload = combine
strategy.state = strategy.states.UNLOADING_STOPPED_COMBINE
assert(not strategy:yieldCallToCloserUnloader(combine),
        'An unloader must not yield once stopped-combine unloading is under way')
assert(not released, 'An actively unloading trailer must retain its combine registration')

local backedOut = false
local releasedBlockedCall = false
strategy.state = {}
strategy.states.MOVING_AWAY_FROM_OTHER_VEHICLE = {}
strategy.combineToUnload = combine
strategy.createClearanceReverseCourse = function() return {}, 18 end
strategy.releaseCombine = function(self)
    releasedBlockedCall = true
    self.combineToUnload = nil
end
strategy.setNewState = function(self, state)
    self.state = state
    self.state.properties = {}
end
strategy.startCourse = function() backedOut = true end
assert(strategy:yieldCallToCloserUnloader(combine, true),
        'A blocked en-route unloader must yield to another eligible trailer')
assert(releasedBlockedCall and backedOut,
        'A blocked unloader must release the combine and reverse on a boundary-contained recovery course')

CpDelayedBoolean = function()
    return { get = function(_, condition) return condition end }
end
AIUtil = { isStopped = function() return true end }
local combineStrategy = {
    isWaitingForUnload = function() return true end,
    alwaysNeedsUnloader = function() return false end,
    getFillLevelPercentage = function() return 100 end,
}
combine.getCpDriveStrategy = function() return combineStrategy end
combine.getCpSettings = function()
    return { callUnloaderPercent = { getValue = function() return 80 end } }
end
strategy.states.WAITING_FOR_PATHFINDER = {}
strategy.states.WAITING_FOR_STANDBY_PATHFINDER = {}
strategy.state = strategy.states.WAITING_FOR_PATHFINDER
strategy.combineToUnload = combine
strategy.inDeadlock = nil
assert(not strategy:isInDeadlock(),
        'A stationary tractor calculating a route must not be treated as blocked and repeatedly reassigned')

strategy.state = strategy.states.UNLOADING_STOPPED_COMBINE
combineStrategy.isDischarging = function() return true end
assert(not strategy:isInDeadlock(),
        'A stopped trailer receiving grain must remain available to a nearby combine')
combineStrategy.isDischarging = function() return false end
assert(strategy:isInDeadlock(),
        'A stopped trailer without grain flow must still be eligible for deadlock recovery')

-- A called trailer must not copy the temporary reverse course while the combine is creating its pocket.
local startedPocketUnload = false
local heldBehindPocket = false
local pocketCombineStrategy = {
    isWaitingForUnload = function() return false end,
    canUnloadWhileMovingAtCurrentPosition = function() return true end,
    isManeuvering = function() return true end,
    isMakingPocket = function() return false end,
}
local pocketCombine = { getCpDriveStrategy = function() return pocketCombineStrategy end }
strategy.combineToUnload = pocketCombine
strategy.setFieldSpeed = function() end
strategy.isOkToStartUnloadingCombine = function() return true end
strategy.startUnloadingCombine = function() startedPocketUnload = true end
strategy.getDistanceFromCombine = function() return 20 end
strategy.getHarvesterTurnClearanceDistance = function() return 50 end
strategy.setMaxSpeed = function(_, speed) heldBehindPocket = speed == 0 end
UnloaderCoordinator = { getStandbyDistance = function() return 30 end }
strategy:followCombineToPocket()
assert(not startedPocketUnload and heldBehindPocket,
        'A trailer must hold behind instead of copying the combine reverse course while a pocket is being made')

heldBehindPocket = false
strategy.getDistanceFromCombine = function() return 60 end
pocketCombineStrategy.isMakingPocket = function() return true end
strategy:followCombineToPocket()
assert(not startedPocketUnload and not heldBehindPocket,
        'A trailer must follow forward at a safe gap while the combine cuts the pocket')

strategy.isOkToStartUnloadingCombine = function() return false end
pocketCombineStrategy.isWaitingForUnload = function() return true end
strategy:followCombineToPocket()
assert(startedPocketUnload,
        'A completed pocket must start a fresh forward pipe approach without the moving-unload alignment gate')

-- A full trailer must hand over where it stands when AutoDrive is ready. AutoDrive then owns the route from the
-- field to its network; Courseplay must not drive back across the field to the configured access point first.
local handovers = 0
local pathfindingStarted = false
strategy.useGiantsUnload = false
strategy.vehicle = {
    getCanAdTakeControl = function() return true end,
}
strategy.augerWagon = nil
strategy.fieldUnloadPositionNode = nil
strategy.invertedStartPositionMarkerNode = {}
strategy.setMaxSpeed = function() end
strategy.releaseCombine = function() end
strategy.startPathfindingToInvertedGoalPositionMarker = function() pathfindingStarted = true end
strategy.onTrailerFull = function() handovers = handovers + 1 end
UnloaderCoordinator.release = function() end
strategy:startUnloadingTrailers()
assert(handovers == 1 and not pathfindingStarted,
        'A full trailer must release directly to an available AutoDrive job instead of returning to the start marker')

-- If a legacy return route reaches the field edge, stop at the last safe position and request the handover once.
strategy.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL = {}
strategy.state = strategy.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL
strategy.fullTrailerHandoverRequested = nil
strategy:requestFullTrailerHandover('boundary')
strategy:requestFullTrailerHandover('boundary repeated')
assert(handovers == 2, 'A boundary-triggered full-trailer handover must only be requested once')

-- Active approaches use the actual field polygon. The full-rig boundary remains deliberately stricter for
-- unattended staging and clearance moves, but must not reject a normal pipe-side target near an edge.
local polygon = { {}, {}, {} }
strategy.vehicle = {
    cpGetFieldPolygon = function() return polygon end,
    cpGetIslandPolygons = function() return { 'island' } end,
    stopCurrentAIJob = function() error('Approach recovery must not stop the AI job') end,
}
strategy.combineApproachBoundary = nil
local approachBoundary = strategy:getFieldworkBoundaryForCombineApproach()
assert(approachBoundary.polygon == polygon and approachBoundary.margin == 0 and
        approachBoundary.islands[1] == 'island',
        'A combine approach must use the field polygon without the conservative full-rig inset')

-- A rejected exact pipe route recovers through a harvested point behind the assigned combine and retains both the
-- running worker and the active assignment.
local recoveryStarted = false
strategy.combineToUnload = combine
strategy.states.WAITING_FOR_PATHFINDER = {}
strategy.setNewState = function(self, state) self.state = state end
strategy.startPathfindingToMovingCombine = function(_, waypoint)
    recoveryStarted = waypoint.x == 12 and waypoint.z == 34
end
UnloaderCoordinator.getStagingWaypoint = function(_, harvester)
    assert(harvester == combine, 'Recovery must retain the assigned combine')
    return { x = 12, z = 34 }
end
assert(strategy:recoverFromFailedCombineApproach(),
        'A failed exact pipe approach must recover through an in-field staging point')
assert(recoveryStarted and strategy.combineToUnload == combine,
        'Approach recovery must retain the active combine assignment')

-- A valid pathfinder course remains usable when only its optional straight alignment extension reaches the edge.
local extendedBy
strategy.combinePathBoundary = {}
FieldworkBoundary = {
    containsSegment = function(_, _, _, goalX) return goalX <= 14 end,
}
local approachCourse = {
    getNumberOfWaypoints = function() return 5 end,
    getWaypointPosition = function() return 10, 0, 20 end,
    extend = function(_, length) extendedBy = length end,
}
assert(strategy:extendCombineApproachWithinField(approachCourse, 10, 1, 0) == 4 and extendedBy == 4,
        'The final alignment extension must be clipped at the boundary instead of discarding the valid route')

-- A short, forward pipe-side correction must join the normal stopped-combine unload course directly. Running the
-- exact-heading pathfinder for this geometry creates a needless loop and can leave a full combine waiting.
local directCombineStrategy = {
    willWaitForUnloadToFinish = function() return true end,
    isReadyToUnload = function() return true end,
}
local directTarget = {}
strategy.combineToUnload = { getCpDriveStrategy = function() return directCombineStrategy end }
strategy.vehicle = { getAIDirectionNode = function() return 'tractorDirection' end }
strategy.turningRadius = 9
strategy.directStoppedApproachTurningRadiusFactor = 3
strategy.getTargetNode = function() return directTarget end
strategy.getFieldworkBoundaryForCombineApproach = function() return {} end
local directDx, directDz = 5, 13
localToLocal = function() return directDx, 0, directDz end
getWorldTranslation = function() return 0, 0, 0 end
localToWorld = function() return directDx, 0, directDz end
MathUtil = MathUtil or {}
MathUtil.vector2Length = function(x, z) return math.sqrt(x * x + z * z) end
CpMathUtil = CpMathUtil or {}
CpMathUtil.isSameDirection = function() return true end
FieldworkBoundary.containsSegment = function() return true end
FieldworkBoundary.captureRig = function() return {} end
FieldworkBoundary.sweepRigSegment = function() return true end
assert(strategy:canStartDirectStoppedCombineApproach(directTarget, 0, 0),
        'A target 14 metres ahead with a modest lateral correction must bypass the global pathfinder')
directDz = -13
assert(not strategy:canStartDirectStoppedCombineApproach(directTarget, 0, 0),
        'A target behind the tractor must still use a manoeuvring route')
directDz = 13
FieldworkBoundary.containsSegment = function() return false end
assert(strategy:canStartDirectStoppedCombineApproach(directTarget, 0, 0),
        'The optional boundary preference must not veto a normal nearby pipe approach')
FieldworkBoundary.containsSegment = function() return true end
directCombineStrategy.isWaitingForUnloadAfterPulledBack = function() return false end
directCombineStrategy.hasAutoAimPipe = function() return false end
directCombineStrategy.getMeasuredBackDistance = function() return 6 end
local directApproachStarted = false
strategy.getPipeOffset = function() return 11, -6 end
strategy.getPipeOffsetReferenceNode = function() return directTarget end
local originalHoldNearbyStandbyUnloadersForDeparture =
        AIDriveStrategyUnloadCombine.holdNearbyStandbyUnloadersForDeparture
strategy.holdNearbyStandbyUnloadersForDeparture = function() end
strategy.isOkToStartUnloadingCombine = function() return false end
strategy.startUnloadingStoppedCombine = function() directApproachStarted = true end
strategy.startUnloadingCombine = AIDriveStrategyUnloadCombine.startUnloadingCombine
strategy.queueForDeparture = function() return false end
strategy.isPathfindingNeeded = function() error('The direct approach must not invoke the global pathfinder') end
UnloaderCoordinator.release = function() end
assert(strategy:call(strategy.combineToUnload, nil) and directApproachStarted,
        'A stopped combine call with close forward geometry must start the unload course immediately')
strategy.holdNearbyStandbyUnloadersForDeparture = originalHoldNearbyStandbyUnloadersForDeparture

-- A standby at a shared entry holds while a nearby active trailer departs. Clearance scales with both complete
-- tractor/trailer trains and their turning radii rather than a fixed user-facing distance.
local function makeVehicle(x, z)
    return {
        rootNode = { x = x, z = z },
        getChildVehicles = function() return { { length = 9 } } end,
        length = 6,
    }
end
AIUtil.getLength = function(vehicle) return vehicle.length end
getWorldTranslation = function(node) return node.x, 0, node.z end
MathUtil = MathUtil or {}
MathUtil.vector2Length = function(x, z) return math.sqrt(x * x + z * z) end
strategy.vehicle = makeVehicle(0, 0)
strategy.turningRadius = 9
strategy.combineToUnload = nil
local departing = {
    vehicle = makeVehicle(12, 0),
    turningRadius = 9,
    combineToUnload = combine,
    states = strategy.states,
    state = strategy.states.WAITING_FOR_PATHFINDER,
}
AIDriveStrategyUnloadCombine.activeUnloaders = { [strategy] = strategy.vehicle, [departing] = departing.vehicle }
assert(strategy:getNearbyDepartingUnloader() == departing,
        'A nearby active departure must be detected before another standby movement begins')
local heldForDeparture = false
strategy.isAvailableForStaging = function() return true end
strategy.holdAtStandbyPosition = function() heldForDeparture = true end
strategy.debugSparse = function() end
strategy:setStandbyAssignment({ harvester = combine, waypoint = { x = 30, z = 30 } })
assert(heldForDeparture, 'A standby movement must yield while a nearby active trailer clears the shared entry')

local nearbyStandbyHeld = false
local nearbyStandby = {
    vehicle = makeVehicle(10, 0),
    turningRadius = 9,
    isInStandbyState = function() return true end,
    holdAtStandbyPosition = function() nearbyStandbyHeld = true end,
}
AIDriveStrategyUnloadCombine.activeUnloaders = {
    [strategy] = strategy.vehicle,
    [nearbyStandby] = nearbyStandby.vehicle,
}
strategy:holdNearbyStandbyUnloadersForDeparture()
assert(nearbyStandbyHeld,
        'Promoting an active call must immediately stop a nearby provisional movement at the shared entry')

print('UnloaderRecoveryTest: OK')

-- A normal moving-combine unload must clear the pipe side before re-entering the pool.
local movingClearance = {isWaitingInPocket = function() return false end,
    isTurningOnHeadland = function() return false end,
    isTurning = function() return false end,
    isAboutToTurn = function() return false end}
local movingCombine = {rootNode = {x = 0, z = 0}, getCpDriveStrategy = function() return movingClearance end}
local reverseState = {}
local clearRig = setmetatable({combineToUnload = movingCombine, states = {MOVING_BACK = reverseState},
    settings = {fullThreshold = {getValue = function() return 85 end}},
    getAllTrailersFull = function() return false end,
    startMovingBackFromCombine = function(self, state, combine, hold)
        self.reverseRequest = {state, combine, hold}
    end,
    debug = function() end}, {__index = AIDriveStrategyUnloadCombine})
clearRig:onUnloadingMovingCombineFinished(movingClearance)
assert(clearRig.reverseRequest and clearRig.reverseRequest[1] == reverseState and
        clearRig.reverseRequest[2] == movingCombine,
        'An emptied moving combine must receive a reverse clearance move before the rig parks')

-- Completing the planned reverse is insufficient when the tractor remains inside the actual envelope.
getWorldTranslation = function(node) return node.x, 0, node.z end
local extension, started = nil, false
clearRig.vehicle = {rootNode = {x = 20, z = 0}}
clearRig.state = {properties = {vehicle = movingCombine, clearanceDistance = 50}}
clearRig.getHarvesterTurnClearanceDistance = function() return 50 end
clearRig.createClearanceReverseCourse = function(_, distance) extension = distance; return {} end
clearRig.startCourse = function() started = true end
assert(clearRig:extendReverseForClearance() and started and extension > 30,
        'Reverse must continue when the course ends before the rig has cleared the combine')
clearRig.vehicle.rootNode.x = 55
assert(not clearRig:extendReverseForClearance(), 'Verified clearance must finish the reverse')
print('Moving-combine release and measured reverse clearance regressions: OK')
