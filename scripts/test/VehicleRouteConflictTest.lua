-- Exercise production geometry, including attachment offsets, rather than mocking an occupancy answer.
MathUtil = {vector2Length = function(x, z) return math.sqrt(x * x + z * z) end}
function getWorldTranslation(n) return n.x, 0, n.z end
function getWorldRotation(n) return 0, n.heading or 0, 0 end
function localToLocal(from, to, x, _, z)
    local fh, th = from.heading or 0, to.heading or 0
    local wx = from.x + math.cos(fh) * x + math.sin(fh) * z - to.x
    local wz = from.z - math.sin(fh) * x + math.cos(fh) * z - to.z
    return math.cos(th) * wx - math.sin(th) * wz, 0, math.sin(th) * wx + math.cos(th) * wz
end
AIUtil = {getWidth = function(v) return v.size.width end, getLength = function(v) return v.size.length end}
dofile('scripts/ai/util/FieldworkBoundary.lua')
dofile('scripts/ai/util/VehicleRouteConflict.lua')
local function vehicle(x, z, width, length, heading, offset)
    local v = {rootNode = {x = x, z = z, heading = heading or 0},
        size = {width = width, length = length, lengthOffset = offset or 0}, children = {}}
    v.getAIDirectionNode = function() return v.rootNode end
    v.getChildVehicles = function() return v.children end
    return v
end
local combine = vehicle(0, 0, 4, 8)
local header = vehicle(0, 6, 15, 2)
header.getAttacherVehicle = function() return combine end
combine.children = {header}
local function course(points, reverse)
    return {getNumberOfWaypoints = function() return #points end,
        getWaypointPosition = function(_, ix) return points[ix][1], 0, points[ix][2] end,
        isReverseAt = function() return reverse or false end}
end
local straight = course({{0, 0}, {0, 90}})
local function conflict(route, other)
    return VehicleRouteConflict.findConflict(
        VehicleRouteConflict.createSweep(FieldworkBoundary.captureRig(combine), route, 12),
        FieldworkBoundary.captureRig(other))
end
assert(not conflict(straight, vehicle(12, 20, 4, 9)),
        'A parallel trailer outside the header envelope must not inherit the old extra five-metre margin')
assert(not conflict(straight, vehicle(0, -11, 4, 8)),
        'A trailer behind the departure must not block forward travel via a header-sized end cap')
assert(not conflict(straight, vehicle(8, -3, 3, 4)),
        'Header width belongs at its actual forward offset, not all along the combine body')
assert(not conflict(course({{0, -15}, {0, 90}}), vehicle(0, -11, 4, 8)),
        'Do not roll backwards over the passed part of PPC\'s relevant segment')
local hit = conflict(straight, vehicle(7, 30, 2, 3))
assert(hit and hit.distance > 15 and hit.distance < 25,
        'A corner of the wide header must detect a trailer that clears the combine body')
local tractor = vehicle(25, 25, 3, 5)
local trailer = vehicle(3, 25, 3, 9, math.pi / 3)
trailer.getAttacherVehicle = function() return tractor end
tractor.children = {trailer}
assert(conflict(straight, tractor), 'A clear tractor must not hide its angled trailer across the route')
assert(conflict(straight, vehicle(14, 25, 2, 10, math.pi / 2, -6)),
        'A rotated long body with an offset centre must use all four corners')
assert(not conflict(straight, vehicle(14, 25, 2, 10, math.pi / 2, 6)),
        'The same offset towards the clear side must not produce a false hold')
local hairpin = course({{0, 0}, {0, 30}, {8, 38}, {20, 40}, {32, 36}, {40, 24}, {40, -10}, {20, -20}})
assert(conflict(hairpin, vehicle(22, -20, 3, 6)),
        'A trailer currently behind us can still obstruct a later bend; do not globally ignore rear vehicles')
assert(conflict(course({{0, 0}, {0, 90}}), vehicle(0, 43.125, 0.05, 0.05)),
        'Sparse waypoints must not miss an obstruction between endpoints')
assert(conflict(course({{0, 0}, {0, -30}}, true), vehicle(0, -15, 3, 6)),
        'A reverse leg must still detect an actual obstruction behind the combine')
local sweep = VehicleRouteConflict.createSweep(FieldworkBoundary.captureRig(combine), straight, 12)
local before = sweep[1].parts[1].z
VehicleRouteConflict.findConflict(sweep, FieldworkBoundary.captureRig(vehicle(0, 60, 3, 5)))
assert(sweep[1].parts[1].z == before, 'Several rig checks must share an immutable sweep')
print('VehicleRouteConflictTest: OK')
