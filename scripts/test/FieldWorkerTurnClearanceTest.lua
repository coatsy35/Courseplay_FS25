function CpObject()
    return {}
end

CpDebug = { DBG_TRAFFIC = 1 }
CpUtil = {
    debugVehicle = function() end,
    infoVehicle = function() end,
    getName = function(vehicle) return vehicle.name end,
}
AIUtil = {
    getWidth = function(vehicle) return vehicle.width end,
    getLength = function(vehicle) return vehicle.length end,
}

dofile('scripts/ai/FieldWorkerProximityController.lua')

local states = {
    WORKING = {},
    TURNING = {},
    DRIVING_TO_WORK_START_WAYPOINT = {},
}

local function makeStrategy(state, workWidth)
    return {
        states = states,
        state = state,
        getWorkWidth = function() return workWidth end,
        isTurning = function(self) return self.state == states.TURNING end,
        isManeuvering = function(self) return self.state == states.TURNING end,
        isAboutToTurn = function() return false end,
    }
end

local function makeVehicle(name, state, workWidth, length)
    local strategy = makeStrategy(state, workWidth)
    local vehicle = {
        name = name,
        width = 4,
        length = length,
        getCpDriveStrategy = function() return strategy end,
    }
    return vehicle, strategy
end

local workingVehicle, working = makeVehicle('Working combine', states.WORKING, 14, 10)
local startingVehicle, starting = makeVehicle('Starting combine', states.DRIVING_TO_WORK_START_WAYPOINT, 14, 10)
local turningVehicle, turning = makeVehicle('Turning combine', states.TURNING, 14, 10)

local startingController = {
    vehicle = startingVehicle,
    workingWidth = 14,
    minimumTurnClearance = FieldWorkerProximityController.minimumTurnClearance,
}
setmetatable(startingController, { __index = FieldWorkerProximityController })
assert(startingController:mustYieldPhysicalTurnClearance(workingVehicle, working),
        'A combine driving to its work-start waypoint must yield to a working combine')

local workingController = {
    vehicle = workingVehicle,
    workingWidth = 14,
    minimumTurnClearance = FieldWorkerProximityController.minimumTurnClearance,
}
setmetatable(workingController, { __index = FieldWorkerProximityController })
assert(not workingController:mustYieldPhysicalTurnClearance(startingVehicle, starting),
        'The working combine must retain priority over a combine returning to work')
assert(workingController:mustYieldPhysicalTurnClearance(turningVehicle, turning),
        'A working combine must yield to another combine already turning')
assert(workingController:getPhysicalTurnClearance(turningVehicle, turning) >= 29,
        'Turn clearance must account for the header and both vehicle lengths')

print('FieldWorkerTurnClearanceTest: OK')
