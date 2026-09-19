--- Geometry estimates for forward headland loops. Each wheeled attachment has
--- its own effective axle and hitch; this is a planar, no-slip planning model,
--- not a measurement of collision shapes or a simulation of GIANTS physics.
HeadlandLoopGeometry = {}
local G = HeadlandLoopGeometry
G.maxArticulation = math.rad(45)
G.alignmentTolerance = math.rad(5)
G.step = 0.5
-- Immutable empty edge list for grid columns without a boundary segment.
G.emptyEdges = {}

local function finite(n)
    return type(n) == 'number' and n == n and math.abs(n) < 1000000
end

local function heading(node)
    local x, _, z = localDirectionToWorld(node, 0, 0, 1)
    return math.atan2(x, z)
end

local function delta(a, b)
    return math.atan2(math.sin(a - b), math.cos(a - b))
end

local function position(p, x, z)
    return p.x + x * math.cos(p.t) + z * math.sin(p.t),
        p.z - x * math.sin(p.t) + z * math.cos(p.t)
end

-- Shared coordinate conventions for the model, validator, search and return.
-- Keep these together so all modules use the same game heading and yaw wrap.
G.math = {finite = finite, heading = heading, delta = delta, position = position}

------------------------------------------------------------------------------------------------------------------------
-- Physical footprints and field boundaries
-- These checks are shared by planning and live handover; neither may use a weaker envelope.
------------------------------------------------------------------------------------------------------------------------

--- Separating-axis rectangle test. Two metres are removed from each longitudinal
--- end because declared vehicle boxes commonly overlap at a normal coupling.
--- Substantial drill/cart overlap during jack-knifing remains detectable.
function G.bodiesOverlap(a, pa, b, pb)
    if a.virtual or b.virtual then return false end
    a, b = a.collision or a, b.collision or b
    -- Exact rectangle SAT using centres and projected half-extents. Avoid
    -- allocating eight corners and re-projecting them onto four axes for every
    -- body pair at every sample of every rejected route.
    local function extents(body, pose)
        local front, back = body.front - 2, body.back + 2
        if front <= back then front, back = body.front, body.back end
        local x, z = position(pose, (body.left + body.right) / 2, (front + back) / 2)
        return x, z, (body.left - body.right) / 2, (front - back) / 2
    end
    local ax, az, aw, al = extents(a, pa)
    local bx, bz, bw, bl = extents(b, pb)
    local ca, sa = math.cos(pa.t), math.sin(pa.t)
    local dx, dz = (bx - ax) * ca - (bz - az) * sa, (bx - ax) * sa + (bz - az) * ca
    local c, s = math.cos(pb.t - pa.t), math.sin(pb.t - pa.t)
    local ac, as = math.abs(c), math.abs(s)
    if math.abs(dx) >= aw + bw * ac + bl * as or
            math.abs(dz) >= al + bw * as + bl * ac or
            math.abs(dx * c - dz * s) >= bw + aw * ac + al * as or
            math.abs(dx * s + dz * c) >= bl + aw * as + al * ac then return false end
    return true
end

--- Does a polygon edge touch a predicted rectangle? Test in the body's frame.
--- This also catches a narrow island or concave boundary between sample corners.
local function edgeTouches(body, pose, a, b)
    local c, s = math.cos(pose.t), math.sin(pose.t)
    local ax, az = (a.x - pose.x) * c - (a.z - pose.z) * s, (a.x - pose.x) * s + (a.z - pose.z) * c
    local bx, bz = (b.x - pose.x) * c - (b.z - pose.z) * s, (b.x - pose.x) * s + (b.z - pose.z) * c
    local lo, hi = 0, 1
    for _, axis in ipairs({{ax, bx - ax, body.right, body.left}, {az, bz - az, body.back, body.front}}) do
        if math.abs(axis[2]) < 1e-9 then
            if axis[1] < axis[3] or axis[1] > axis[4] then return false end
        else
            local u, v = (axis[3] - axis[1]) / axis[2], (axis[4] - axis[1]) / axis[2]
            lo, hi = math.max(lo, math.min(u, v)), math.min(hi, math.max(u, v))
            if lo > hi then return false end
        end
    end
    return true
end

function G.bodyFits(body, pose, boundary)
    if not boundary then return true end
    -- The narrow chassis and wide working bar occupy different longitudinal
    -- ranges. Check their union, not a full-width rectangle the chassis length.
    if body.collision then
        return G.bodyFits(body.collision, pose, boundary) and
            (not body.workArea or G.bodyFits(body.workArea, pose, boundary))
    end
    local centreX, centreZ = position(pose, (body.left + body.right) / 2, (body.front + body.back) / 2)
    local halfWidth, halfLength = (body.left - body.right) / 2, (body.front - body.back) / 2
    local c, s = math.abs(math.cos(pose.t)), math.abs(math.sin(pose.t))
    local radiusX, radiusZ = c * halfWidth + s * halfLength, s * halfWidth + c * halfLength
    local minX, maxX, minZ, maxZ = centreX - radiusX, centreX + radiusX, centreZ - radiusZ, centreZ + radiusZ
    -- Numeric grid coordinates avoid allocating a string key for every body
    -- sample. Query stamps deduplicate shared edges without a per-query table.
    -- This cache belongs to this field snapshot, never to a different search.
    boundary.query = boundary.query + 1
    local query = boundary.query
    for gx = math.floor(minX / 32), math.floor(maxX / 32) do
        local column = boundary.grid[gx]
        if column then
            for gz = math.floor(minZ / 32), math.floor(maxZ / 32) do
                for _, edge in ipairs(column[gz] or G.emptyEdges) do
                    if edge.query ~= query then
                        if edgeTouches(body, pose, edge[1], edge[2]) then return false end
                        edge.query = query
                    end
                end
            end
        end
    end
    local x, z = centreX, centreZ
    local gx, gz = math.floor(x / 32), math.floor(z / 32)
    local cells, edges = boundary.cells[gx], boundary.grid[gx]
    if cells and cells[gz] ~= nil then return cells[gz] end
    local inside = CpMathUtil.isPointInPolygon(boundary.polygon, x, z)
    for _, polygon in ipairs(boundary.islands) do
        if CpMathUtil.isPointInPolygon(polygon, x, z) then inside = false end
    end
    -- A cell without a polygon edge lies wholly inside or wholly outside.
    if not edges or not edges[gz] then
        if not cells then cells = {}; boundary.cells[gx] = cells end
        cells[gz] = inside
    end
    return inside
end

--- Resolve the field once, then index its outline and islands for repeated
--- footprint queries. A missing job polygon can use the map or custom field.
function G.getBoundary(vehicle)
    local polygon = vehicle.cpGetFieldPolygon and vehicle:cpGetFieldPolygon()
    local source = 'job field'
    if not polygon or #polygon < 3 then
        local node = vehicle:getAIDirectionNode()
        local x, _, z = getWorldTranslation(node)
        local custom = g_customFieldManager and g_customFieldManager:getCustomField(x, z)
        if custom then
            polygon = custom:getVertices()
            source = 'custom field'
        elseif CpFieldUtil and CpFieldUtil.getFieldAtWorldPosition and CpFieldUtil.getFieldPolygon then
            local field = CpFieldUtil.getFieldAtWorldPosition(x, z)
            if field then
                polygon = CpFieldUtil.getFieldPolygon(field)
                source = 'map field'
            end
        end
    end
    if not polygon or #polygon < 3 then return nil end
    local islands = vehicle.cpGetIslandPolygons and vehicle:cpGetIslandPolygons() or {}
    local boundary = {polygon = polygon, islands = islands, grid = {}, cells = {}, query = 0, source = source}
    local polygons = {polygon}
    for _, island in ipairs(islands) do polygons[#polygons + 1] = island end
    for _, points in ipairs(polygons) do
        for i, a in ipairs(points) do
            local b = points[i % #points + 1]
            local edge = {a, b}
            for gx = math.floor(math.min(a.x, b.x) / 32), math.floor(math.max(a.x, b.x) / 32) do
                local column = boundary.grid[gx]
                if not column then column = {}; boundary.grid[gx] = column end
                for gz = math.floor(math.min(a.z, b.z) / 32), math.floor(math.max(a.z, b.z) / 32) do
                    column[gz] = column[gz] or {}
                    table.insert(column[gz], edge)
                end
            end
        end
    end
    return boundary
end

--- Width-only corridor for unsupported chains, including CP's changing offset.
--- This cannot validate the swept bodies of an unsupported internal pivot.
function G.widthCourseFits(vehicle, course, width, steeringLength)
    local boundary = G.getBoundary(vehicle)
    if not boundary then return true end
    local halfWidth = math.max(width, vehicle.size and vehicle.size.width or 0) / 2
    local halfLength = math.max(halfWidth, (vehicle.size and vehicle.size.length or 0) / 2)
    local body = {left = halfWidth, right = -halfWidth, front = halfLength, back = -halfLength}
    local previous, offset = nil, 0
    for i = 1, course:getNumberOfWaypoints() do
        if course:getUseTightTurnOffset(i) then
            offset = AIUtil.calculateTightTurnOffsetForTurnManeuver(vehicle, steeringLength, course, i, offset)
        else
            offset = 0
        end
        local x, _, z = course.waypoints[i]:getOffsetPosition(offset, 0)
        local pose = {x = x, z = z, t = course:getWaypointYRotation(i)}
        if previous then
            local distance = math.sqrt((x - previous.x)^2 + (z - previous.z)^2)
            local count = math.max(1, math.ceil(distance / G.step), math.ceil(math.abs(delta(pose.t, previous.t)) / math.rad(2)))
            for j = 1, count do
                local p = {x = previous.x + (x - previous.x) * j / count,
                    z = previous.z + (z - previous.z) * j / count,
                    t = previous.t + delta(pose.t, previous.t) * j / count}
                if not G.bodyFits(body, p, boundary) then return false end
            end
        elseif not G.bodyFits(body, pose, boundary) then return false end
        previous = pose
    end
    return true
end
