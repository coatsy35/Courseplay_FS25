CpDebug = { DBG_UNLOAD_COMBINE = 1 }
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

local function makeHarvester(name, x, isForager, secondsUntilCall, stageX)
    local currentIx = 1000
    local course = {
        getPreviousWaypointIxWithinDistance = function(_, _, distance)
            return currentIx - math.floor(distance)
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
        getFillLevelPercentage = function() return 50 end,
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
            return distance, distance
        end,
        getDistanceAndEteToVehicle = function(self, vehicle)
            local distance = math.abs(self.x - vehicle.rootNode.x)
            return distance, distance
        end,
        setStandbyAssignment = function(self, assignment) self.assignment = assignment end,
        clearStandbyAssignment = function(self) self.assignment = nil end,
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

-- A partly filled trailer wins while it remains close enough to justify finishing its load.
local continuityCombine = makeHarvester('Continuity combine', 500, false, 10, 500)
local partial = makeUnloader('Part-filled trailer', 100, true, nil, 45)
local empty = makeUnloader('Closer empty trailer', 480, true, nil, 0)
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
g_currentMission.time = 250000
UnloaderCoordinator.assignments = {}
UnloaderCoordinator:rebalance(true)
assert(localEmpty.assignment and localEmpty.assignment.reserved,
        'A distant partly filled trailer must not displace a nearby empty trailer')
assert(UnloaderCoordinator:getCallScore(45, 400) > UnloaderCoordinator:getCallScore(0, 20),
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

-- A soft combine reservation may still be overridden when it is the only trailer available to another combine.
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
assert(UnloaderCoordinator:canBeCalledBy(onlyTrailer, secondCombine),
        'A second combine may call the only softly reserved trailer')

print('UnloaderCoordinatorTest: OK')
