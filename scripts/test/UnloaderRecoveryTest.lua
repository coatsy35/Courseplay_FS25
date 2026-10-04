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

local clearanceSpeed
local reversing = false
local clearance = setmetatable({
    settings = {fieldSpeed = {getValue = function() return 20 end},
        reverseSpeed = {getValue = function() return 8 end}},
    ppc = {isReversing = function() return reversing end},
    state = {properties = {vehicle = {getCpDriveStrategy = function() return nil end}}},
    movingAwayDelay = {get = function() return true end},
    setMaxSpeed = function(_, speed) clearanceSpeed = speed end,
}, {__index = AIDriveStrategyUnloadCombine})
clearance:moveAwayFromOtherVehicle()
assert(clearanceSpeed == 20, 'Forward clearance must use CP field speed')
reversing = true
clearance:moveAwayFromOtherVehicle()
assert(clearanceSpeed == 8, 'Reverse clearance must use CP reverse speed')

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
strategy.startPipeApproachFromPocket = function() startedPocketUnload = true end
strategy.getDistanceFromCombine = function() return 20 end
strategy.getHarvesterTurnClearanceDistance = function() return 50 end
strategy.setMaxSpeed = function(_, speed) heldBehindPocket = speed == 0 end
UnloaderCoordinator = { getStandbyDistance = function() return 30 end,
    hasPhysicalHarvesterClearance = function() return true end }
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
        'A completed coordinator pocket must request the normal pipe approach')

-- AD readiness is not permission to abandon CP's checked field departure.
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
strategy.startFullTrailerDeparture = function() pathfindingStarted = true end
strategy.onTrailerFull = function() handovers = handovers + 1 end
UnloaderCoordinator.release = function() end
strategy:startUnloadingTrailers()
assert(handovers == 0 and pathfindingStarted,
        'A full trailer must retain CP control and start its checked departure even when AD is ready')

-- If a legacy return route reaches the field edge, stop at the last safe position and request the handover once.
strategy.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL = {}
strategy.state = strategy.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL
strategy.fullTrailerHandoverRequested = nil
strategy:requestFullTrailerHandover('boundary')
strategy:requestFullTrailerHandover('boundary repeated')
assert(handovers == 1, 'A verified full-trailer handover must only be requested once')

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

-- A nearby but unaligned call must use CP's ordinary rear pathfinding target, with no direct shortcut.
local requested
local waitingStrategy = {willWaitForUnloadToFinish = function() return true end,
    isWaitingForUnloadAfterPulledBack = function() return false end,
    hasAutoAimPipe = function() return false end, getMeasuredBackDistance = function() return 6 end}
local waitingCombine = {getCpDriveStrategy = function() return waitingStrategy end}
strategy.getPipeOffset = function() return 11, -6 end
strategy.getPipeOffsetReferenceNode = function() return {} end
local originalHold = AIDriveStrategyUnloadCombine.holdNearbyStandbyUnloadersForDeparture
strategy.holdNearbyStandbyUnloadersForDeparture = function() end
strategy.isOkToStartUnloadingCombine = function() return false end
strategy.queueForDeparture = function() return false end
strategy.isPathfindingNeeded = function() return true end
strategy.startPathfindingToWaitingCombine = function(_, x, z) requested = {x, z} end
UnloaderCoordinator.release = function() end
assert(strategy:call(waitingCombine, nil) and requested and requested[1] == 11 and requested[2] == -8,
    'An unaligned tractor must enter from the original rear target, not jump directly onto the pipe course')
strategy.holdNearbyStandbyUnloadersForDeparture = originalHold

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
g_currentMission = {vehicleSystem = {vehicles = {}}}
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

-- Recorded Oct 1 row-end stall: 89% grain remains, TURNING, no discharge or processing,
-- but the tractor stayed in UNLOADING_MOVING_COMBINE indefinitely instead of reversing clear.
local autoAim = false
local turning, finishing, discharging, processing, always, headland = true, false, false, false, false, false
local rowEnd = {
    isTurning = function() return turning end, isAboutToTurn = function() return not turning end,
    isFinishingRow = function() return finishing end, isDischarging = function() return discharging end,
    isProcessingFruit = function() return processing end, alwaysNeedsUnloader = function() return always end,
    hasAutoAimPipe = function() return autoAim or always end,
    getFillLevelPercentage = function() return 89 end,
    willWaitForUnloadToFinish = function() return false end,
    isManeuvering = function() return turning end,
}
local endCombine = {getCpDriveStrategy = function() return rowEnd end}
local reversed, forwardGoal, speed, normalLookahead = nil, false, nil, false
local rowRig = setmetatable({combineToUnload = endCombine,
    state = {}, states = {MOVING_BACK = {}, UNLOADING_STOPPED_COMBINE = {}},
    followCourse = {setOffset = function() end, isTurnStartAtIx = function() return false end,
        getCurrentWaypointIx = function() return 100 end},
    settings = {fullThreshold = {getValue = function() return 85 end}},
    getFollowingCourseOffset = function() return -12.2 end,
    changeToUnloadWhenTrailerFull = function() return false end,
    driveBesideCombine = function() return 90, 90 end,
    ppc = {setNormalLookaheadDistance = function() normalLookahead = true end},
    startMovingBackFromCombine = function(self, state, combine, hold)
        reversed = {state = state, combine = combine, hold = hold}
        self.state = state
    end,
    isBehindAndAlignedToCombine = function() return true end,
    setMaxSpeed = function(_, value) speed = value end,
    debug = function() end, debugSparse = function() end,
}, {__index = AIDriveStrategyUnloadCombine})
local gx = rowRig:unloadMovingCombine()
assert(reversed and reversed.state == rowRig.states.MOVING_BACK and reversed.combine == endCombine and
    reversed.hold and normalLookahead and gx == nil,
    'A fixed-pipe combine starting a turn without discharge must trigger clearance reverse even with grain remaining')
for _, reason in ipairs({'discharge', 'processing', 'finishing', 'forager', 'autoAim', 'aboutToTurn'}) do
    reversed, normalLookahead = nil, false
    rowRig.state = {}
    turning, finishing, discharging, processing, always, autoAim = true, false, false, false, false, false
    if reason == 'discharge' then discharging = true
    elseif reason == 'processing' then processing = true
    elseif reason == 'finishing' then finishing = true
    elseif reason == 'forager' then always, processing = true, true
    elseif reason == 'autoAim' then autoAim = true
    else turning = false end
    rowRig:unloadMovingCombine()
    assert(not reversed, 'Do not interrupt ' .. reason .. ' for row-end clearance')
end
-- The actual reverse primitive reserves/holds the full turn clearance, rather than post-unload clearance.
turning, finishing, always = true, false, false
rowRig.UNLOAD_TYPES = {SILO_LOADER = 'silo'}
rowRig.unloadTargetType = 'combine'
rowRig.vehicle = {rootNode = {x = 50, z = 0}}
rowRig.getHarvesterTurnClearanceDistance = function() return 40 end
local registered, requested, startedReverse
UnloaderCoordinator.registerClearingUnloader = function(_, driver, combine, distance)
    registered = distance; assert(driver == rowRig and combine == endCombine)
end
rowRig.createClearanceReverseCourse = function(_, distance) requested = distance; return {}, distance end
rowRig.setNewState = function(self, state) self.state = {properties = {}, requested = state} end
rowRig.startCourse = function() startedReverse = true end
rowRig.settings.reverseSpeed = {getValue = function() return 5 end}
AIDriveStrategyUnloadCombine.startMovingBackFromCombine(rowRig, rowRig.states.MOVING_BACK, endCombine, true)
assert(requested == 40 and registered == 40 and startedReverse and rowRig.state.properties.holdCombine and
    rowRig.state.properties.clearanceDistance == 40,
    'An active turn must reserve and drive the full reverse clearance while holding the combine')
print('Row-end no-discharge reverse and protected transfer regressions: OK')

-- Recorded 2986 stall: a full on-field combine stopped, but its follower did not transfer or retry.
do
    local states = {UNLOADING_ON_FIELD = {}, WAITING_FOR_UNLOAD_ON_FIELD = {}, POCKET = {}}
    local status = {flow = false, processing = false, pipeMoving = false, turning = false, autoAim = false, fill = 99.5}
    local driver = {states = states, state = states.UNLOADING_ON_FIELD, unloadState = states.WAITING_FOR_UNLOAD_ON_FIELD,
        hasAutoAimPipe = function() return status.autoAim end, alwaysNeedsUnloader = function() return false end,
        isTurning = function() return status.turning end, isManeuvering = function() return status.turning end,
        isProcessingFruit = function() return status.processing end, isPipeMoving = function() return status.pipeMoving end,
        isDischarging = function() return status.flow end, isUnloadFinished = function() return false end,
        getFillLevelPercentage = function() return status.fill end}
    local combine = {getCpDriveStrategy = function() return driver end, getIsCpActive = function() return true end}
    local reversed, attempted, released = 0, 0, 0
    local rig = setmetatable({vehicle = {rootNode = {x = 0, z = 0}}, combineToUnload = combine,
        states = {UNLOADING_MOVING_COMBINE = {}, UNLOADING_STOPPED_COMBINE = {}, MOVING_BACK = {}},
        ppc = {setNormalLookaheadDistance = function() end}, debug = function() end,
        startMovingBackFromCombine = function(self, state, target, hold)
            assert(target == combine and hold and self.combineToUnload == combine)
            self.state = state; self.state.properties = {}; reversed = reversed + 1
        end,
        startPipeApproachFromPocket = function(self, force)
            assert(force and self.combineToUnload == combine)
            attempted = attempted + 1
        end,
        recordFailedCombineApproach = function() released = released + 1 end,
        startWaitingForSomethingToDo = function() released = released + 1 end},
        {__index = AIDriveStrategyUnloadCombine})
    rig.state = rig.states.UNLOADING_MOVING_COMBINE
    g_time = 0
    assert(not rig:recoverStalledPipeApproach())
    g_time = 4999
    assert(not rig:recoverStalledPipeApproach(), 'A brief no-flow pause must retain normal unloading')
    g_time = 5000
    assert(rig:recoverStalledPipeApproach() and reversed == 1 and rig.state.properties.retryPipeApproach,
        'Five seconds without motion or flow must reverse with the original call retained')
    rig:finishPipeApproachReverse()
    assert(attempted == 1 and released == 0, 'Completed clearance must force the checked rear pipe approach')
    for _, reason in ipairs({'flow', 'processing', 'pipeMoving', 'turning', 'autoAim', 'pocket', 'movement', 'grain'}) do
        rig.state = rig.states.UNLOADING_STOPPED_COMBINE
        rig.pipeApproachProgress = nil
        g_time = 10000
        rig:recoverStalledPipeApproach()
        g_time = 16000
        if reason == 'pocket' then driver.unloadState = states.POCKET
        elseif reason == 'movement' then rig.vehicle.rootNode.x = rig.vehicle.rootNode.x + 1.1
        elseif reason == 'grain' then status.fill = status.fill - 1
        else status[reason] = true end
        assert(not rig:recoverStalledPipeApproach(), 'Do not recover during ' .. reason)
        status.flow, status.processing, status.pipeMoving, status.turning, status.autoAim = false, false, false, false, false
        driver.unloadState = states.WAITING_FOR_UNLOAD_ON_FIELD
    end
    rig.pipeApproachRecoveryAttempts = 2
    rig.pipeApproachProgress = nil
    rig.state = rig.states.UNLOADING_MOVING_COMBINE
    g_time = 20000; rig:recoverStalledPipeApproach()
    g_time = 25000; assert(rig:recoverStalledPipeApproach())
    assert(rig.state.properties.releaseFailedPipeApproach and released == 0,
        'An exhausted retry must still clear before releasing ownership')
    rig:finishPipeApproachReverse()
    assert(released == 2 and attempted == 1, 'Repeated failure must release once without an endless retry route')
end
print('Stopped full-combine no-progress recovery regressions: OK')

-- The 2986 turn reverse was cancelled immediately because its radial distance was already large.
do
    local combine = {rootNode = {x = 0, z = 0}}
    local rig = setmetatable({vehicle = {rootNode = {x = 50, z = 0}},
        state = {properties = {vehicle = combine, clearanceDistance = 40,
            reverseOrigin = {x = 50, z = 0}, minimumReverseTravel = 5}}},
        {__index = AIDriveStrategyUnloadCombine})
    assert(not rig:isAtHarvesterClearance(), 'A new reverse must not finish before moving despite existing radial separation')
    rig.vehicle.rootNode.x = 55
    assert(rig:isAtHarvesterClearance(), 'Actual reverse travel and physical clearance may finish the reverse')
end
print('Already-separated reverse initial travel regression: OK')
