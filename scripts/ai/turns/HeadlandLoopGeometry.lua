--- Geometry estimates for forward headland loops. Each wheeled attachment has
--- its own effective axle and hitch; this is a planar, no-slip planning model,
--- not a measurement of collision shapes or a simulation of GIANTS physics.
HeadlandLoopGeometry = {}
local G = HeadlandLoopGeometry
G.maxArticulation = math.rad(45)
G.internalArticulation = math.rad(25)
G.alignmentTolerance = math.rad(5)
G.step = 0.5

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

--- Keep body size and working markers: folded declared widths alone can be
--- much narrower than an unfolded drill. Preserve asymmetric marker extents.
function G.getBody(object, node)
    local size = object.size
    if not size or not finite(size.width) or not finite(size.length) or
            size.width <= 0 or size.length <= 0 or not object.rootNode then return nil end
    local body = {left = -math.huge, right = math.huge, front = -math.huge, back = math.huge}
    local declared = {left = -math.huge, right = math.huge, front = -math.huge, back = math.huge}
    local function include(target, x, z)
        target.left, target.right = math.max(target.left, x), math.min(target.right, x)
        target.front, target.back = math.max(target.front, z), math.min(target.back, z)
    end
    for _, x in ipairs({-size.width / 2, size.width / 2}) do
        for _, z in ipairs({-size.length / 2, size.length / 2}) do
            local bx, _, bz = localToLocal(object.rootNode, node,
                x + (size.widthOffset or 0), 0, z + (size.lengthOffset or 0))
            include(body, bx, bz)
            include(declared, bx, bz)
        end
    end
    if object.getAIMarkers then
        local left, right, back = object:getAIMarkers()
        for _, marker in pairs({left, right, back}) do
            if marker and marker ~= 0 then
                local x, _, z = localToLocal(marker, node, 0, 0, 0)
                include(body, x, z)
            end
        end
    end
    for _, key in ipairs({'left', 'right', 'front', 'back'}) do
        if not finite(body[key]) or not finite(declared[key]) then return nil end
    end
    -- Working markers protect the field boundary, while declared dimensions
    -- provide the less misleading solid-body rectangle for implement clearance.
    body.collision = declared
    return body
end

local function addLink(model, link, body, includeWidth)
    model.links[#model.links + 1] = link
    model.bodies[#model.bodies + 1] = body
    if includeWidth ~= false then model.width = math.max(model.width, body.left - body.right) end
end

--- Model one internal drawbar yaw joint as two independent links. The drawbar
--- has no axle, so its pose is a conservative kinematic approximation rather
--- than a GIANTS physics simulation. Keeping it separate still exposes both
--- articulation angles and the cart body to the route checks.
local function getInternalDrawbar(object, joint, axle)
    if not object.components or not joint.rootNode or
            not ImplementUtil.findJointNodeConnectingToNode then return nil end
    local _, nodes, limits = ImplementUtil.findJointNodeConnectingToNode(
        object, joint.rootNode, object.rootNode)
    local pivot
    for i, limit in ipairs(limits or {}) do
        if math.abs(limit[2] or 0) > math.rad(5) then
            if pivot then return nil end
            pivot = nodes and nodes[i]
        end
    end
    if not pivot or pivot == 0 then return nil end
    local hx, _, hz = localToLocal(joint.node, joint.rootNode, 0, 0, 0)
    local px, _, pz = localToLocal(pivot, joint.rootNode, 0, 0, 0)
    local drawbarLength = hz - pz
    local ax, _, axleLength = localToLocal(pivot, axle, 0, 0, 0)
    if not finite(drawbarLength) or not finite(axleLength) or drawbarLength < 0.5 or
            axleLength < 0.5 or math.abs(hx - px) > 0.25 or math.abs(ax) > 0.25 then return nil end
    return pivot, drawbarLength, axleLength
end

--- Detect a serial chain. One unsteered internal yaw joint in an implement's
--- input drawbar is represented explicitly; ambiguous joints still fall back.
function G.detect(vehicle)
    local node = vehicle:getAIDirectionNode()
    local rootBody = G.getBody(vehicle, node)
    if not rootBody then return nil, 'missing tractor dimensions' end
    local x, _, z = getWorldTranslation(node)
    local model = {root = {x = x, z = z, t = heading(node)}, bodies = {rootBody}, links = {}, width = rootBody.left - rootBody.right}
    local parent, parentNode, seen = vehicle, node, {[vehicle] = true}
    while parent.getAttachedImplements do
        local attachments = parent:getAttachedImplements()
        if #attachments == 0 then break end
        if #attachments ~= 1 then return nil, 'branched attachment chain' end
        local object = attachments[1].object
        if not object or seen[object] or #model.links >= 6 then return nil, 'unsupported attachment chain' end
        seen[object] = true
        if not ImplementUtil.isWheeledImplement(object) then return nil, 'mounted or unsupported attachment' end
        local joint = object.getActiveInputAttacherJoint and object:getActiveInputAttacherJoint()
        local axle = object.steeringAxleNode
        if not joint or not joint.node or joint.node == 0 or not axle or axle == 0 then
            return nil, 'missing hitch or steering axle'
        end
        local yawJoints = 0
        for _, componentJoint in ipairs(object.componentJoints or {}) do
            if componentJoint.rotLimit and math.abs(componentJoint.rotLimit[2] or 0) > math.rad(5) then
                yawJoints = yawJoints + 1
            end
        end
        if yawJoints > 1 then return nil, 'multiple internal yaw joints' end
        for _, wheel in ipairs(object.spec_wheels and object.spec_wheels.wheels or {}) do
            local steering = wheel.steering or wheel
            if math.abs(steering.steeringAxleScale or 0) > 0.01 then
                return nil, 'steered implement axle'
            end
        end
        local hx, _, hitch = localToLocal(joint.node, parentNode, 0, 0, 0)
        local body = G.getBody(object, axle)
        if not body or not finite(hitch) or math.abs(hx) > 0.25 or hitch > 0.25 then
            return nil, 'off-centre, front-mounted or invalid hitch geometry'
        end
        if yawJoints == 1 then
            local pivot, drawbarLength, axleLength = getInternalDrawbar(object, joint, axle)
            if not pivot then return nil, 'unsupported internal yaw geometry' end
            local drawbarBody = {left = 0.75, right = -0.75,
                front = drawbarLength + 0.25, back = -0.25, virtual = true}
            addLink(model, {length = drawbarLength, hitch = hitch,
                heading = heading(joint.rootNode), internal = true,
                maxArticulation = G.internalArticulation}, drawbarBody, false)
            addLink(model, {length = axleLength, hitch = 0,
                heading = heading(axle), internal = true,
                maxArticulation = G.internalArticulation}, body)
            model.internalPivots = (model.internalPivots or 0) + 1
        else
            local lx, _, length = localToLocal(joint.node, axle, 0, 0, 0)
            if not finite(length) or length < 0.5 or math.abs(lx) > 0.25 then
                return nil, 'off-centre, front-mounted or invalid hitch geometry'
            end
            addLink(model, {length = length, hitch = hitch, heading = heading(axle)}, body)
        end
        parent, parentNode = object, axle
    end
    if #model.links < 2 then return nil, 'fewer than two supported towing pivots' end
    return model
end

--- Separating-axis rectangle test. Two metres are removed from each longitudinal
--- end because declared vehicle boxes commonly overlap at a normal coupling.
--- Substantial drill/cart overlap during jack-knifing remains detectable.
function G.bodiesOverlap(a, pa, b, pb)
    if a.virtual or b.virtual then return false end
    a, b = a.collision or a, b.collision or b
    local function corners(body, pose)
        local front, back = body.front - 2, body.back + 2
        if front <= back then front, back = body.front, body.back end
        local result = {}
        for _, x in ipairs({body.left, body.right}) do
            for _, z in ipairs({front, back}) do
                local wx, wz = position(pose, x, z)
                result[#result + 1] = {x = wx, z = wz}
            end
        end
        return result
    end
    local ac, bc = corners(a, pa), corners(b, pb)
    for _, angle in ipairs({pa.t, pa.t + math.pi / 2, pb.t, pb.t + math.pi / 2}) do
        local ux, uz = math.cos(angle), -math.sin(angle)
        local amin, amax, bmin, bmax = math.huge, -math.huge, math.huge, -math.huge
        for _, p in ipairs(ac) do local q = p.x * ux + p.z * uz; amin, amax = math.min(amin, q), math.max(amax, q) end
        for _, p in ipairs(bc) do local q = p.x * ux + p.z * uz; bmin, bmax = math.min(bmin, q), math.max(bmax, q) end
        if amax <= bmin or bmax <= amin then return false end
    end
    return true
end

--- Steady-circle lower bound, separately propagating each off-axle hitch.
--- It seeds the search; transient articulation is checked on the actual route.
function G.minimumRadius(model, minimum)
    if not finite(minimum) or minimum <= 0 then return nil end
    local function fits(radius)
        for i, link in ipairs(model.links) do
            local squared = radius * radius + link.hitch * link.hitch - link.length * link.length
            if squared <= 0 then return false end
            local nextRadius = math.sqrt(squared)
            local body = model.bodies[i + 1]
            if nextRadius < math.max(math.abs(body.left), math.abs(body.right)) + 0.5 or
                    math.atan2(link.length, nextRadius) - math.atan2(link.hitch, radius) >
                        (link.maxArticulation or G.maxArticulation) then
                return false
            end
            radius = nextRadius
        end
        return true
    end
    local low, high = minimum, minimum
    while not fits(high) and high < 100 do high = high * 1.25 end
    if not fits(high) then return nil end
    for _ = 1, 16 do
        local mid = (low + high) / 2
        if fits(mid) then high = mid else low = mid end
    end
    return high
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
    local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
    for _, bx in ipairs({body.left, body.right}) do
        for _, bz in ipairs({body.front, body.back}) do
            local x, z = position(pose, bx, bz)
            minX, minZ, maxX, maxZ = math.min(minX, x), math.min(minZ, z), math.max(maxX, x), math.max(maxZ, z)
        end
    end
    local seen = {}
    for gx = math.floor(minX / 32), math.floor(maxX / 32) do
        for gz = math.floor(minZ / 32), math.floor(maxZ / 32) do
            for _, edge in ipairs(boundary.grid[gx .. ':' .. gz] or {}) do
                if not seen[edge] then
                    if edgeTouches(body, pose, edge[1], edge[2]) then return false end
                    seen[edge] = true
                end
            end
        end
    end
    local x, z = position(pose, (body.left + body.right) / 2, (body.front + body.back) / 2)
    local key = math.floor(x / 32) .. ':' .. math.floor(z / 32)
    if boundary.cells[key] ~= nil then return boundary.cells[key] end
    local inside = CpMathUtil.isPointInPolygon(boundary.polygon, x, z)
    for _, polygon in ipairs(boundary.islands) do
        if CpMathUtil.isPointInPolygon(polygon, x, z) then inside = false end
    end
    -- A cell without a polygon edge lies wholly inside or wholly outside.
    if not boundary.grid[key] then boundary.cells[key] = inside end
    return inside
end

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
    local boundary = {polygon = polygon, islands = islands, grid = {}, cells = {}, source = source}
    local polygons = {polygon}
    for _, island in ipairs(islands) do polygons[#polygons + 1] = island end
    for _, points in ipairs(polygons) do
        for i, a in ipairs(points) do
            local b = points[i % #points + 1]
            local edge = {a, b}
            for gx = math.floor(math.min(a.x, b.x) / 32), math.floor(math.max(a.x, b.x) / 32) do
                for gz = math.floor(math.min(a.z, b.z) / 32), math.floor(math.max(a.z, b.z) / 32) do
                    local key = gx .. ':' .. gz
                    boundary.grid[key] = boundary.grid[key] or {}
                    table.insert(boundary.grid[key], edge)
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

--- Advance each trailer from its parent's hitch displacement, using a midpoint
--- integration of d(theta)/ds = lateral hitch velocity / hitch-to-axle length.
function G.advance(model, previous, root)
    local result = {root}
    for i, link in ipairs(model.links) do
        local ox, oz = position(previous[i], 0, link.hitch)
        local nx, nz = position(result[i], 0, link.hitch)
        local dx, dz, angle = nx - ox, nz - oz, previous[i + 1].t
        local mid = angle + (dx * math.cos(angle) - dz * math.sin(angle)) / link.length / 2
        angle = angle + (dx * math.cos(mid) - dz * math.sin(mid)) / link.length
        result[i + 1] = {x = nx - link.length * math.sin(angle), z = nz - link.length * math.cos(angle), t = angle}
    end
    return result
end

function G.validate(model, course, boundary, entryIx, alignmentNode, loweringDistance)
    local poses = {{x = model.root.x, z = model.root.z, t = model.root.t}}
    for i, link in ipairs(model.links) do
        local x, z = position(poses[i], 0, link.hitch)
        poses[i + 1] = {x = x - link.length * math.sin(link.heading), z = z - link.length * math.cos(link.heading), t = link.heading}
    end
    local targetHeading = heading(alignmentNode)
    local alignedAtWork = false
    local peak = 0
    local function check(ix)
        for i, pose in ipairs(poses) do
            local boundaryBody = model.bodies[i].collision or model.bodies[i]
            if not G.bodyFits(boundaryBody, pose, boundary) then
                return false, string.format('field boundary (%s, body %d, waypoint %d)',
                    boundary and boundary.source or 'unavailable', i, ix)
            end
            if i > 1 then
                local angle = math.abs(delta(poses[i - 1].t, pose.t))
                peak = math.max(peak, angle)
                if angle > (model.links[i - 1].maxArticulation or G.maxArticulation) then
                    return false, 'articulation'
                end
            end
            -- Consecutive rectangles intentionally meet at their coupling. An
            -- internal drawbar inserts a virtual body, so drill/cart clearance
            -- is checked as a non-consecutive physical pair.
            for j = 1, i - 2 do
                if G.bodiesOverlap(model.bodies[j], poses[j], model.bodies[i], pose) then
                    return false, 'implement clearance'
                end
            end
        end
        if ix > entryIx and not alignedAtWork then
            local _, _, z = worldToLocal(alignmentNode, poses[1].x, 0, poses[1].z)
            if z >= -loweringDistance then
                for _, pose in ipairs(poses) do
                    if math.abs(delta(pose.t, targetHeading)) > G.alignmentTolerance then return false, 'settling' end
                end
                alignedAtWork = true
            end
        end
        return true
    end
    local ok, reason = check(1)
    if not ok then return false, reason end
    local px, _, pz = course:getWaypointPosition(1)
    local angle = model.root.t
    for i = 2, course:getNumberOfWaypoints() do
        local x, _, z = course:getWaypointPosition(i)
        local nextAngle = course:getWaypointYRotation(i)
        local distance = math.sqrt((x - px)^2 + (z - pz)^2)
        local count = math.max(1, math.ceil(distance / G.step), math.ceil(math.abs(delta(nextAngle, angle)) / math.rad(2)))
        for j = 1, count do
            poses = G.advance(model, poses, {x = px + (x - px) * j / count,
                z = pz + (z - pz) * j / count, t = angle + delta(nextAngle, angle) * j / count})
            ok, reason = check(i)
            if not ok then return false, reason end
        end
        px, pz, angle = x, z, nextAngle
    end
    return alignedAtWork, alignedAtWork and peak or 'missing work entry'
end

--- Search a bounded set; shortest accepted candidate, not a global optimum.
function G.plan(maneuver, model, loweringDistance)
    local radius = G.minimumRadius(model, maneuver.turningRadius)
    if not radius then return nil, 'radius exceeds search limit' end
    local boundary = G.getBoundary(maneuver.vehicle)
    if (model.internalPivots or 0) > 0 and not boundary then
        return nil, 'field boundary unavailable for internal-pivot loop'
    end
    local width = math.max(maneuver.workWidth, model.width)
    local scale = 0
    for _, link in ipairs(model.links) do scale = scale + link.length end
    local best, bestLength, result = nil, math.huge, 'no candidate'
    local turnEndNode = maneuver.turnContext:getTurnEndNodeAndOffsets(maneuver.steeringLength)
    for _, radiusFactor in ipairs({1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6}) do
        for _, entryFactor in ipairs({1, 2, 3}) do
            for _, pull in ipairs({0, width / 2, width}) do
                local entry = scale * entryFactor + loweringDistance
                local candidate = Course.createFromNode(maneuver.vehicle, maneuver.vehicleDirectionNode, 0, 0, math.max(0.5, pull), 1, false)
                local path = PathfinderUtil.findAnalyticPath(PathfinderUtil.dubinsSolver,
                    maneuver.vehicleDirectionNode, 0, math.max(0.5, pull) + 0.5, turnEndNode, 0, -entry, radius * radiusFactor)
                if path and #path > 1 then
                    candidate:append(Course.createFromAnalyticPath(maneuver.vehicle, path, true))
                    local entryIx = candidate:getNumberOfWaypoints()
                    local ending = maneuver.turnContext:appendEndingTurnCourse(candidate, maneuver.steeringLength)
                    if candidate:getLength() < bestLength then
                        local ok, detail = G.validate(model, candidate, boundary, entryIx,
                            maneuver.turnContext.vehicleAtTurnEndNode, loweringDistance)
                        if ok then
                            TurnManeuver.setLowerImplements(candidate, ending, true)
                            best, bestLength = candidate, candidate:getLength()
                            result = string.format('%d pivots (%d internal), width %.1f m, radius %.1f m, entry %.1f m, peak angle %.1f deg, articulation clearance checked, boundary %s',
                                #model.links, model.internalPivots or 0, width, radius * radiusFactor, entry,
                                math.deg(detail), boundary and boundary.source or 'unavailable')
                        elseif not best then result = detail end
                    end
                end
            end
        end
    end
    return best, result
end
