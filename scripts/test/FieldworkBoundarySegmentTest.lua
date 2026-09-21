MathUtil = {
    vector2Length = function(x, z) return math.sqrt(x * x + z * z) end,
}

CpMathUtil = {}
function CpMathUtil.isPointInPolygon(polygon, x, z)
    local inside = false
    local j = #polygon
    for i = 1, #polygon do
        local xi, zi = polygon[i].x, polygon[i].z
        local xj, zj = polygon[j].x, polygon[j].z
        if (zi > z) ~= (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi then
            inside = not inside
        end
        j = i
    end
    return inside
end

dofile('scripts/ai/util/FieldworkBoundary.lua')

local boundary = {
    polygon = {{x = 0, z = 0}, {x = 100, z = 0}, {x = 100, z = 100}, {x = 0, z = 100}},
    margin = 0,
    islands = {{{x = 45, z = 45}, {x = 55, z = 45}, {x = 55, z = 55}, {x = 45, z = 55}}},
}

assert(FieldworkBoundary.containsSegment(boundary, 10, 10, 40, 40, true),
        'A contained live steering segment must be accepted')
assert(not FieldworkBoundary.containsSegment(boundary, 10, 10, 110, 10, true),
        'A live steering segment must not leave the field')
assert(FieldworkBoundary.containsSegment(boundary, -5, 10, 5, 10, true),
        'An AutoDrive handover may move only inwards from outside the field')
assert(not FieldworkBoundary.containsSegment(boundary, -5, 10, -1, 10, true),
        'An AutoDrive handover must not continue outside the field')
assert(not FieldworkBoundary.containsSegment(boundary, 40, 50, 60, 50, true),
        'A live steering segment must not cross a field island')

local function course(points)
    return {
        getNumberOfWaypoints = function() return #points end,
        getWaypointPosition = function(_, ix) return points[ix].x, 0, points[ix].z end,
    }
end

local enteringCourse = course({{x = -5, z = 20}, {x = 5, z = 20}, {x = 20, z = 20}})
assert(FieldworkBoundary.containsCourse(boundary, enteringCourse, 1, 3, true),
        'A newly appended entry may begin outside and continue into the field')
local leavingCourse = course({{x = 20, z = 20}, {x = 95, z = 20}, {x = 105, z = 20}})
assert(not FieldworkBoundary.containsCourse(boundary, leavingCourse, 1, 3, true),
        'A newly appended entry must not leave the field after entering')
local neverEnteringCourse = course({{x = -10, z = 20}, {x = -5, z = 20}})
assert(not FieldworkBoundary.containsCourse(boundary, neverEnteringCourse, 1, 2, true),
        'A newly appended entry must finish inside the field')

print('FieldworkBoundarySegmentTest: OK')

-- A centreline inside the field does not make a tractor/trailer footprint safe.
local box = {width = 2, length = 6, xOffset = 0, zOffset = 0}
assert(FieldworkBoundary.boxOutsideDistance(boundary, 0.2, 20, 0, box) > 0,
        'The vehicle side must remain inside the polygon, not just its reference node')
assert(FieldworkBoundary.boxOutsideDistance(boundary, 10, 20, 0, box) == 0)
assert(FieldworkBoundary.boxOutsideDistance(boundary, 50, 50, 0, {width = 10, length = 10}) > 0,
        'An island entirely enclosed by a footprint must be detected even when all corners are inside the field')
assert(not FieldworkBoundary.containsSegment(boundary, -5, 50, 70, 50, true),
        'An entry segment must not enter the field, cross an island, then enter again')
local articulated = {
    {x = 10, z = 30, heading = 0, box = {width = 2, length = 3}},
    {x = 3, z = 20, heading = math.pi / 4, box = {width = 2, length = 7}},
}
assert(FieldworkBoundary.rigOutsideDistance(boundary, articulated) > 0,
        'The trailer corner must be checked independently of the safely positioned tractor')
articulated[2].x = 15
assert(FieldworkBoundary.rigOutsideDistance(boundary, articulated) == 0)
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
assert(not FieldworkBoundary.sweepRigSegment(boundary,
        {{x = 40, z = 50, heading = math.pi / 2, box = {width = 1, length = 2}}}, 60, 50, false, 5),
        'A route must not sweep a body through an island between safe endpoints')
print('FieldworkBoundary footprint and entry regressions: OK')

function getWorldTranslation(n) return n.x, 0, n.z end
function getWorldRotation(n) return 0, n.heading or 0, 0 end
function localToLocal(from, to, x, _, z)
    local fh, th = from.heading or 0, to.heading or 0
    local wx = from.x + math.cos(fh) * x + math.sin(fh) * z - to.x
    local wz = from.z - math.sin(fh) * x + math.cos(fh) * z - to.z
    return math.cos(th) * wx - math.sin(th) * wz, 0, math.sin(th) * wx + math.cos(th) * wz
end
AIUtil = {getWidth = function(v) return v.size.width end, getLength = function(v) return v.size.length end}
local tractor = {rootNode = {x = 20, z = 30}, size = {width = 3, length = 6}}
tractor.getAIDirectionNode = function() return tractor.rootNode end
local trailer = {rootNode = {x = 20, z = 20}, size = {width = 3, length = 10}, spec_wheels = {}}
trailer.getAttacherVehicle = function() return tractor end
trailer.getActiveInputAttacherJoint = function() return {node = {x = 20, z = 26}} end
tractor.getChildVehicles = function() return {tractor, trailer} end
local rig = FieldworkBoundary.captureRig(tractor)
assert(#rig == 2 and rig[2].parent == rig[1] and rig[2].articulated,
        'Capturing the complete rig must preserve the hitch hierarchy without counting the tractor twice')
assert(FieldworkBoundary.containsRigSteering(boundary, tractor, 20, 50, false, 9))
tractor.rootNode.z, trailer.rootNode.z = 4, -6
trailer.getActiveInputAttacherJoint = function() return {node = {x = 20, z = 0}} end
assert(FieldworkBoundary.containsRigSteering(boundary, tractor, 20, 30, false, 9),
        'An AD entry with the trailer still outside must be allowed to move progressively inwards')
assert(not FieldworkBoundary.containsRigSteering(boundary, tractor, 20, -30, true, 9),
        'The same rig must not reverse further out of the field')
print('Articulated live steering regressions: OK')

-- JPS grid nodes are route hints, not articulated vehicle poses. The detailed search must still reject the
-- same aligned destination when its trailer projects outside the field.
function CpObject() return {} end
CpMathUtil.angleToGame = function(t) return t end
PathfinderUtil = {helperNode = {}, setWorldPositionAndRotationOnTerrain = function() end}
dofile('scripts/pathfinder/PathfinderConstraints.lua')
dofile('scripts/pathfinder/JumpPointSearch.lua')
local constraints = setmetatable({fieldworkBoundary = boundary, protectRigBoundary = true, vehicle = tractor,
    ignoreTrailerAtStartRange = 0, collisionNodeCount = 0,
    collisionDetector = {findCollidingShapes = function() return 0 end},
    vehicleData = {
        getVehicle = function() return tractor end,
        getVehicleOverlapBoxParams = function() return {width = 1, length = 1} end,
        getTowedImplement = function() return trailer end,
        getHitchOffset = function() return -1 end,
        getTowedImplementOverlapBoxParams = function() return {width = 1, length = 4, zOffset = -5} end,
    }}, {__index = PathfinderConstraints})
local grid = setmetatable({constraints = constraints}, {__index = JumpPointSearch})
local gridNode = {x = 10, y = -3, t = 0, tTrailer = 0, d = 0}
assert(grid:isValidNode(gridNode), 'Coarse routing must not reject a corridor based on an artificial trailer heading')
assert(not constraints:isValidNode(gridNode, true, true),
        'The detailed destination check must reject a trailer extending beyond the boundary')
assert(not grid:isValidNode({x = -10, y = -3, t = 0, d = 0}), 'Coarse search must still respect the field')
assert(not grid:isValidNode({x = 50, y = -50, t = 0, d = 0}), 'Coarse search must still avoid islands')
constraints.collisionDetector.findCollidingShapes = function() return 1 end
assert(not grid:isValidNode(gridNode), 'Coarse search must still avoid real vehicle obstacles')
constraints.collisionDetector.findCollidingShapes = function() return 0 end
assert(constraints:isValidNode({x = 20, y = -25, t = 0, tTrailer = 0, d = 0}, true, true),
        'A fully contained detailed destination must remain usable')
print('Coarse routing and detailed rig containment regressions: OK')

-- Unloader contexts opt into preference, while other fieldwork contexts retain their strict policy.
constraints.protectRigBoundary, constraints.preferFieldworkBoundary = false, true
constraints.offFieldPenalty, constraints.maxFruitPercent, constraints.penaltyFactor = 7.5, 10, 1
constraints:resetCounts()
CpFieldUtil = {isOnField = function() return true end}
PathfinderUtil.isWorldPositionOwned = function() return true end
PathfinderUtil.hasFruit = function() return false, 0 end
local insideNode, outsideNode = {x = 20, y = -25, t = 0, d = 0}, {x = -10, y = -25, t = 0, d = 0}
assert(constraints:isValidNode(outsideNode, true, true),
        'An unloader route near the boundary must remain possible when normal collision checks pass')
assert(constraints:getNodePenalty(outsideNode) > constraints:getNodePenalty(insideNode),
        'Route selection must prefer the assigned field even if neighbouring ground is also a field')
assert(not constraints:isValidAnalyticSolutionNode(outsideNode),
        'An analytic shortcut must not bypass the in-field planning preference')
constraints.collisionDetector.findCollidingShapes = function() return 1 end
assert(not constraints:isValidNode(outsideNode, true, true),
        'A soft boundary must never disable collision detection')
print('Boundary routing preference and preserved collision checks: OK')
