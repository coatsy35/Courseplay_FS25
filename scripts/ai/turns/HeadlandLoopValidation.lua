--[[
Headland loop: sampled chain validation
Integrate every pivot and check every body. A candidate is accepted only after its complete return passes.
]]

local G = HeadlandLoopGeometry
local heading = G.math.heading
local delta, position = G.math.delta, G.math.position

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

--- Retain the interpolation state between frames. Sample count and angle spacing
--- stay fixed, so yielding affects responsiveness rather than acceptance criteria.
function G.createValidator(model, course, boundary, entryIx, alignmentNode, loweringDistance, workStartNode)
    local poses = {{x = model.root.x, z = model.root.z, t = model.root.t}}
    for i, link in ipairs(model.links) do
        local x, z = position(poses[i], 0, link.hitch)
        poses[i + 1] = {x = x - link.length * math.sin(link.heading), z = z - link.length * math.cos(link.heading), t = link.heading}
    end
    local targetHeading = heading(alignmentNode)
    local alignedAtWork = false
    local entryLateral = 0
    local peak = 0
    -- Field containment, articulation and physical clearance are independent
    -- requirements. A narrow chassis does not replace the wide work-area check.
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
        if ix > entryIx and not alignedAtWork then
            local _, _, z = worldToLocal(alignmentNode, poses[1].x, 0, poses[1].z)
            if z >= -loweringDistance then
                -- Reaching the outgoing line is not the same as completing
                -- trailer settling. Keep validating the straight return.
                alignedAtWork = true
            end
        end
        return true
    end
    local ok, reason = check(1)
    local px, _, pz = course:getWaypointPosition(1)
    local angle = model.root.t
    local i, j, count, x, z, nextAngle = 2, 0
    return {step = function(_, budget)
        if not ok then return true, false, reason end
        for _ = 1, budget do
            if i > course:getNumberOfWaypoints() then
                -- A curved fieldwork return is already checked point by point;
                -- only a straight return must settle to the original tangent.
                if not course.followsFieldwork then
                    for _, pose in ipairs(poses) do
                        if math.abs(delta(pose.t, targetHeading)) > G.alignmentTolerance then
                            return true, false, 'cart still settling at end of straight'
                        end
                    end
                end
                return true, alignedAtWork, (alignedAtWork) and peak or 'missing work entry',
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
            poses = G.advance(model, poses, root)
            ok, reason = check(i)
            if not ok then return true, false, reason end
            if j == count then
                if i == entryIx and workStartNode then
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
                px, pz, angle, i, j = x, z, nextAngle, i + 1, 0
            end
        end
        return false
    end}
end

--- Synchronous wrapper for short live continuations and offline qualification.
--- Full loop searches use the incremental validator directly.
function G.validate(model, course, boundary, entryIx, alignmentNode, loweringDistance)
    local validator = G.createValidator(model, course, boundary, entryIx, alignmentNode, loweringDistance)
    while true do
        local done, ok, detail = validator:step(64)
        if done then return ok, detail end
    end
end

