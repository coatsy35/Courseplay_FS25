function CpObject()
    return {}
end

AIDriveStrategyFieldWorkCourse = {}
MathUtil = {
    vector2Length = function(x, z) return math.sqrt(x * x + z * z) end,
}
CpMathUtil = {
    clamp = function(value, minimum, maximum) return math.max(minimum, math.min(value, maximum)) end,
}
FieldworkBoundary = {
    forVehicle = function() return nil end,
}

dofile('scripts/ai/strategies/AIDriveStrategyCombineCourse.lua')

local function makeCourse(points)
    local waypoints = {}
    for i, point in ipairs(points) do
        waypoints[i] = {
            x = point.x,
            z = point.z,
            getOffsetPosition = function(self, offsetX, offsetZ)
                return self.x + offsetX, 0, self.z + offsetZ
            end,
        }
    end
    return {
        waypoints = waypoints,
        getPreviousWaypointIxWithinDistance = function(_, ix, distance)
            local backIx = ix - math.ceil(distance)
            return backIx >= 1 and backIx or nil
        end,
        isTurnStartAtIx = function() return false end,
        isTurnEndAtIx = function() return false end,
        isReverseAt = function() return false end,
        getWaypointPosition = function(self, ix)
            local waypoint = self.waypoints[ix]
            return waypoint.x, 0, waypoint.z
        end,
        getWaypoint = function(self, ix) return self.waypoints[ix] end,
        getOffset = function() return 0, 0 end,
    }
end

local function makeGeometryStrategy(course)
    local strategy = {
        vehicle = {},
        course = course,
        pocketReverseDistance = 5,
        pocketCurveToleranceFactor = AIDriveStrategyCombineCourse.pocketCurveToleranceFactor,
        pocketCourseSuitability = {},
        pullBackRightSideOffset = 6,
        getWorkWidth = function() return 12 end,
    }
    return setmetatable(strategy, { __index = AIDriveStrategyCombineCourse })
end

local straight = {}
for i = 1, 12 do
    straight[i] = { x = 0, z = i }
end
local straightStrategy = makeGeometryStrategy(makeCourse(straight))
assert(straightStrategy:isPocketCourseSectionSuitable(8),
        'A straight reverse-and-offset section must allow a pocket')

local curved = {}
for i = 1, 12 do
    local z = i
    curved[i] = { x = (z - 4) * (z - 4) * 0.18, z = z }
end
local curvedStrategy = makeGeometryStrategy(makeCourse(curved))
local suitable, _, reason = curvedStrategy:isPocketCourseSectionSuitable(8)
assert(not suitable and reason:find('bends'),
        'A broad curve without explicit turn waypoints must reject a pocket')

local planningCourse = {
    getDistanceToLastWaypoint = function() return 100 end,
    getNumberOfWaypoints = function() return 30 end,
    getDistanceBetweenWaypoints = function(_, a, b) return math.abs(a - b) end,
}
local planningStrategy = {
    course = planningCourse,
    settings = { selfUnload = { getValue = function() return false end } },
    ppc = {
        getLastPassedWaypointIx = function() return 10 end,
        getCurrentWaypointIx = function() return 10 end,
    },
    combineController = { getFillLevel = function() return 500 end },
    waypointIxWhenFull = 20,
    distanceUntilFull = 10,
    pocketReverseDistance = 8,
    pocketFillLevelFullPercentage = 95,
    normalFillLevelFullPercentage = 99.5,
    getWorkWidth = function() return 12 end,
    shouldMakePocket = function() return true end,
    debug = function() end,
    debugSparse = function() end,
}
setmetatable(planningStrategy, { __index = AIDriveStrategyCombineCourse })

planningStrategy.isPocketCourseSectionSuitable = function(_, ix)
    return ix < 12
end
planningStrategy:updatePocketUnloadPlan(10)
assert(planningStrategy.startPocketBeforeUnsafeSection,
        'The combine must pocket before a curved section when it cannot reach another safe section')

planningStrategy.isPocketCourseSectionSuitable = function(_, ix)
    return ix < 12 or ix >= 15
end
planningStrategy:updatePocketUnloadPlan(10)
assert(not planningStrategy.startPocketBeforeUnsafeSection and
        planningStrategy.fillLevelFullPercentage == planningStrategy.normalFillLevelFullPercentage,
        'The combine must pass a curve when predicted capacity reaches the next safe section')

planningStrategy.isPocketCourseSectionSuitable = function(_, ix)
    if ix == 10 then return false, nil, 'curved section' end
    return ix >= 15
end
planningStrategy:updatePocketUnloadPlan(10)
assert(not planningStrategy.startPocketBeforeUnsafeSection and
        planningStrategy.fillLevelFullPercentage == planningStrategy.normalFillLevelFullPercentage,
        'The combine must carry through a curve when it can reach a safe section before becoming full')

CpUtil = {
    getName = function(vehicle) return vehicle.name end,
}
local candidateCalled = false
local candidateStrategy = {
    call = function() candidateCalled = true return true end,
    getFillLevelPercentage = function() return 0 end,
}
local candidate = {
    name = 'Near trailer',
    getCpDriveStrategy = function() return candidateStrategy end,
}
local recoveryRequested = false
local assigned = {
    vehicle = { name = 'Far trailer' },
    getDistanceAndEteToVehicle = function() return 100, 100 end,
    getFillLevelPercentage = function() return 0 end,
    isInDeadlock = function() return false end,
    yieldCallToCloserUnloader = function(_, _, recoverFromBlock)
        recoveryRequested = recoverFromBlock
        return true
    end,
}
local switchStrategy = setmetatable({
    vehicle = {},
    debug = function() end,
    findUnloader = function() return candidate, 20 end,
    alwaysNeedsUnloader = function() return false end,
    isWaitingForUnload = function() return false end,
    combineController = { getFillLevelPercentage = function() return 79 end },
    settings = { callUnloaderPercent = { getValue = function() return 80 end } },
}, { __index = AIDriveStrategyCombineCourse })
assert(not switchStrategy:shouldReconsiderAssignedUnloader(),
        'An assigned lead must remain stable before the configured call percentage')
switchStrategy.combineController.getFillLevelPercentage = function() return 80 end
assert(switchStrategy:shouldReconsiderAssignedUnloader(),
        'An assigned lead must be reassessed as soon as the configured call percentage is reached')
switchStrategy.isWaitingForUnload = function() return true end
assert(switchStrategy:trySwitchToCloserUnloader(assigned) and candidateCalled,
        'A stopped combine must transfer a distant call to a materially quicker eligible trailer')
candidateCalled = false
assigned.pendingDepartureCall = {combine = switchStrategy.vehicle}
assert(switchStrategy:trySwitchToCloserUnloader(assigned) and candidateCalled,
        'A queued distant call must also yield to a materially quicker trailer that can respond')
assigned.pendingDepartureCall = nil

candidateCalled = false
assigned.getDistanceAndEteToVehicle = function() return 25, 25 end
assigned.isInDeadlock = function() return true end
switchStrategy.findUnloader = function() return candidate, 20 end
assert(switchStrategy:trySwitchToCloserUnloader(assigned) and candidateCalled and recoveryRequested,
        'A stopped combine must replace a blocked trailer and request its boundary-aware recovery')

-- Exercise the moving replacement with the actual multi-return shape of the engine speed API.
switchStrategy.isWaitingForUnload = function() return false end
switchStrategy.vehicle.getSpeedLimit = function() return 18, false end
switchStrategy.getSecondsUntilFull = function() return 100 end
switchStrategy.getClosestFieldworkWaypointIx = function() return 100 end
switchStrategy.getFieldworkCourse = function() return {
    getNextWaypointIxWithinDistance = function(_, ix, distance)
        assert(distance == 100, 'Replacement prediction must use only the numeric speed return')
        return ix + 10
    end,
} end
switchStrategy.findBestWaypointToUnload = function(_, ix) return ix end
local movingReplacementCalled = false
switchStrategy.callUnloader = function(_, selected, ix, ete)
    movingReplacementCalled = selected == candidate and ix == 110 and ete == 20
    return movingReplacementCalled
end
assert(switchStrategy:trySwitchToCloserUnloader(assigned) and movingReplacementCalled,
        'A moving replacement must remain callable when getSpeedLimit also returns a boolean')
switchStrategy.getClosestFieldworkWaypointIx = function() return nil end
assigned.yieldCallToCloserUnloader = function() error('Must retain the existing call during an unlocated manoeuvre') end
assert(not switchStrategy:trySwitchToCloserUnloader(assigned),
        'A temporary course with no passed waypoint must not release the active unloader')

local pocketCallAccepted = false
local pocketLeadStrategy = {
    callForPocket = function(_, combine)
        pocketCallAccepted = combine ~= nil
        return true
    end,
}
local pocketLead = { getCpDriveStrategy = function() return pocketLeadStrategy end }
local pocketCallStrategy = setmetatable({
    vehicle = {
        getSpeedLimit = function() return 10 end,
    },
    course = {
        getWaypoint = function(_, ix) return { x = ix, z = 0 } end,
        getDistanceBetweenWaypoints = function(_, a, b) return math.abs(a - b) end,
        getCurrentWaypointIx = function() return 100 end,
    },
    waypointIxWhenCallUnloader = 200,
    combineController = { getFillLevelPercentage = function() return 75 end },
    settings = { callUnloaderPercent = { getValue = function() return 80 end } },
    findUnloader = function() return pocketLead, 40 end,
}, { __index = AIDriveStrategyCombineCourse })
assert(not pocketCallStrategy:callLeadForPocketWhenNeeded() and not pocketCallAccepted,
        'Combine staging must not promote the lead before the configured call percentage')
pocketCallStrategy.combineController.getFillLevelPercentage = function() return 80 end
assert(pocketCallStrategy:callLeadForPocketWhenNeeded() and pocketCallAccepted,
        'A first-headland restriction must still call the parked lead at the configured call percentage')

-- Exercise the public call dispatcher, including a finished row below the normal call percentage.
local fill, callPercent, waiting, directCalls, pocketCalls = 74, 80, true, 0, 0
pocketCallStrategy.timeToCallUnloader = {get = function() return true end, set = function() end}
pocketCallStrategy.unloader = {get = function() return nil end}
pocketCallStrategy.debug = function() end
pocketCallStrategy.alwaysNeedsUnloader = function() return false end
pocketCallStrategy.isWaitingForUnload = function() return waiting end
pocketCallStrategy.findBestWaypointToUnload = function() return nil end
pocketCallStrategy.getFieldworkCourse = function(self) return self.course end
pocketCallStrategy.getClosestFieldworkWaypointIx = function() return 100 end
pocketCallStrategy.combineController.getFillLevelPercentage = function() return fill end
pocketCallStrategy.settings.nearbyStandbyUnloaders = {getValue = function() return 1 end}
pocketCallStrategy.settings.callUnloaderPercent.getValue = function() return callPercent end
pocketLeadStrategy.call = function() directCalls = directCalls + 1; return true end
pocketLeadStrategy.callForPocket = function() pocketCalls = pocketCalls + 1; return true end
pocketCallStrategy:callUnloaderWhenNeeded()
assert(directCalls == 1, 'A combine already waiting below the threshold must still call a trailer')
waiting, fill = false, 79
pocketCallStrategy:callUnloaderWhenNeeded()
assert(pocketCalls == 0, 'A working combine below its setting must leave its staged lead parked')
fill = 80
pocketCallStrategy:callUnloaderWhenNeeded()
assert(pocketCalls == 1, 'At the call setting the first-headland pocket lead must be called')
callPercent, fill = 65, 64
pocketCallStrategy:callUnloaderWhenNeeded()
assert(pocketCalls == 1)
fill = 65
pocketCallStrategy:callUnloaderWhenNeeded()
assert(pocketCalls == 2, 'The trigger must follow the setting rather than a hard-coded 80 percent')

-- Reproduce loading at 90.5% with no previous sample: never choose the last waypoint (2434).
g_currentMission = {time = 1000}
CpMathUtil.divide = function(a, b) return b == 0 and math.huge or a / b end
local fillLitres = 18109.4
pocketCallStrategy.combineController.getFillLevel = function() return fillLitres end
pocketCallStrategy.combineController.getCapacity = function() return 20000 end
pocketCallStrategy.course.getDistanceToNextWaypoint = function() return 3 end
pocketCallStrategy.course.getNumberOfWaypoints = function() return 2434 end
pocketCallStrategy.course.getNextWaypointIxWithinDistance = function(_, ix, distance)
    return distance == math.huge and 2434 or ix + math.ceil(distance / 3), distance
end
pocketCallStrategy.fillLevelAtLastWaypoint = 0
pocketCallStrategy.litersPerMeter, pocketCallStrategy.litersPerSecond = 0, 0
callPercent = 80
pocketCallStrategy:estimateDistanceUntilFull(393)
assert(pocketCallStrategy.waypointIxWhenCallUnloader == 393,
        'Starting above the call setting with zero harvest rate must target the current waypoint')
fillLitres = 12000
pocketCallStrategy.fillLevelAtLastWaypoint = 0
pocketCallStrategy:estimateDistanceUntilFull(393)
assert(pocketCallStrategy.waypointIxWhenCallUnloader == nil,
        'An unknown future call position must not masquerade as the end of the course')

-- Dispatch at start, without passing any waypoint, regardless of a stale/missing prediction or infinite speed limit.
for _, percentage in ipairs({65, 80, 95}) do
    callPercent = percentage
    for _, startedFill in ipairs({percentage, 100}) do
        fill = startedFill
        for _, prediction in ipairs({false, 2434}) do
            pocketCallStrategy.waypointIxWhenCallUnloader = prediction or nil
            local before = pocketCalls
            pocketCallStrategy.findUnloader = function(_, combine, waypoint)
                assert(combine == pocketCallStrategy.vehicle and waypoint == nil,
                        'Overdue calls must choose the closest suitable trailer to the combine itself')
                return pocketLead, 40
            end
            pocketCallStrategy.vehicle.getSpeedLimit = function() return math.huge, false end
            pocketCallStrategy:callUnloaderWhenNeeded()
            assert(pocketCalls == before + 1, 'A loaded save above the setting must dispatch without fill history')
        end
    end
end

-- A future interception must not bypass the headland/pocket rules when it is moved ahead.
fill, callPercent = 90, 80
pocketCallStrategy.vehicle.getSpeedLimit = function() return 10, false end
pocketCallStrategy.getSecondsUntilFull = function() return 10 end
pocketCallStrategy.findBestWaypointToUnload = function(_, ix) return ix == 100 and ix or nil end
local before = pocketCalls
pocketCallStrategy:callUnloaderWhenNeeded()
assert(pocketCalls == before + 1, 'An unsafe future intercept must dispatch the pocket lead instead')

-- Retain a useful search for an eleven-second gain, but still replace it for a genuinely nearby alternative.
switchStrategy.isWaitingForUnload = function() return true end
assigned.getDistanceAndEteToVehicle = function() return 400, 85.5 end
assigned.isInDeadlock = function() return false end
assigned.pathfinderController = {isActive = function() return true end}
assigned.yieldCallToCloserUnloader = function() return true end
switchStrategy.findUnloader = function() return candidate, 73.9 end
assert(not switchStrategy:trySwitchToCloserUnloader(assigned), 'Small ETE changes must not discard route searches')
switchStrategy.findUnloader = function() return candidate, 20 end
assert(switchStrategy:trySwitchToCloserUnloader(assigned), 'A substantially closer trailer must still take over')

-- The field log showed a 60%-full trailer become free 75 m away while an empty trailer was still en route.
-- A 5.5-second arrival gain must transfer that call, even though ordinary search hysteresis is ten seconds.
assigned.pathfinderController = nil
assigned.getDistanceAndEteToVehicle = function() return 90, 21.9 end
candidateStrategy.getFillLevelPercentage = function() return 60 end
switchStrategy.findUnloader = function() return candidate, 16.4 end
candidateCalled = false
assert(switchStrategy:trySwitchToCloserUnloader(assigned) and candidateCalled,
        'A nearer free part-loaded trailer must take over an en-route empty trailer')

print('PocketCoursePlanningTest: OK')
