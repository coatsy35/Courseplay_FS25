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

--- Check segments as well as waypoints. An optional sub-range lets callers validate only a newly appended section
--- without rejecting an existing generated headland course that legitimately uses the full working width.
---@param firstIx number|nil
---@param lastIx number|nil
---@param allowEntry boolean|nil allow the range to start outside the corridor provided it enters and never leaves
function FieldworkBoundary.containsCourse(boundary, course, firstIx, lastIx, allowEntry)
    if not boundary then return true end
    if not course then return false end
    firstIx = math.max(1, firstIx or 1)
    lastIx = math.min(course:getNumberOfWaypoints(), lastIx or course:getNumberOfWaypoints())
    if firstIx > lastIx then return false end
    local px, _, pz = course:getWaypointPosition(firstIx)
    local hasEntered = FieldworkBoundary.contains(boundary, px, pz)
    if not hasEntered and not allowEntry then return false end
    for i = firstIx + 1, lastIx do
        local x, _, z = course:getWaypointPosition(i)
        local count = math.max(1, math.ceil(MathUtil.vector2Length(x - px, z - pz) / 0.5))
        for j = 1, count do
            local inside = FieldworkBoundary.contains(boundary,
                    px + (x - px) * j / count, pz + (z - pz) * j / count)
            if hasEntered and not inside then
                return false
            end
            hasEntered = hasEntered or inside
        end
        px, pz = x, z
    end
    return hasEntered
end

--- Check a live steering segment. An AutoDrive handover may begin just outside the corridor, but can then only
--- steer to a point inside it. Once inside, the complete segment must remain contained.
function FieldworkBoundary.containsSegment(boundary, x, z, gx, gz, allowEntry)
    if not boundary then return true end
    local entered = FieldworkBoundary.contains(boundary, x, z)
    if not entered and not allowEntry then return false end
    local distance = MathUtil.vector2Length(gx - x, gz - z)
    local steps = math.max(1, math.ceil(distance / 0.5))
    for i = 1, steps do
        local inside = FieldworkBoundary.contains(boundary, x + (gx - x) * i / steps,
                z + (gz - z) * i / steps)
        if entered and not inside then return false end
        entered = entered or inside
    end
    return entered
end

-- Sample oriented rectangles, including their edges/interior. A centreline alone cannot protect an articulated
-- trailer on a bend. Use the raw polygon here: the rectangle already includes the machine's physical width.
local function boundaryGeometry(boundary)
    if boundary.geometry then return boundary.geometry end
    local geometry = {edges = {}, cells = {}, inside = {}}
    local polygons = {boundary.polygon}
    for _, island in ipairs(boundary.islands or {}) do table.insert(polygons, island) end
    for _, polygon in ipairs(polygons) do
        local previous = polygon[#polygon]
        for _, point in ipairs(polygon) do
            local edge = {a = previous, b = point}
            table.insert(geometry.edges, edge)
            for ix = math.floor(math.min(previous.x, point.x) / 32), math.floor(math.max(previous.x, point.x) / 32) do
                for iz = math.floor(math.min(previous.z, point.z) / 32), math.floor(math.max(previous.z, point.z) / 32) do
                    local key = ix .. ':' .. iz
                    geometry.cells[key] = geometry.cells[key] or {}
                    table.insert(geometry.cells[key], edge)
                end
            end
            previous = point
        end
    end
    boundary.geometry = geometry
    return geometry
end

function FieldworkBoundary.boxOutsideDistance(boundary, x, z, heading, box)
    if not boundary then return 0 end
    local geometry = boundaryGeometry(boundary)
    local function inside(px, pz)
        local key = math.floor(px / 32) .. ':' .. math.floor(pz / 32)
        if not geometry.cells[key] and geometry.inside[key] ~= nil then return geometry.inside[key] end
        local result = CpMathUtil.isPointInPolygon(boundary.polygon, px, pz)
        for _, island in ipairs(boundary.islands or {}) do
            if CpMathUtil.isPointInPolygon(island, px, pz) then result = false; break end
        end
        if not geometry.cells[key] then geometry.inside[key] = result end
        return result
    end
    local c, sn = math.cos(heading), math.sin(heading)
    local cx = x + c * (box.xOffset or 0) + sn * (box.zOffset or 0)
    local cz = z - sn * (box.xOffset or 0) + c * (box.zOffset or 0)
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    local worst = 0
    for _, corner in ipairs({{-1, -1}, {-1, 1}, {1, -1}, {1, 1}}) do
        local px = cx + c * corner[1] * box.width + sn * corner[2] * box.length
        local pz = cz - sn * corner[1] * box.width + c * corner[2] * box.length
        minX, maxX, minZ, maxZ = math.min(minX, px), math.max(maxX, px), math.min(minZ, pz), math.max(maxZ, pz)
        if not inside(px, pz) then
            local nearest = math.huge
            for _, edge in ipairs(geometry.edges) do
                local dx, dz = edge.b.x - edge.a.x, edge.b.z - edge.a.z
                local t = math.max(0, math.min(1, ((px - edge.a.x) * dx + (pz - edge.a.z) * dz) /
                        math.max(0.0001, dx * dx + dz * dz)))
                nearest = math.min(nearest, MathUtil.vector2Length(px - edge.a.x - t * dx, pz - edge.a.z - t * dz))
            end
            worst = math.max(worst, nearest + 0.001)
        end
    end
    if worst > 0 then return worst end
    -- All corners being inside is insufficient for a concave boundary or an island enclosed by the box. Clip
    -- nearby polygon edges against the box in local coordinates; any intersection makes this pose unsafe.
    local checked = {}
    for ix = math.floor(minX / 32), math.floor(maxX / 32) do
        for iz = math.floor(minZ / 32), math.floor(maxZ / 32) do
            for _, edge in ipairs(geometry.cells[ix .. ':' .. iz] or {}) do
                if not checked[edge] then
                    checked[edge] = true
                    local ax, az = c * (edge.a.x - cx) - sn * (edge.a.z - cz), sn * (edge.a.x - cx) + c * (edge.a.z - cz)
                    local bx, bz = c * (edge.b.x - cx) - sn * (edge.b.z - cz), sn * (edge.b.x - cx) + c * (edge.b.z - cz)
                    local lo, hi = 0, 1
                    for _, axis in ipairs({{ax, bx - ax, box.width}, {az, bz - az, box.length}}) do
                        if math.abs(axis[2]) < 0.000001 then
                            if math.abs(axis[1]) > axis[3] then hi = -1 end
                        else
                            local t1, t2 = (-axis[3] - axis[1]) / axis[2], (axis[3] - axis[1]) / axis[2]
                            lo, hi = math.max(lo, math.min(t1, t2)), math.min(hi, math.max(t1, t2))
                        end
                    end
                    if lo <= hi then return 0.001 end
                end
            end
        end
    end
    return 0
end

function FieldworkBoundary.captureRig(vehicle)
    local rig, byVehicle = {}, {}
    local function add(object)
        if byVehicle[object] then return byVehicle[object] end
        local parent = object ~= vehicle and object.getAttacherVehicle and object:getAttacherVehicle()
        local parentPart = parent and add(parent)
        local node = object == vehicle and vehicle:getAIDirectionNode() or object.rootNode
        local x, _, z = getWorldTranslation(node)
        local _, heading = getWorldRotation(node)
        local size = object.size
        local part = {x = x, z = z, heading = heading, node = node, parent = parentPart,
            box = {width = AIUtil.getWidth(object) / 2 + 0.25, length = AIUtil.getLength(object) / 2 + 0.25,
                zOffset = size and size.lengthOffset or 0}}
        if object == vehicle then
            local _, _, offset = localToLocal(object.rootNode, node, 0, 0, 0)
            part.box.zOffset = part.box.zOffset + offset
        end
        if parentPart then
            local joint = object.getActiveInputAttacherJoint and object:getActiveInputAttacherJoint()
            local pivot = joint and joint.node or node
            part.px, _, part.pz = localToLocal(pivot, parentPart.node, 0, 0, 0)
            part.hx, _, part.hz = localToLocal(pivot, node, 0, 0, 0)
            part.articulated = object.spec_wheels ~= nil and math.abs(part.hz) > 1
            part.relativeHeading = heading - parentPart.heading
        end
        byVehicle[object] = part
        table.insert(rig, part)
        return part
    end
    add(vehicle)
    for _, object in ipairs(vehicle:getChildVehicles()) do add(object) end
    return rig
end

local function wrappedAngle(angle)
    return (angle + math.pi) % (2 * math.pi) - math.pi
end

function FieldworkBoundary.advanceRig(rig, x, z, heading, signedDistance)
    rig[1].x, rig[1].z, rig[1].heading = x, z, heading
    for i = 2, #rig do
        local part = rig[i]
        local parent = part.parent
        if parent then
            if part.articulated then
                part.heading = part.heading + signedDistance * math.sin(parent.heading - part.heading) /
                        math.max(1, math.abs(part.hz))
            else
                part.heading = parent.heading + part.relativeHeading
            end
            local hx = parent.x + math.cos(parent.heading) * part.px + math.sin(parent.heading) * part.pz
            local hz = parent.z - math.sin(parent.heading) * part.px + math.cos(parent.heading) * part.pz
            part.x = hx - math.cos(part.heading) * part.hx - math.sin(part.heading) * part.hz
            part.z = hz + math.sin(part.heading) * part.hx - math.cos(part.heading) * part.hz
        end
    end
end

function FieldworkBoundary.rigOutsideDistance(boundary, rig)
    local worst = 0
    for _, part in ipairs(rig) do
        worst = math.max(worst, FieldworkBoundary.boxOutsideDistance(boundary, part.x, part.z, part.heading, part.box))
    end
    return worst
end

-- Roll out the attached bodies in half-metre steps. Entry may begin outside after AD handover, but each step
-- must reduce the protrusion; once fully inside, no body is allowed to leave the polygon again.
function FieldworkBoundary.sweepRigSegment(boundary, rig, gx, gz, reverse, turningRadius)
    local x, z, heading = rig[1].x, rig[1].z, rig[1].heading
    local dx, dz = gx - x, gz - z
    local distance = MathUtil.vector2Length(dx, dz)
    if distance < 0.01 then return true end
    local targetHeading = math.atan2(dx, dz) + (reverse and math.pi or 0)
    local count = math.max(1, math.ceil(distance / 0.5))
    local step = distance / count
    local previous = FieldworkBoundary.rigOutsideDistance(boundary, rig)
    for i = 1, count do
        local difference = wrappedAngle(targetHeading - heading)
        heading = heading + math.max(-step / turningRadius, math.min(step / turningRadius, difference))
        FieldworkBoundary.advanceRig(rig, x + dx * i / count, z + dz * i / count, heading, reverse and -step or step)
        local outside = FieldworkBoundary.rigOutsideDistance(boundary, rig)
        if outside > previous + 0.0001 then return false end
        previous = outside
    end
    return true
end

function FieldworkBoundary.containsRigCourse(boundary, vehicle, course, turningRadius)
    if not boundary then return true end
    local rig = FieldworkBoundary.captureRig(vehicle)
    for i = 1, course:getNumberOfWaypoints() do
        local x, _, z = course:getWaypointPosition(i)
        if not FieldworkBoundary.sweepRigSegment(boundary, rig, x, z, course:isReverseAt(i), turningRadius) then return false end
    end
    return FieldworkBoundary.rigOutsideDistance(boundary, rig) == 0
end

-- The live controller steers towards a lookahead point on an arc, rather than translating straight towards it.
-- Check the imminent swept motion using the same curvature relation as a pursuit controller.
function FieldworkBoundary.containsRigSteering(boundary, vehicle, gx, gz, reverse, turningRadius)
    local rig = FieldworkBoundary.captureRig(vehicle)
    local outside = FieldworkBoundary.rigOutsideDistance(boundary, rig)
    local step = reverse and -0.5 or 0.5
    for _ = 1, 8 do
        local lead = rig[1]
        local dx, dz = gx - lead.x, gz - lead.z
        if dx * dx + dz * dz < 0.25 then break end
        local lateral = math.cos(lead.heading) * dx - math.sin(lead.heading) * dz
        local curvature = math.max(-1 / turningRadius, math.min(1 / turningRadius, 2 * lateral / (dx * dx + dz * dz)))
        local middleHeading = lead.heading + curvature * step / 2
        FieldworkBoundary.advanceRig(rig, lead.x + math.sin(middleHeading) * step,
                lead.z + math.cos(middleHeading) * step, lead.heading + curvature * step, step)
        local nextOutside = FieldworkBoundary.rigOutsideDistance(boundary, rig)
        if nextOutside > outside + 0.0001 then return false end
        outside = nextOutside
    end
    return true
end
