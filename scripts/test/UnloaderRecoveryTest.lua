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

print('UnloaderRecoveryTest: OK')
