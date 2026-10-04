-- Exercise CourseTurn's real driving/acceptance path; the fieldwork strategy does not own its PPC callbacks.
function CpObject(base)
    local class = {}
    if base then setmetatable(class, {__index = base}) end
    return class
end
CpDebug = {DBG_TURN = 1}
CpMathUtil = {pointsToGameInPlace = function(points) return points end}
AIUtil = {getDirectionNodeToReverserNodeOffset = function() return 0 end}
g_currentMission = {time = 1000}
dofile('scripts/ai/turns/AITurn.lua')

local function setting(value) return {getValue = function() return value end} end
local function fixture()
    local course = {ix = 30, fromStart = 100, toEnd = 200, radius = nil, reversing = {}, lower = {}}
    function course:getCurrentWaypointIx() return self.ix end
    function course:getDistanceFromFirstWaypoint() return self.fromStart end
    function course:getDistanceToLastWaypoint() return self.toEnd end
    function course:getNextWaypointIxWithinDistance(ix) return ix + 5 end
    function course:getMinRadiusWithinDistance() return self.radius end
    function course:isReverseAt(ix) return self.reversing[ix] or false end
    function course:setUseTightTurnOffsetForLastWaypoints() end
    function course:adjustForReversing() end
    function course:setOffset() end
    local ppc = {normalLookAheadDistance = 4.7, lookahead = 2.35, reversed = false}
    function ppc:isReversing() return self.reversed end
    function ppc:setLookaheadDistance(distance) self.lookahead = distance end
    function ppc:setShortLookaheadDistance() self.lookahead = 2.35 end
    function ppc:setCourse(value) self.course = value end
    function ppc:initialize() self.initialised = (self.initialised or 0) + 1 end
    local turn = setmetatable({
        vehicle = {}, turningRadius = 4.7, ppc = ppc,
        states = {TURNING = 'turn', ENDING_TURN = 'ending', FINISHING_ROW = 'finishing',
            WAITING_FOR_PATHFINDER = 'pathfinder', WAITING_FOR_TURN_PATH = 'retry'},
        state = 'turn', settings = {turnSpeed = setting(12), fieldSpeed = setting(24)},
        turnCourse = course, pathfinderTurnCourse = course,
        turnContext = {appendPathfinderEndingTurnCourse = function() return 10 end,
            isHeadlandCorner = function() return false end},
        debug = function() end, changeDirectionWhenAligned = function() end,
        changeToFwdWhenWaypointReached = function() end,
        fitCalculatedTurnToBoundary = function() return true end,
    }, {__index = CourseTurn})
    return turn, course, ppc
end
TurnManeuver = {
    LOWER_IMPLEMENT_AT_TURN_END = 'lower',
    hasTurnControl = function(course, ix) return course.lower[ix] end,
    setLowerImplements = function() end,
}

local turn, course, ppc = fixture()
local _, _, _, speed = turn:getDriveData(16)
assert(speed == 24 and ppc.lookahead == 6,
        'A long accepted pathfinder turn must pair travelling speed with travelling lookahead')
course.radius = 5
_, _, _, speed = turn:getDriveData(16)
assert(speed == 12 and ppc.lookahead == 2.35,
        'A tight middle bend must use the configured turn speed, not field speed')
course.radius = 30
_, _, _, speed = turn:getDriveData(16)
assert(speed == 24 and ppc.lookahead == 6, 'An open broad bend must restore travelling steering')

course.reversing[course.ix + 4] = true
_, _, _, speed = turn:getDriveData(16)
assert(speed == 12 and ppc.lookahead == 2.35, 'Restore precision before the upcoming reverse cusp')
course.reversing = {}
ppc.reversed = true
_, _, _, speed = turn:getDriveData(16)
assert(speed == 12 and ppc.lookahead == 2.35, 'A reverse section must never use travelling lookahead')
ppc.reversed = false
course.lower[course.ix + 4] = true
_, _, _, speed = turn:getDriveData(16)
assert(speed == 12 and ppc.lookahead == 2.35, 'Restore precision before the lowering/row-entry section')
course.lower = {[course.ix] = true}
ppc.lookahead = 6
_, _, _, speed = turn:getDriveData(16)
assert(turn.state == turn.states.ENDING_TURN and speed == 12 and ppc.lookahead == 2.35,
        'The actual ending-turn transition must retain precision in the same update')

turn, course, ppc = fixture()
course.toEnd = 19
assert(turn:getForwardSpeed() == 12 and ppc.lookahead == 2.35, 'Final approach retains turn-speed steering')
course.toEnd, course.fromStart = 200, 9
assert(turn:getForwardSpeed() == 12 and ppc.lookahead == 2.35, 'Initial manoeuvre retains precise steering')
course.fromStart = 100
turn.pathfinderTurnCourse = nil
assert(turn:getForwardSpeed() == 24 and ppc.lookahead == 2.35,
        'Calculated turns retain their original speed and lookahead')
turn.pathfinderTurnCourse = course
course.chainReturn = {}
assert(turn:getForwardSpeed() == 12 and ppc.lookahead == 2.35,
        'Chain-planned loops retain their own tested turn-speed behaviour')

turn, course, ppc = fixture()
Course = function() return course end
turn.state = turn.states.FINISHING_ROW
turn.pathfinderTurnCourse = nil
turn:onPathfindingDone({{}, {}, {}})
assert(turn.state == turn.states.TURNING and ppc.initialised == 1 and
        turn.pathfinderTurnCourse == course and ppc.lookahead == 6,
        'Successful callback must initialise travelling steering even before waypoint listeners fire')
turn.generateCalculatedTurn = function(self)
    self.pathfinderTurnCourse = nil
    self.turnCourse = course
    self.ppc:setShortLookaheadDistance()
end
turn:onPathfindingDone(nil)
assert(turn.pathfinderTurnCourse == nil and ppc.lookahead == 2.35,
        'A failed ordinary turn must not mark its calculated fallback as path-found travel')

-- Recorded failure: a distant row (188 m forward / 106 m sideways) was sent to the local analytical
-- fallback, which translated its whole course into a 103.7 m reverse. Exercise the real failure/retry
-- callbacks, including immediate solver failure, rather than testing a distance formula in isolation.
turn, course, ppc = fixture()
turn.isDistantPathfinderTurn = true
turn.state = turn.states.FINISHING_ROW
turn.pathfinderTurnCourse, turn.turnCourse = nil, nil
turn.fieldWorkCourse, turn.workWidth = {}, 15.2
turn.turnContext.getTurnEndNodeAndOffsets = function() return 'original-row-start', -13 end
turn.turnContext.getBoundaryId = function() return 'field' end
FieldworkBoundary = {forVehicle = function() return {} end}
local calls, clearRequests = {}, 0
local intendedHeadland = {}
local departure, departureKind, departureVehicle = {}, nil, nil
Course = setmetatable({createStraightForwardCourse = function(_, length, offset)
    assert(length == 0.5 and offset == 0, 'Only the immediate physical departure may be scouted')
    return departure
end}, {__call = function() return course end})
turn.vehicle.getAIDirectionNode = function() return 'combine-direction' end
turn.driveStrategy = {
    getAllowReversePathfinding = function() return true end,
    getFrontAndBackMarkers = function() return 4, 4 end,
    getWorkWidth = function() return 15.2 end,
    isTurnOnFieldActive = function() return true end,
    setPathfindingDoneCallback = function() end,
    isConnectingPathBlockedByWorker = function(_, route, margin, workerOnly, liveScan)
        if route == departure then
            assert(margin == 0 and workerOnly == false and liveScan == true)
            return departureKind ~= nil, departureKind, departureVehicle
        end
        assert(route == intendedHeadland)
        clearRequests = clearRequests + 1
        return true, 'unloader'
    end,
}
turn.generateCalculatedTurn = function() error('Never use a local analytical turn for this distant transfer') end
PathfinderUtil = {findPathForTurn = function(_, _, goal, offset, _, reverse, headland, _, _, _, _, _, join)
    assert(goal == 'original-row-start' and offset == -13, 'Retries must not skip or move the original work start')
    assert(reverse == turn.driveStrategy:getAllowReversePathfinding(),
        'Distant transfers must preserve the vehicle reversing permission on every retry')
    table.insert(calls, {join = join, headland = headland})
    return {turnHeadlandCourse = intendedHeadland}, {done = true}
end}
turn.finishRow = function(self) self:generatePathfinderTurn(true) end
_, _, _, speed = turn:getDriveData(16)
assert(speed == 0 and #calls == 1 and clearRequests == 1 and not ppc.initialised,
        'Immediate failure must request trailer clearance and brake in the same update, without recursion')
assert(turn.state == turn.states.WAITING_FOR_TURN_PATH and turn.distantTurnPathRetryAt == 1500)
turn.startRecoveryTurn = function() error('Waiting for a checked path must not launch a reversing recovery') end
turn:onBlocked()
turn:getDriveData(16)
assert(#calls == 1, 'The waiting state must not spin the pathfinder before the retry deadline')
for attempt = 1, 4 do
    g_currentMission.time = turn.distantTurnPathRetryAt
    _, _, _, speed = turn:getDriveData(16)
    assert(speed == 0 and #calls == attempt + 1 and not ppc.initialised,
            'Each update starts at most one alternative; all failures remain safely stopped')
end
for i = 1, 4 do
    assert(calls[i].headland == turn.fieldWorkCourse and calls[i].join == 4 * turn.turningRadius + 20 * (i - 1))
end
assert(calls[5].headland == nil, 'After four blocked hand-offs, search a fresh route to the same row')
assert(turn.distantTurnPathRetryAt == g_currentMission.time + 5000, 'An exhausted batch must back off')

-- The recorded no-headland failure never produced turnHeadlandCourse. A parked rig occupying the
-- departure must receive clearance before that search starts; active calls and adjacent clear rigs proceed.
departureKind = 'unloader'
local activeCall, available = nil, true
departureVehicle = {getCpDriveStrategy = function() return {
    getCombineToUnload = function() return activeCall end,
    isAvailableForStaging = function() return available end,
} end}
local searches, attempt = #calls, turn.distantTurnPathAttempt
turn:generatePathfinderTurn(true)
assert(#calls == searches and turn.state == turn.states.WAITING_FOR_TURN_PATH and
        turn.distantTurnPathRetryAt == g_currentMission.time + 500 and turn.distantTurnPathAttempt == attempt,
        'An occupied departure must request clearance immediately without exhausting headland alternatives')
departureKind = nil
turn:updateDistantTurnPathRetry()
assert(#calls == searches, 'Departure clearance retries must respect their deadline')
g_currentMission.time = turn.distantTurnPathRetryAt
turn:updateDistantTurnPathRetry()
assert(#calls == searches + 1, 'Once the rig has reversed clear, the normal search must resume')
activeCall, departureKind = {}, 'unloader'
turn:generatePathfinderTurn(true)
assert(#calls == searches + 2, 'An active unloading call must not be interrupted by departure scouting')
activeCall, available = nil, false
turn:generatePathfinderTurn(true)
assert(#calls == searches + 3, 'An unavailable rig must not cause an unsupported clearance hold')

-- A later valid candidate must retain the approach/lowering sequence, but neither a forbidden reverse nor
-- a fixed headland middle occupied by another vehicle may activate PPC.
course.isForwardOnly = function() return true end
turn.turnCourseFitsField = function() return true end
turn.driveStrategy.isConnectingPathBlockedByWorker = function() return true, 'fieldWorker' end
turn:onPathfindingDone({{}, {}, {}})
assert(not ppc.initialised and turn.state == turn.states.WAITING_FOR_TURN_PATH,
        'A fixed headland middle crossing another combine must not be driven unchecked')
turn.driveStrategy.isConnectingPathBlockedByWorker = function() return true, 'unloader' end
turn:onPathfindingDone({{}, {}, {}})
assert(not ppc.initialised, 'The combine must wait while an unloader clears its accepted route')
turn.driveStrategy.isConnectingPathBlockedByWorker = function() return false end
course.isForwardOnly = function() return false end
turn.driveStrategy.getAllowReversePathfinding = function() return false end
turn:generatePathfinderTurn(true)
turn:onPathfindingDone({{}, {}, {}})
assert(not ppc.initialised, 'Reject reverse segments when the vehicle forbids reversing')
course.isForwardOnly = function() return true end
turn.turnCourseFitsField = function() return false end
turn:onPathfindingDone({{}, {}, {}})
assert(not ppc.initialised, 'A joined path and its approach must fit the field before activation')
turn.turnCourseFitsField = function() return true end
turn:onPathfindingDone({{}, {}, {}})
assert(turn.state == turn.states.TURNING and ppc.initialised == 1 and ppc.course == course and ppc.lookahead == 6,
        'Once clear, the distant turn resumes the checked forward course automatically')
turn.driveStrategy.getAllowReversePathfinding = function() return true end
course.isForwardOnly = function() return false end
turn:onPathfindingDone({{}, {}, {}})
assert(ppc.initialised == 2 and turn.state == turn.states.TURNING,
        'A collision-checked reverse manoeuvre must be accepted when the vehicle permits it')

-- Check that the shared pathfinder actually consumes a requested hand-off, retaining the default otherwise.
PathfinderInterface = {}
dofile('scripts/pathfinder/HybridAStarWithAStarInTheMiddle.lua')
State3D = {copy = function(node) return node end}
coursePlayCoroutine = {create = function(fn) return fn end}
local planner = setmetatable({middlePathfinder = {run = function() end}, debug = function() end,
    resume = function(self) return self.hybridRange end}, {__index = HybridAStarWithAStarInTheMiddle})
local start = {updateH = function() end}
assert(planner:start(start, {}, 12, false, {}, 0) == 48, 'Ordinary pathfinder hand-offs retain their default')
planner.hybridRangeOverride = 68
assert(planner:start(start, {}, 12, false, {}, 0) == 68, 'A distant retry must change the actual searched hand-off')
print('PathfinderTurnTravelTest: OK')
