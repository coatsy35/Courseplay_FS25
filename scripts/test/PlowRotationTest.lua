local lu = require('luaunit')
package.path = package.path .. ';../?.lua;../util/?.lua;../courseGenerator/?.lua;../ai/controllers/?.lua;../ai/turns/?.lua;../ai/strategies/?.lua'
require('CpObject')
require('CpUtil')
require('CpMathUtil')

g_time = 0
CpDebug = { DBG_TURN = 1 }
CpUtil.debugVehicle = function() end
CpUtil.getCurrentVehicle = function() end
CourseGenerator = { cRowWaypointDistance = 5 }
g_currentMission = { terrainRootNode = 0 }
getTerrainHeightAtWorldPos = function() return 0 end
MathUtil = {
    vector2Length = function(x, z) return math.sqrt(x * x + z * z) end,
    getYRotationFromDirection = function(x, z) return math.atan2(x, z) end
}
MathUtil.vector2Normalize = function(x, z)
    local length = MathUtil.vector2Length(x, z)
    return x / length, z / length
end
MathUtil.getPointPointDistance = function(x1, z1, x2, z2)
    return MathUtil.vector2Length(x2 - x1, z2 - z1)
end
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
        self.course = self.fieldWorkCourse
    end
}
require('AIDriveStrategyPlowCourse')
CpMathUtil.isSameDirection = function(_, aligned) return aligned end

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
    result.fieldWorkCourse = result.course
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

function testHeadlandResumeUsesFieldworkCourseDuringTemporaryApproach()
    for _, side in ipairs({ true, false }) do
        for _, resumeIx in ipairs({ 1, 2 }) do
            local worker = strategy(2, true)
            worker.fieldWorkCourse.isOnClockwiseHeadland = function() return not side end
            worker.course = course({})
            worker:resumeFieldworkAfterTurn(resumeIx)
            lu.assertEquals(worker.rotations, { side })
            lu.assertEquals(worker.rotationsAtResume, 1)
            lu.assertIs(worker.course, worker.fieldWorkCourse)
        end
    end
end

function testTemporaryCourseCannotCauseHeadlandRotationOnCentreRow()
    local worker = strategy(nil, true)
    worker.course = course({ headlandPassNumber = 1 }, { headlandPassNumber = 1 })
    worker:resumeFieldworkAfterTurn(1)
    lu.assertEquals(worker.rotations, {})
end

-- Mock only the engine I/O; exercise the real course, waypoint and nullable-value serialisers.
local function xmlFile()
    local xml = { values = {} }
    function xml:setValue(key, ...)
        self.values[key] = { ... }
    end
    function xml:getValue(key, default)
        if self.values[key] then return table.unpack(self.values[key]) end
        return default
    end
    function xml:iterate(key, callback)
        local ix = 0
        while self.values[string.format('%s(%d)#position', key, ix)] do
            callback(ix, string.format('%s(%d)', key, ix))
            ix = ix + 1
        end
    end
    return xml
end

for _, valueType in ipairs({ 'Bool', 'Int32', 'Float32', 'String' }) do
    _G['streamWrite' .. valueType] = function(stream, value)
        table.insert(stream.values, { valueType, value })
    end
    _G['streamRead' .. valueType] = function(stream)
        local value = stream.values[stream.ix]
        lu.assertNotNil(value, 'Read beyond the end of the stream')
        lu.assertEquals(value[1], valueType)
        stream.ix = stream.ix + 1
        return value[2]
    end
end

local function firstRowCourse(leftBoundary, rightBoundary)
    local waypoints = {}
    for i = 1, 5 do
        local attributes = CourseGenerator.WaypointAttributes()
        attributes.rowStart = i == 1
        attributes.rowEnd = i == 5
        attributes.rowNumber = 1
        attributes.leftSideBlockBoundary = leftBoundary
        attributes.rightSideBlockBoundary = rightBoundary
        attributes.leftSideWorked = false
        attributes.rightSideWorked = true
        waypoints[i] = { x = 0, z = (i - 1) * 5, attributes = attributes }
    end
    waypoints[6] = { x = 5, z = 20 }
    return Course(nil, waypoints)
end

local function assertFirstRowRestored(original, restored)
    lu.assertEquals(restored:getNumberOfWaypoints(), original:getNumberOfWaypoints())
    for i, wp in ipairs(original.waypoints) do
        lu.assertEquals(restored.waypoints[i].attributes, wp.attributes)
        lu.assertEquals(restored:shouldPlowBeOnTheLeft(i), original:shouldPlowBeOnTheLeft(i))
    end
end

function testBoundaryFlagsRegisteredInXmlSchema()
    XMLValueType = { BOOL = 'bool', INT = 'int', STRING = 'string' }
    local registered = {}
    CourseGenerator.WaypointAttributes.registerXmlSchema({
        register = function(_, valueType, key) registered[key] = valueType end
    }, 'wp(?)')
    lu.assertEquals(registered['wp(?)#leftSideBlockBoundary'], XMLValueType.BOOL)
    lu.assertEquals(registered['wp(?)#rightSideBlockBoundary'], XMLValueType.BOOL)
end

function testFirstRowOrientationSurvivesCompactedAndFullXmlRoundTrips()
    for _, compacted in ipairs({ true, false }) do
        for _, boundaries in ipairs({ { true, false }, { false, true }, {} }) do
            local original = firstRowCourse(boundaries[1], boundaries[2])
            original.compacted = compacted
            local xml = xmlFile()
            original:saveToXml(xml, 'course')
            local savedWaypoints = 0
            xml:iterate('course.wp', function() savedWaypoints = savedWaypoints + 1 end)
            lu.assertEquals(savedWaypoints, compacted and 3 or 6)
            local restored = Course.createFromXml(nil, xml, 'course')
            -- Reconstructed intermediate points omit explicit false rowStart/rowEnd flags.
            for i = 2, 4 do
                lu.assertEquals(restored.waypoints[i].attributes.rowNumber, 1)
                lu.assertEquals(restored.waypoints[i].attributes.leftSideWorked, false)
                lu.assertEquals(restored.waypoints[i].attributes.rightSideWorked, true)
            end
            for i = 1, 5 do
                lu.assertEquals(restored.waypoints[i].attributes.leftSideBlockBoundary, boundaries[1])
                lu.assertEquals(restored.waypoints[i].attributes.rightSideBlockBoundary, boundaries[2])
                lu.assertEquals(restored:shouldPlowBeOnTheLeft(i), original:shouldPlowBeOnTheLeft(i))
            end
            lu.assertEquals(restored:getNumberOfWaypoints(), 6)
            lu.assertEquals(restored.waypoints[5].attributes.rowNumber, 1)
            lu.assertNil(restored.waypoints[6].attributes.rowNumber)
            lu.assertNil(restored.waypoints[6].attributes.leftSideBlockBoundary)
            lu.assertNil(restored.waypoints[6].attributes.rightSideBlockBoundary)
        end
    end
end

function testFirstRowOrientationSurvivesNetworkRoundTrip()
    for _, boundaries in ipairs({ { true, false }, { false, true }, {} }) do
        local original = firstRowCourse(boundaries[1], boundaries[2])
        local stream = { values = {}, ix = 1 }
        original:writeStream(nil, stream)
        local restored = Course.createFromStream(nil, stream)
        assertFirstRowRestored(original, restored)
        lu.assertEquals(stream.ix, #stream.values + 1)
    end
end

function testOlderSavedCoursesWithoutBoundaryFlagsStillLoad()
    local original = firstRowCourse(true, false)
    local xml = xmlFile()
    original:saveToXml(xml, 'course')
    xml.values['course.wp(0)#leftSideBlockBoundary'] = nil
    xml.values['course.wp(0)#rightSideBlockBoundary'] = nil
    local restored = Course.createFromXml(nil, xml, 'course')
    local legacy = firstRowCourse(nil, nil)
    for i = 1, 5 do
        lu.assertNil(restored.waypoints[i].attributes.leftSideBlockBoundary)
        lu.assertNil(restored.waypoints[i].attributes.rightSideBlockBoundary)
        lu.assertEquals(restored:shouldPlowBeOnTheLeft(i), legacy:shouldPlowBeOnTheLeft(i))
    end
end

function testLoadedRowsDoNotInheritPreviousRowsBoundaryFlags()
    local original = firstRowCourse(true, false)
    for i, wp in ipairs(firstRowCourse(nil, true).waypoints) do
        wp.x = wp.x + 10
        if i <= 5 then wp.attributes.rowNumber = 2 end
        table.insert(original.waypoints, wp)
    end
    for _, compacted in ipairs({ true, false }) do
        original.compacted = compacted
        local xml = xmlFile()
        original:saveToXml(xml, 'course')
        local restored = Course.createFromXml(nil, xml, 'course')
        lu.assertEquals(restored:getNumberOfWaypoints(), 12)
        for i = 7, 11 do
            lu.assertEquals(restored.waypoints[i].attributes.rowNumber, 2)
            lu.assertNil(restored.waypoints[i].attributes.leftSideBlockBoundary)
            lu.assertIsTrue(restored.waypoints[i].attributes.rightSideBlockBoundary)
        end
    end
end

os.exit(lu.LuaUnit.run())
