-- Read-only FS25 geometry serialisation. Distances are metres; angles radians.
VGCGeometry = {}
local G = VGCGeometry
G.NULL = {}

function G.array(values)
    return setmetatable(values or {}, {__jsonArray=true})
end

function G.json(value)
    if value == nil or value == G.NULL then return 'null' end
    local kind = type(value)
    if kind == 'boolean' then return tostring(value) end
    if kind == 'number' then
        if value ~= value or math.abs(value) == math.huge then return 'null' end
        return string.format('%.10g', value)
    end
    if kind == 'string' then
        return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
            if c == '"' then return '\\"' end
            if c == '\\' then return '\\\\' end
            return string.format('\\u%04x', c:byte())
        end) .. '"'
    end
    assert(kind == 'table', 'Unsupported JSON value: ' .. kind)
    local parts = {}
    if getmetatable(value) and getmetatable(value).__jsonArray then
        for _, item in ipairs(value) do parts[#parts+1] = G.json(item) end
        return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys = {}
    for key in pairs(value) do keys[#keys+1] = tostring(key) end
    table.sort(keys)
    for _, key in ipairs(keys) do parts[#parts+1] = G.json(key) .. ':' .. G.json(value[key]) end
    return '{' .. table.concat(parts, ',') .. '}'
end

function G.call(object, name, ...)
    if not object or type(object[name]) ~= 'function' then return nil end
    local ok, a,b,c,d,e = pcall(object[name], object, ...)
    if ok then return a,b,c,d,e end
    return nil
end

function G.scalars(object, names)
    local result = {}
    for _, name in ipairs(names) do
        local v = object and object[name]
        result[name] = (type(v)=='number' or type(v)=='string' or type(v)=='boolean') and v or G.NULL
    end
    return result
end

function G.vector(v)
    if type(v) ~= 'table' then return G.NULL end
    return G.array({v[1] or G.NULL,v[2] or G.NULL,v[3] or G.NULL})
end

function G.node(node, reference)
    if not node or node == 0 or not reference or reference == 0 then return G.NULL end
    local ok, result = pcall(function()
        local x,y,z = localToLocal(node, reference, 0,0,0)
        local dx,dy,dz = localDirectionToLocal(node, reference, 0,0,1)
        local ux,uy,uz = localDirectionToLocal(node, reference, 0,1,0)
        return {position=G.array({x,y,z}),forward=G.array({dx,dy,dz}),up=G.array({ux,uy,uz})}
    end)
    return ok and result or G.NULL
end

function G.world(node)
    if not node or node == 0 then return G.NULL end
    local ok, result = pcall(function()
        local x,y,z = getWorldTranslation(node)
        local dx,dy,dz = localDirectionToWorld(node,0,0,1)
        local ux,uy,uz = localDirectionToWorld(node,0,1,0)
        return {position=G.array({x,y,z}),forward=G.array({dx,dy,dz}),up=G.array({ux,uy,uz})}
    end)
    return ok and result or G.NULL
end

function G.identity(object)
    local configurations = {}
    for k,v in pairs(object.configurations or {}) do
        if type(v)=='number' or type(v)=='string' then configurations[tostring(k)] = v end
    end
    local model = tostring(object.configFileName or 'unknown'):gsub('\\','/')
    local signature = model .. '|' .. G.json(configurations)
    local hash = 0
    for i=1,#signature do hash=(hash*31+signature:byte(i))%2147483647 end
    local name = G.call(object,'getName') or model:match('([^/]+)$') or 'machine'
    local stem = (model:match('([^/]+)%.xml$') or 'machine'):gsub('[^%w_-]','_')
    return {id=stem .. '_' .. string.format('%08x',hash),model=model,name=name,configurations=configurations}
end

function G.state(object)
    local result = {
        lowered=G.call(object,'getIsLowered'),turnedOn=G.call(object,'getIsTurnedOn'),
        inWorkPosition=G.call(object,'getIsInWorkPosition'),
        speedKph=G.call(object,'getLastSpeed'),movingDirection=object.movingDirection,
        steeringInput=object.rotatedTime,
        articulationRad=object.spec_articulatedAxis and object.spec_articulatedAxis.curRot,
        crabSteeringMode=object.spec_crabSteering and object.spec_crabSteering.state,
        foldAnimationTime=object.spec_foldable and object.spec_foldable.foldAnimTime
    }
    local plough = object.spec_plow
    if plough and plough.rotationPart then
        result.ploughRotationTime=G.call(object,'getAnimationTime',plough.rotationPart.turnAnimation)
    end
    for _, key in ipairs({'lowered','turnedOn','inWorkPosition','speedKph','movingDirection','steeringInput',
                         'articulationRad','crabSteeringMode','foldAnimationTime','ploughRotationTime'}) do
        if result[key] == nil then result[key]=G.NULL end
    end
    return result
end

function G.workAreas(object, reference)
    local result = G.array()
    for i, area in ipairs(object.spec_workArea and object.spec_workArea.workAreas or {}) do
        result[#result+1] = {index=i,type=area.type or G.NULL,
            start=G.node(area.start,reference),width=G.node(area.width,reference),height=G.node(area.height,reference),
            disabled=area.isDisabled == nil and G.NULL or area.isDisabled}
    end
    return result
end

function G.snapshot(object, category, label)
    local root = object.rootNode
    assert(root and root ~= 0, 'Machine has no valid root node')
    local left,right,back,inverted,width=G.call(object,'getAIMarkers')
    local result = {schema='fs25-geometry-capture',schemaVersion=1,identity=G.identity(object),
        category=category or 'unclassified',label=label or 'unspecified',
        coordinateSystem={reference='machine.rootNode',axes='x/y/z',units='metres',angles='radians',
                          note='Use captured direction vectors; root orientation is not assumed to face forwards.'},
        state=G.state(object),declaredSize=G.scalars(object.size,{'width','length','height','lengthOffset','widthOffset'}),
        aiDirection=G.node(G.call(object,'getAIDirectionNode'),root),
        aiSteering=G.node(G.call(object,'getAISteeringNode'),root),
        steeringAxle=G.node(object.steeringAxleNode,root),
        aiMarkers={left=G.node(left,root),right=G.node(right,root),back=G.node(back,root),
                   inverted=inverted == nil and G.NULL or inverted,reportedWidth=width or G.NULL},
        workAreas=G.workAreas(object,root),wheels=G.array(),components=G.array(),componentJoints=G.array(),
        inputCouplings=G.array(),outputCouplings=G.array(),
        turning={declaredMaxRadius=object.maxTurningRadius or G.NULL,
                 aiMinRadius=G.call(object,'getAIMinTurningRadius') or G.NULL},
        steeringControls=G.scalars(object,{'minRotTime','maxRotTime','rotatedTime','wheelSteeringDuration'}),
        clearance={safeDrawbarAngle=G.NULL,collisionEnvelope=G.NULL,
                   status='Not measured. Declared size and joint limits are not collision-clearance limits.'}}
    for i,component in ipairs(object.components or {}) do
        result.components[#result.components+1]={index=i,pose=G.node(component.node,root)}
    end
    for i,joint in ipairs(object.componentJoints or {}) do
        result.componentJoints[#result.componentJoints+1]={index=i,pose=G.node(joint.jointNode,root),
            rotLimit=G.vector(joint.rotLimit),transLimit=G.vector(joint.transLimit),
            componentIndices=G.vector(joint.componentIndices)}
    end
    for i,wheel in ipairs(object.spec_wheels and object.spec_wheels.wheels or {}) do
        local physics = wheel.physics or wheel
        local steering = wheel.steering or wheel
        result.wheels[#result.wheels+1]={index=i,physicsNode=G.node(physics.node,root),
            representation=G.node(wheel.repr,root),driveNode=G.node(wheel.driveNode,root),
            physics=G.scalars(physics,{'radius','width','positionX','positionY','positionZ'}),
            steering=G.scalars(steering,{'steeringNodeMinRot','steeringNodeMaxRot','steeringAxleScale','steeringAxleRotMin','steeringAxleRotMax'}),
            steeringPhysics=G.scalars(physics,{'rotMin','rotMax','rotSpeed','steeringAngle'})}
    end
    local active = G.call(object,'getActiveInputAttacherJoint')
    for i,joint in ipairs(object.spec_attachable and object.spec_attachable.inputAttacherJoints or {}) do
        result.inputCouplings[#result.inputCouplings+1]={index=i,active=joint==active,
            pose=G.node(joint.node,root),jointType=joint.jointType or G.NULL,
            root=G.node(joint.rootNode,root),lowerRotLimitScale=G.vector(joint.lowerRotLimitScale),
            upperRotLimitScale=G.vector(joint.upperRotLimitScale),
            limits=G.scalars(joint,{'allowsLowering','isHardAttached','rotLimitFactor'})}
    end
    for i,joint in ipairs(object.spec_attacherJoints and object.spec_attacherJoints.attacherJoints or {}) do
        result.outputCouplings[#result.outputCouplings+1]={index=i,pose=G.node(joint.jointTransform,root),
            jointType=joint.jointType or G.NULL,lowerRotLimit=G.vector(joint.lowerRotLimit),
            upperRotLimit=G.vector(joint.upperRotLimit)}
    end
    local art=object.spec_articulatedAxis
    if art and art.componentJoint then
        result.articulation={pivot=G.node(art.rotationNode,root),limits=G.scalars(art,{'rotMin','rotMax','rotSpeed','curRot'})}
    else result.articulation=G.NULL end
    result.availability={workAreas=#result.workAreas>0,aiMarkers=left~=nil and right~=nil,
        steeringAxle=result.steeringAxle~=G.NULL,wheels=#result.wheels>0}
    local radius,rotationNode,wheels,factor=G.call(object,'getAITurnRadiusLimitation')
    local turnWheels=G.array()
    for _,wheel in pairs(wheels or {}) do
        turnWheels[#turnWheels+1]={pose=G.node(wheel.repr,root),
            steering=G.scalars(wheel.steering,{'steeringAxleScale','steeringAxleRotMax'})}
    end
    result.turning.implementLimitation={manualRadius=radius or G.NULL,rotationNode=G.node(rotationNode,root),
        wheels=turnWheels,rotLimitFactor=factor or G.NULL,pivotSource=G.NULL}
    for i,joint in ipairs(object.spec_attachable and object.spec_attachable.inputAttacherJoints or {}) do
        if rotationNode and rotationNode==joint.node then
            result.turning.implementLimitation.pivotSource={type='inputCoupling',index=i}
        end
    end
    for i,joint in ipairs(object.componentJoints or {}) do
        if rotationNode and rotationNode==joint.jointNode then
            result.turning.implementLimitation.pivotSource={type='componentJoint',index=i}
        end
    end
    return result
end

function G.wheelStates(object)
    local result=G.array()
    for i,wheel in ipairs(object.spec_wheels and object.spec_wheels.wheels or {}) do
        result[#result+1]={index=i,pose=G.node(wheel.repr,object.rootNode),
            physics=G.scalars(wheel.physics,{'steeringAngle','rotMin','rotMax'}),
            steering=G.scalars(wheel.steering,{'steeringAxleScale','steeringAxleRotMin','steeringAxleRotMax'})}
    end
    return result
end

-- Context values are observations, not intrinsic radii of the standalone implement.
function G.turnContext(root, object)
    local result={rootIdentity=G.identity(root).id,giantsToolRadius=G.NULL,cpRadius=G.NULL,cpOverride=G.NULL}
    local strategy=G.call(root,'getCpDriveStrategy')
    result.cpActiveStrategyRadius=strategy and strategy.turningRadius or G.NULL
    if object.isServer and object.getAITurnRadiusLimitation and AIVehicleUtil then
        local ok,value=pcall(AIVehicleUtil.getMaxToolRadius,{object=object})
        if ok then result.giantsToolRadius=value or G.NULL end
    end
    local name=g_modManager and g_modManager.CP_MOD_NAME
    local cp=name and _G[name]
    if cp and cp.AIUtil then
        local ok,value=pcall(cp.AIUtil.getTurningRadius,root,false)
        if ok then result.cpRadius=value or G.NULL end
        if cp.g_vehicleConfigurations then
            result.cpOverride=G.call(cp.g_vehicleConfigurations,'get',object,'turnRadius') or G.NULL
        end
    end
    return result
end

function G.cpTrace(root)
    local strategy=G.call(root,'getCpDriveStrategy')
    if not strategy then return G.NULL end
    local context=strategy.turnContext or {}
    return {state=G.call(strategy,'getStateAsString') or G.NULL,
        radius=strategy.turningRadius or G.NULL,
        waypoint=G.call(strategy.ppc,'getCurrentWaypointIx') or G.NULL,
        workStart=G.world(context.workStartNode),workEnd=G.world(context.workEndNode),
        note='CP turn-context references may persist outside a turn; interpret with state and waypoint.'}
end

function G.objects(root)
    local result, seen = {}, {}
    local function visit(object,parent,jointIndex)
        if not object or seen[object] then return end
        seen[object]=true
        result[#result+1]={object=object,parent=parent,jointIndex=jointIndex}
        for _, attachment in ipairs(G.call(object,'getAttachedImplements') or {}) do
            visit(attachment.object,object,attachment.jointDescIndex)
        end
    end
    visit(root)
    return result
end
