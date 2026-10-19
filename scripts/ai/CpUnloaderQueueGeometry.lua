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

-- Split a convex footprint against a half-plane. Rectangle winding is
-- counter-clockwise, so positive cross products are inside.
local function split(poly,a,b)
    local inside,outside={},{}
    for i,p in ipairs(poly) do
        local q=poly[i%#poly+1]
        local dp,dq=cross(a,b,p),cross(a,b,q)
        if dp>=0 then inside[#inside+1]=p end
        if dp<=0 then outside[#outside+1]=p end
        if (dp<0 and dq>0) or (dp>0 and dq<0) then
            local f=dp/(dp-dq)
            local hit={x=p.x+(q.x-p.x)*f,z=p.z+(q.z-p.z)*f}
            inside[#inside+1]=hit; outside[#outside+1]=hit
        end
    end
    return inside,outside
end

local function area(poly)
    local sum=0
    for i=2,#poly-1 do sum=sum+cross(poly[1],poly[i],poly[i+1]) end
    return math.abs(sum)/2
end

-- Exact convex pieces outside the UNION of the captured starting footprints.
-- The capture is immutable: movement cannot grow the permitted starting area.
function G.outsideFootprints(rectangle,footprints)
    local pieces={rectangle}
    for _,occupied in ipairs(footprints) do
        local nextPieces={}
        for _,poly in ipairs(pieces) do
            local remaining=poly
            for i,a in ipairs(occupied) do
                if #remaining<3 then break end
                local outside
                remaining,outside=split(remaining,a,occupied[i%#occupied+1])
                if #outside>=3 and area(outside)>1e-8 then nextPieces[#nextPieces+1]=outside end
            end
        end
        pieces=nextPieces
    end
    return pieces
end

-- Density queries accept parallelograms. Cover each convex piece completely
-- with its smallest edge-aligned rectangle; any extra area is conservative.
function G.coveringRectangle(poly)
    local best,bestArea
    for i,a in ipairs(poly) do
        local b=poly[i%#poly+1]
        local dx,dz=b.x-a.x,b.z-a.z
        local length=math.sqrt(dx*dx+dz*dz)
        if length>1e-8 then
            dx,dz=dx/length,dz/length
            local xmin,xmax,zmin,zmax=math.huge,-math.huge,math.huge,-math.huge
            for _,p in ipairs(poly) do
                local x,z=(p.x-a.x)*dx+(p.z-a.z)*dz,-(p.x-a.x)*dz+(p.z-a.z)*dx
                xmin,xmax=math.min(xmin,x),math.max(xmax,x)
                zmin,zmax=math.min(zmin,z),math.max(zmax,z)
            end
            local size=(xmax-xmin)*(zmax-zmin)
            if not bestArea or size<bestArea then
                local function point(x,z) return {x=a.x+x*dx-z*dz,z=a.z+x*dz+z*dx} end
                best={point(xmin,zmin),point(xmax,zmin),point(xmax,zmax),point(xmin,zmax)}
                bestArea=size
            end
        end
    end
    return best
end
