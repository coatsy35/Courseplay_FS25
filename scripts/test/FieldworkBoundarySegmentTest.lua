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
