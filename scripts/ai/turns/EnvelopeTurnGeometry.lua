-- Live GIANTS/CP adapter for EnvelopeTurnPlanner. No model names or PW-specific
-- dimensions belong here: measurements are refreshed after lifting/rotation.
EnvelopeTurnGeometry = {}
local G, E = EnvelopeTurnGeometry, EnvelopeTurnPlanner

local function finite(n)
    return type(n)=='number' and n==n and math.abs(n)<100000
end

function G.pose(node)
    local x,_,z=getWorldTranslation(node)
    local dx,_,dz=localDirectionToWorld(node,0,0,1)
    return {x=x,z=z,t=math.atan2(dx,dz)}
end

-- Use production PPC's segment/goal-point selection in the candidate predictor.
-- A private direction node avoids moving any real vehicle during calculation.
-- The proxy is deliberately tiny: no AI job, callbacks or implement commands.
function G.tracker(p,path)
    local node=CpUtil.createNode('envelopePrediction',p.start.x,p.start.z,p.start.t)
    local proxy={maxTurningRadius=p.radius,getName=function() return 'Envelope prediction' end,
        getAIDirectionNode=function() return node end,stopCurrentAIJob=function() end,
        getCpSettings=function() return {} end}
    local ppc=PurePursuitController(proxy)
    ppc.shortLookaheadDistance=p.lookahead
    ppc:setShortLookaheadDistance()
    ppc:setCourse(Course(proxy,path,true))
    ppc:initialize(1)
    -- Prediction is deliberately silent; per-sample PPC logging with debug on
    -- would produce thousands of records for each rejected candidate.
    ppc.debug=function() end
    ppc.debugSparse=function() end
    ppc.showDebugTable=function() end
    ppc.showGoalpointDiag=function() end
    local tracker={}
    function tracker:sample(s)
        setTranslation(node,s.x,getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode,s.x,0,s.z),s.z)
        setRotation(node,0,s.t,0)
        ppc:update()
        local x,_,z=ppc:getGoalPointPosition()
        return ppc:getCurrentWaypointIx(),x,z
    end
    function tracker:delete()
        if not node then return end
        -- PPC's public destructor owns its waypoints; this adapter owns only
        -- its input node. This path also runs when the user cancels planning.
        ppc:delete()
        CpUtil.destroyNode(node)
        node=nil
        p.activeTracker=nil
    end
    p.activeTracker=tracker
    return tracker
end

function G.enabled(vehicle,context)
    local setting=vehicle:getCpSettings().envelopeAlignedTurns
    return setting and setting:getValue() and not context:isHeadlandCorner()
end

-- The first integration handles a rigid tractor and direct mounted tools, or
-- one passive trailer. It must not flatten an articulated tractor/seed-cart
-- chain into one fictitious hinge. Unsupported equipment retains stock CP.
function G.supported(vehicle)
    if vehicle.spec_articulatedAxis and vehicle.spec_articulatedAxis.componentJoint then
        return false,'articulated tractor requires a multi-body predictor'
    end
    local trailer=AIUtil.getFirstReversingImplementWithWheels(vehicle,true)
    for _,attachment in ipairs(vehicle:getAttachedImplements()) do
        local object=attachment.object
        if #object:getAttachedImplements()>0 then return false,'chained attachments require a multi-body predictor' end
        if ImplementUtil.isWheeledImplement(object) and object~=trailer then
            return false,'multiple or front wheeled implements are not supported'
        end
    end
    if trailer then
        if not trailer.steeringAxleNode or not trailer:getActiveInputAttacherJoint() then
            return false,'missing trailer pivot or steering axle'
        end
        if trailer.spec_articulatedAxis and trailer.spec_articulatedAxis.componentJoint then
            return false,'articulated implement requires a multi-body predictor'
        end
        -- Positive rear-wheel steering is not passive trailer kinematics.
        for _,wheel in ipairs(trailer.spec_wheels and trailer.spec_wheels.wheels or {}) do
            local steering=wheel.steering or {}
            if math.abs(steering.steeringAxleScale or 0)>0.001 then
                return false,'steered trailer requires its steering law'
            end
        end
    end
    return true,trailer
end

local function markerAt(node,reference,towed,hitchLocal,rear)
    local x,_,z=localToLocal(node,reference,0,0,0)
    return {x=x-(hitchLocal and hitchLocal.x or 0),z=z-(hitchLocal and hitchLocal.z or 0),
        towed=towed,rear=rear,node=node}
end

local function addRectangle(p,reference,towed,hitchLocal,xMin,xMax,zMin,zMax)
    -- Include the full perimeter, not only corners. A concave boundary can
    -- pass between four valid corners. Spacing is bounded independently of width.
    local corners={{xMin,zMin},{xMax,zMin},{xMax,zMax},{xMin,zMax}}
    for i,a in ipairs(corners) do
        local b=corners[i%4+1]
        local n=math.max(1,math.ceil(math.sqrt((b[1]-a[1])^2+(b[2]-a[2])^2)/0.4))
        for j=0,n-1 do
            p.footprint[#p.footprint+1]={x=a[1]+(b[1]-a[1])*j/n-(hitchLocal and hitchLocal.x or 0),
                z=a[2]+(b[2]-a[2])*j/n-(hitchLocal and hitchLocal.z or 0),towed=towed}
        end
    end
end

function G.capture(turn)
    local vehicle,context=turn.vehicle,turn.turnContext
    local supported,trailer=G.supported(vehicle)
    if not supported then return nil,trailer end
    local node=vehicle:getAIDirectionNode()
    local p={start=G.pose(node),goal=G.pose(context.workStartNode),radius=AIUtil.getTurningRadius(vehicle),
        width=turn.workWidth,lookahead=turn.ppc.shortLookaheadDistance or 3,
        hitchX=0,hitchZ=0,work={},footprint={},objects={},loweringLead=0.5,
        -- This is a conservative numerical ceiling, NOT a drawbar collision
        -- certificate. Any smaller exposed physical yaw stop takes precedence.
        maxArticulation=math.rad(85),workCentreX=0}
    if not finite(p.radius) or p.radius<=0 then return nil,'invalid CP turning radius' end
    local hitchLocal
    if trailer then
        local input=trailer:getActiveInputAttacherJoint()
        local hx,_,hz=localToLocal(input.node,trailer.steeringAxleNode,0,0,0)
        hitchLocal={x=hx,z=hz}
        p.hitchX,_,p.hitchZ=localToLocal(input.node,node,0,0,0)
        p.length=hz
        p.start.phi=G.pose(trailer.steeringAxleNode).t
        p.trailerNode=trailer.steeringAxleNode
        if not finite(p.length) or p.length<0.5 or math.abs(hx)>0.25 then
            return nil,'unsupported offset axle or invalid hitch-to-axle length'
        end
        for _,attachment in ipairs(vehicle:getAttachedImplements()) do
            if attachment.object==trailer then
                local joint=vehicle.spec_attacherJoints and vehicle.spec_attacherJoints.attacherJoints[attachment.jointDescIndex]
                local upper=joint and joint.upperRotLimit and joint.upperRotLimit[2]
                local scale=input.upperRotLimitScale and input.upperRotLimitScale[2] or 1
                if finite(upper) and math.abs(upper)>0.01 and finite(scale) and scale>0 then
                    p.maxArticulation=math.min(p.maxArticulation,math.abs(upper*scale))
                end
            end
        end
    else p.start.phi=p.start.t end
    local front=-math.huge
    for _,object in pairs(vehicle:getChildVehicles()) do
        local towed=object==trailer
        local reference=towed and trailer.steeringAxleNode or node
        local hl=towed and hitchLocal or nil
        -- CP's scanner includes the unfolded physical machine. Enlarge it with
        -- AI work markers too: collision boxes may omit non-colliding tines.
        local scanner=VehicleSizeScanner()
        -- VehicleSizeScanner currently places its probes about object.rootNode,
        -- even with another reference supplied. Scan in its native frame and
        -- explicitly transform every corner; never treat root-relative extents
        -- as tractor-/axle-relative dimensions.
        local sf,sr,sl,ss=scanner:scan(object)
        if not (finite(sf) and finite(sr) and finite(sl) and finite(ss)) then
            return nil,'invalid scanned equipment bounds'
        end
        local size=object.size or {}
        sf=math.max(sf,(size.length or 0)/2+(size.lengthOffset or 0))
        sr=math.min(sr,-(size.length or 0)/2+(size.lengthOffset or 0))
        sl=math.max(sl,(size.width or 0)/2)
        ss=math.min(ss,-(size.width or 0)/2)
        local zMax,zMin,xMax,xMin=-math.huge,math.huge,-math.huge,math.huge
        for _,x in ipairs({sl,ss}) do
            for _,z in ipairs({sf,sr}) do
                local rx,_,rz=localToLocal(object.rootNode,reference,x,0,z)
                xMin,xMax=math.min(xMin,rx),math.max(xMax,rx)
                zMin,zMax=math.min(zMin,rz),math.max(zMax,rz)
            end
        end
        if not (finite(zMax) and finite(zMin) and finite(xMax) and finite(xMin)) then
            return nil,'invalid scanned equipment bounds'
        end
        local left,right,back=WorkWidthUtil.getAIMarkers(object,true)
        if left then
            if not right or not back then return nil,'incomplete working markers' end
            local l=markerAt(left,reference,towed,hl,false)
            local r=markerAt(right,reference,towed,hl,false)
            local b=markerAt(back,reference,towed,hl,true)
            -- Long plough front markers are staggered. Keep BOTH actual front
            -- points, and extend their width to the rear soil-engaging marker.
            local rearLeft={x=l.x,z=b.z,towed=towed,rear=true}
            local rearRight={x=r.x,z=b.z,towed=towed,rear=true}
            local entry={object=object,reference=reference,hitchLocal=hl,towed=towed,
                left=left,right=right,back=back,markers={l,r,rearLeft,rearRight}}
            p.objects[#p.objects+1]=entry
            for _,m in ipairs(entry.markers) do
                p.work[#p.work+1]=m
                local x,z=m.x+(hl and hl.x or 0),m.z+(hl and hl.z or 0)
                xMin,xMax=math.min(xMin,x),math.max(xMax,x)
                zMin,zMax=math.min(zMin,z),math.max(zMax,z)
                if not m.rear then front=math.max(front,m.z+(towed and p.hitchZ or 0)) end
            end
            p.workCentreX=p.workCentreX+(l.x+r.x)/2+(towed and p.hitchX or 0)
        end
        addRectangle(p,reference,towed,hl,xMin,xMax,zMin,zMax)
    end
    if #p.work==0 then return nil,'no working envelope' end
    p.front=front
    p.workCentreX=p.workCentreX/#p.objects
    local exit=G.pose(context.workEndNode)
    local dx,dz=E.localPoint(exit,p.goal)
    p.slope=math.abs(dx)>0.5 and dz/dx or 0
    if math.abs(p.slope)>2 then return nil,'row endpoints do not define a supported pike' end
    local ahead=context:getDistanceToFieldEdge(node)
    local _,startZ=E.localPoint(p.start,exit)
    -- This distance only seeds candidate placement. Every accepted body sample
    -- must also satisfy the actual polygon/density checks below.
    p.headland=math.max(0,math.min(150,(ahead or 0)+startZ)/math.sqrt(1+p.slope*p.slope))
    local polygon=vehicle.cpGetFieldPolygon and vehicle:cpGetFieldPolygon()
    local islands=vehicle.cpGetIslandPolygons and vehicle:cpGetIslandPolygons() or {}
    if not polygon or #polygon<3 then return nil,'field polygon unavailable; generate the course on this field first' end
    -- Cache on a 0.25 m grid. Add its half-diagonal to the reserve so rounding
    -- can NEVER turn a failed clearance sample into a successful one.
    local cache={}
    p.contains=function(x,z)
        local ix,iz=math.floor(x*4+0.5),math.floor(z*4+0.5)
        local key=ix..':'..iz
        if cache[key]~=nil then return cache[key] end
        local q={x=ix/4,z=iz/4}
        local valid=E.inside(q,polygon,E.reserve+0.18)
        if valid then
            for _,island in ipairs(islands) do
                if not E.outside(q,island,E.reserve+0.18) then valid=false end
                if not valid then break end
            end
        end
        if valid then valid=CpFieldUtil.isOnField(q.x,q.z) and true or false end
        cache[key]=valid
        return valid
    end
    p.dubins=function(start,goal,radius)
        local path=PathfinderUtil.findAnalyticPathFromStartToGoal(PathfinderUtil.dubinsSolver,
            State3D(start.x,-start.z,CpMathUtil.angleFromGame(start.t)),
            State3D(goal.x,-goal.z,CpMathUtil.angleFromGame(goal.t)),radius)
        if not path then return nil end
        local points={}
        for _,wp in ipairs(path) do points[#points+1]={x=wp.x,z=-wp.y} end
        return points
    end
    p.newTracker=function(path) return G.tracker(p,path) end
    return p
end

-- Live marker positions are compared against their calibrated straight-row
-- offsets. This is independent of the tractor's predicted path and catches
-- actual hitch lag, tracking errors and a plough which has not finished rotating.
function G.assessLive(p,vehicle)
    local s=G.pose(vehicle:getAIDirectionNode())
    s.phi=p.trailerNode and G.pose(p.trailerNode).t or s.t
    local error,angle,contact=0,0,-math.huge
    for _,entry in ipairs(p.objects) do
        local reference=G.pose(entry.reference)
        angle=math.max(angle,math.abs(E.wrap(reference.t-p.goal.t)))
        local points={}
        for _,node in ipairs({entry.left,entry.right,entry.back}) do
            local x,_,z=getWorldTranslation(node)
            points[#points+1]={x=x,z=z}
        end
        -- Reconstruct rear edge corners at the actual back marker's station.
        -- The front markers may themselves be staggered longitudinally.
        local backX,backZ=E.localPoint(points[3],reference)
        for i=1,2 do
            local x=E.localPoint(points[i],reference)
            points[i+2]=E.point(reference.x,reference.z,reference.t,x,backZ)
        end
        for i,m in ipairs(entry.markers) do
            local x,z=E.localPoint(points[i],p.goal)
            local expected=m.x+(m.towed and p.hitchX or 0)
            error=math.max(error,math.abs(x-expected))
            if not m.rear then contact=math.max(contact,z-p.slope*(x-p.workCentreX)) end
        end
    end
    return error<=E.edgeTolerance and angle<=E.angleTolerance,error,angle,contact,s
end
