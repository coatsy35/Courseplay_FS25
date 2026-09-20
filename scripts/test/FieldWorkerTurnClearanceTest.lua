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

local rearApproachingController = {
    vehicle = approachingTurnVehicle,
    workingWidth = 14,
    minimumTurnClearance = FieldWorkerProximityController.minimumTurnClearance,
}
setmetatable(rearApproachingController, { __index = FieldWorkerProximityController })
assert(rearApproachingController:mustYieldPhysicalTurnClearance(workingVehicle, working, true, false),
        'A rear combine approaching a turn must keep yielding to the established lead combine')
assert(not rearApproachingController:hasPhysicalTurnPriority(workingVehicle, working, true, false),
        'Approaching a turn must not reverse the established convoy order')
assert(not workingController:mustYieldPhysicalTurnClearance(approachingTurnVehicle, approachingTurn, false, true),
        'The established lead combine must retain priority until it has cleared the corner')
assert(workingController:hasPhysicalTurnPriority(approachingTurnVehicle, approachingTurn, false, true),
        'The lead combine must not stop for a follower that is approaching the same corner')

local otherAhead, selfAhead = rearApproachingController:resolveTurnConvoyOrder(
        workingVehicle, working, true, false)
assert(otherAhead and not selfAhead, 'A measurable lead vehicle must establish the convoy order')
otherAhead, selfAhead = rearApproachingController:resolveTurnConvoyOrder(
        workingVehicle, working, false, false)
assert(otherAhead and not selfAhead,
        'The established convoy order must survive ambiguous trail geometry throughout the turn')

wideLeading.getExpectedRearwardManeuverDistance = function() return 25 end
assert(wideFollowingController:getPhysicalTurnClearance(wideLeadingVehicle, wideLeading) >= 81,
        'A following combine must reserve the lead combine pocket reversing distance')

print('FieldWorkerTurnClearanceTest: OK')

-- Real getMaxSpeed integration: different course names must still respect an overlapping physical turn area.
workingVehicle.rootNode, turningVehicle.rootNode = 2, 1
workingVehicle.getAIDirectionNode = function() return 2 end
turningVehicle.getAIDirectionNode = function() return 1 end
turningVehicle.getIsCpFieldWorkActive = function() return true end
turningVehicle.getCpSettings = function() return {convoyDistance = {getValue = function() return 30 end}} end
turning.getFieldWorkProximity = function() error('Unrelated course trails must not establish convoy ordering') end
workingController.hasSameCourse = function() return false end
workingController.getFieldWorkProximity = function() return math.huge end
workingController.updateTrail = function() end
workingController.debugSparse = function() end
workingController.slowDownFactor = {update = function() end, get = function() return 1 end}
g_currentMission = {vehicleSystem = {vehicles = {workingVehicle, turningVehicle}}}
MathUtil = {vector2Length = function(x, z) return math.sqrt(x*x + z*z) end}
CpMathUtil = {clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end}
getWorldTranslation = function(node) return node == 1 and 40 or 0, 0, 0 end
assert(workingController:getMaxSpeed(30, 10) == 0,
        'A working combine must stop outside the turn envelope of a machine on an independently named course')
local oppositeAhead, oppositeBehind = rearApproachingController:resolveTurnConvoyOrder(workingVehicle, working, false, true)
assert(oppositeAhead and not oppositeBehind, 'Contradictory trail samples during the turn must not reverse established priority')
print('Independent course turn regression: OK')
