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
