local lu = require('luaunit')
package.path = package.path .. ';../?.lua;../courseGenerator/?.lua;../ai/controllers/?.lua;../ai/turns/?.lua;../ai/strategies/?.lua'
require('CpObject')

g_time = 0
CpDebug = { DBG_TURN = 1 }
CpUtil = { debugVehicle = function() end }
CourseGenerator = {}
require('WaypointAttributes')
require('Waypoint')
require('Course')
require('ImplementController')
require('PlowController')
require('AITurn')

-- Exercise the plough strategy without starting the game's fieldworker state machine.
AIDriveStrategyCourse = { onTurnEndProgressEvent = 'turnEndProgress' }
AIDriveStrategyFieldWorkCourse = {
    resumeFieldworkAfterTurn = function(self, ix)
        self.resumedAt = ix
        self.rotationsAtResume = #self.rotations
    end
}
require('AIDriveStrategyPlowCourse')
CpMathUtil = { isSameDirection = function(_, aligned) return aligned end }

local function waypoint(attributes)
    return setmetatable({ attributes = setmetatable(attributes, CourseGenerator.WaypointAttributes) }, Waypoint)
end

local function course(attributes, nextAttributes, nextTurnLeft)
    local result = setmetatable({ waypoints = { waypoint(attributes) } }, Course)
    if nextAttributes then
        result.waypoints[2] = waypoint(nextAttributes)
        result.waypoints[1].nextRowStartIx = 2
    end
    result.isNextTurnLeft = function() return nextTurnLeft end
    return result
end

function testFirstCentreRowFacesEitherBlockBoundary()
    lu.assertIsTrue(course({ rowNumber = 1, leftSideBlockBoundary = true }, nil, true):shouldPlowBeOnTheLeft(1))
    lu.assertIsFalse(course({ rowNumber = 1, rightSideBlockBoundary = true }, nil, false):shouldPlowBeOnTheLeft(1))
end

function testCentreRowsStillAlternateUsingNextTurn()
    for _, row in ipairs({ 1, 2 }) do
        lu.assertIsFalse(course({ rowNumber = row }, nil, true):shouldPlowBeOnTheLeft(1))
        lu.assertIsTrue(course({ rowNumber = row }, nil, false):shouldPlowBeOnTheLeft(1))
    end
end

function testLastCentreRowUsesWorkedSideBeforeHeadland()
    local headland = { headlandPassNumber = 1 }
    lu.assertIsTrue(course({ rowNumber = 8, leftSideWorked = true }, headland, true):shouldPlowBeOnTheLeft(1))
    lu.assertIsFalse(course({ rowNumber = 8, leftSideWorked = false }, headland, false):shouldPlowBeOnTheLeft(1))
    lu.assertIsFalse(course({ rowNumber = 8 }, headland, false):shouldPlowBeOnTheLeft(1))
end

function testUnknownNextTurnReturnsBooleanWorkedSide()
    lu.assertIsTrue(course({ leftSideWorked = true }):shouldPlowBeOnTheLeft(1))
    lu.assertIsFalse(course({ leftSideWorked = false }):shouldPlowBeOnTheLeft(1))
    lu.assertIsFalse(course({}):shouldPlowBeOnTheLeft(1))
end

function testHeadlandSideStillFollowsClockwiseDirection()
    local field = course({ headlandPassNumber = 1 })
    field.isOnClockwiseHeadland = function() return true end
    lu.assertIsFalse(field:shouldPlowBeOnTheLeft(1))
    field.isOnClockwiseHeadland = function() return false end
    lu.assertIsTrue(field:shouldPlowBeOnTheLeft(1))
end

local function controller(animationTime, rotating, towed)
    local requests = {}
    local result = setmetatable({
        plowSpec = { rotationPart = { turnAnimation = 'turn' } },
        implement = {
            getAnimationTime = function() return animationTime end,
            getIsAnimationPlaying = function() return rotating end,
            getIsPlowRotationAllowed = function() return true end,
            setRotationMax = function(_, side) table.insert(requests, side) end
        },
        lastPlowSide = CpTemporaryObject(),
        towed = towed,
        debug = function() end
    }, PlowController)
    return result, requests
end

function testRotationMustFinishOnRequestedSide()
    for _, sample in ipairs({
        { 0, false, true }, { 1, true, false },
        { 0.5, false, false }, { 0.001, false, false }, { 0.999, false, false }
    }) do
        local plough = controller(sample[1], false)
        lu.assertEquals(plough:isRotatedToSide(true), sample[2])
        lu.assertEquals(plough:isRotatedToSide(false), sample[3])
    end
end

function testFixedPloughDoesNotNeedRotation()
    local plough, requests = controller(0, false)
    plough.plowSpec.rotationPart.turnAnimation = nil
    lu.assertIsTrue(plough:isRotatedToSide(true))
    lu.assertIsTrue(plough:isRotatedToSide(false))
    plough:onTurnEndProgress(true, false, true, true)
    lu.assertEquals(requests, {})
end

function testWrongSideIsCorrectedInBothDirections()
    for _, sample in ipairs({ { 0, true }, { 1, false } }) do
        local plough, requests = controller(sample[1], false)
        plough:onTurnEndProgress(true, false, false, sample[2])
        lu.assertEquals(requests, { sample[2] })
        lu.assertEquals(plough.lastPlowSide:get(), sample[2])
    end
end

function testCorrectOrActivelyRotatingPloughIsNotRestarted()
    for _, sample in ipairs({ { 1, false, true }, { 0, false, false }, { 0.5, true, true } }) do
        local plough, requests = controller(sample[1], sample[2])
        plough:onTurnEndProgress(true, false, true, sample[3])
        lu.assertEquals(requests, {})
    end
end

function testTowedPloughWaitsUntilReversingEnds()
    local plough, requests = controller(0.5, false, true)
    plough:onTurnEndProgress(true, true, true, true)
    lu.assertEquals(requests, {})
    plough:onTurnEndProgress(true, false, true, true)
    lu.assertEquals(requests, { true })
end

function testRotationWaitsForAlignmentOrLowering()
    local plough, requests = controller(0, false)
    plough:onTurnEndProgress(false, false, false, true)
    lu.assertEquals(requests, {})
    plough:onTurnEndProgress(false, false, true, true)
    lu.assertEquals(requests, { true })
end

function testTurnResumePassesPloughSideInsteadOfTurnDirection()
    for _, side in ipairs({ true, false }) do
        local raised, resumed
        local turn = setmetatable({
            getLowerImplementNode = function() return 123 end,
            ppc = { isReversing = function() return false end, restorePreviouslyRegisteredListeners = function() end },
            turnContext = { isLeftTurn = function() return not side end, shouldPlowBeOnTheLeft = function() return side end },
            driveStrategy = {
                raiseControllerEvent = function(_, ...) raised = { ... } end,
                resumeFieldworkAfterTurn = function(_, ix) resumed = ix end
            }
        }, AITurn)
        turn:resumeFieldworkAfterTurn(5)
        lu.assertEquals(raised, { 'turnEndProgress', 123, false, true, side })
        lu.assertEquals(resumed, 5)
    end
end

local function strategy(headlandIx, rotatable)
    local rotations = {}
    local result = setmetatable({
        course = course({}, {}),
        ppc = { getCurrentWaypointIx = function() return 1 end },
        plowOffsetUnknown = CpTemporaryObject(true),
        rotations = rotations,
        controllers = {
            {},
            {
                isRotatablePlow = function() return rotatable end,
                rotate = function(_, side) table.insert(rotations, side) end
            }
        },
        debug = function() end
    }, AIDriveStrategyPlowCourse)
    if headlandIx then
        result.course.waypoints[headlandIx].attributes.headlandPassNumber = 1
    end
    result.plowOffsetUnknown:set(false, 3000)
    result.course.isOnClockwiseHeadland = function() return false end
    return result
end

function testRotatePloughsUsesExplicitWaypointOrCurrentWaypoint()
    local worker = strategy(2, true)
    worker:rotatePlows()
    worker:rotatePlows(2)
    lu.assertEquals(worker.rotations, { false, true })
end

function testHeadlandResumeRechecksSideBeforeResuming()
    for _, sample in ipairs({ { 1, 1 }, { 2, 1 }, { 2, 2 } }) do
        local worker = strategy(sample[1], true)
        worker:resumeFieldworkAfterTurn(sample[2])
        lu.assertEquals(worker.rotations, { true })
        lu.assertEquals(worker.rotationsAtResume, 1)
        lu.assertEquals(worker.resumedAt, sample[2])
        lu.assertIsTrue(worker.plowOffsetUnknown:get())
    end
end

function testCentreResumeDoesNotForceHeadlandRotation()
    local worker = strategy(nil, true)
    worker:resumeFieldworkAfterTurn(1)
    lu.assertEquals(worker.rotations, {})
    lu.assertEquals(worker.resumedAt, 1)
end

function testFixedPloughSkipsHeadlandReinitialisation()
    local worker = strategy(2, false)
    worker:resumeFieldworkAfterTurn(1)
    lu.assertEquals(worker.rotations, {})
    lu.assertEquals(worker.resumedAt, 1)
end

os.exit(lu.LuaUnit.run())
