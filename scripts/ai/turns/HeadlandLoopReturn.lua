--[[
Headland loop: return and fieldwork handover
Keep lowering, live alignment and continuation separate: a curved row is not the original corner tangent.
]]

local G = HeadlandLoopGeometry
local heading, delta = G.math.heading, G.math.delta

--- Wait for the tractor itself to reach the return; PPC lookahead alone is too early.
function G.isOnReturn(vehicle, returnPose)
    local node = vehicle:getAIDirectionNode()
    local x, _, z = getWorldTranslation(node)
    local along = (x - returnPose.x) * math.sin(returnPose.t) + (z - returnPose.z) * math.cos(returnPose.t)
    return along >= -.5 and math.abs(delta(heading(node), returnPose.t)) <= G.alignmentTolerance
end

--- Discard a search if braking or hitch movement invalidates its frozen initial pose.
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
    if r.fieldCourse == course then
        local node = vehicle:getAIDirectionNode()
        for i = ix, r.fieldEndIx do
            if course:isTurnStartAtIx(i) or course:isReverseAt(i) then return nil, false end
            local x, y, z = course:getWaypointPosition(i)
            local dx, _, dz = worldToLocal(node, x, y, z)
            if dz > 1 and math.abs(dx) < r.model.width / 4 then return i, true, r.fieldEndIx end
        end
        return nil, false
    end
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

--- Permit an early handover only when the remaining fieldwork course covers the
--- checked return. Verify live body positions and hitch angles before simulating
--- that continuation; the original straight-return fallback also needs alignment.
function G.canContinueOnCheckedRow(vehicle, course, ix, turnCourse)
    local r = turnCourse and turnCourse.chainReturn
    if not r or not r.model or not r.boundary then return false, 'missing model' end
    local nextIx, covered, lastIx = G.getContinuation(vehicle, course, ix, turnCourse)
    if not nextIx or not covered or (not r.fieldCourse and not G.isOnReturn(vehicle, r)) then return false, 'continuation corridor' end
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
        if not r.fieldCourse and body.working and math.abs(delta(pose.t, r.t)) > G.alignmentTolerance then return false, 'working body heading' end
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
    continuation.followsFieldwork = r.fieldCourse ~= nil
    return G.validate(live, continuation, r.boundary, 1, node, 0)
end

--- One decision for CourseTurn: retain the checked return until the real
--- fieldwork course can take over. Ordinary turns keep their existing behaviour.
function G.canResumeFieldwork(vehicle, fieldCourse, turnContext, turnCourse)
    local r = turnCourse and turnCourse.chainReturn
    if not r then return true end
    if not r.fieldCourse and G.isAligned(vehicle, turnContext.vehicleAtTurnEndNode) then return true end
    return G.canContinueOnCheckedRow(vehicle, fieldCourse, turnContext.turnEndWpIx, turnCourse)
end
