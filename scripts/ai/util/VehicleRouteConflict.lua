--- Physical occupancy of a live route. Unlike a staging corridor, this uses separate oriented bodies:
--- a wide header is at the front of the combine, not a circular exclusion zone around its rear axle.
--- Rig poses and articulation use the same geometry as FieldworkBoundary; no GIANTS collision checks are disabled.
VehicleRouteConflict = {}

local function rectangle(part, padding)
    local c, s = math.cos(part.heading), math.sin(part.heading)
    local box = part.box
    return {x = part.x + c * (box.xOffset or 0) + s * (box.zOffset or 0),
        z = part.z - s * (box.xOffset or 0) + c * (box.zOffset or 0),
        ux = c, uz = -s, vx = s, vz = c,
        width = box.width + (padding or 0), length = box.length + (padding or 0)}
end

local function overlaps(a, b)
    local dx, dz = b.x - a.x, b.z - a.z
    -- Separating-axis test: corners/length offsets and angled trailers remain rectangular, not three circles.
    for _, axis in ipairs({{a.ux, a.uz}, {a.vx, a.vz}, {b.ux, b.uz}, {b.vx, b.vz}}) do
        local x, z = axis[1], axis[2]
        local extentA = a.width * math.abs(x * a.ux + z * a.uz) +
                a.length * math.abs(x * a.vx + z * a.vz)
        local extentB = b.width * math.abs(x * b.ux + z * b.uz) +
                b.length * math.abs(x * b.vx + z * b.vz)
        if math.abs(dx * x + dz * z) > extentA + extentB then return false end
    end
    return true
end

local function angleDifference(a, b)
    return (a - b + math.pi) % (2 * math.pi) - math.pi
end

--- Consume a captured rig, rolling its complete footprint along the remaining live course. The first
--- waypoint starts PPC's relevant segment and can already be behind us: begin at the actual pose and
--- travel to that segment's end. Later bends are all retained, including ones which return behind us.
function VehicleRouteConflict.createSweep(rig, course, turningRadius)
    local sweep = {}
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
            sample.parts[i] = rectangle(part, padding)
        end
        table.insert(sweep, sample)
    end
    append(2, 1, 0)
    local travelled = 0
    for ix = 2, course:getNumberOfWaypoints() do
        local x, z, heading = rig[1].x, rig[1].z, rig[1].heading
        local gx, _, gz = course:getWaypointPosition(ix)
        local dx, dz = gx - x, gz - z
        local distance = MathUtil.vector2Length(dx, dz)
        if distance > 0.01 then
            local reverse = course.isReverseAt and course:isReverseAt(ix) or false
            local targetHeading = math.atan2(dx, dz) + (reverse and math.pi or 0)
            local count = math.ceil(distance / 0.25)
            local step = distance / count
            for n = 1, count do
                local previous = {}
                for i, part in ipairs(rig) do
                    previous[i] = {x = part.x, z = part.z, heading = part.heading}
                end
                local delta = angleDifference(targetHeading, heading)
                local maxAngle = step / math.max(1, turningRadius)
                heading = heading + math.max(-maxAngle, math.min(maxAngle, delta))
                FieldworkBoundary.advanceRig(rig, x + dx * n / count, z + dz * n / count,
                        heading, reverse and -step or step)
                append(ix, ix - 1 + n / count, travelled + (n - 1) * step, previous)
            end
            travelled = travelled + distance
        end
    end
    return sweep
end

--- Return the earliest occupied segment and distance along the route, examining every attached body.
--- Build the sweep once per scan; it can then be checked against all unloaders without repeating the rollout.
function VehicleRouteConflict.findConflict(sweep, otherRig)
    local obstacles = {}
    for i, part in ipairs(otherRig) do obstacles[i] = rectangle(part) end
    for _, sample in ipairs(sweep) do
        for _, part in ipairs(sample.parts) do
            for _, obstacle in ipairs(obstacles) do
                if overlaps(part, obstacle) then return sample end
            end
        end
    end
    return nil
end
