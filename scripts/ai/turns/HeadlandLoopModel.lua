--[[
Headland loop: implement model
Measure each coupling once while stopped. Width, physical body and working area have different purposes.
]]

local G = HeadlandLoopGeometry
local finite, heading = G.math.finite, G.math.heading

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
