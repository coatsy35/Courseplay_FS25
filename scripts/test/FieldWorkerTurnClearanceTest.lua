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

local function makeStrategy(state, workWidth, aboutToTurn)
    return {
        states = states,
        state = state,
        getWorkWidth = function() return workWidth end,
        isTurning = function(self) return self.state == states.TURNING end,
        isManeuvering = function(self) return self.state == states.TURNING end,
        isAboutToTurn = function() return aboutToTurn or false end,
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
local approachingTurnVehicle, approachingTurn = makeVehicle('Combine approaching turn', states.WORKING, 14, 10)
approachingTurn.isAboutToTurn = function() return true end

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
assert(not workingController:hasPhysicalTurnPriority(turningVehicle, turning),
        'A working follower must not take priority from a turning combine')
assert(workingController:mustYieldPhysicalTurnClearance(approachingTurnVehicle, approachingTurn),
        'A following combine must yield before the combine ahead begins its turn')
assert(workingController:getPhysicalTurnClearance(turningVehicle, turning) >= 50,
        'Turn clearance must account for the header and both vehicle lengths')

local wideLeadingVehicle, wideLeading = makeVehicle('18 metre combine', states.TURNING, 18, 10)
local wideFollowingController = {
    vehicle = workingVehicle,
    workingWidth = 15,
    minimumTurnClearance = FieldWorkerProximityController.minimumTurnClearance,
}
setmetatable(wideFollowingController, { __index = FieldWorkerProximityController })
assert(wideFollowingController:getPhysicalTurnClearance(wideLeadingVehicle, wideLeading) >= 56,
        'An 18 metre header must retain at least 56 metres of physical turn clearance')
assert(wideFollowingController:getPhysicalTurnClearance(wideLeadingVehicle, wideLeading) +
        FieldWorkerProximityController.turnSlowDownBand >= 86,
        'An 18 metre header must start slowing the following combine at least 86 metres away')

local turningController = {
    vehicle = turningVehicle,
    workingWidth = 14,
    minimumTurnClearance = FieldWorkerProximityController.minimumTurnClearance,
}
setmetatable(turningController, { __index = FieldWorkerProximityController })
assert(turningController:hasPhysicalTurnPriority(workingVehicle, working),
        'A turning lead combine must ignore the follower trail that would otherwise create mutual yielding')

wideLeading.getExpectedRearwardManeuverDistance = function() return 25 end
assert(wideFollowingController:getPhysicalTurnClearance(wideLeadingVehicle, wideLeading) >= 81,
        'A following combine must reserve the lead combine pocket reversing distance')

print('FieldWorkerTurnClearanceTest: OK')
