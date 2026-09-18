--- Geometry estimates for forward headland loops. Each wheeled attachment has
--- its own effective axle and hitch; this is a planar, no-slip planning model,
--- not a measurement of collision shapes or a simulation of GIANTS physics.
HeadlandLoopGeometry = {}
local G = HeadlandLoopGeometry
G.maxArticulation = math.rad(45)
G.alignmentTolerance = math.rad(5)
-- Leave a margin between the predicted settling point and the live handover.
-- The passive drawbar approximation settles faster than the captured cart.
G.plannedAlignmentTolerance = math.rad(2)
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
    local workArea = {left = -math.huge, right = math.huge, front = -math.huge, back = math.huge}
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
                body.working = true
                local x, _, z = localToLocal(marker, node, 0, 0, 0)
                include(body, x, z)
                include(workArea, x, z)
            end
        end
    end
    for _, key in ipairs({'left', 'right', 'front', 'back'}) do
        if not finite(body[key]) or not finite(declared[key]) then return nil end
    end
    -- Working markers protect the field boundary, while declared dimensions
    -- provide the less misleading solid-body rectangle for implement clearance.
    body.collision = declared
    body.workArea = body.working and workArea or nil
    return body
end

local function addLink(model, link, body, includeWidth)
    model.links[#model.links + 1] = link
    model.bodies[#model.bodies + 1] = body
    if includeWidth ~= false then model.width = math.max(model.width, body.left - body.right) end
end

--- Prefer the coupling limits GIANTS has already combined for this attachment.
--- If those are unavailable, use its output joint and input-joint scale (the
--- same yaw convention as AIVehicleUtil). An internal drawbar has a separate
--- limit: it must not be copied onto the implement's external hitch.
function G.getHitchLimit(parent, attachment, inputJoint)
    local lower = attachment.lowerRotLimit and attachment.lowerRotLimit[2]
    local upper = attachment.upperRotLimit and attachment.upperRotLimit[2]
    if not finite(lower) or not finite(upper) then
        local joint = parent.getAttacherJointDescFromObject and parent:getAttacherJointDescFromObject(attachment.object)
        local scale = inputJoint.lowerRotLimitScale and inputJoint.lowerRotLimitScale[2]
        if joint and joint.lowerRotLimit and joint.upperRotLimit and finite(scale) then
            lower, upper = joint.lowerRotLimit[2], joint.upperRotLimit[2]
            if finite(lower) and finite(upper) then
                lower, upper = lower * scale, upper * scale
            end
        end
    end
    if finite(lower) and finite(upper) then
        return math.min(math.rad(85), math.max(math.abs(lower), math.abs(upper)))
    end
    return G.maxArticulation
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
    local pivot, yawLimit
    for i, limit in ipairs(limits or {}) do
        if math.abs(limit[2] or 0) > math.rad(5) then
            if pivot then return nil end
            pivot = nodes and nodes[i]
            yawLimit = math.abs(limit[2])
        end
    end
    if not pivot or pivot == 0 then return nil end
    local hx, _, hz = localToLocal(joint.node, joint.rootNode, 0, 0, 0)
    local px, _, pz = localToLocal(pivot, joint.rootNode, 0, 0, 0)
    local drawbarLength = hz - pz
    local ax, _, axleLength = localToLocal(pivot, axle, 0, 0, 0)
    if not finite(drawbarLength) or not finite(axleLength) or drawbarLength < 0.5 or
            axleLength < 0.5 or math.abs(hx - px) > 0.25 or math.abs(ax) > 0.25 then return nil end
    return pivot, drawbarLength, axleLength, yawLimit
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
        local hitchLimit = G.getHitchLimit(parent, attachments[1], joint)
        if hitchLimit < math.rad(5) then return nil, 'locked towing hitch' end
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
            local pivot, drawbarLength, axleLength, yawLimit = getInternalDrawbar(object, joint, axle)
            if not pivot then return nil, 'unsupported internal yaw geometry' end
            local drawbarBody = {left = 0.75, right = -0.75,
                front = drawbarLength + 0.25, back = -0.25, virtual = true}
            addLink(model, {length = drawbarLength, hitch = hitch,
                heading = heading(joint.rootNode), node = joint.rootNode, positionNode = pivot, internal = true,
                maxArticulation = hitchLimit}, drawbarBody, false)
            addLink(model, {length = axleLength, hitch = 0,
                heading = heading(axle), node = axle, internal = true,
                maxArticulation = yawLimit}, body)
            model.internalPivots = (model.internalPivots or 0) + 1
        else
            local lx, _, length = localToLocal(joint.node, axle, 0, 0, 0)
            if not finite(length) or length < 0.5 or math.abs(lx) > 0.25 then
                return nil, 'off-centre, front-mounted or invalid hitch geometry'
            end
            addLink(model, {length = length, hitch = hitch, heading = heading(axle), node = axle, maxArticulation = hitchLimit}, body)
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

--- Steady-circle lower bound, separately propagating each off-axle hitch.
--- It seeds the search; transient articulation is checked on the actual route.
function G.minimumRadius(model, minimum)
    if not finite(minimum) or minimum <= 0 then return nil end
    local function fits(radius)
        for i, link in ipairs(model.links) do
            local squared = radius * radius + link.hitch * link.hitch - link.length * link.length
            if squared <= 0 then return false end
            local nextRadius = math.sqrt(squared)
            if math.atan2(link.length, nextRadius) - math.atan2(link.hitch, radius) >
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
    local x, z = centreX, centreZ
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

function G.createValidator(model, course, boundary, entryIx, alignmentNode, loweringDistance, rootOnly, workStartNode, stopWhenSettled)
    local poses = {{x = model.root.x, z = model.root.z, t = model.root.t}}
    for i, link in ipairs(model.links) do
        local x, z = position(poses[i], 0, link.hitch)
        poses[i + 1] = {x = x - link.length * math.sin(link.heading), z = z - link.length * math.cos(link.heading), t = link.heading}
    end
    local targetHeading = heading(alignmentNode)
    local alignedAtWork = false
    local settledIx, entryLateral = nil, 0
    local peak = 0
    local function check(ix)
        for i, pose in ipairs(poses) do
            local boundaryBody = model.bodies[i]
            if not G.bodyFits(boundaryBody, pose, boundary) then
                return false, string.format('field boundary (%s, body %d, waypoint %d, x %.1f z %.1f)',
                    boundary and boundary.source or 'unavailable', i, ix, pose.x, pose.z)
            end
            if i > 1 then
                local angle = math.abs(delta(poses[i - 1].t, pose.t))
                peak = math.max(peak, angle)
                if angle > (model.links[i - 1].maxArticulation or G.maxArticulation) then
                    return false, 'articulation'
                end
            end
            -- The clearance rectangles exclude the coupling ends, so adjacent
            -- physical bodies can be checked too; virtual drawbars are ignored.
            for j = 1, i - 1 do
                if G.bodiesOverlap(model.bodies[j], poses[j], model.bodies[i], pose) then
                    return false, 'implement clearance'
                end
            end
        end
        if not rootOnly and ix > entryIx and not alignedAtWork then
            local _, _, z = worldToLocal(alignmentNode, poses[1].x, 0, poses[1].z)
            if z >= -loweringDistance then
                -- Reaching the outgoing line is not the same as completing
                -- trailer settling. Keep validating the straight return.
                alignedAtWork = true
            end
        end
        return true
    end
    if rootOnly then poses = {poses[1]} end
    local ok, reason = check(1)
    local px, _, pz = course:getWaypointPosition(1)
    local angle = model.root.t
    local i, j, count, x, z, nextAngle = 2, 0
    return {step = function(_, budget)
        if not ok then return true, false, reason end
        for _ = 1, budget do
            if rootOnly and i > entryIx then return true, true, 0 end
            if i > course:getNumberOfWaypoints() then
                if not rootOnly then
                    for _, pose in ipairs(poses) do
                        if math.abs(delta(pose.t, targetHeading)) > G.alignmentTolerance then
                            return true, false, 'cart still settling at end of straight'
                        end
                    end
                end
                return true, rootOnly or alignedAtWork, (rootOnly or alignedAtWork) and peak or 'missing work entry',
                    {endIx = course:getNumberOfWaypoints(), entryLateral = entryLateral}
            end
            if j == 0 then
                x, _, z = course:getWaypointPosition(i)
                nextAngle = course:getWaypointYRotation(i)
                local distance = math.sqrt((x - px)^2 + (z - pz)^2)
                count = math.max(1, math.ceil(distance / G.step), math.ceil(math.abs(delta(nextAngle, angle)) / math.rad(2)))
            end
            j = j + 1
            local root = {x = px + (x - px) * j / count,
                z = pz + (z - pz) * j / count, t = angle + delta(nextAngle, angle) * j / count}
            poses = rootOnly and {root} or G.advance(model, poses, root)
            ok, reason = check(i)
            if not ok then return true, false, reason end
            if j == count then
                if not rootOnly and i == entryIx and workStartNode then
                    for bodyIndex, body in ipairs(model.bodies) do
                        if body.workArea then
                            local area = body.workArea
                            local wx, wz = position(poses[bodyIndex], (area.left + area.right) / 2, area.front)
                            local lx, _, lz = worldToLocal(workStartNode, wx, 0, wz)
                            -- Match WorkStartHandler: use the leading marker
                            -- when aligned, otherwise the two markers' average.
                            if math.abs(delta(poses[bodyIndex].t, targetHeading)) < math.rad(15) then
                                lz = lz + math.abs(math.sin(delta(poses[bodyIndex].t, targetHeading))) * (area.left - area.right) / 2
                            end
                            if lz > -loweringDistance then return true, false, 'late work entry' end
                            if math.abs(lx) > (area.left - area.right) / 4 then
                                return true, false, 'working implement misses return corridor'
                            end
                            entryLateral = math.max(entryLateral, math.abs(lx))
                        end
                    end
                end
                if not rootOnly and alignedAtWork then
                    local aligned = true
                    for _, pose in ipairs(poses) do
                        aligned = aligned and math.abs(delta(pose.t, targetHeading)) <= G.plannedAlignmentTolerance
                    end
                    settledIx = aligned and (settledIx or i) or nil
                    -- Validate another five metres as a tracking reserve. All
                    -- return waypoints are one metre apart.
                    if stopWhenSettled and settledIx and i >= settledIx + 5 then
                        return true, true, peak, {endIx = i, entryLateral = entryLateral}
                    end
                end
                px, pz, angle, i, j = x, z, nextAngle, i + 1, 0
            end
        end
        return false
    end}
end

function G.isOnReturn(vehicle, returnPose)
    local node = vehicle:getAIDirectionNode()
    local x, _, z = getWorldTranslation(node)
    local along = (x - returnPose.x) * math.sin(returnPose.t) + (z - returnPose.z) * math.cos(returnPose.t)
    return along >= -.5 and math.abs(delta(heading(node), returnPose.t)) <= G.alignmentTolerance
end

function G.matchesStart(vehicle, model)
    local node = vehicle:getAIDirectionNode()
    local x, _, z = getWorldTranslation(node)
    if (x - model.root.x)^2 + (z - model.root.z)^2 > .25^2 or
            math.abs(delta(heading(node), model.root.t)) > math.rad(2) then return false end
    for _, link in ipairs(model.links) do
        if link.node and math.abs(delta(heading(link.node), link.heading)) > math.rad(2) then return false end
    end
    return true
end

--- Check the live chain before handing control back to the fieldwork course.
--- No geometry is re-detected while the joints are moving: their measured
--- headings, including the cart's drawbar, are sufficient for this check.
function G.isAligned(vehicle, targetNode)
    local target = heading(targetNode)
    local object, seen = vehicle, {}
    while object do
        if seen[object] then return false end
        seen[object] = true
        local node = object == vehicle and vehicle:getAIDirectionNode() or object.steeringAxleNode
        if not node then return false, 'missing axle node' end
        local error = math.deg(math.abs(delta(heading(node), target)))
        if error > math.deg(G.alignmentTolerance) then
            return false, string.format('%s axle %.1f degrees', CpUtil.getName(object), error)
        end
        local joint = object.getActiveInputAttacherJoint and object:getActiveInputAttacherJoint()
        if joint and joint.rootNode then
            local error = math.deg(math.abs(delta(heading(joint.rootNode), target)))
            if error > math.deg(G.alignmentTolerance) then
                return false, string.format('%s drawbar %.1f degrees', CpUtil.getName(object), error)
            end
        end
        local children = object.getAttachedImplements and object:getAttachedImplements() or {}
        if #children > 1 then return false end
        object = children[1] and children[1].object
    end
    return true
end

--- Resolve the continuation by physical distance along the checked return,
--- not a fixed number of fieldwork waypoints. Never search across another turn.
--- The second result says the fieldwork line covers the entire settling reserve.
function G.getContinuation(vehicle, course, ix, turnCourse)
    if not course or not turnCourse or not turnCourse.chainReturn then return nil, false end
    local r = turnCourse.chainReturn
    local ex, _, ez = turnCourse:getWaypointPosition(turnCourse:getNumberOfWaypoints())
    local endDistance = (ex - r.x) * math.sin(r.t) + (ez - r.z) * math.cos(r.t)
    local node, nextIx = vehicle:getAIDirectionNode(), nil
    local tolerance = r.model and r.model.width / 4 or .5
    local previousAlong = -math.huge
    for i = ix, course:getNumberOfWaypoints() do
        if course:isTurnStartAtIx(i) or course:isReverseAt(i) then return nextIx, false end
        local x, y, z = course:getWaypointPosition(i)
        local side = (x - r.x) * math.cos(r.t) - (z - r.z) * math.sin(r.t)
        local along = (x - r.x) * math.sin(r.t) + (z - r.z) * math.cos(r.t)
        if along < previousAlong or math.abs(side) > tolerance or math.abs(delta(course:getWaypointYRotation(i), r.t)) > math.rad(15) then
            return nextIx, false
        end
        previousAlong = along
        local dx, _, dz = worldToLocal(node, x, y, z)
        if not nextIx and dz > 1 and math.abs(dx) < tolerance and along <= endDistance + .5 then nextIx = i end
        if along >= endDistance then return nextIx, nextIx ~= nil, i end
    end
    return nextIx, false
end

--- Cart alignment need not delay working on the very same validated straight.
--- Require its full reserve to exist on the fieldwork course, and verify actual
--- physical positions, hitch limits and working-body headings before handover.
function G.canContinueOnCheckedRow(vehicle, course, ix, turnCourse)
    local r = turnCourse and turnCourse.chainReturn
    if not r or not r.model or not r.boundary then return false, 'missing model' end
    local nextIx, covered, lastIx = G.getContinuation(vehicle, course, ix, turnCourse)
    if not nextIx or not covered or not G.isOnReturn(vehicle, r) then return false, 'continuation corridor' end
    local model, poses = r.model, {}
    local node = vehicle:getAIDirectionNode()
    local x, _, z = getWorldTranslation(node)
    poses[1] = {x = x, z = z, t = heading(node)}
    for i, link in ipairs(model.links) do
        local x, _, z = getWorldTranslation(link.positionNode or link.node)
        poses[i + 1] = {x = x, z = z, t = heading(link.node)}
    end
    for i, pose in ipairs(poses) do
        local body = model.bodies[i]
        if body.working and math.abs(delta(pose.t, r.t)) > G.alignmentTolerance then return false, 'working body heading' end
        if i > 1 and math.abs(delta(pose.t, poses[i - 1].t)) >
                (model.links[i - 1].maxArticulation or G.maxArticulation) then return false, 'live articulation' end
        if not G.bodyFits(body, pose, r.boundary) then return false, 'live field boundary' end
        for j = 1, i - 1 do
            if G.bodiesOverlap(model.bodies[j], poses[j], body, pose) then return false, 'live clearance' end
        end
    end
    -- The real headland can bend slightly within that corridor. Validate its
    -- actual points from the measured current pose, rather than assuming it is
    -- identical to the temporary straight. The distance is bounded by the
    -- reserved return and the search above cannot cross another corner.
    local live = {root = poses[1], bodies = model.bodies, links = {}}
    for i, link in ipairs(model.links) do
        live.links[i] = table.clone(link)
        live.links[i].heading = poses[i + 1].t
    end
    local path = {}
    for i = nextIx, lastIx do
        local x, _, z = course:getWaypointPosition(i)
        path[#path + 1] = {x = x, y = -z}
    end
    local continuation = G.createCandidate(node, .5, path)
    return G.validate(live, continuation, r.boundary, 1, node, 0)
end

function G.validate(model, course, boundary, entryIx, alignmentNode, loweringDistance)
    local validator = G.createValidator(model, course, boundary, entryIx, alignmentNode, loweringDistance)
    while true do
        local done, ok, detail = validator:step(64)
        if done then return ok, detail end
    end
end

--- Cheaply reject a tractor path which crosses the field edge before running
--- the articulated-chain integration. This is especially useful when several
--- alternative Dubins words are being compared at a tight field corner.
function G.rootCourseFits(model, course, boundary)
    if not boundary then return true end
    local body = model.bodies[1].collision or model.bodies[1]
    local previous = {x = model.root.x, z = model.root.z, t = model.root.t}
    if not G.bodyFits(body, previous, boundary) then return false end
    for i = 1, course:getNumberOfWaypoints() do
        local x, _, z = course:getWaypointPosition(i)
        local pose = {x = x, z = z, t = course:getWaypointYRotation(i)}
        local distance = math.sqrt((x - previous.x)^2 + (z - previous.z)^2)
        local count = math.max(1, math.ceil(distance / G.step),
            math.ceil(math.abs(delta(pose.t, previous.t)) / math.rad(2)))
        for j = 1, count do
            local sample = {x = previous.x + (x - previous.x) * j / count,
                z = previous.z + (z - previous.z) * j / count,
                t = previous.t + delta(pose.t, previous.t) * j / count}
            if not G.bodyFits(body, sample, boundary) then return false end
        end
        previous = pose
    end
    return true
end

--- Planning needs positions and tangents, not the fieldwork metadata, terrain
--- queries and debug output built by Course for every rejected candidate.
function G.createCandidate(node, pull, path)
    local points = {}
    local segments = math.max(1, math.floor(pull))
    for i = 0, segments do
        local x, _, z = localToWorld(node, 0, 0, pull * i / segments)
        points[#points + 1] = {x = x, z = z}
    end
    for _, p in ipairs(path) do points[#points + 1] = {x = p.x, z = -p.y} end
    local candidate = {waypoints = points}
    function candidate:getNumberOfWaypoints() return #self.waypoints end
    function candidate:getWaypointPosition(ix)
        local p = self.waypoints[ix]
        return p.x, 0, p.z
    end
    function candidate:getWaypointYRotation(ix)
        ix = math.max(1, math.min(ix, #self.waypoints - 1))
        local a, b = self.waypoints[ix], self.waypoints[ix + 1]
        if math.abs(b.x - a.x) + math.abs(b.z - a.z) < .00001 then
            return self:getWaypointYRotation(ix > 1 and ix - 1 or ix + 1)
        end
        return math.atan2(b.x - a.x, b.z - a.z)
    end
    function candidate:getWaypointLocalPosition(reference, ix)
        local x, y, z = self:getWaypointPosition(ix)
        return worldToLocal(reference, x, y, z)
    end
    function candidate:getLength()
        local length = 0
        for ix = 2, #self.waypoints do
            local a, b = self.waypoints[ix - 1], self.waypoints[ix]
            length = length + math.sqrt((a.x - b.x)^2 + (a.z - b.z)^2)
        end
        return length
    end
    function candidate:appendWaypoints(waypoints)
        for _, p in ipairs(waypoints) do self.waypoints[#self.waypoints + 1] = p end
    end
    return candidate
end

--- Incremental search. GIANTS does not provide Lua coroutines: retain explicit
--- state and bound both candidate preparation and sampled validation per update.
function G.createSearch(maneuver, model, loweringDistance)
    local search = {done = false, phase = 'preparing', candidates = {}, tested = 0, rejected = {}, model = model}
    local steadyRadius = G.minimumRadius(model, maneuver.turningRadius)
    local boundary = G.getBoundary(maneuver.vehicle)
    if not steadyRadius or ((model.internalPivots or 0) > 0 and not boundary) then
        search.done = true
        search.reason = not steadyRadius and 'radius exceeds search limit' or 'field boundary unavailable for internal-pivot loop'
    end
    if boundary and not G.bodyFits(model.bodies[1], model.root, boundary) then
        search.done = true
        search.reason = string.format('tractor starts outside %s boundary at x %.1f z %.1f',
            boundary.source, model.root.x, model.root.z)
    end
    local width = math.max(maneuver.workWidth, model.width)
    local scale, chainLength = 0, 0
    for _, link in ipairs(model.links) do
        scale = scale + link.length
        chainLength = chainLength + link.length - link.hitch
    end
    local radii, seenRadius = {}, {}
    local function addRadius(radius)
        local key = math.floor(radius * 100 + 0.5)
        if not seenRadius[key] then radii[#radii + 1], seenRadius[key] = radius, true end
    end
    addRadius(maneuver.turningRadius)
    if steadyRadius then
        for _, factor in ipairs({1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6}) do addRadius(steadyRadius * factor) end
        -- Refine practical radii instead of jumping directly to very large loops.
        for r = maneuver.turningRadius + 2, math.max(steadyRadius * 2, maneuver.turningRadius + 10), 2 do addRadius(r) end
    end
    table.sort(radii)
    local entries, pulls = {}, {0, width / 4, width / 2, width}
    -- The target node belongs to the work area, not the tractor. A rear drill
    -- can still be before that line when the tractor has already crossed it.
    -- Validate the predicted working markers at the actual end of the curve.
    local ahead = math.max(0, -(maneuver.turnContext.frontMarkerDistance or 0) - loweringDistance)
    local seenEntry = {}
    local function addEntry(entry)
        local key = math.floor(entry * 4 + .5)
        if not seenEntry[key] then entries[#entries + 1], seenEntry[key] = entry, true end
    end
    for fraction = 1, 8 do addEntry(-ahead * fraction / 8) end
    for _, factor in ipairs({0, .25, .5, 1, 2, 3}) do addEntry(scale * factor + loweringDistance) end
    local solvers = {}
    for pathType = DubinsSolver.PathType.LSL, DubinsSolver.PathType.LRL do
        solvers[#solvers + 1] = {solver = DubinsSolver({pathType}), name = tostring(pathType)}
    end
    local turnEndNode = maneuver.turnContext:getTurnEndNodeAndOffsets(maneuver.steeringLength)
    local gx, _, gz = getWorldTranslation(turnEndNode)
    Logging.info('[CP headland loop] search pose x %.2f z %.2f heading %.2f; target x %.2f z %.2f heading %.2f; boundary %s (%d vertices)',
        model.root.x, model.root.z, math.deg(model.root.t), gx, gz, math.deg(heading(turnEndNode)),
        boundary and boundary.source or 'unavailable', boundary and #boundary.polygon or 0)
    for i, link in ipairs(model.links) do
        local body = model.bodies[i + 1]
        Logging.info('[CP headland loop] link %d: hitch %.2f length %.2f heading %.2f limit %.2f; body left %.2f right %.2f front %.2f back %.2f',
            i, link.hitch, link.length, math.deg(link.heading), math.deg(link.maxArticulation or G.maxArticulation),
            body.left, body.right, body.front, body.back)
    end
    local ri, ei, pi, si, candidateIx = 1, 1, 1, 1, 1
    local prepared = false
    local function nextDescriptor()
        local radius, entry, pull = radii[ri], entries[ei], math.max(.5, pulls[pi])
        local solver = solvers[si]
        local x, z, t = PathfinderUtil.getNodePositionAndDirection(maneuver.vehicleDirectionNode, 0, pull + .5)
        local start = State3D(x, -z, CpMathUtil.angleFromGame(t))
        x, z, t = PathfinderUtil.getNodePositionAndDirection(turnEndNode, 0, -entry)
        local goal = State3D(x, -z, CpMathUtil.angleFromGame(t))
        local solution = solver.solver:solve(start, goal, radius)
        if solution then
            local length = solution:getLength(radius)
            if length < 100000 then
                search.candidates[#search.candidates + 1] = {solution = solution, start = start, radius = radius,
                    entry = entry, pull = pull, name = solver.name, score = length + pull + entry}
            end
        end
        si = si + 1
        if si > #solvers then si, pi = 1, pi + 1 end
        if pi > #pulls then pi, ei = 1, ei + 1 end
        if ei > #entries then ei, ri = 1, ri + 1 end
        return ri > #radii
    end
    local function reject(detail)
        local category = string.match(detail, '^[^(]+') or detail
        search.rejected[category] = (search.rejected[category] or 0) + 1
        search.lastRejection = detail
        -- Keep the shortest rejected route's location, not a huge loop's edge.
        search.firstRejection = search.firstRejection or detail
    end
    function search:step()
        if self.done then return true, self.course, self.reason end
        if not prepared then
            for _ = 1, 16 do
                if nextDescriptor() then
                    table.sort(self.candidates, function(a, b) return a.score < b.score end)
                    prepared = true
                    self.phase = 'validating'
                    break
                end
            end
            return false
        end
        if self.validator then
            local done, ok, detail, returnData = self.validator:step(32)
            if not done then return false end
            self.validator = nil
            if ok then
                local points = {}
                for ix = 1, returnData and returnData.endIx or self.pending:getNumberOfWaypoints() do
                    points[#points + 1] = self.pending.waypoints[ix]
                end
                self.pending = Course(maneuver.vehicle, points, true)
                self.pending.temporary = true
                for ix = self.entryIx, self.pending:getNumberOfWaypoints() do
                    TurnManeuver.addTurnControlToWaypoint(self.pending.waypoints[ix], TurnManeuver.LOWER_IMPLEMENT_AT_TURN_END, true)
                end
                local x, _, z = self.pending:getWaypointPosition(self.entryIx)
                self.pending.chainReturn = {x = x, z = z, t = heading(maneuver.turnContext.vehicleAtTurnEndNode),
                    lateralTolerance = (returnData and returnData.entryLateral or 0) + .5, model = model, boundary = boundary}
                -- Descriptors are ordered by route length, so stop at the first
                -- validated solution. This is a bounded search, not a global optimum.
                self.course = self.pending
                self.reason = string.format('%d pivots (%d internal), width %.1f m, radius %.1f m, entry %.1f m, Dubins %s, peak angle %.1f deg, boundary %s, %d candidates tested',
                    #model.links, model.internalPivots or 0, width, self.option.radius, self.option.entry,
                    self.option.name, math.deg(detail), boundary and boundary.source or 'unavailable', self.tested)
                self.done = true
                return true, self.course, self.reason
            end
            reject(detail)
            self.pending = nil
            return false
        end
        local option = self.candidates[candidateIx]
        if not option then
            self.done = true
            local counts = {}
            for category, count in pairs(self.rejected) do counts[#counts + 1] = string.format('%s=%d', category, count) end
            table.sort(counts)
            self.reason = string.format('no fitting candidate (%d tested; %s); shortest rejected: %s; last: %s',
                self.tested, table.concat(counts, ', '), self.firstRejection or 'none', self.lastRejection or 'none')
            return true, nil, self.reason
        end
        candidateIx = candidateIx + 1
        self.tested = self.tested + 1
        self.option = option
        local path = option.solution:getWaypoints(option.start, option.radius)
        if not path or #path < 2 then reject('empty analytic path'); return false end
        -- Reject obvious excursions before allocating/enriching several Course
        -- copies. Passing this coarse check never accepts a route: the complete
        -- chain, including the tractor, is still sampled at 0.5 m below.
        if boundary then
            local count = math.min(32, #path)
            for j = 1, count do
                local point = path[1 + math.floor((j - 1) * (#path - 1) / (count - 1))]
                local pose = {x = point.x, z = -point.y, t = CpMathUtil.angleToGame(point.t)}
                if not G.bodyFits(model.bodies[1], pose, boundary) then
                    reject(string.format('field boundary (tractor curve, x %.1f z %.1f)', pose.x, pose.z))
                    return false
                end
            end
        end
        local candidate = G.createCandidate(maneuver.vehicleDirectionNode, option.pull, path)
        self.entryIx = candidate:getNumberOfWaypoints()
        self.ending = maneuver.turnContext:appendEndingTurnCourse(candidate, 2 * chainLength)
        self.pending = candidate
        self.validator = G.createValidator(model, candidate, boundary, self.entryIx,
            maneuver.turnContext.vehicleAtTurnEndNode, loweringDistance, false, maneuver.turnContext.workStartNode, false)
        return false
    end
    return search
end

--- Synchronous entry point for offline qualification. Runtime uses step().
function G.plan(maneuver, model, loweringDistance)
    local search = G.createSearch(maneuver, model, loweringDistance)
    while true do
        local done, course, reason = search:step()
        if done then return course, reason end
    end
end
