CpDebug = { DBG_UNLOAD_COMBINE = 1 }
MathUtil = {vector2Length = function(x, z) return math.sqrt(x * x + z * z) end}
CpUtil = {
    debugFormat = function() end,
    getName = function(vehicle) return vehicle.name end,
}

function getWorldTranslation(node)
    return node.x, 0, node.z
end

function getWorldRotation()
    return 0, 0, 0
end

local function setting(value)
    return { getValue = function() return value end }
end

local function makeHarvester(name, x, isForager, secondsUntilCall, stageX, secondsUntilFull, fillLevelPercentage)
    local currentIx = 1000
    local course = {
        getPreviousWaypointIxWithinDistance = function(_, ix, distance)
            return ix - math.floor(distance)
        end,
        isTurnStartAtIx = function() return false end,
        isTurnEndAtIx = function() return false end,
        isReverseAt = function() return false end,
        getWaypoint = function(_, ix) return {
            x = stageX - (currentIx - ix),
            z = 0,
        } end,
    }
    local strategy = {
        callUnloader = function() end,
        isTurning = function() return false end,
        isManeuvering = function() return false end,
        isAboutToTurn = function() return false end,
        getFieldworkCourse = function() return course end,
        getClosestFieldworkWaypointIx = function() return currentIx end,
        getWorkWidth = function() return 15 end,
        alwaysNeedsUnloader = function() return isForager end,
        getSecondsUntilUnloaderCall = function() return secondsUntilCall end,
        getSecondsUntilFull = function() return secondsUntilFull or secondsUntilCall + 60 end,
        getFillLevelPercentage = function() return fillLevelPercentage or 50 end,
    }
    local harvester = {
        name = name,
        rootNode = { x = x, z = 0 },
        getIsCpActive = function() return true end,
        getCpDriveStrategy = function() return strategy end,
        getCpSettings = function() return {
            nearbyStandbyUnloaders = setting(1),
            standbyUnloaderDistance = setting(50),
            callUnloaderPercent = setting(80),
        } end,
    }
    return harvester
end

local function makeUnloader(name, x, available, activeHarvester, fill)
    local strategy = {
        vehicle = { name = name, rootNode = { x = x, z = 0 } },
        x = x,
        assignment = nil,
        isAvailableForStaging = function() return available end,
        getCombineToUnload = function() return activeHarvester end,
        getFillLevelPercentage = function() return fill or 0 end,
        getHarvesterTurnClearanceDistance = function() return 50 end,
        isServingPosition = function() return true end,
        getDistanceAndEteToWaypoint = function(self, waypoint)
            local distance = math.abs(self.x - waypoint.x)
            return distance, distance / 5
        end,
        getDistanceAndEteToVehicle = function(self, vehicle)
            local distance = math.abs(self.x - vehicle.rootNode.x)
            return distance, distance / 5
        end,
        setStandbyAssignment = function(self, assignment) self.assignment = assignment end,
        clearStandbyAssignment = function(self) self.assignment = nil end,
        hasReachedStandbyPosition = function(self) return self.reachedStandby or false end,
    }
    return strategy
end

dofile('scripts/ai/UnloaderCoordinator.lua')

local forager = makeHarvester('Forager', 0, true, 0, 0)
local combine = makeHarvester('Combine', 200, false, 20, 200)
local active = makeUnloader('Active trailer', 0, false, forager, 95)
local nearForager = makeUnloader('Relief trailer', 20, true, nil, 0)
local nearCombine = makeUnloader('Combine trailer', 180, true, nil, 0)
local spare = makeUnloader('Spare trailer', 100, true, nil, 0)

AIDriveStrategyUnloadCombine = {
    activeUnloaders = {
        [active] = active.vehicle,
        [nearForager] = nearForager.vehicle,
        [nearCombine] = nearCombine.vehicle,
        [spare] = spare.vehicle,
    },
}
AIDriveStrategyCombineCourse = {
    isActiveCpCombine = function(vehicle)
        return vehicle and vehicle.getIsCpActive and vehicle:getIsCpActive()
    end,
}
g_currentMission = {
    time = 100000,
    vehicleSystem = { vehicles = { forager, combine } },
}

UnloaderCoordinator:rebalance(true)

assert(nearForager.assignment and nearForager.assignment.harvester == forager,
        'The closest relief trailer should be reserved for the forage harvester')
assert(nearForager.assignment.isFirm, 'Forage relief coverage must be firm')
assert(nearCombine.assignment and nearCombine.assignment.harvester == combine,
        'The closest remaining trailer should stage for the combine')
assert(not nearCombine.assignment.isFirm, 'Combine staging must remain soft')
assert(spare.assignment and spare.assignment.role == 'POOL',
        'A surplus trailer should receive a separate shared-pool staging position')
assert(spare.assignment.targetMovementThreshold == UnloaderCoordinator.stagingRetargetDistance,
        'Pool movement and drive-strategy retargeting must use the same hysteresis')
assert(not spare.assignment.isFirm, 'Shared-pool positioning must remain interruptible')
assert(UnloaderCoordinator:canBeCalledBy(nearForager, forager),
        'The reserved forage harvester must be able to promote its relief trailer')
assert(not UnloaderCoordinator:canBeCalledBy(nearForager, combine),
        'Another harvester must not take a firm forage relief reservation')
assert(UnloaderCoordinator:canBeCalledBy(spare, combine),
        'Soft combine staging must not exclude a better trailer from a real call')
assert(UnloaderCoordinator:isStillClearingHarvester(active, forager),
        'A registered unloader must keep its harvester waiting while it clears')
assert(not UnloaderCoordinator:isStillClearingHarvester(active, combine),
        'An unloader serving another harvester must not delay this combine')
local spareHarvester = spare.assignment.harvester
g_currentMission.time = g_currentMission.time + UnloaderCoordinator.rebalanceIntervalMs
spare.x = spareHarvester == forager and 190 or 10
UnloaderCoordinator:rebalance(true)
assert(spare.assignment.harvester == spareHarvester and spare.assignment.waypoint,
        'A rear pool trailer must keep its harvester and fixed parking assignment')

-- A partly filled trailer wins while it remains close enough to justify finishing its load.
local continuityCombine = makeHarvester('Continuity combine', 500, false, 10, 500)
local partial = makeUnloader('Part-filled trailer', 430, true, nil, 45)
local empty = makeUnloader('Closer empty trailer', 440, true, nil, 0)
AIDriveStrategyUnloadCombine.activeUnloaders = {
    [partial] = partial.vehicle,
    [empty] = empty.vehicle,
}
g_currentMission.time = 200000
g_currentMission.vehicleSystem.vehicles = { continuityCombine }
UnloaderCoordinator.assignments = {}
UnloaderCoordinator:rebalance(true)
assert(partial.assignment and partial.assignment.reserved,
        'A nearby partly filled trailer must be reserved before a closer empty trailer')
assert(not empty.assignment.reserved, 'Only one trailer may be reserved for a combine')

-- Distance eventually outweighs the partial load, matching the normal Courseplay call score.
local remotePartial = makeUnloader('Remote part-filled trailer', -1000, true, nil, 45)
local localEmpty = makeUnloader('Local empty trailer', 480, true, nil, 0)
AIDriveStrategyUnloadCombine.activeUnloaders = {
    [remotePartial] = remotePartial.vehicle,
    [localEmpty] = localEmpty.vehicle,
}
MathUtil = {
    vector2Length = function(x, z) return math.sqrt(x * x + z * z) end,
}
g_currentMission.time = 250000
UnloaderCoordinator.assignments = {}
UnloaderCoordinator:rebalance(true)
assert(localEmpty.assignment and localEmpty.assignment.reserved,
        'A distant partly filled trailer must not displace a nearby empty trailer')
assert(UnloaderCoordinator:getCallScore(45, 35) > UnloaderCoordinator:getCallScore(0, 20),
        'A nearby partial load must beat a slightly closer empty trailer')
assert(UnloaderCoordinator:getCallScore(45, 1500) < UnloaderCoordinator:getCallScore(0, 20),
        'A remote partial load must lose to a nearby empty trailer')

-- A non-urgent reservation stays in a dynamically distant pool rather than chasing the combine.
local distantDemandCombine = makeHarvester('Non-urgent combine', 800, false, 600, 800)
local pooled = makeUnloader('Pooled trailer', 790, true, nil, 0)
AIDriveStrategyUnloadCombine.activeUnloaders = { [pooled] = pooled.vehicle }
g_currentMission.time = 300000
g_currentMission.vehicleSystem.vehicles = { distantDemandCombine }
UnloaderCoordinator.assignments = {}
UnloaderCoordinator:rebalance(true)
assert(pooled.assignment and pooled.assignment.reserved and pooled.assignment.role == 'POOL',
        'A non-urgent combine trailer must remain reserved in the field pool')
assert(math.abs(pooled.assignment.waypoint.x - distantDemandCombine.rootNode.x) >= 100,
        'The pool target must remain well clear of the combine')

-- Lead staging always uses harvested ground behind the current combine rather than unharvested future crop.
local predictedCombine = makeHarvester('Predicted combine', 0, false, 120, 0)
predictedCombine:getCpDriveStrategy().waypointIxWhenCallUnloader = 1100
local predictedDemand = UnloaderCoordinator:createDemand(predictedCombine, g_currentMission.time)
assert(predictedDemand.waypointIx == 950 and predictedDemand.waypoint.x == -50,
        'The close standby target must sit on harvested ground behind the current combine')

-- A soft reservation protects clearly earlier downtime, but yields to a more urgent real call.
local firstCombine = makeHarvester('First combine', 0, false, 5, 0)
local secondCombine = makeHarvester('Second combine', 500, false, 50, 500)
local onlyTrailer = makeUnloader('Only trailer', 20, true, nil, 30)
AIDriveStrategyUnloadCombine.activeUnloaders = { [onlyTrailer] = onlyTrailer.vehicle }
g_currentMission.time = 400000
g_currentMission.vehicleSystem.vehicles = { firstCombine, secondCombine }
UnloaderCoordinator.assignments = {}
UnloaderCoordinator:rebalance(true)
assert(onlyTrailer.assignment and onlyTrailer.assignment.harvester == firstCombine,
        'The only trailer should cover the most urgent combine first')
assert(not UnloaderCoordinator:canBeCalledBy(onlyTrailer, secondCombine),
        'A less urgent combine must not take the only trailer from an imminent downtime reservation')
local urgentSecondCombine = makeHarvester('Urgent second combine', 500, false, 0, 500, 2, 99)
assert(UnloaderCoordinator:canBeCalledBy(onlyTrailer, urgentSecondCombine),
        'A more urgent combine may override a soft reservation')

-- Once normal call thresholds are passed, actual time until full and fill level must retain deterministic priority.
local nearlyFull = makeHarvester('Nearly full combine', 0, false, 0, 0, 5, 98)
local merelyDue = makeHarvester('Merely due combine', 100, false, 0, 100, 60, 85)
local nearlyFullDemand = UnloaderCoordinator:createDemand(nearlyFull, g_currentMission.time)
local merelyDueDemand = UnloaderCoordinator:createDemand(merelyDue, g_currentMission.time)
assert(UnloaderCoordinator.sortDemands(nearlyFullDemand, merelyDueDemand),
        'The combine closest to downtime must rank first after both call thresholds have passed')

-- Once a combine has called its lead, its own call percentage must not also promote the rear trailer.
local coveredCombine = makeHarvester('Covered combine', 0, false, 0, 0, 30, 90)
local calledLead = makeUnloader('Called lead', -40, false, coveredCombine, 0)
local rearTrailer = makeUnloader('Rear trailer', -150, true, nil, 0)
AIDriveStrategyUnloadCombine.activeUnloaders = {
    [calledLead] = calledLead.vehicle,
    [rearTrailer] = rearTrailer.vehicle,
}
g_currentMission.vehicleSystem.vehicles = { coveredCombine }
UnloaderCoordinator.assignments = {}
UnloaderCoordinator.trailerFillSamples = {}
UnloaderCoordinator:rebalance(true)
assert(rearTrailer.assignment and rearTrailer.assignment.role == 'POOL',
        'A rear trailer must stay parked while the already-called lead still has capacity')

-- A pool trailer enters the field once, then remains parked until promotion.
local progressionCombine = makeHarvester('Progression combine', 0, false, 500, 0)
local progressiveTrailer = makeUnloader('Progressive trailer', -250, true, nil, 0)
local progressionDemand = {
    harvester = progressionCombine,
    harvesterStrategy = progressionCombine:getCpDriveStrategy(),
    secondsUntilNeeded = 0,
}
local holdWaypoint = UnloaderCoordinator:getWaypointAtUnloader(progressiveTrailer)
assert(type(holdWaypoint.angle) == 'number' and not holdWaypoint:getIsReverse(),
        'Coordinator hold positions must be complete pathfinder waypoints')
local oldPoolAssignment = {
    harvester = progressionCombine,
    role = 'POOL',
    waypoint = holdWaypoint,
}
local nearerWaypoint, nearerWaypointIx = UnloaderCoordinator:getPoolWaypoint(progressiveTrailer, progressionDemand, 1,
        oldPoolAssignment)
assert(nearerWaypoint.x > holdWaypoint.x + 100,
        'A distant pool trailer must move nearer when the combine becomes urgent')

oldPoolAssignment.waypoint = nearerWaypoint
oldPoolAssignment.waypointIx = nearerWaypointIx
progressionDemand.secondsUntilNeeded = 500
local stableWaypoint = UnloaderCoordinator:getPoolWaypoint(progressiveTrailer, progressionDemand, 1,
        oldPoolAssignment)
assert(stableWaypoint == nearerWaypoint,
        'A reached pool position must remain fixed instead of following urgency changes')

-- A rear trailer may make another deliberate move only when predicted need advances materially and the next
-- course-derived layer is genuinely closer to the harvester.
progressiveTrailer.reachedStandby = true
progressionDemand.secondsUntilNeeded = 300
oldPoolAssignment.waypoint = { x = -250, z = 0 }
oldPoolAssignment.waypointIx = 750
oldPoolAssignment.stagedAtSecondsUntilNeeded = 500
local advancedPoolWaypoint = UnloaderCoordinator:getPoolWaypoint(progressiveTrailer, progressionDemand, 1,
        oldPoolAssignment)
assert(advancedPoolWaypoint.x > oldPoolAssignment.waypoint.x + 40,
        'A rear trailer must advance to a nearer parked layer when predicted demand materially increases')

local promotedWaypoint = { x = 25, z = 0 }
local firstStandbyWaypoint = UnloaderCoordinator:getStableStagingWaypoint(progressionCombine, 'STANDBY',
        promotedWaypoint, 25, oldPoolAssignment)
assert(firstStandbyWaypoint == promotedWaypoint,
        'Promotion from pool to lead standby must allow one deliberate move nearer')
local standbyAssignment = {
    harvester = progressionCombine,
    role = 'STANDBY',
    waypoint = promotedWaypoint,
    waypointIx = 25,
}
local fixedStandbyWaypoint = UnloaderCoordinator:getStableStagingWaypoint(progressionCombine, 'STANDBY',
        { x = 100, z = 0 }, 100, standbyAssignment)
assert(fixedStandbyWaypoint == promotedWaypoint,
        'An en-route lead standby must finish its current deliberate move')

progressiveTrailer.reachedStandby = true
progressiveTrailer.x = -200
progressionDemand.fillLevelPercentage = 80
progressionDemand.isFirm = false
local advancedStandbyWaypoint = UnloaderCoordinator:getStableStagingWaypoint(progressionCombine, 'STANDBY',
        { x = -50, z = 0 }, 950, standbyAssignment, progressiveTrailer, progressionDemand)
assert(advancedStandbyWaypoint.x == -50,
        'A reached lead must advance from a distant stop when its combine reaches the call percentage')

local accessPointTrailer = makeUnloader('Access-point trailer', -110, true, nil, 0)
local accessPointAssignment = {
    harvester = progressionCombine,
    role = 'POOL',
    waypoint = UnloaderCoordinator:getWaypointAtUnloader(accessPointTrailer),
}
progressionDemand.secondsUntilNeeded = 0
local fieldWaypoint, fieldWaypointIx = UnloaderCoordinator:getPoolWaypoint(accessPointTrailer,
        progressionDemand, 1, accessPointAssignment)
assert(fieldWaypointIx and fieldWaypoint ~= accessPointAssignment.waypoint,
        'A trailer at an AutoDrive access point must enter an in-field staging layer')

print('UnloaderCoordinatorTest: OK')

local forageA = makeHarvester('Reserved forager', 0, true, 0, 0, 0, 0)
local forageB = makeHarvester('Earlier urgent forager', 10, true, 0, 10, 0, 100)
local firmRelief = makeUnloader('Firm relief', 5, true, nil, 0)
AIDriveStrategyUnloadCombine.activeUnloaders = {[firmRelief] = firmRelief.vehicle}
g_currentMission.vehicleSystem.vehicles = {forageB, forageA}
UnloaderCoordinator.assignments = {[firmRelief] = {harvester = forageA, isFirm = true, reserved = true,
    role = 'STANDBY', assignedAt = g_currentMission.time}}
UnloaderCoordinator:rebalance(true)
assert(firmRelief.assignment.harvester == forageA,
        'A demand processed earlier must not steal another forager relief during fleet allocation')

local capacityCombine = makeHarvester('Capacity combine', 0, false, 0, 0, 30, 90)
capacityCombine:getCpDriveStrategy().combineController = {getFillLevel = function() return 19000 end}
local partialLead = makeUnloader('Partial lead', 0, false, capacityCombine, 60)
partialLead.getFreeCapacityForHarvester = function() return 12000 end
AIDriveStrategyUnloadCombine.activeUnloaders = {[partialLead] = partialLead.vehicle}
assert(UnloaderCoordinator:createDemand(capacityCombine, g_currentMission.time).secondsUntilNeeded == 0,
        'Relief must prepare before discharge when the active partial load cannot accommodate the tank')
partialLead.getFreeCapacityForHarvester = function() return 30000 end
assert(UnloaderCoordinator:createDemand(capacityCombine, g_currentMission.time).secondsUntilNeeded > 0)

local predictive = makeHarvester('Moving staging target', 0, false, 120, 0)
-- GIANTS returns a speed and an additional boolean, not just a single number.
predictive.getSpeedLimit = function() return 18, true end
predictive:getCpDriveStrategy():getFieldworkCourse().getNextWaypointIxWithinDistance = function(_, ix, distance)
    return ix + math.floor(distance)
end
PathfinderUtil = {hasFruit = function() return false end}
local predictedWaypoint, predictedIx = UnloaderCoordinator:getPredictedStagingWaypoint(predictive, predictive:getCpDriveStrategy(), 20)
assert(predictedIx == 1050 and predictedWaypoint.x == 50,
        'The future staging target must account for the combine travel before the call')
PathfinderUtil.hasFruit = function() return true end
_, predictedIx = UnloaderCoordinator:getPredictedStagingWaypoint(predictive, predictive:getCpDriveStrategy(), 20)
assert(predictedIx == 950, 'Predicted staging must fall back to harvested ground rather than park in future crop')
predictive:getCpDriveStrategy().getClosestFieldworkWaypointIx = function() return nil end
assert(UnloaderCoordinator:getPredictedStagingWaypoint(predictive, predictive:getCpDriveStrategy(), 20) == nil,
        'Starting a temporary pocket course without a passed waypoint must not crash fleet staging')
print('Fleet reservation, capacity and prediction regressions: OK')

-- Coverage, not the still-full tank of a served combine, determines who gets the remaining trailer.
local covered = makeHarvester('Covered full combine', 0, false, 0, 0, 0, 100)
local uncovered = makeHarvester('Uncovered combine', 1000, false, 0, 1000, 10, 98)
covered:getCpDriveStrategy().combineController = {getFillLevel = function() return 20000 end}
local serving = makeUnloader('Active lead', 0, false, covered, 0)
serving.getFreeCapacityForHarvester = function() return 32000 end
local remaining = makeUnloader('Remaining trailer', 10, true, nil, 0)
AIDriveStrategyUnloadCombine.activeUnloaders = {[serving] = serving.vehicle, [remaining] = remaining.vehicle}
g_currentMission.vehicleSystem.vehicles = {covered, uncovered}
UnloaderCoordinator.assignments = {[remaining] = {harvester = covered, reserved = true, isFirm = false,
    role = 'POOL', assignedAt = g_currentMission.time}}
assert(UnloaderCoordinator:canBeCalledBy(remaining, uncovered),
        'An unnecessary relief reservation must not deny a call from an uncovered combine')
UnloaderCoordinator:rebalance(true)
assert(remaining.assignment.harvester == uncovered and remaining.assignment.reserved,
        'An uncovered nearly-full combine must receive the trailer before a covered combine receives relief')
covered:getCpDriveStrategy().litersPerSecond = 20
serving.getFreeCapacityForHarvester = function() return 21000 end
assert(UnloaderCoordinator:createDemand(covered, g_currentMission.time).secondsUntilNeeded == 50,
        'Relief must account for crop arriving after the tank fills the active trailer')

-- A moving harvester extends the journey to close staging; a distant demand must not cause constant following.
local movingHarvester = makeHarvester('Moving harvester', 350, false, 110, 350)
movingHarvester.getSpeedLimit = function() return 7.2, true end
local approaching = makeUnloader('Approaching trailer', 0, true, nil, 0)
local movingDemand = UnloaderCoordinator:createDemand(movingHarvester, g_currentMission.time)
assert(UnloaderCoordinator:shouldDeploy(approaching, movingDemand),
        'The lead must leave early enough to close the gap to a moving combine by the call setting')
movingHarvester.getSpeedLimit = function() return 0, false end
assert(not UnloaderCoordinator:shouldDeploy(approaching, movingDemand),
        'Without harvester movement this same journey is not due yet')
local parkedAssignment = {harvester = movingHarvester, role = 'STANDBY', waypoint = {x = 0, z = 0}, waypointIx = 600}
approaching.reachedStandby = true
movingDemand.secondsUntilNeeded = 600
local parkedPoint = UnloaderCoordinator:getStableStagingWaypoint(movingHarvester, 'STANDBY',
        {x = 300, z = 0}, 950, parkedAssignment, approaching, movingDemand)
assert(parkedPoint == parkedAssignment.waypoint, 'A parked lead must not chase a combine with distant demand')

-- Four independent combines receive one reservation each; surplus trailers stay in the rear pool.
local fleetHarvesters, fleetTrailers = {}, {}
AIDriveStrategyUnloadCombine.activeUnloaders = {}
UnloaderCoordinator.assignments = {}
for i = 1, 4 do
    fleetHarvesters[i] = makeHarvester('Combine ' .. i, i * 1000, false, 100, i * 1000)
    fleetTrailers[i] = makeUnloader('Trailer ' .. i, i * 1000 - 50, true, nil, 0)
    AIDriveStrategyUnloadCombine.activeUnloaders[fleetTrailers[i]] = fleetTrailers[i].vehicle
end
local extra = makeUnloader('Extra trailer', 1950, true, nil, 0)
AIDriveStrategyUnloadCombine.activeUnloaders[extra] = extra.vehicle
g_currentMission.vehicleSystem.vehicles = fleetHarvesters
UnloaderCoordinator:rebalance(true)
local reservations, pools = {}, 0
for _, assignment in pairs(UnloaderCoordinator.assignments) do
    if assignment.reserved then
        assert(not reservations[assignment.harvester], 'A combine must never have two reserved leads')
        reservations[assignment.harvester] = true
    else
        assert(assignment.role == 'POOL'); pools = pools + 1
    end
end
for _, harvester in ipairs(fleetHarvesters) do assert(reservations[harvester]) end
assert(pools == 1, 'The spare trailer must be pooled rather than becoming a second lead')
local aheadTrailer = makeUnloader('Ahead waiting trailer', 2000, true, nil, 40)
UnloaderCoordinator.assignments[aheadTrailer] = {harvester = fleetHarvesters[1], role = 'POOL',
    reserved = false, waitUntilHarvesterPasses = true}
aheadTrailer.shouldWaitAtPoolForHarvester = function(_, harvester) return harvester == fleetHarvesters[1] end
assert(not UnloaderCoordinator:canBeCalledBy(aheadTrailer, fleetHarvesters[1]),
        'An ahead trailer must retain its fruit-protected wait for a harvester that has not passed')
assert(UnloaderCoordinator:canBeCalledBy(aheadTrailer, fleetHarvesters[2]),
        'A wait for one harvester must not exclude a safe call from another that has already passed')
print('Fleet coverage, call timing and parked-lead acceptance regressions: OK')

-- Reproduce the follower claiming a newly available nearby trailer before the full lead's update runs.
local lead = makeHarvester('Lead', 200, false, 0, 200, 0, 96)
local follower = makeHarvester('Follower', 150, false, 0, 150, 30, 85)
local leadStrategy, followerStrategy = lead:getCpDriveStrategy(), follower:getCpDriveStrategy()
leadStrategy.isWaitingForUnload = function() return true end
followerStrategy.isWaitingForUnload = function() return false end
local freeTrailer = makeUnloader('Free trailer', 100, true, nil, 30)
freeTrailer.isServingPosition = function() return true end
freeTrailer.isAllowedToBeCalled = function() return true end
AIDriveStrategyUnloadCombine.activeUnloaders = {[freeTrailer] = freeTrailer.vehicle}
g_currentMission.vehicleSystem.vehicles = {follower, lead}
assert(not UnloaderCoordinator:shouldServeHarvesterFirst(freeTrailer, follower),
        'A follower updating first must leave the nearby trailer available for the waiting lead')
assert(UnloaderCoordinator:shouldServeHarvesterFirst(freeTrailer, lead))
followerStrategy.isWaitingForUnload = function() return true end
followerStrategy.fieldWorkerProximityController = {fieldWorkCourse = {}, hasSameCourse = function() return true end,
    otherVehicleAheadOnTrail = {[lead] = true}}
leadStrategy.fieldWorkerProximityController = {fieldWorkCourse = {}, hasSameCourse = function() return true end,
    otherVehicleAheadOnTrail = {[follower] = false}}
assert(not UnloaderCoordinator:shouldServeHarvesterFirst(freeTrailer, follower),
        'Both waiting: the established convoy leader retains first call')
leadStrategy.fieldWorkerProximityController = nil
assert(UnloaderCoordinator:shouldServeHarvesterFirst(freeTrailer, lead) and
        not UnloaderCoordinator:shouldServeHarvesterFirst(freeTrailer, follower),
        'One recorded convoy trail must establish the same priority from both callers')
local servingLead = makeUnloader('Serving lead', 200, false, lead, 0)
AIDriveStrategyUnloadCombine.activeUnloaders[servingLead] = servingLead.vehicle
assert(not UnloaderCoordinator:shouldServeHarvesterFirst(freeTrailer, follower),
        'The follower must not send a second trailer into the lead trailer’s working corridor')
AIDriveStrategyUnloadCombine.activeUnloaders[servingLead] = nil
lead.rootNode.x = 2000
assert(UnloaderCoordinator:shouldServeHarvesterFirst(freeTrailer, follower),
        'A distant harvester must not monopolise a trailer beside another due combine')
print('Waiting lead and order-independent call priority regressions: OK')

-- A spare inside its predicted pool layer must not loop backwards merely to match a new pool waypoint/heading.
local parked = makeUnloader('Parked spare', 100, true, nil, 0)
local poolHarvester = makeHarvester('Pool harvester', 300, false, 200, 300)
g_currentMission.vehicleSystem.vehicles = {poolHarvester}
parked.vehicle.cpGetFieldPolygon = function() return {} end
AIUtil = {getWidth = function() return 3 end}
FieldworkBoundary = {forVehicle = function() return {} end, contains = function() return true end}
PathfinderUtil.hasFruit = function() return false end
local waypoint = UnloaderCoordinator:getPoolWaypoint(parked, {
    harvester = poolHarvester, harvesterStrategy = poolHarvester:getCpDriveStrategy(), secondsUntilNeeded = 500,
}, 2)
assert(waypoint.x == parked.vehicle.rootNode.x, 'An unneeded spare already clear in the field must stay parked')
local justCleared = makeUnloader('Just cleared', 250, true, nil, 60)
justCleared.vehicle.cpGetFieldPolygon = function() return {} end
justCleared.postUnloadClearanceHarvester = poolHarvester
justCleared.getDistanceAndEteToVehicle = function() return 500, 100 end
PathfinderUtil.hasFruit = function() return true end
local clearedWaypoint = UnloaderCoordinator:getPoolWaypoint(justCleared, {
    harvester = poolHarvester, harvesterStrategy = poolHarvester:getCpDriveStrategy(), secondsUntilNeeded = 500,
}, 2)
assert(clearedWaypoint.x == justCleared.vehicle.rootNode.x,
        'A cleared trailer must stay parked despite a long turning route estimate and nearby crop')
PathfinderUtil.hasFruit = function() return false end
print('Parked spare does not backtrack: OK')

-- Two nearby combines share a rig that can finish its current tank and still take more crop.
lead.rootNode.x = 200
leadStrategy.combineController = {getFillLevel = function() return 10000 end}
leadStrategy.litersPerSecond = 0
servingLead.getFreeCapacityForHarvester = function() return 25000 end
AIDriveStrategyUnloadCombine.activeUnloaders = {[servingLead] = servingLead.vehicle, [freeTrailer] = freeTrailer.vehicle}
lead.rootNode.x = 380
assert(UnloaderCoordinator:getSharedUnloader(follower) == servingLead,
        'The same-course sharing corridor must extend beyond the old 100 m cutoff')
assert(not UnloaderCoordinator:shouldServeHarvesterFirst(freeTrailer, follower),
        'Combines on the same headland must share the serving trailer before they converge at a corner')
lead.rootNode.x = 200
g_currentMission.vehicleSystem.vehicles = {lead, follower}
UnloaderCoordinator.assignments = {}
assert(not UnloaderCoordinator:shouldServeHarvesterFirst(freeTrailer, follower),
        'Nearby follower must wait for the shared rig instead of calling a second trailer')
assert(UnloaderCoordinator:createDemand(follower, g_currentMission.time).sharedUnloader == servingLead)
UnloaderCoordinator:rebalance(true)
assert(freeTrailer.assignment.role == 'POOL', 'Relief stays well back even when both combines need unloading')
servingLead.getFreeCapacityForHarvester = function() return 5000 end
assert(not UnloaderCoordinator:shouldServeHarvesterFirst(freeTrailer, follower),
        'Remaining capacity alone must not summon another trailer before the lead has finished')
UnloaderCoordinator:rebalance(true)
assert(freeTrailer.assignment.role == 'POOL', 'Urgent combine relief must not enter close standby while the pipe is occupied')
assert(math.abs(freeTrailer.assignment.waypoint.x - lead.rootNode.x) >= UnloaderCoordinator.minimumPoolDistance,
        'Even urgent relief must park outside the rear pool clearance')
servingLead.getFreeCapacityForHarvester = function() return 25000 end
lead.rootNode.x = 2000
assert(UnloaderCoordinator:shouldServeHarvesterFirst(freeTrailer, follower),
        'Separated combines require independent trailers')
lead.rootNode.x = 200
UnloaderCoordinator.trailerFillSamples[servingLead] = {fill = 0, time = g_currentMission.time - 1000, rate = 10}
assert(UnloaderCoordinator:getSecondsUntilRelief(lead, leadStrategy, servingLead, g_currentMission.time) == math.huge,
        'Rapid pipe transfer must not predict that a sufficient trailer needs immediate replacement')
leadStrategy.litersPerSecond = 50
assert(UnloaderCoordinator:getSecondsUntilRelief(lead, leadStrategy, servingLead, g_currentMission.time) == 300)
print('Shared combine trailer, rear relief and crop-rate regressions: OK')

servingLead.getCombineToUnload = function() return nil end
servingLead.states = {MOVING_BACK = {}}
servingLead.state = servingLead.states.MOVING_BACK
UnloaderCoordinator.clearingUnloaders[servingLead.vehicle] = {harvester = lead, distance = 60}
assert(UnloaderCoordinator:getSharedUnloader(follower) == servingLead,
        'Brief post-unload reversing must not summon an empty replacement for a nearby partial load')
servingLead.isInDeadlock = function() return true end
assert(not UnloaderCoordinator:getSharedUnloader(follower), 'A blocked rig must not indefinitely suppress another trailer')
servingLead.isInDeadlock = nil
servingLead.state = {}
assert(not UnloaderCoordinator:getSharedUnloader(follower), 'Clearance coverage ends when reversing ends')
print('Partial-load clearance and blocked coverage regressions: OK')

-- A shared rig travelling to the first nearby combine must not be rejected just because
-- its current journey estimate to the second exceeds the staging margin.
servingLead.state = {}
servingLead.getCombineToUnload = function() return lead end
servingLead.getDistanceAndEteToVehicle = function() return 300, 70 end
UnloaderCoordinator.clearingUnloaders[servingLead.vehicle] = nil
assert(UnloaderCoordinator:getSharedUnloader(follower) == servingLead,
        'The active rig must cover an adjacent combine throughout its first journey')
servingLead.states.UNLOADING_STOPPED_COMBINE = {}
servingLead.state = servingLead.states.UNLOADING_STOPPED_COMBINE
servingLead.isInDeadlock = function() return true end
assert(UnloaderCoordinator:getSharedUnloader(follower) == servingLead,
        'A temporary hold during transfer must not release the nearby corridor to a second trailer')
servingLead.isInDeadlock = nil
print('Adjacent combine shares en-route active trailer: OK')

-- Rebalancing must not revoke an assignment while its rig is still clearing a connector.
local clearing = makeUnloader('Clearing trailer', 100, true, nil, 0)
clearing.isConnectorClearancePending = function() return true end
local clearingAssignment = {harvester = lead, role = 'STANDBY', reserved = true}
AIDriveStrategyUnloadCombine.activeUnloaders = {[clearing] = clearing.vehicle}
g_currentMission.vehicleSystem.vehicles = {}
UnloaderCoordinator.assignments = {[clearing] = clearingAssignment}
UnloaderCoordinator:rebalance(true)
assert(UnloaderCoordinator.assignments[clearing] == clearingAssignment and clearing.assignment == clearingAssignment,
        'A clearing trailer must keep its assignment until the whole rig leaves the connector')
