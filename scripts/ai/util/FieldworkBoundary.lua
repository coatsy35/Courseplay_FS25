--- Field corridor shared by startup, row-turn generation and pathfinding.
FieldworkBoundary = {}

function FieldworkBoundary.forVehicle(vehicle, width)
    local polygon = vehicle and vehicle.cpGetFieldPolygon and vehicle:cpGetFieldPolygon()
    if not polygon or #polygon < 3 then return nil end
    return {polygon = polygon, margin = math.max(width or 0, vehicle.size and vehicle.size.width or 0) / 2,
        islands = vehicle.cpGetIslandPolygons and vehicle:cpGetIslandPolygons() or {}}
end

function FieldworkBoundary.contains(boundary, x, z)
    if not boundary then return true end
    local function inside(px, pz)
        if not CpMathUtil.isPointInPolygon(boundary.polygon, px, pz) then return false end
        for _, island in ipairs(boundary.islands) do
            if CpMathUtil.isPointInPolygon(island, px, pz) then return false end
        end
        return true
    end
    if not inside(x, z) then return false end
    for i = 0, 7 do
        local angle = i * math.pi / 4
        if not inside(x + boundary.margin * math.cos(angle), z + boundary.margin * math.sin(angle)) then
            return false
        end
    end
    return true
end

--- Shorten the backwards run-in to the contiguous corridor before the work point.
function FieldworkBoundary.fitOffset(boundary, x, z, heading, wanted)
    if not boundary or wanted >= 0 then return wanted end
    local fitted = 0
    for distance = 0, math.ceil(-wanted) do
        local offset = math.max(wanted, -distance)
        if not FieldworkBoundary.contains(boundary, x + math.sin(heading) * offset,
                z + math.cos(heading) * offset) then return fitted end
        fitted = offset
    end
    return fitted
end

--- Check segments as well as waypoints, including any appended entry adjustment.
function FieldworkBoundary.containsCourse(boundary, course)
    if not boundary then return true end
    if not course then return false end
    local px, _, pz = course:getWaypointPosition(1)
    if not FieldworkBoundary.contains(boundary, px, pz) then return false end
    for i = 2, course:getNumberOfWaypoints() do
        local x, _, z = course:getWaypointPosition(i)
        local count = math.max(1, math.ceil(MathUtil.vector2Length(x - px, z - pz) / 0.5))
        for j = 1, count do
            if not FieldworkBoundary.contains(boundary, px + (x - px) * j / count, pz + (z - pz) * j / count) then
                return false
            end
        end
        px, pz = x, z
    end
    return true
end
