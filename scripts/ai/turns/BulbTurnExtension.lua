--- Extend the crossing tangent of a Dubins bulb before its final quarter-circle.
--- Preserve the preceding bulb and the turn radius; return to the row with an
--- opposite arc, followed by the ordinary straight approach. Coordinates here
--- are the pathfinder's planar coordinates, not GIANTS world coordinates.
BulbTurnExtension = {}

function BulbTurnExtension.extend(path, solution, width, steeringLength, maxAdvance)
    local descriptor = solution and solution.pathDescriptor
    if not path or not descriptor or steeringLength <= 0 or maxAdvance <= 0 or
            descriptor.param[3] < math.pi / 2 or descriptor.type3 == 'S' then
        return path, 0
    end
    local radius = descriptor.rho
    -- Two equal-radius arcs bring the tractor back to the row. Their extra
    -- forward travel is 2R sin(a), and their lateral recovery is 2R(1-cos(a)).
    local advance = math.min(maxAdvance, 1.1 * radius)
    local clearance = 2 * radius * (1 - math.sqrt(1 - (advance / (2 * radius))^2))
    local across = math.min(width / 2, steeringLength / 4, clearance)
    if across < 0.001 then
        return path, 0
    end
    local angle = math.acos(1 - across / (2 * radius))
    local cut = solution:getLength(radius) - radius * math.pi / 2
    local step = math.min(1, radius * math.pi / 12)
    local originalStep = solution:getLength(radius) / (#path - 1)
    local result = {}
    -- Keep the original sampled prefix exactly, including the first waypoint.
    for i = 1, #path do
        if (i - 1) * originalStep >= cut then break end
        table.insert(result, path[i])
    end
    local join = dubins_path_sample(descriptor, cut)
    table.insert(result, join)
    local function appendSegment(length, curvature)
        local start = result[#result]
        local count = math.ceil(length / step)
        for i = 1, count do
            local distance = length * i / count
            local heading = start.t + curvature * distance
            local x, y
            if curvature == 0 then
                x, y = start.x + distance * math.cos(start.t), start.y + distance * math.sin(start.t)
            else
                x = start.x + (math.sin(heading) - math.sin(start.t)) / curvature
                y = start.y - (math.cos(heading) - math.cos(start.t)) / curvature
            end
            table.insert(result, State3D(x, y, heading, 0, nil, Gear.Forward))
        end
    end
    local direction = descriptor.type3 == 'L' and 1 or -1
    appendSegment(across, 0)
    appendSegment(radius * (math.pi / 2 + angle), direction / radius)
    appendSegment(radius * angle, -direction / radius)
    return result, across
end
