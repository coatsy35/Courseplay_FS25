-- Regression sequences for assignment changes, staging retries and handover ownership.
function CpObject() return {} end
CpUtil = {getName = function(v) return v.name or 'vehicle' end, debugFormat = function() end,
    isStateOneOf = function(state, states) for _, s in pairs(states) do if s == state then return true end end return false end}
CpDebug = {DBG_UNLOAD_COMBINE = 1}
MathUtil = {vector2Length = function(x, z) return math.sqrt(x*x + z*z) end}
AIUtil = {getLength = function(v) return v.length or 6 end}
Course = {createStraightForwardCourse = function() return {} end}
PathfinderUtil = {hasFruit = function() return false end}
FillType = {UNKNOWN = 0}
function getWorldTranslation(n) return n.x, 0, n.z end
function entityExists(n) return n ~= nil end
g_time = 100000
g_currentMission = {time = g_time, vehicleSystem = {vehicles = {}}}
dofile('scripts/ai/UnloaderCoordinator.lua')
dofile('scripts/ai/strategies/AIDriveStrategyUnloadCombine.lua')
dofile('scripts/ai/strategies/AIDriveStrategyCombineCourse.lua')

local function setting(v) return {getValue = function() return v end} end
local function vehicle(x)
    return {name = 'vehicle', rootNode = {x = x, z = 0}, getChildVehicles = function() return {} end,
        getCpSettings = function() return {nearbyStandbyUnloaders = setting(1), standbyUnloaderDistance = setting(50)} end}
end
local function unloader(x)
    local s = setmetatable({vehicle = vehicle(x), states = {}, turningRadius = 9,
        debug = function() end, debugSparse = function() end, setMaxSpeed = function() end,
        startCourse = function(self, course) self.course = course end}, {__index = AIDriveStrategyUnloadCombine})
    for name in pairs(AIDriveStrategyUnloadCombine.myStates) do s.states[name] = {properties = {}} end
    for name in pairs(AIDriveStrategyUnloadCombine.myCombineUnloadStates) do s.states[name] = {properties = {}} end
    s.combineUnloadStates = AIDriveStrategyUnloadCombine.myCombineUnloadStates
    s.state = s.states.IDLE
    s.setNewState = function(self, state) self.state = state end
    s.pathfinderController = {active = false,
        cancel = function(self) self.active = false end,
        registerListeners = function(self, object, done, failed, obstacle)
            self.object, self.done, self.failed, self.obstacle = object, done, failed, obstacle
        end}
    return s
end
local function harvester(x)
    local v = vehicle(x)
    local strategy = {callUnloader = function() end, deregisterUnloader = function() end,
        getFillType = function() return 1 end, isTurning = function() return false end,
        isAboutToTurn = function() return false end, isAboutToReturnFromPocket = function() return false end}
    v.getIsCpActive = function() return true end
    v.getCpDriveStrategy = function() return strategy end
    return v, strategy
end
local a, b = harvester(100), harvester(200)

-- A callback from the released call must not change a new call, including when the new state has the same name.
local first = unloader(0)
first.combineToUnload = a
first.state = first.states.WAITING_FOR_PATHFINDER
first.pathfinderController.active = true
local oldCompleted, newCompleted = false, false
first:registerCombinePathfinderListeners(function() oldCompleted = true end)
local oldCallback = first.pathfinderController.done
assert(first:yieldCallToCloserUnloader(a))
assert(not first.pathfinderController.active and first.combineToUnload == nil and first.state == first.states.IDLE)
first.combineToUnload = b
first.state = first.states.WAITING_FOR_PATHFINDER
first:registerCombinePathfinderListeners(function() newCompleted = true end)
oldCallback(first, first.pathfinderController, true, {})
first.pathfinderController.done(first, first.pathfinderController, true, {})
assert(not oldCompleted and newCompleted, 'Only the current assignment may consume a pathfinder result')
first:recordFailedCombineApproach()
first:releaseCombine()
assert(not first:canRetryCombineApproach(b) and first:canRetryCombineApproach(a))
g_time = g_time + 15001
assert(first:canRetryCombineApproach(b), 'A failed route must become eligible after its bounded cooldown')

-- A stopped standby far from its target has not arrived; an unchanged target must be retried after failure.
local staged = unloader(0)
staged.state = staged.states.WAITING_IN_STANDBY
staged.standbyTargetX, staged.standbyTargetZ = 100, 0
staged.standbyAssignment = {harvester = a, role = 'STANDBY', waypoint = {x = 100, z = 0}}
staged.isAvailableForStaging = function() return true end
staged.getNearbyDepartingUnloader = function() return nil end
local stagingAttempts = 0
staged.startPathfindingToStandby = function() stagingAttempts = stagingAttempts + 1 end
staged.standbyRetryAt = g_time + 5000
assert(not staged:hasReachedStandbyPosition())
staged:setStandbyAssignment(staged.standbyAssignment)
assert(stagingAttempts == 0)
g_time = g_time + 5001
staged:setStandbyAssignment(staged.standbyAssignment)
assert(stagingAttempts == 1, 'A failed unchanged standby destination must not become a permanent hold')
staged.state = staged.states.WAITING_FOR_STANDBY_PATHFINDER
staged.pathfinderController.active = true
staged.standbyPathfindingStartedAt = g_currentMission.time - 60000
staged.standbyTargetStartedAt = g_currentMission.time - 60000
staged:setStandbyAssignment(staged.standbyAssignment)
assert(staged.pathfinderController.active and staged.state == staged.states.WAITING_FOR_STANDBY_PATHFINDER,
        'A progressing standby search must not be cancelled just because it exceeds 15 seconds')

local spare = unloader(0)
spare.isAvailableForStaging = function() return true end
spare.startPathfindingToStandby = function()
    error('A pooled spare must remain parked until promoted to the lead')
end
spare:setStandbyAssignment({harvester = a, role = 'POOL', waypoint = {x = 100, z = 0}})
assert(spare.state == spare.states.WAITING_IN_STANDBY)
staged:setStandbyAssignment({harvester = a, role = 'STANDBY', waypoint = {x = 180, z = 0}})
assert(stagingAttempts == 1 and staged.pathfinderController.active,
        'An advancing staging target must not repeatedly restart the same in-progress departure search')
staged.vehicle.rootNode.x = 97
staged.state = staged.states.WAITING_IN_STANDBY
assert(staged:hasReachedStandbyPosition())

-- Two accepted real calls beside each other must not both start departure pathfinding.
local lead, queued = unloader(0), unloader(4)
local function configureCall(s)
    s.getPipeOffset = function() return 10, -6 end
    s.getPipeOffsetReferenceNode = function() return 1 end
    s.getCombinesMeasuredBackDistance = function() return 6 end
    s.isOkToStartUnloadingCombine = function() return false end
    s.canStartDirectStoppedCombineApproach = function() return false end
    s.isPathfindingNeeded = function() return true end
    s.startPathfindingToMovingCombine = function(self) self.pathfinderController.active = true end
end
configureCall(lead); configureCall(queued)
AIDriveStrategyUnloadCombine.activeUnloaders = {[lead] = lead.vehicle, [queued] = queued.vehicle}
assert(lead:call(a, {x = 100, z = 0}))
assert(queued:call(b, {x = 200, z = 0}))
assert(lead.pathfinderController.active and not queued.pathfinderController.active)
assert(queued.combineToUnload == b and queued.state == queued.states.WAITING_FOR_DEPARTURE)
lead.vehicle.rootNode.x = 100
queued:resumeDepartureCall()
assert(queued.pathfinderController.active and queued.state == queued.states.WAITING_FOR_PATHFINDER)

-- A staged lead can use the pocket-follow course immediately without driving a new loop to its own position.
local pocketLead, pocketHarvester = unloader(0), harvester(100)
local pocketStrategy = pocketHarvester:getCpDriveStrategy()
pocketStrategy.isWaitingForUnload = function() return false end
pocketStrategy.isManeuvering = function() return true end
pocketLead.state = pocketLead.states.WAITING_IN_STANDBY
pocketLead.standbyAssignment = {harvester = pocketHarvester, waypoint = {x = 0, z = 0}, role = 'STANDBY'}
UnloaderCoordinator.assignments[pocketLead] = pocketLead.standbyAssignment
AIDriveStrategyUnloadCombine.activeUnloaders = {[pocketLead] = pocketLead.vehicle}
pocketLead.isPathfindingNeeded = function() return false end
local followedPocket = false
pocketLead.startFollowingCombineToPocket = function() followedPocket = true end
pocketLead.startPathfindingToMovingCombine = function() error('A parked lead must not start a needless route') end
assert(pocketLead:callForPocket(pocketHarvester) and followedPocket and pocketLead.combineToUnload == pocketHarvester)
pocketStrategy.isWaitingForUnload = function() return true end
local calledReadyPocket = false
pocketLead.call = function(_, combine, waypoint)
    calledReadyPocket = combine == pocketHarvester and waypoint == nil; return true
end
assert(pocketLead:callForPocket(pocketHarvester) and calledReadyPocket,
        'A ready pocket must use the pipe approach immediately rather than return to staging')

local thresholdTrailer = unloader(0)
thresholdTrailer.settings = {fullThreshold = setting(85)}
thresholdTrailer.getAllTrailersFull = function(_, threshold) assert(threshold == 85); return true end
assert(not thresholdTrailer:isAllowedToBeCalled(a), 'A trailer due to leave at its threshold must not take a new call')
local train, attached = vehicle(0), vehicle(0)
train.length, attached.length = 6, 10
train.getChildVehicles = function() return {train, attached, attached} end
assert(AIDriveStrategyUnloadCombine.getTrainLength(train) == 16,
        'Clearance dimensions must count each attached vehicle once, including APIs that return the tractor')

-- The full trailer retains ownership throughout its reverse, and the separate record survives AD handover.
local full = unloader(100)
full.combineToUnload = a
full.unloadTargetType = AIDriveStrategyUnloadCombine.UNLOAD_TYPES.COMBINE
full.settings = {reverseSpeed = setting(5)}
full.getHarvesterTurnClearanceDistance = function() return 50 end
local plannedReverseDistance
full.createClearanceReverseCourse = function(_, distance) plannedReverseDistance = distance; return {}, distance end
full.isDriveUnloadNowRequested = function() return false end
full.getAllTrailersFull = function() return true end
assert(full:changeToUnloadWhenTrailerFull())
assert(full.combineToUnload == a and full.state.properties.clearanceDistance == 36 and plannedReverseDistance == 36,
    'The post-unload route and measured clearance must both be 20% shorter')
full:releaseCombine()
assert(UnloaderCoordinator:isStillClearingHarvester(nil, a), 'Deregistration must not authorise a premature pocket return')
full.vehicle.rootNode.x = 137
assert(not UnloaderCoordinator:isStillClearingHarvester(nil, a))

-- Firm relief cannot be stolen by an earlier demand in the next rebalance.
local relief = unloader(0)
relief.isAvailableForStaging = function() return true end
relief.isServingPosition = function() return true end
relief.getFreeCapacityForHarvester = function() return 1000 end
UnloaderCoordinator.assignments = {[relief] = {harvester = a, isFirm = true, reserved = true}}
assert(not UnloaderCoordinator:canServeDemand(relief, {harvester = b}))
assert(UnloaderCoordinator:canServeDemand(relief, {harvester = a}))

-- Compatible capacity counts each fill unit once, even if there are several target nodes for that unit.
local trailer = {getFillUnitAllowsFillType = function(_, ix) return ix == 1 end,
    getFillUnitFreeCapacity = function() return 12000 end}
first.trailerNodes = {{trailer = trailer, fillUnitIx = 1}, {trailer = trailer, fillUnitIx = 1}, {trailer = trailer, fillUnitIx = 2}}
assert(first:getFreeCapacityForHarvester(a) == 12000)
assert(first:canAcceptFillTypeFromHarvester(a))
trailer.getFillUnitFreeCapacity = function() return 0 end
assert(first:getFreeCapacityForHarvester(a) == 0 and first:canAcceptFillTypeFromHarvester(a),
        'A compatible full trailer must remain a corridor owner despite having no remaining capacity')
trailer.getFillUnitAllowsFillType = function() return false end
assert(not first:canAcceptFillTypeFromHarvester(a), 'Unsupported or mixed crop must not count as shared coverage')
trailer.getFillUnitAllowsFillType = function(_, ix) return ix == 1 end
trailer.getFillUnitFreeCapacity = function() return 12000 end

-- Initial and replacement selections must agree for the recorded 60%-full/43s versus empty/20s candidates.
local partial, empty = unloader(0), unloader(0)
for _, s in ipairs({partial, empty}) do
    s.vehicle.getCpDriveStrategy = function() return s end
    s.isServingPosition = function() return true end
    s.isAllowedToBeCalled = function() return true end
end
partial.getFillLevelPercentage = function() return 60 end
partial.getDistanceAndEteToVehicle = function() return 221, 43 end
empty.getFillLevelPercentage = function() return 0 end
empty.getDistanceAndEteToVehicle = function() return 94, 20 end
g_currentMission.vehicleSystem.vehicles = {partial.vehicle, empty.vehicle}
AIDriveStrategyUnloadCombine.isActiveCpCombineUnloader = function() return true end
local selector = setmetatable({vehicle = a, debug = function() end}, {__index = AIDriveStrategyCombineCourse})
assert(selector:findUnloader(a, nil, false) == partial.vehicle)
assert(selector:findUnloader(a, nil, true) == partial.vehicle)
partial.getDistanceAndEteToVehicle = function() return 1500, 300 end
assert(selector:findUnloader(a, nil) == empty.vehicle, 'A distant partial load must not monopolise the call')
partial.getDistanceAndEteToVehicle = function() return 100, 22 end
assert(selector:findUnloader(a, nil, false) == partial.vehicle, 'A genuinely nearby partial load retains preference')

local transferring = unloader(0)
transferring.state = transferring.states.UNLOADING_STOPPED_COMBINE
transferring.getDistanceAndEteToVehicle = function() return 10, 2 end
transferring.yieldCallToCloserUnloader = function()
    error('A transferring trailer must not be replaced')
end
assert(not selector:trySwitchToCloserUnloader(transferring),
        'A proximity hold during crop transfer must not cause a second trailer to be called')

print('UnloaderLifecycleTest: OK')

-- Reproduce the recorded 14-metre forward join while the combine is WORKING, then the full stopped case with
-- stopForUnload disabled. Use the real combine state predicates, not a hardcoded willWaitForUnloadToFinish=true.
local combineStates = {WORKING = {}, UNLOADING_ON_FIELD = {}, WAITING_FOR_UNLOAD_ON_FIELD = {}}
local moving = setmetatable({states = combineStates, state = combineStates.WORKING,
    settings = {stopForUnload = setting(false)}, isReadyToUnload = function() return true end},
    {__index = AIDriveStrategyCombineCourse})
local close = unloader(0)
close.combineToUnload = {getCpDriveStrategy = function() return moving end}
close.vehicle.getAIDirectionNode = function() return 1 end
close.getTargetNode = function() return 2 end
close.getFieldworkBoundaryForCombineApproach = function() return nil end
close.getPipeOffset = function() return 10, -6 end
close.getPipeOffsetReferenceNode = function() return 2 end
localToLocal = function() return 5, 0, 13 end
localToWorld = function() return 5, 0, 13 end
getWorldTranslation = function() return 0, 0, 0 end
CpMathUtil = {isSameDirection = function() return true end}
FieldworkBoundary = {containsSegment = function() return true end, captureRig = function() return {} end,
    sweepRigSegment = function() return true end}
local joinedMoving, joinedStopped = 0, 0
close.startCourseFollowingCombine = function() joinedMoving = joinedMoving + 1 end
close.startUnloadingStoppedCombine = function() joinedStopped = joinedStopped + 1 end
assert(not moving:willWaitForUnloadToFinish())
assert(close:canStartDirectStoppedCombineApproach(2, 10, -6))
close:startUnloadingCombine()
assert(joinedMoving == 1 and joinedStopped == 0)
moving.state, moving.unloadState = combineStates.UNLOADING_ON_FIELD, combineStates.WAITING_FOR_UNLOAD_ON_FIELD
assert(not moving:willWaitForUnloadToFinish() and moving:isWaitingForUnload())
assert(close:canStartDirectStoppedCombineApproach(2, 10, -6))
close:startUnloadingCombine()
assert(joinedMoving == 1 and joinedStopped == 1)
print('Recorded moving/stopped combine join regressions: OK')

-- Exercise the actual update dispatcher: boundary preference must not cancel driving or override proximity control.
local frame = unloader(0)
frame.updateLowFrequencyImplementControllers = function() end
frame.calculateAutoAimPipeOffsetX = function() end
frame.ppc = {isReversing = function() return false end, getGoalPointPosition = function() return 1, 0, 1 end}
frame.hasToWaitForAssignedCombine = function() return false end
frame.setMaxSpeed = function(self, value) self.maxSpeed = math.min(self.maxSpeed, value) end
frame.setFieldSpeed = function(self) self:setMaxSpeed(15) end
frame.checkProximitySensors = function(self) self:setMaxSpeed(7) end
frame.checkCollisionWarning = function() end
local resumed = 0
frame.resumeDepartureCall = function() resumed = resumed + 1 end
frame.pathfinderController.isActive = function() return false end
frame.driveToCombine = function(self) self:setFieldSpeed() end
frame.state = frame.states.DRIVING_TO_COMBINE
frame.isNextDriveSegmentInsideField = function() error('Hard boundary veto must not run') end
frame.maxSpeed = math.huge
local _, _, _, speed = frame:getDriveData(16)
assert(speed == 7, 'Normal driving must retain the approach and obey proximity speed limits')
frame.state = frame.states.WAITING_FOR_DEPARTURE
frame.maxSpeed = math.huge
_, _, _, speed = frame:getDriveData(16)
assert(speed == 0 and resumed == 1, 'A queued call must remain stopped while checking whether it may depart')
print('Unloader update dispatcher regressions: OK')

-- When the final combine stops after emptying, a partly filled trailer must leave its pipe
-- before handing off for delivery. A surviving combine still needs that trailer available.
local finished = unloader(0)
finished.updateLowFrequencyImplementControllers = function() end
finished.calculateAutoAimPipeOffsetX = function() end
finished.ppc = {isReversing = function() return false end,
    getGoalPointPosition = function() return 1, 0, 1 end}
finished.checkProximitySensors = function() end
finished.checkCollisionWarning = function() end
finished.isDriveUnloadNowRequested = function() return false end
finished.combineUnloadStates = {finished.states.UNLOADING_STOPPED_COMBINE}
finished.getFillLevelPercentage = function() return 35 end
finished.combineToUnload = a
finished.state = finished.states.UNLOADING_STOPPED_COMBINE
a.getIsCpActive = function() return false end
local departing
finished.startMovingBackFromCombine = function(_, state, combine)
    departing = state == finished.states.MOVING_BACK_WITH_TRAILER_FULL and combine == a
    finished.state = state
end
finished:getDriveData(16)
assert(departing and finished.combineToUnload == nil,
        'A partly loaded trailer must depart when its final combine ends work')
a.getIsCpActive = function() return true end
local remaining = harvester(50)
g_currentMission.vehicleSystem.vehicles = {a, remaining}
getWorldTranslation = function(node) return node.x, 0, node.z end
finished.isServingPosition = function(_, x) return x == 50 end
assert(finished:areThereAnyCombinesOrLoaderLeftoverOnTheField(a),
        'The remaining combine position, not the stopped combine position, identifies field demand')
g_currentMission.vehicleSystem.vehicles = {}

-- Large-field searches must reach their own bounded completion, rather than lose the call after 30 seconds.
local frameCombine, frameCombineStrategy = harvester(100)
frameCombineStrategy.registerUnloader = function() end
frame.combineToUnload = frameCombine
frame.state = frame.states.WAITING_FOR_PATHFINDER
frame.pathfinderController.startedAt = g_time - 60000
frame.pathfinderController.isActive = function() return true end
frame.maxSpeed = math.huge
_, _, _, speed = frame:getDriveData(16)
assert(speed == 0 and frame.combineToUnload == frameCombine and frame.state == frame.states.WAITING_FOR_PATHFINDER,
        'A long active search must retain its assignment so the entry queue can eventually depart')

-- A successful path callback may synchronously launch a recovery search. The old completion must not reset it.
dofile('scripts/ai/PathfinderController.lua')
local controller = setmetatable({requestGeneration = 1, startedAt = 1, debug = function() end,
    getTemporaryCourseFromPath = function() return {} end}, {__index = PathfinderController})
controller.callbackSuccessFunction = function(c)
    c:start({}, 3, function() return {isActive = function() return true end}, {done = false} end)
end
controller:onFinish({path = {1, 2, 3}})
assert(controller.startedAt == g_time and controller.numRetries == 3 and controller:isActive(),
        'Completing an old route must not reset a new recovery request launched by its callback')
controller:cancel()
assert(not controller:isActive() and controller.currentPathfinderCall == nil)
print('Pathfinder re-entrant completion regression: OK')

-- Reproduce the observed successful-route -> boundary rejection -> release/restage cycle.
FieldworkBoundary = {containsRigCourse = function() error('A completed unloader route must not be vetoed') end}
AIUtil.getDirectionNodeToReverserNodeOffset = function() return 0 end
local route = {adjustForReversing = function() end}
for _, moving in ipairs({true, false}) do
    local driver = unloader(0)
    driver.combineToUnload = a
    driver.state = driver.states.WAITING_FOR_PATHFINDER
    driver.extendCombineApproachWithinField = function() end
    local callback = moving and driver.onPathfindingDoneToMovingCombine or driver.onPathfindingDoneToWaitingCombine
    assert(callback(driver, driver.pathfinderController, true, route))
    assert(driver.combineToUnload == a and driver.course == route and
            driver.state == (moving and driver.states.DRIVING_TO_MOVING_COMBINE or driver.states.DRIVING_TO_COMBINE),
            'A successful approach must retain its combine and enter the driving state')
end
local failed = unloader(0)
failed.combineToUnload = a
failed:recordFailedCombineApproach()
failed.isAvailableForStaging = function() return true end
failed.startPathfindingToStandby = function() error('A failed call must not immediately cause a pool journey') end
failed:clearStandbyAssignment()
failed:setStandbyAssignment({harvester = b, role = 'POOL', waypoint = {x = -100, z = 0}})
assert(failed.state == failed.states.WAITING_IN_STANDBY)
print('Accepted route retention and failed-call parking regressions: OK')

-- A restarted strategy for the same physical trailer must not queue behind its own clearance record.
local oldDriver = unloader(100)
UnloaderCoordinator:registerClearingUnloader(oldDriver, a, 36)
UnloaderCoordinator:unregister(oldDriver)
local restarted = unloader(100)
restarted.vehicle = oldDriver.vehicle
restarted.getNearbyDepartingUnloader = function() return nil end
restarted.holdNearbyStandbyUnloadersForDeparture = function() end
assert(not restarted:queueForDeparture(a), 'A restarted owner must not wait for itself to clear')
assert(UnloaderCoordinator:isStillClearingHarvester(nil, a),
        'Ignoring self for departure must retain the combine\'s physical clearance protection')
local replacement = unloader(100)
replacement.getNearbyDepartingUnloader = function() return nil end
replacement.holdNearbyStandbyUnloadersForDeparture = function() end
assert(replacement:queueForDeparture(a), 'A different trailer must still wait for the clearing owner')
restarted.pendingDepartureCall = {combine = a, startedAt = g_time}
local resumedOwnCall = false
restarted.call = function() resumedOwnCall = true end
restarted:resumeDepartureCall()
assert(resumedOwnCall, 'An already queued owner must also be able to resume its own call')
oldDriver.vehicle.rootNode.x = 137
assert(not UnloaderCoordinator:isStillClearingHarvester(nil, a))

-- Exercise the update loop after stopping a combine during a held reverse.
local parked = unloader(100)
parked.updateLowFrequencyImplementControllers = function() end
parked.calculateAutoAimPipeOffsetX = function() end
parked.ppc = {isReversing = function() return true end}
parked.getReverseDriveData = function() return 0, 0, 8 end
parked.checkProximitySensors = function() end
parked.checkCollisionWarning = function() end
parked.settings = {reverseSpeed = setting(8), fullThreshold = setting(85)}
parked.getDistanceFromCombine = function() return 0, 0, -1 end
parked.state = parked.states.MOVING_BACK
local ended = harvester(100)
ended.getIsCpActive = function() return false end
ended.getCpDriveStrategy = function() return nil end
parked.combineToUnload = ended
parked.state.properties = {vehicle = ended, holdCombine = true}
parked:getDriveData(16)
assert(parked.state == parked.states.MOVING_BACK,
        'Stopping the combine must retain clearance movement without calling a deleted strategy')

-- A served trailer can already be parked when the final combine stops.
parked.isAtHarvesterClearance = function() return true end
parked:startWaitingForSomethingToDo()
assert(parked.postUnloadClearanceHarvester == ended and parked.combineToUnload == nil)
parked.ppc = {isReversing = function() return false end, getGoalPointPosition = function() return 0, 0, 0 end}
parked.isDriveUnloadNowRequested = function() return false end
parked.checkForTrailerToUnloadTo = {get = function() return false end}
parked.updateStandbyCoordinator = function() end
parked.getFillLevelPercentage = function() return 35 end
parked.isServingPosition = function() return true end
local deliveries = 0
parked.startUnloadingTrailers = function(self)
    deliveries = deliveries + 1
    self.state = self.states.WAITING_FOR_PATHFINDER
end
g_currentMission.vehicleSystem.vehicles = {remaining}
parked:getDriveData(16)
assert(deliveries == 0, 'A partial load remains available while another combine works in the field')
g_currentMission.vehicleSystem.vehicles = {}
parked.postUnloadClearanceHarvester = nil
parked:getDriveData(16)
assert(deliveries == 0, 'A partly loaded trailer that has not served the field must not leave automatically')
parked.postUnloadClearanceHarvester = ended
parked:getDriveData(16)
assert(deliveries == 1, 'A released partial load must depart after the last field worker stops')
parked:getDriveData(16)
assert(deliveries == 1, 'Final-load delivery must not restart on every update')
parked.state = parked.states.WAITING_IN_STANDBY
parked:getDriveData(16)
assert(deliveries == 2, 'A served trailer parked in standby must also deliver its final partial load')
parked.state = parked.states.IDLE
parked.getFillLevelPercentage = function() return 0 end
parked:getDriveData(16)
assert(deliveries == 2, 'Empty trailers must remain available at field completion')
print('Restarted clearance, stopped combine and final parked load regressions: OK')
