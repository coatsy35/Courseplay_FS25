function CpObject(base)
    local object = {}
    if base then setmetatable(object, {__index = base}) end
    return object
end

AIDriveStrategyCourse = {}
VariableWorkWidth = {onAIFieldWorkerStart = function() end, onAIImplementStart = function() end}
AIDriveStrategyFieldCourse = {onFieldCourseLoadedCallback = function() end, delete = function() end}
Utils = {overwrittenFunction = function(_, replacement) return replacement end}

local connectorIsContained = true
FieldworkBoundary = {
    forVehicle = function(vehicle, width)
        assert(width == 0, 'A generated connector must use the vehicle envelope, not the header width')
        return {vehicle = vehicle}
    end,
    containsCourse = function(_, course)
        return connectorIsContained and course.contained
    end,
}

dofile('scripts/ai/strategies/AIDriveStrategyFieldWorkCourse.lua')

local strategy = setmetatable({
    vehicle = {},
    turningRadius = 12,
    getWorkWidth = function() return 15 end,
}, {__index = AIDriveStrategyFieldWorkCourse})

local localConnector = {contained = true, getLength = function() return 45 end}
assert(not strategy:canDriveConnectingPathDirectly(localConnector),
        'A local join must retain accurate pathfinding')

local longConnector = {contained = true, getLength = function() return 700 end}
assert(strategy:canDriveConnectingPathDirectly(longConnector),
        'A long contained generated connector must be driven without a duplicate global search')

longConnector.contained = false
assert(not strategy:canDriveConnectingPathDirectly(longConnector),
        'A connector that leaves the field must not bypass pathfinding')

print('FieldworkConnectingPathTest: OK')
