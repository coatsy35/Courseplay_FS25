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
    createBoundaryContainedReverseCourse = function() return nil, 0 end,
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
strategy.createBoundaryContainedReverseCourse = function() return {}, 18 end
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

print('UnloaderRecoveryTest: OK')
