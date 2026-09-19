CpDebug = { DBG_UNLOAD_COMBINE = 1 }
CpUtil = {
    debugFormat = function() end,
    getName = function(vehicle) return vehicle.name end,
}

function getWorldTranslation(node)
    return node.x, 0, node.z
end

local function setting(value)
    return { getValue = function() return value end }
end

local function makeHarvester(name, x, isForager, secondsUntilCall, stageX)
    local course = {
        getPreviousWaypointIxWithinDistance = function() return 10 end,
        isTurnStartAtIx = function() return false end,
        isTurnEndAtIx = function() return false end,
        isReverseAt = function() return false end,
        getWaypoint = function() return {
            x = stageX,
            z = 0,
        } end,
    }
    local strategy = {
        callUnloader = function() end,
        isTurning = function() return false end,
        isManeuvering = function() return false end,
        isAboutToTurn = function() return false end,
        getFieldworkCourse = function() return course end,
        getClosestFieldworkWaypointIx = function() return 20 end,
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
        vehicle = { name = name },
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
        return vehicle == forager or vehicle == combine
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
assert(UnloaderCoordinator:canBeCalledBy(nearCombine, forager),
        'A real call must be allowed to interrupt soft combine staging')

print('UnloaderCoordinatorTest: OK')
