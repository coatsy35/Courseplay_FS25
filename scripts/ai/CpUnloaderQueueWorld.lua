-- Engine boundary for queue movement. Native unloading never uses these limits.
CpUnloaderQueueWorld = {}
local W = CpUnloaderQueueWorld
local G = CpUnloaderQueueGeometry
local H = HeadlandLoopGeometry

local function distanceToSegment(p,a,b)
    local dx,dz=b.x-a.x,b.z-a.z
    local f=math.max(0,math.min(1,((p.x-a.x)*dx+(p.z-a.z)*dz)/math.max(0.001,dx*dx+dz*dz)))
    local q={x=a.x+f*dx,z=a.z+f*dz}
    return math.sqrt((p.x-q.x)^2+(p.z-q.z)^2),q
end

local function entryGate(strategy,model,boundary)
    local operation=strategy.queueData and strategy.queueData.operation
    if operation~='prepare' and operation~='yield' then return nil,'not preparing or yielding' end
    local start=model.root
    local outside=false
    local poses=W.poses(model)
    for i,body in ipairs(model.bodies) do
        if not G.within(W.rectangle(body,poses[i]),boundary.polygon,boundary.islands) then outside=true end
    end
    if not outside then return nil,'whole train inside field' end
    -- Preparation and priority clearance start from the actual rig, not the AD return marker. A
    -- waiting queue may extend along the verge or arrive without that marker.
    -- Only a bounded connection to this field is admitted; every swept body
    -- still has to pass crop, island, obstacle and articulation checks.
    local width=math.max(15,2*strategy.turningRadius)
    local length=AIUtil.getLength(strategy.vehicle)
    local nearest,entry
    for i,a in ipairs(boundary.polygon) do
        local d,p=distanceToSegment(start,a,boundary.polygon[i%#boundary.polygon+1])
        if not nearest or d<nearest then nearest,entry=d,p end
    end
    if nearest and nearest<=100 then
        return {start=start,entry=entry,width=width+length},'bounded entrance available'
    end
    return nil,nearest and string.format('field edge %.1f m away (limit 100 m)',nearest) or 'no field edge'
end

local function inEntrance(world,rectangle)
    if not world.entrance then return false end
    for i,a in ipairs(rectangle) do
        local b=rectangle[i%#rectangle+1]
        local count=math.max(1,math.ceil(math.sqrt((b.x-a.x)^2+(b.z-a.z)^2)))
        for j=0,count do
            local p={x=a.x+(b.x-a.x)*j/count,z=a.z+(b.z-a.z)*j/count}
            if not G.inside(world.boundary.polygon,p) and
                    distanceToSegment(p,world.entrance.start,world.entrance.entry)>world.entrance.width then return false end
        end
    end
    return true
end

function W.pose(node)
    local x, _, z = getWorldTranslation(node)
    return {x=x, z=z, t=H.math.heading(node)}
end

function W.model(vehicle)
    local model, reason = H.detect(vehicle)
    if model or reason ~= 'fewer than two supported towing pivots' then return model, reason end
    -- The shared detector has already checked every coupling. Its two-pivot
    -- minimum is specific to headland loops, not ordinary queue trailers.
    local node = vehicle:getAIDirectionNode()
    local body = H.getBody(vehicle, node)
    model = {root=W.pose(node), bodies={body}, links={}, width=body.left-body.right}
    local attachment = vehicle:getAttachedImplements()[1]
    if attachment then
        local object = attachment.object
        local joint, axle = object:getActiveInputAttacherJoint(), object.steeringAxleNode
        local _, _, hitch = localToLocal(joint.node, node, 0, 0, 0)
        local _, _, length = localToLocal(joint.node, axle, 0, 0, 0)
        model.links[1] = {hitch=hitch, length=length, node=axle,
            heading=H.math.heading(axle), maxArticulation=H.getHitchLimit(vehicle, attachment, joint)}
        model.bodies[2] = H.getBody(object, axle)
        model.width = math.max(model.width, model.bodies[2].left-model.bodies[2].right)
    end
    return model
end

function W.poses(model)
    local poses = {model.root}
    for _, link in ipairs(model.links) do
        local pose = W.pose(link.positionNode or link.node)
        pose.t = H.math.heading(link.node)
        poses[#poses+1] = pose
    end
    return poses
end

function W.settledPoses(model,root)
    local poses={root}
    for i,link in ipairs(model.links) do
        local x,z=H.math.position(poses[i],0,link.hitch-link.length)
        poses[i+1]={x=x,z=z,t=root.t}
    end
    return poses
end

function W.rectangle(body, pose, buffer)
    return G.rectangle({x=pose.x,z=pose.z,heading=pose.t}, {
        width=body.left-body.right, length=body.front-body.back,
        xOffset=(body.left+body.right)/2, zOffset=(body.front+body.back)/2}, buffer or 0.3)
end

function W.new(strategy)
    local model, reason = W.model(strategy.vehicle)
    if not model then return nil, reason end
    local boundary = FieldworkBoundary.forVehicle(strategy.vehicle, 0)
    if not boundary then return nil, 'field boundary unavailable' end
    local world = {strategy=strategy, model=model, boundary=boundary, fruit={}, node=createTransformGroup('cpQueueProbe')}
    world.entrance,world.entranceReason=entryGate(strategy,model,boundary)
    link(getRootNode(), world.node)
    world.collision = PathfinderCollisionDetector(strategy.vehicle, {}, {}, false, CpUtil.getDefaultCollisionFlags())
    for _, desc in pairs(g_fruitTypeManager:getFruitTypes()) do
        if desc.terrainDataPlaneId and desc.terrainDataPlaneId ~= 0 and desc.numStateChannels and desc.numStateChannels > 0 then
            local modifier = DensityMapModifier.new(desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels,
                g_currentMission.terrainRootNode)
            local item = {modifier=modifier, filter=DensityMapFilter.new(modifier), cut={},
                grass=desc.name=='GRASS' or desc.name=='MEADOW'}
            for state, isCut in pairs(desc.cutStates or {}) do
                if isCut == true and type(state) == 'number' and state >= 0 and state % 1 == 0 then
                    -- FruitTypeDesc.cutStates already uses density-map state values.
                    item.cut[state] = true
                end
            end
            world.fruit[#world.fruit+1] = item
        end
    end
    if #world.fruit == 0 then W.delete(world); return nil, 'crop density unavailable' end
    return world
end

function W.delete(world)
    if world and world.node then delete(world.node); world.node=nil end
end

function W.cropFree(world, rectangle, grassVerge)
    local a,b,d = rectangle[1],rectangle[2],rectangle[4]
    for _, item in ipairs(world.fruit) do
        if not (grassVerge and item.grass) then
        item.modifier:setParallelogramWorldCoords(a.x,a.z,b.x,b.z,d.x,d.z,DensityCoordType.POINT_POINT_POINT)
        item.filter:setValueCompareParams(DensityValueCompareType.GREATER,0)
        local _, count, total = item.modifier:executeGet(item.filter)
        if not H.math.finite(count) or not H.math.finite(total) or total<=0 or count<0 then return false end
        local standing = count
        for state in pairs(item.cut) do
            item.filter:setValueCompareParams(DensityValueCompareType.EQUAL,state)
            local _, cut, pixels = item.modifier:executeGet(item.filter)
            if not H.math.finite(cut) or pixels~=total or cut<0 then return false end
            standing = standing-cut
        end
        if standing > 0 then return false end
        end
    end
    return true
end

function W.bodyClear(world, body, pose, corridor, perimeterConnector)
    local rectangle = W.rectangle(body, pose)
    local contained=G.within(rectangle,world.boundary.polygon,world.boundary.islands)
    local entrance=not contained and inEntrance(world,rectangle)
    if not perimeterConnector and not contained and not entrance then return false, 'field boundary' end
    for _,island in ipairs(world.boundary.islands) do
        if G.overlap(rectangle,island) then return false,'island' end
    end
    if corridor and not corridor(rectangle) then return false, 'outside harvested exit corridor' end
    if not W.cropFree(world, rectangle,entrance or perimeterConnector) then return false, 'standing crop' end
    PathfinderUtil.setWorldPositionAndRotationOnTerrain(world.node,pose.x,pose.z,pose.t,0.5)
    -- Reuse native collision filtering, without appending every background
    -- rejection to PathfinderUtil's global debug-box array.
    local rx,ry,rz=getWorldRotation(world.node)
    local x,y,z=localToWorld(world.node,(body.left+body.right)/2,1,(body.front+body.back)/2)
    local width,length=(body.left-body.right)/2+0.3,(body.front-body.back)/2+0.3
    local detector=world.collision
    detector.currentOverlapBoxPosition={pos={x,y,z},direction={math.sin(ry),math.cos(ry)},size=math.max(width,length)}
    detector.collidingShapes=0
    overlapBox(x,y+0.2,z,rx,ry,rz,width,1,length,'_overlapBoxCallback',detector,
        detector.collisionMask,true,true,true,true)
    if detector.collidingShapes > 0 then
        return false, 'vehicle or obstacle'
    end
    return true
end

function W.clear(world, poses, corridor)
    for i, body in ipairs(world.model.bodies) do
        if i > 1 and math.abs(H.math.delta(poses[i-1].t,poses[i].t)) > world.model.links[i-1].maxArticulation then
            return false, 'articulation limit'
        end
        local clear, reason = W.bodyClear(world,body,poses[i],corridor)
        if not clear then return false,reason end
    end
    for i=2,#poses do
        for j=1,i-1 do
            if H.bodiesOverlap(world.model.bodies[j],poses[j],world.model.bodies[i],poses[i]) then
                return false,'train overlap'
            end
        end
    end
    return true
end

-- Live footprint collection deliberately includes dollies and mounted bodies.
function W.currentBodies(vehicle)
    local result, seen = {}, {}
    local function collect(object)
        if seen[object] then return false end
        seen[object]=true
        local body = object.rootNode and H.getBody(object,object.rootNode)
        if not body then return false end
        result[#result+1] = {body=body,pose=W.pose(object.rootNode)}
        for _, attachment in ipairs(object.getAttachedImplements and object:getAttachedImplements() or {}) do
            if not collect(attachment.object) then return false end
        end
        return true
    end
    return collect(vehicle) and result or nil
end
