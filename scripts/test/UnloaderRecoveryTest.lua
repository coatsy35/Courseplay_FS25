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

print('UnloaderRecoveryTest: OK')
