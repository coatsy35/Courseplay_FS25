--- Physical occupancy of a live route. Unlike a staging corridor, this uses separate oriented bodies:
--- a wide header is at the front of the combine, not a circular exclusion zone around its rear axle.
--- Rig poses and articulation use the same geometry as FieldworkBoundary; no GIANTS collision checks are disabled.
VehicleRouteConflict = {}

local function rectangle(part, padding)
    local c, s = math.cos(part.heading), math.sin(part.heading)
    local box = part.box
    local r = {x = part.x + c * (box.xOffset or 0) + s * (box.zOffset or 0),
        z = part.z - s * (box.xOffset or 0) + c * (box.zOffset or 0),
        ux = c, uz = -s, vx = s, vz = c,
        width = box.width + (padding or 0), length = box.length + (padding or 0),
        node = part.node, heading = part.heading, padding = padding or 0}
    r.extentX = math.abs(c) * r.width + math.abs(s) * r.length
    r.extentZ = math.abs(s) * r.width + math.abs(c) * r.length
    return r
end

local function separated(a, b, dx, dz, x, z)
    local extentA = a.width * math.abs(x * a.ux + z * a.uz) +
            a.length * math.abs(x * a.vx + z * a.vz)
    local extentB = b.width * math.abs(x * b.ux + z * b.uz) +
            b.length * math.abs(x * b.vx + z * b.vz)
    return math.abs(dx * x + dz * z) > extentA + extentB
end

local function overlaps(a, b)
    local dx, dz = b.x - a.x, b.z - a.z
    -- A conservative world-axis rejection precedes the identical four-axis rectangle test.
    -- Avoid allocating five temporary tables for every body pair in every sampled route.
    if math.abs(dx) > a.extentX + b.extentX or math.abs(dz) > a.extentZ + b.extentZ then return false end
    return not separated(a, b, dx, dz, a.ux, a.uz) and
        not separated(a, b, dx, dz, a.vx, a.vz) and
        not separated(a, b, dx, dz, b.ux, b.uz) and
        not separated(a, b, dx, dz, b.vx, b.vz)
end

local function angleDifference(a, b)
    return (a - b + math.pi) % (2 * math.pi) - math.pi
end

--- Consume a captured rig, rolling its complete footprint along the remaining live course. The first
--- waypoint starts PPC's relevant segment and can already be behind us: begin at the actual pose and
--- travel to that segment's end. Later bends are all retained, including ones which return behind us.
function VehicleRouteConflict.createSweepJob(rig, course, turningRadius)
    local sweep = {cells = {}}
    local function append(ix, progress, distance, previous)
        local sample = {ix = ix, progress = progress, distance = distance, parts = {}}
        for i, part in ipairs(rig) do
            local padding = 0
            if previous then
                local old = previous[i]
                local radius = MathUtil.vector2Length(part.box.width + math.abs(part.box.xOffset or 0),
                        part.box.length + math.abs(part.box.zOffset or 0))
                -- Cover motion between samples as well as each endpoint, including the outer header corner.
                padding = MathUtil.vector2Length(part.x - old.x, part.z - old.z) +
                        radius * math.abs(angleDifference(part.heading, old.heading))
            end
            local rect = rectangle(part, padding)
            sample.parts[i] = rect
            local entry = {sample = sample, sampleIndex = #sweep + 1, ownIndex = i, part = rect}
            -- Immutable spatial index: reject distant samples without scanning the whole route.
            for cx = math.floor((rect.x - rect.extentX) / 16), math.floor((rect.x + rect.extentX) / 16) do
                for cz = math.floor((rect.z - rect.extentZ) / 16), math.floor((rect.z + rect.extentZ) / 16) do
                    local key = cx .. ':' .. cz
                    sweep.cells[key] = sweep.cells[key] or {}
                    table.insert(sweep.cells[key], entry)
                end
            end
        end
        table.insert(sweep, sample)
    end
    append(2, 1, 0)
    local travelled, ix, segment = 0, 2, nil
    return {step = function()
        if ix > course:getNumberOfWaypoints() then return true, sweep end
        if not segment then
            local x, z, heading = rig[1].x, rig[1].z, rig[1].heading
            local gx, _, gz = course:getWaypointPosition(ix)
            local dx, dz = gx - x, gz - z
            local distance = MathUtil.vector2Length(dx, dz)
            if distance <= 0.01 then ix = ix + 1; return false end
            local reverse = course.isReverseAt and course:isReverseAt(ix) or false
            local count = math.ceil(distance / 0.25)
            segment = {x = x, z = z, dx = dx, dz = dz, heading = heading, distance = distance,
                reverse = reverse, targetHeading = math.atan2(dx, dz) + (reverse and math.pi or 0),
                count = count, step = distance / count, n = 0}
        end
        local c = segment
        c.n = c.n + 1
        local previous = {}
        for i, part in ipairs(rig) do previous[i] = {x = part.x, z = part.z, heading = part.heading} end
        local delta = angleDifference(c.targetHeading, c.heading)
        local maxAngle = c.step / math.max(1, turningRadius)
        c.heading = c.heading + math.max(-maxAngle, math.min(maxAngle, delta))
        FieldworkBoundary.advanceRig(rig, c.x + c.dx * c.n / c.count, c.z + c.dz * c.n / c.count,
            c.heading, c.reverse and -c.step or c.step)
        append(ix, ix - 1 + c.n / c.count, travelled + (c.n - 1) * c.step, previous)
        if c.n == c.count then travelled = travelled + c.distance; ix = ix + 1; segment = nil end
        return false
    end}
end

function VehicleRouteConflict.createSweep(rig, course, turningRadius, checkpoint)
    local job = VehicleRouteConflict.createSweepJob(rig, course, turningRadius)
    while true do
        if checkpoint then checkpoint() end
        local done, result = job:step()
        if done then return result end
    end
end

--- A collinear translation with unchanged body headings has an exact rectangular swept union.
--- Avoid hundreds of sampled/indexed poses for this common straight waiting/working lane.
--- Any steering, direction change or articulation uses the full sampled rollout instead.
function VehicleRouteConflict.createStraightSweep(rig, course)
    local lead = rig[1]
    if not lead then return end
    local si, co = math.sin(lead.heading), math.cos(lead.heading)
    local travelled, x, z, direction = 0, lead.x, lead.z, nil
    for ix = 2, course:getNumberOfWaypoints() do
        local gx, _, gz = course:getWaypointPosition(ix)
        local dx, dz = gx - x, gz - z
        local along, across = si * dx + co * dz, co * dx - si * dz
        if math.abs(across) > 0.000000001 then return end
        if math.abs(along) > 0.01 then
            local sign = along > 0 and 1 or -1
            local reverse = course.isReverseAt and course:isReverseAt(ix) or false
            if sign ~= (reverse and -1 or 1) or direction and direction ~= sign then return end
            direction, travelled = sign, travelled + along
            x, z = gx, gz
        end
    end
    for _, part in ipairs(rig) do
        if math.abs(math.sin(part.heading - lead.heading)) > 0.000000001 or
            part.articulated and math.abs(math.sin(part.parent.heading - part.heading)) > 0.000000001 then return end
    end
    local union = {}
    for i, part in ipairs(rig) do
        local box = part.box
        -- The sampled rollout adds up to 0.25 m translation padding at every endpoint.
        union[i] = {x = part.x + si * travelled / 2, z = part.z + co * travelled / 2,
            heading = part.heading, node = part.node,
            box = {width = box.width + 0.25, length = box.length + math.abs(travelled) / 2 + 0.25,
                xOffset = box.xOffset, zOffset = box.zOffset}}
    end
    local pose = {getNumberOfWaypoints = function() return 1 end}
    local _, sweep = VehicleRouteConflict.createSweepJob(union, pose, 1):step()
    return sweep
end

--- Return the earliest occupied segment and distance along the route, examining every attached body.
--- The optional second result identifies the overlapping bodies for hold diagnostics; the sweep stays immutable.
--- Build the sweep once per scan; it can then be checked against all unloaders without repeating the rollout.
local function findRectanglesConflict(sweep, obstacles)
    if sweep.cells then
        local best, bestOther
        for otherIndex, obstacle in ipairs(obstacles) do
            local seen = {}
            for cx = math.floor((obstacle.x - obstacle.extentX) / 16), math.floor((obstacle.x + obstacle.extentX) / 16) do
                for cz = math.floor((obstacle.z - obstacle.extentZ) / 16), math.floor((obstacle.z + obstacle.extentZ) / 16) do
                    for _, entry in ipairs(sweep.cells[cx .. ':' .. cz] or {}) do
                        if not seen[entry] then
                            seen[entry] = true
                            if overlaps(entry.part, obstacle) and (not best or
                                    entry.sampleIndex < best.sampleIndex or entry.sampleIndex == best.sampleIndex and
                                    (entry.ownIndex < best.ownIndex or entry.ownIndex == best.ownIndex and otherIndex < bestOther)) then
                                best, bestOther = entry, otherIndex
                            end
                        end
                    end
                end
            end
        end
        if best then return best.sample, {ownIndex = best.ownIndex, otherIndex = bestOther,
            own = best.part, other = obstacles[bestOther]} end
        return nil
    end
    for _, sample in ipairs(sweep) do
        for ownIndex, part in ipairs(sample.parts) do
            for otherIndex, obstacle in ipairs(obstacles) do
                if overlaps(part, obstacle) then
                    return sample, {ownIndex = ownIndex, otherIndex = otherIndex, own = part, other = obstacle}
                end
            end
        end
    end
end

function VehicleRouteConflict.findConflict(sweep, otherRig)
    local obstacles = {}
    for i, part in ipairs(otherRig) do obstacles[i] = rectangle(part) end
    return findRectanglesConflict(sweep, obstacles)
end

--- Exact intersection of two immutable swept routes, using the first route's spatial index.
function VehicleRouteConflict.findSweepConflict(sweep, other)
    for _, sample in ipairs(other) do
        if findRectanglesConflict(sweep, sample.parts) then return true end
    end
    return false
end
