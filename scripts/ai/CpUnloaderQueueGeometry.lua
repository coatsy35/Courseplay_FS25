-- Pure geometry used by queue parking and route acceptance, in world x/z.
CpUnloaderQueueGeometry = {}
local G = CpUnloaderQueueGeometry

function G.point(pose, x, z)
    local s, c = math.sin(pose.heading), math.cos(pose.heading)
    return {x = pose.x + c * x + s * z, z = pose.z - s * x + c * z}
end

function G.rectangle(pose, box, buffer)
    local w, l = box.width / 2 + buffer, box.length / 2 + buffer
    local x, z = box.xOffset or 0, box.zOffset or 0
    return {G.point(pose, x-w, z-l), G.point(pose, x+w, z-l),
        G.point(pose, x+w, z+l), G.point(pose, x-w, z+l)}
end

local function cross(a, b, c)
    return (b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x)
end

local function between(a, b, p)
    return p.x >= math.min(a.x,b.x)-1e-6 and p.x <= math.max(a.x,b.x)+1e-6
        and p.z >= math.min(a.z,b.z)-1e-6 and p.z <= math.max(a.z,b.z)+1e-6
end

function G.intersects(a, b, c, d)
    local abC, abD, cdA, cdB = cross(a,b,c), cross(a,b,d), cross(c,d,a), cross(c,d,b)
    if abC*abD < 0 and cdA*cdB < 0 then return true end
    return (math.abs(abC)<1e-6 and between(a,b,c)) or (math.abs(abD)<1e-6 and between(a,b,d))
        or (math.abs(cdA)<1e-6 and between(c,d,a)) or (math.abs(cdB)<1e-6 and between(c,d,b))
end

function G.inside(polygon, point)
    local inside = false
    for i, a in ipairs(polygon) do
        local b = polygon[i % #polygon + 1]
        if math.abs(cross(a,b,point)) < 1e-6 and between(a,b,point) then return true end
        if (a.z > point.z) ~= (b.z > point.z) and
                point.x < (b.x-a.x)*(point.z-a.z)/(b.z-a.z)+a.x then inside = not inside end
    end
    return inside
end

function G.edgesCross(a, b)
    for i, p in ipairs(a) do
        for j, q in ipairs(b) do
            if G.intersects(p, a[i % #a+1], q, b[j % #b+1]) then return true end
        end
    end
    return false
end

function G.overlap(a, b)
    return G.edgesCross(a,b) or G.inside(a,b[1]) or G.inside(b,a[1])
end

function G.within(rectangle, field, islands)
    if not field or #field < 3 then return false end
    for _, corner in ipairs(rectangle) do
        if not G.inside(field, corner) then return false end
    end
    -- Four inside corners alone miss concave boundaries and small islands.
    if G.edgesCross(rectangle, field) then return false end
    for _, island in ipairs(islands or {}) do
        if G.overlap(rectangle, island) then return false end
    end
    return true
end

-- Candidate ranking measures clearance of every rectangle, not just the tractor.
-- The caller supplies validated samples and the combine's protected corridor.
function G.firstClearTime(samples, corridor, speed)
    if speed <= 0 then return math.huge end
    local clearFrom
    for index = #samples, 1, -1 do
        local sample = samples[index]
        local clear = true
        for _, rectangle in ipairs(sample.rectangles) do
            if G.overlap(rectangle, corridor) then clear = false; break end
        end
        if not clear then break end
        clearFrom = sample.distance / speed
    end
    return clearFrom or math.huge
end

function G.bestClearance(candidates, corridor)
    local best, bestTime
    for _, candidate in ipairs(candidates) do
        if candidate.valid then
            local time = G.firstClearTime(candidate.samples, corridor, candidate.speed)
            if time < math.huge and (not bestTime or time < bestTime) then
                best, bestTime = candidate, time
            end
        end
    end
    return best, bestTime
end

-- Final departure gate: the headland polygon must describe a surveyed,
-- harvested handover area, not merely the field boundary or an AD node.
-- The engine adapter must supply current rectangles for every attached vehicle.
function G.canHandOver(rectangles, headland, protectedAreas)
    if not rectangles or #rectangles == 0 or not headland or #headland < 3 then return false end
    for _, rectangle in ipairs(rectangles) do
        if #rectangle ~= 4 or math.abs(cross(rectangle[1],rectangle[2],rectangle[3])) < 1e-6 then return false end
        if not G.within(rectangle, headland, protectedAreas) then return false end
    end
    return true
end
