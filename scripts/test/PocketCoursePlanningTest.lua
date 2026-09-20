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
}
local candidate = {
    name = 'Near trailer',
    getCpDriveStrategy = function() return candidateStrategy end,
}
local recoveryRequested = false
local assigned = {
    vehicle = { name = 'Far trailer' },
    getDistanceAndEteToVehicle = function() return 100, 100 end,
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
}, { __index = AIDriveStrategyCombineCourse })
assert(switchStrategy:trySwitchToCloserUnloader(assigned) and candidateCalled,
        'A stopped combine must transfer a distant call to a materially quicker eligible trailer')

candidateCalled = false
assigned.getDistanceAndEteToVehicle = function() return 25, 25 end
assigned.isInDeadlock = function() return true end
switchStrategy.findUnloader = function() return candidate, 20 end
assert(switchStrategy:trySwitchToCloserUnloader(assigned) and candidateCalled and recoveryRequested,
        'A stopped combine must replace a blocked trailer and request its boundary-aware recovery')

print('PocketCoursePlanningTest: OK')
