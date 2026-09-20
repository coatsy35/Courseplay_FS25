-- Run the actual JPS successor loop, not just its local validity helper. Engine logging and time are stubbed.
dofile('scripts/CpObject.lua')
dofile('scripts/geometry/Vector.lua')
dofile('scripts/pathfinder/BinaryHeap.lua')
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
CpDebug = {DBG_PATHFINDER = 1}
CpUtil = {debugVehicle = function() end, debugFormat = function() end}
CourseGenerator = {isRunningInGame = function() return true end}
Logger = setmetatable({level = {error = 1, debug = 2}}, {__call = function()
    return {trace = function() end, debug = function() end, setLevel = function() end}
end})
g_Courseplay = {globalSettings = {getSettings = function() return {
    maxDeltaAngleAtGoalDeg = {getValue = function() return 45 end},
    deltaAngleRelaxFactorDeg = {getValue = function() return 0 end},
} end}}
function openIntervalTimer() return 1 end
function closeIntervalTimer() end
function readIntervalTimerMs() return 0 end
function DubinsSolver() return {} end
dofile('scripts/pathfinder/HybridAStar.lua')
dofile('scripts/pathfinder/AnalyticSolution.lua')
dofile('scripts/pathfinder/State3D.lua')
-- GIANTS accepts floating-point values in %d logging; stock Lua 5.4 does not. Logging is irrelevant to the search.
State3D.__tostring = function() return 'pose' end
dofile('scripts/pathfinder/AStar.lua')
dofile('scripts/pathfinder/JumpPointSearch.lua')

local coarseChecks, detailedChecks = 0, 0
local constraints = {
    -- A bent field corridor with a concave boundary. A grid point has no usable trailer heading.
    isValidNode = function(_, node, _, _, coarse)
        if coarse then coarseChecks = coarseChecks + 1 else detailedChecks = detailedChecks + 1 end
        local inside = node.x >= 0 and node.x <= 90 and node.y >= 0 and node.y <= 90 and
                (node.y <= 18 or node.x >= 72)
        -- Model a detailed footprint rejection at artificial grid poses, the cause of the failed live searches.
        return inside and (coarse or node.pred == nil)
    end,
    isValidAnalyticSolutionNode = function() return true end,
    getNodePenalty = function() return 0 end,
    showStatistics = function() end,
}
local grid = JumpPointSearch(nil, 100, 4000)
local result = grid:start(State3D(9, 9, 0), State3D(81, 81, math.pi / 2), 9, false, constraints, 8)
while not result.done do result = grid:resume() end
assert(result.path and #result.path > 2, 'The actual coarse successor loop must find the bent corridor')
assert(coarseChecks > 0 and detailedChecks == 0, 'No grid successor or goal may use an invented rig pose')
for _, node in ipairs(result.path) do
    assert(constraints:isValidNode(node, true, true, true), 'Smoothing must not cut across the concave boundary')
end

local detailed = HybridAStar(nil)
detailed.constraints = constraints
assert(not detailed:isValidNode({x = 9, y = 9, pred = {}}),
        'Detailed driving searches must retain rig containment checks')
assert(not grid:isValidNode(State3D(-3, 9, 0)), 'Coarse routing must still reject points outside the field')
print('UnloaderGridRoutingTest: OK')
