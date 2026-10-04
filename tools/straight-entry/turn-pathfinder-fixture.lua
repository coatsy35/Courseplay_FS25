-- CR11/319, 28 September 2026 09:55:58: the headland-to-row leg exhausted every turn search.
-- Keep the original target and heading. The polygon is the map's static field 11 outline,
-- not CP's unpersisted detected polygon. GIANTS collision/terrain queries are adapters below;
-- CourseTurn dispatch, HybridAStar, Dubins and PathfinderConstraints are production code.
require('BinaryHeap')
require('HybridAStar')
require('HybridAStarWithAStarInTheMiddle')
require('PathfinderConstraints')
g_Courseplay = {globalSettings = {getSettings = function()
    return {maxDeltaAngleAtGoalDeg = {getValue = function() return 6 end}}
end}}
CourseGenerator.isRunningInGame = function() return true end
CourseGenerator.addDebugPolyline = function() end
Polyline = function(points) return points end -- debug drawing only
function openIntervalTimer() return os.clock() end
function readIntervalTimerMs(timer) return (os.clock() - timer) * 1000 end
function closeIntervalTimer() end
function ensureHelperNode() end
PathfinderUtil.helperNode = {}
PathfinderUtil.setWorldPositionAndRotationOnTerrain = function(node, x, z, heading)
    node.x, node.z, node.t = x, z, heading
end
PathfinderUtil.isWorldPositionOwned = function() return true end
PathfinderUtil.hasFruit = function() return false, 0 end
CpFieldUtil = {isOnField = function() return true end}

local outline = {
        {x = -390.85300, z = -603.38700}, {x = -392.26245, z = -614.95330}, {x = -396.88901, z = -630.14840},
        {x = -402.27880, z = -643.08160}, {x = -405.96080, z = -656.71090}, {x = -405.96080, z = -991.21700},
        {x = -401.36260, z = -1001.71700}, {x = -396.32358, z = -1005.29300}, {x = -388.89164, z = -1007.07600},
        {x = -74.89300, z = -1007.07600}, {x = -61.88800, z = -1004.65800}, {x = -50.58200, z = -997.78300},
        {x = -40.17000, z = -994.11900}, {x = -13.71700, z = -989.10700}, {x = -3.64000, z = -986.44000},
        {x = 7.78800, z = -978.32900}, {x = 24.58100, z = -960.21900}, {x = 30.60400, z = -952.39800},
        {x = 34.28200, z = -944.76700}, {x = 36.44500, z = -932.88500}, {x = 34.72100, z = -923.88500},
        {x = 10.49200, z = -871.24400}, {x = -0.57600, z = -839.99700}, {x = -5.41800, z = -821.06700},
        {x = -5.50700, z = -811.99600}, {x = -2.48500, z = -806.21700}, {x = 4.83800, z = -798.57600},
        {x = 58.81700, z = -745.98500}, {x = 109.22100, z = -686.29410}, {x = 124.42800, z = -661.26500},
        {x = 129.52700, z = -636.64290}, {x = 127.46600, z = -567.58620}, {x = 127.46600, z = -419.51100},
        {x = 125.92600, z = -400.19600}, {x = 118.59900, z = -368.15100}, {x = 111.35500, z = -352.29500},
        {x = 106.42500, z = -343.05800}, {x = 96.76700, z = -322.80100}, {x = 93.91000, z = -319.88600},
        {x = 81.70900, z = -314.92600}, {x = 74.58200, z = -314.33000}, {x = 66.06000, z = -316.46100},
        {x = 60.00500, z = -319.95700}, {x = 40.89600, z = -335.31800}, {x = 19.77400, z = -352.89700},
        {x = 1.41100, z = -362.68200}, {x = -47.78200, z = -380.25200}, {x = -57.04300, z = -380.63300},
        {x = -66.06100, z = -376.38700}, {x = -70.60000, z = -367.46500}, {x = -74.36100, z = -355.45500},
        {x = -100.44800, z = -194.21600}, {x = -101.91300, z = -188.44100}, {x = -109.18600, z = -182.87400},
        {x = -114.60600, z = -181.69000}, {x = -121.57300, z = -182.08300}, {x = -150.90500, z = -192.35900},
        {x = -202.96300, z = -209.90600}, {x = -249.85100, z = -225.51200}, {x = -333.73220, z = -245.04400},
        {x = -380.90720, z = -252.89400}, {x = -441.15640, z = -262.12500}, {x = -449.79620, z = -264.47800},
        {x = -453.14330, z = -266.99400}, {x = -456.31380, z = -273.63800}, {x = -455.37290, z = -283.46300},
        {x = -416.88520, z = -495.98500}, {x = -410.91840, z = -521.12990}, {x = -408.90740, z = -526.43310},
        {x = -404.19750, z = -533.41640}, {x = -392.80936, z = -546.22120}, {x = -390.85300, z = -553.85610},
    }

-- Rotations and reflections use pathfinder XY coordinates. The same transform is applied to
-- the static boundary, departure pose and target, so this does not assume one compass bearing.
function recordedTurnSearch(degrees, mirror, kind, obstruction, completeTurn, allowReverse)
    local angle = math.rad(degrees)
    local function transform(x, y)
        x = mirror * x
        return x * math.cos(angle) - y * math.sin(angle), x * math.sin(angle) + y * math.cos(angle)
    end
    local function pose(x, y, heading)
        local px, py = transform(x, y)
        local dx, dy = transform(math.cos(math.rad(heading)), math.sin(math.rad(heading)))
        return State3D(px, py, math.atan2(dy, dx))
    end
    local polygon = {}
    for i, p in ipairs(outline) do
        local x, y = transform(p.x, -p.z)
        polygon[i] = {x = x, z = -y}
    end
    local vehicle = {size = {width = 3.95}, cpGetFieldPolygon = function() return polygon end}
    local boundary, reverse, reference, offset
    local goalNode = {}
    local turn = setmetatable({vehicle = vehicle, workWidth = 15.2, turningRadius = 4.7,
        steeringLength = 0, isDistantPathfinderTurn = true, fieldWorkCourse = {},
        states = {WAITING_FOR_PATHFINDER = 'searching'},
        debug = function() end,
        turnContext = {
            isHeadlandCorner = function() return kind == 'corner' end,
            getTurnEndNodeAndOffsets = function() return goalNode, -6 end,
            getBoundaryId = function() return 'F' end,
        },
        driveStrategy = {
            callUnloader = kind ~= 'tractor' and function() end or nil,
            getFrontAndBackMarkers = function() return 5.5, 5 end,
            getAllowReversePathfinding = function() return allowReverse == true end,
            getWorkWidth = function() return 15.2 end,
            isTurnOnFieldActive = function() return true end,
            setPathfindingDoneCallback = function() end,
        },
    }, CourseTurn)
    local findPath = PathfinderUtil.findPathForTurn
    PathfinderUtil.findPathForTurn = function(_, _, target, targetOffset, _, allowReverse, _, _, _, _, _, corridor)
        boundary, reverse, reference, offset = corridor, allowReverse, target, targetOffset
        return {}, {done = false}
    end
    g_currentMission.time = 0
    turn:generatePathfinderTurn(true)
    PathfinderUtil.findPathForTurn = findPath
    assert(reference == goalNode and offset == -6 and reverse == (allowReverse == true),
        'The original target and vehicle reversing permission must reach the solver unchanged')

    local collisionChecks = 0
    local constraints = setmetatable({fieldworkBoundary = boundary, vehicle = vehicle,
        turnRadius = 4.7, maxFruitPercent = 50, offFieldPenalty = 10, penaltyFactor = 1,
        ignoreTrailerAtStartRange = 0, logger = Logger('turn replay'),
        collisionDetector = {findCollidingShapes = function(_, _, _, box)
            collisionChecks = collisionChecks + 1
            assert(box.width == 15.2, 'The field margin must not narrow the obstacle collision box')
            return obstruction and 1 or 0
        end},
        vehicleData = {
            getVehicle = function() return vehicle end,
            getVehicleOverlapBoxParams = function() return {width = 15.2, length = 12} end,
            getTowedImplement = function() end,
        },
    }, PathfinderConstraints)
    constraints:resetCounts()
    local start, goal = pose(28.64, 354.52, 320), pose(44.45, 342.62, 80)
    local finder = HybridAStar(vehicle, 200, 10000, true)
    if completeTurn then
        -- Saved course's exact 17-point/53.4 m headland section used by this logged turn.
        local headland = {
            {43.27,342.55}, {39.02,346.03}, {36.89,347.78}, {34.76,349.52}, {32.63,351.26},
            {30.50,353.00}, {28.37,354.75}, {25.96,356.69}, {22.81,358.81}, {19.89,360.20},
            {15.32,362.74}, {12.92,364.08}, {10.51,365.41}, {8.11,366.75}, {5.70,368.09},
            {2.12,370.06}, {-1.25,371.53},
        }
        local middle = {}
        for i = #headland, 1, -1 do middle[#middle + 1] = pose(headland[i][1], headland[i][2], 0) end
        finder = HybridAStarWithPathInTheMiddle(vehicle, 200, middle, true, reverse and ReedsSheppSolver(ReedsShepp.ForwardEndingPathWords) or DubinsSolver())
        finder.hybridRangeOverride = 4 * 4.7
        start = pose(6.83, 396.49, 260)
    end
    math.randomseed(2969)
    local result = finder:start(start, goal, 4.7, reverse, constraints, 3)
    while not result.done do result = finder:resume() end
    if result.path then
        for _, point in ipairs(result.path) do
            assert(reverse or point.gear ~= Gear.Backward, 'A vehicle forbidding reverse must remain forward-only')
            assert(constraints:isValidNode(point), 'The returned route must retain boundary and obstacle checks')
        end
        turn.turnCourse = Course(vehicle, CpMathUtil.pointsToGameInPlace(result.path), true)
        assert(turn:turnCourseFitsField(FieldworkBoundary.forVehicle(vehicle, 15.2)),
            'The search and the real turn acceptance must agree about the field corridor')
        local last = turn.turnCourse:getWaypoint(turn.turnCourse:getNumberOfWaypoints())
        assert(math.sqrt((last.x - goal.x)^2 + (last.z + goal.y)^2) < 2.2,
            'The accepted turn must reach the unchanged row-entry target')
        if completeTurn then
            -- Exercise the actual callback too: append the lowering approach and activate PPC only
            -- after the joined/smoothed path and its tail pass the normal final acceptance checks.
            local function nodeAhead(distance)
                local x, y = transform(44.45 + distance * math.cos(math.rad(80)),
                    342.62 + distance * math.sin(math.rad(80)))
                return {x = x, z = -y, t = CpMathUtil.angleToGame(goal.t)}
            end
            turn.turnContext = setmetatable({vehicleAtTurnEndNode = nodeAhead(6), workStartNode = nodeAhead(11.5),
                frontMarkerDistance = 5.5, backMarkerDistance = 5, workWidth = 15.2,
                isHeadlandCorner = function() return false end, debug = function() end}, TurnContext)
            turn.ppc = {normalLookAheadDistance = 4.7,
                setCourse = function(self, value) self.course = value end,
                initialize = function(self) self.initialised = true end,
                setLookaheadDistance = function() end, setShortLookaheadDistance = function() end,
                isReversing = function() return false end}
            turn.settings = {turnSpeed = {getValue = function() return 12 end},
                fieldSpeed = {getValue = function() return 24 end}}
            turn.states.TURNING = 'turning'
            turn.driveStrategy.isConnectingPathBlockedByWorker = function() return false end
            AIUtil.getDirectionNodeToReverserNodeOffset = function() return 0 end
            -- pointsToGameInPlace above converted the result; restore only its coordinates for the callback.
            for _, p in ipairs(result.path) do p.y = -p.z end
            turn:onPathfindingDone(result.path)
            assert(turn.state == 'turning' and turn.ppc.initialised and turn.ppc.course == turn.turnCourse,
                'The complete recorded turn must start instead of scheduling another path retry')
            assert(reverse or turn.turnCourse:isForwardOnly(), 'A vehicle forbidding reverse must remain forward-only')
        end
    end
    local iterations = completeTurn and (finder.startHybridAStarPathfinder.iterations +
        finder.endHybridAStarPathfinder.iterations) or finder.iterations
    local reversePoints = 0
    if result.path then
        for _, point in ipairs(result.path) do
            if point.gear == Gear.Backward then reversePoints = reversePoints + 1 end
        end
    end
    return result.path and #result.path or 0, iterations, boundary.margin, collisionChecks, reversePoints
end
