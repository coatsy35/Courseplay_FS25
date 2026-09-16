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

-- Match stock AIReverseDriver: an implement may provide a direction frame
-- which remains correct when its body is offset or a reversible plough rolls.
-- steeringAxleNode alone can point along that skewed body rather than the
-- wheels' travel direction. Use ONE frame for prediction and live admission.
function G.trailerDirectionNode(object)
    local explicit=object.getAIToolReverserDirectionNode and object:getAIToolReverserDirectionNode()
    if explicit and explicit~=0 then return explicit,'implement direction node' end
    return object.steeringAxleNode,'steering axle node'
end

-- A three-point-mounted drawbar can lock yaw at the tractor and turn at an
-- internal implement joint instead. Only use that declared joint when it
-- connects directly to the input's tractor-fixed component; otherwise the
-- single passive-trailer model must retain its ordinary input pivot.
function G.trailerPivotNode(object,input)
    local declared
    if object.getAITurnRadiusLimitation then local _;_,declared=object:getAITurnRadiusLimitation() end
    local scale=input.upperRotLimitScale and input.upperRotLimitScale[2]
    if declared and declared~=0 and declared~=input.node and scale==0 and input.rootNode then
        for _,joint in ipairs(object.componentJoints or {}) do
            if joint.jointNode==declared then
                for _,index in ipairs(joint.componentIndices or {}) do
                    local component=object.components and object.components[index]
                    if component and component.node==input.rootNode then
                        local limit=joint.rotLimit and joint.rotLimit[2]
                        return declared,'internal drawbar joint',limit,declared
                    end
                end
            end
        end
    end
    return input.node,'input coupling',nil,declared
end

-- The numerical model is horizontal. Project WORLD positions into a yaw-only
-- frame: localToLocal includes pitch/roll, so a raised or flipped plough would
-- otherwise acquire different lengths and mirrored marker offsets.
function G.planarPoint(source,reference,x,y,z)
    local wx,_,wz=localToWorld(source,x or 0,y or 0,z or 0)
    return E.localPoint({x=wx,z=wz},G.pose(reference))
end

-- GIANTS driveToPoint derives curvature from a goal in AISteeringNode space.
-- PPC tracks AIDirectionNode instead. Return an equivalent steering goal so
-- both prediction and execution request the SAME bounded curvature, even when
-- the tractor has a different steering-node origin or a tighter steering lock.
-- This changes only this turn's goal; GIANTS retains steering slew/physics.
function G.driveGoal(p,vehicle,gx,gz)
    local state=G.pose(vehicle:getAIDirectionNode())
    local k=E.pursuitCurvature(p,state,gx,gz)
    local distance=math.min(4,p.lookahead,p.radius)
    local x=0.5*k*distance*distance
    local z=math.sqrt(math.max(0,distance*distance-x*x))
    local node=vehicle:getAISteeringNode()
    local wx,_,wz=localToWorld(node,x,0,z)
    return wx,wz,k
end

-- Use production PPC's segment/goal-point selection in the candidate predictor.
-- A private direction node avoids moving any real vehicle during calculation.
-- The proxy is deliberately tiny: no AI job, callbacks or implement commands.
function G.tracker(p,path,screening)
    if screening then return E.newPlanarTracker(p,path) end
    local node=CpUtil.createNode('envelopePrediction',p.start.x,p.start.z,p.start.t)
    local proxy={maxTurningRadius=p.trackingRadius or p.radius,getName=function() return 'Envelope prediction' end,
        getAIDirectionNode=function() return node end,stopCurrentAIJob=function() end,
        getCpSettings=function() return {} end}
    local ppc=PurePursuitController(proxy)
    ppc.shortLookaheadDistance=p.lookahead
    ppc:setShortLookaheadDistance()
    -- Prediction is deliberately silent; per-sample PPC logging with debug on
    -- would produce thousands of records for each rejected candidate.
    ppc.debug=function() end
    ppc.debugSparse=function() end
    ppc.showDebugTable=function() end
    ppc.showGoalpointDiag=function() end
    for _,wp in ipairs({ppc.currentWpNode,ppc.relevantWpNode,ppc.nextWpNode,ppc.goalWpNode}) do
        wp.logChanges=false
    end
    ppc:setCourse(Course(proxy,path,true))
    ppc:initialize(1)
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

-- The tractor can already be beyond a short row when its trailing work edge
-- reaches the start. CP's normal forward-waypoint hand-off can then initialise
-- on/past the turn marker without emitting that marker's callback. Preserve
-- the generated order and explicitly finish that row before starting its turn.
function G.pendingRowTurn(course,entryIx,resumeIx)
    for i=entryIx+1,math.min(resumeIx,course:getNumberOfWaypoints()-1) do
        if course:isTurnStartAtIx(i) and not course:isOnHeadland(i) then return i end
    end
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
        if not G.trailerDirectionNode(trailer) or not trailer:getActiveInputAttacherJoint() then
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
    local x,z=G.planarPoint(node,reference)
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

-- CP's generated row attributes describe the PLANNED worked side. They are
-- not a soil-state sensor (starting halfway through a course can disagree).
-- Use only an unambiguous side as a preference, never as clearance evidence.
function G.workedSide(turn)
    local course=turn.fieldWorkCourse
    local ix=turn.turnContext.turnStartWpIx
    local wp=course and course:getWaypoint(ix)
    local a=wp and wp.attributes
    if not a then return nil end
    if a.leftSideWorked==true and a.rightSideWorked==false then return -1 end
    if a.rightSideWorked==true and a.leftSideWorked==false then return 1 end
    return nil
end

-- Restrict only this experimental connection, leaving CP's shared solver
-- untouched. LRL/RLR place the alternative bulb on opposite sides; the full
-- trailer simulation still decides whether that connection is acceptable.
function G.analyticPath(start,goal,radius,loopSide)
    local solver=PathfinderUtil.dubinsSolver
    if loopSide then
        G.loopSolvers=G.loopSolvers or {
            [-1]=DubinsSolver({DubinsSolver.PathType.LRL}),
            [1]=DubinsSolver({DubinsSolver.PathType.RLR})}
        if type(loopSide)=='string' then
            -- The shortest tractor Dubins solution is not necessarily the
            -- best trailer path. Keep valid CSC alternatives available.
            G.loopSolvers[loopSide]=G.loopSolvers[loopSide] or DubinsSolver({DubinsSolver.PathType[loopSide]})
        end
        solver=G.loopSolvers[loopSide]
    end
    local s=State3D(start.x,-start.z,CpMathUtil.angleFromGame(start.t))
    local g=State3D(goal.x,-goal.z,CpMathUtil.angleFromGame(goal.t))
    local solution=solver:solve(s,g,radius)
    if not solution then return nil end
    local points={}
    for _,wp in ipairs(solution:getWaypoints(s,radius)) do points[#points+1]={x=wp.x,z=-wp.y} end
    return points
end

function G.capture(turn)
    local vehicle,context=turn.vehicle,turn.turnContext
    local supported,trailer=G.supported(vehicle)
    if not supported then return nil,trailer end
    local node=vehicle:getAIDirectionNode()
    local p={start=G.pose(node),goal=G.pose(context.workStartNode),radius=AIUtil.getTurningRadius(vehicle),
        trackingRadius=vehicle.maxTurningRadius,
        approachSpeed=vehicle:getCpSettings().turnSpeed:getValue(),
        width=turn.workWidth,lookahead=turn.ppc.shortLookaheadDistance or 3,
        hitchX=0,hitchZ=0,work={},footprint={},objects={},loweringLead=0.5,
        -- This is a conservative numerical ceiling, NOT a drawbar collision
        -- certificate. Any smaller exposed physical yaw stop takes precedence.
        maxArticulation=math.rad(85),workCentreX=0}
    if not finite(p.radius) or p.radius<=0 then return nil,'invalid CP turning radius' end
    local hitchLocal
    if trailer then
        local input=trailer:getActiveInputAttacherJoint()
        local direction,source=G.trailerDirectionNode(trailer)
        local pivot,pivotSource,pivotLimit,declared=G.trailerPivotNode(trailer,input)
        local hx,hz=G.planarPoint(pivot,direction)
        hitchLocal={x=hx,z=hz}
        p.inputHitchX,p.inputHitchZ=G.planarPoint(input.node,node)
        p.hitchX,p.hitchZ=G.planarPoint(pivot,node)
        p.pivotSource=pivotSource
        if finite(pivotLimit) and math.abs(pivotLimit)>0 then
            p.maxArticulation=math.min(p.maxArticulation,math.abs(pivotLimit))
        end
        p.length=hz
        p.axleOffsetX=hx
        p.start.phi=G.pose(direction).t
        p.trailerNode=direction
        p.directionSource=source
        p.directionOffset=trailer.steeringAxleNode and E.wrap(p.start.phi-G.pose(trailer.steeringAxleNode).t) or 0
        if declared and declared~=0 then p.declaredPivotX,p.declaredPivotZ=G.planarPoint(declared,node) end
        -- A lateral axle offset is valid for a passive trailer. Its yaw rate
        -- depends on the longitudinal hitch-to-axle lever hz; hx affects the
        -- axle position/forward speed and is retained in every marker offset.
        if not finite(hx) or not finite(p.length) or p.length<0.5 then
            return nil,string.format('invalid horizontal hitch-to-axle geometry (lateral %s, longitudinal %s)',tostring(hx),tostring(hz))
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
        local reference=towed and p.trailerNode or node
        local hl=towed and hitchLocal or nil
        -- CP's scanner includes the unfolded physical machine. Enlarge it with
        -- AI work markers too: collision boxes may omit non-colliding tines.
        local scanner=VehicleSizeScanner()
        -- VehicleSizeScanner currently places its probes about object.rootNode,
        -- even with another reference supplied. Scan in its native frame and
        -- explicitly transform every corner; never treat root-relative extents
        -- as tractor-/axle-relative dimensions.
        local centred=false
        for _,controller in pairs(turn.driveStrategy.controllers) do
            if controller.implement==object and controller.isRotatablePlow and controller:isRotatablePlow() then
                centred=turn.needsWorkingGeometry and not controller:isRotationActive() and not controller:isFullyRotated()
            end
        end
        local sf,sr,sl,ss
        local complete=false
        if centred and scanner._measureDimension then
            -- The nominal working width defeats the benefit of centring.
            -- Use current collision extents only when ALL four probes hit;
            -- the scanner's default value on a missed probe is not a size.
            complete=true
            local function measure(distance,axis)
                local value=scanner:_measureDimension(object,nil,distance,distance>0 and 0.1 or -0.1,axis)
                complete=complete and scanner.scannedVehicleFound
                return value
            end
            sf,sr,sl,ss=measure(50,'z'),measure(-50,'z'),measure(50,'x'),measure(-50,'x')
            complete=complete and sf>sr and sl>ss
        else sf,sr,sl,ss=scanner:scan(object) end
        if not (finite(sf) and finite(sr) and finite(sl) and finite(ss)) then
            return nil,'invalid scanned equipment bounds'
        end
        local size=object.size or {}
        if not (centred and complete) then
            sf=math.max(sf,(size.length or 0)/2+(size.lengthOffset or 0))
            sr=math.min(sr,-(size.length or 0)/2+(size.lengthOffset or 0))
            sl=math.max(sl,(size.width or 0)/2)
            ss=math.min(ss,-(size.width or 0)/2)
        end
        local zMax,zMin,xMax,xMin=-math.huge,math.huge,-math.huge,math.huge
        for _,x in ipairs({sl,ss}) do
            for _,z in ipairs({sf,sr}) do
                local rx,rz=G.planarPoint(object.rootNode,reference,x,0,z)
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
    if turn.entrySlope~=nil then p.slope=turn.entrySlope end
    if math.abs(p.slope)>2 then return nil,'row endpoints do not define a supported pike' end
    -- This distance only seeds candidate placement. Every accepted body sample
    -- must also satisfy the actual polygon/density checks below. Retain the
    -- outgoing measurement after rotation: the tractor now faces INTO the field
    -- and a new forward query measures a different edge entirely.
    if turn.headlandSeed then p.headland=turn.headlandSeed
    else
        local ahead=context:getDistanceToFieldEdge(node)
        local _,startZ=E.localPoint(p.start,exit)
        p.headland=math.max(0,math.min(150,(ahead or 0)+startZ)/math.sqrt(1+p.slope*p.slope))
    end
    local polygon=vehicle.cpGetFieldPolygon and vehicle:cpGetFieldPolygon()
    local islands=vehicle.cpGetIslandPolygons and vehicle:cpGetIslandPolygons() or {}
    if not polygon or #polygon<3 then return nil,'field polygon unavailable; generate the course on this field first' end
    local fieldCheck=E.polygonChecker(polygon,E.reserve+0.18,true)
    local islandChecks={}
    for _,island in ipairs(islands) do islandChecks[#islandChecks+1]=E.polygonChecker(island,E.reserve+0.18,false) end
    -- Cache on a 0.25 m grid. Add its half-diagonal to the reserve so rounding
    -- can NEVER turn a failed clearance sample into a successful one.
    local cache={}
    p.contains=function(x,z)
        local ix,iz=math.floor(x*4+0.5),math.floor(z*4+0.5)
        -- Numeric grid keys avoid allocating a coordinate string for every
        -- sampled corner, while retaining exactly the same grid and reserve.
        local column=cache[ix]
        if not column then column={};cache[ix]=column end
        if column[iz]~=nil then return column[iz] end
        local q={x=ix/4,z=iz/4}
        local valid=fieldCheck(q)
        if valid then
            for _,check in ipairs(islandChecks) do
                if not check(q) then valid=false end
                if not valid then break end
            end
        end
        if valid then valid=CpFieldUtil.isOnField(q.x,q.z) and true or false end
        column[iz]=valid
        return valid
    end
    p.workedSide=G.workedSide(turn)
    p.dubins=G.analyticPath
    p.newTracker=function(path,screening) return G.tracker(p,path,screening) end
    return p
end

-- Keep only a numerical raised-state model for speculative preparation on a
-- later row. Equipment identity/width must match; every execution still scans
-- and validates the real current geometry. No scene nodes are moved here.
function G.turnModel(p)
    local model={width=p.width,side=E.turnSide(p),angle=E.wrap(p.start.phi-p.start.t),objects={},work={},footprint={}}
    for _,key in ipairs({'length','axleOffsetX','hitchX','hitchZ','front','workCentreX'}) do model[key]=p[key] end
    for i,entry in ipairs(p.objects) do model.objects[i]=entry.object end
    for _,key in ipairs({'work','footprint'}) do
        for i,m in ipairs(p[key]) do model[key][i]={x=m.x,z=m.z,towed=m.towed,rear=m.rear} end
    end
    return model
end

function G.applyTurnModel(p,model)
    if not model or math.abs(model.width-p.width)>0.001 or #model.objects~=#p.objects then return false end
    for i,entry in ipairs(p.objects) do if entry.object~=model.objects[i] then return false end end
    local mirror=E.turnSide(p)==model.side and 1 or -1
    for _,key in ipairs({'length','hitchZ','front'}) do p[key]=model[key] end
    for _,key in ipairs({'axleOffsetX','hitchX','workCentreX'}) do p[key]=model[key] and model[key]*mirror end
    p.start.phi=E.wrap(p.start.t+model.angle*mirror)
    for _,key in ipairs({'work','footprint'}) do
        p[key]={}
        for i,m in ipairs(model[key]) do p[key][i]={x=m.x*mirror,z=m.z,towed=m.towed,rear=m.rear} end
    end
    return true
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
    return error<=E.entryTolerance(p) and angle<=E.angleTolerance,error,angle,contact,s
end
