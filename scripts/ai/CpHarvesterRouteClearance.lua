-- Final clearance gate for harvester connecting paths only. Native turns,
-- unloading, crop costs and tractor implement entry remain unchanged.
CpHarvesterRouteClearance = {}
local R = CpHarvesterRouteClearance
local C = AIDriveStrategyCombineCourse

local function pose(node)
    local x,_,z=getWorldTranslation(node)
    local dx,_,dz=localDirectionToWorld(node,0,0,1)
    return {x=x,z=z,t=math.atan2(dx,dz)}
end

local function delta(a,b) return (b-a+math.pi)%(2*math.pi)-math.pi end
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end

function R.delete(check)
    if check and check.node then delete(check.node); check.node=nil end
end

function R.new(vehicle,course)
    if not course or course:getNumberOfWaypoints()<2 then return nil,'missing connector geometry' end
    local geometry=PathfinderUtil.VehicleData(vehicle,true,0)
    -- This gate covers self-propelled harvesters with mounted headers. A towed
    -- body requires articulated swept-path validation, not a rigid approximation.
    if geometry:getTowedImplement() then return nil,'unsupported towed body on harvester connector' end
    local raw=geometry:getVehicleOverlapBoxParams()
    local box={width=raw.width,length=raw.length,xOffset=raw.xOffset,zOffset=raw.zOffset}
    for _,key in ipairs({'width','length','xOffset','zOffset'}) do
        if not finite(box[key]) then return nil,'invalid harvester footprint' end
    end
    if box.width<=0 or box.length<=0 then return nil,'empty harvester footprint' end
    -- VehicleData's AI-marker rectangles do not retain its buffer argument.
    -- Expand both half-extents explicitly, without changing the native geometry.
    box.width=box.width+0.5; box.length=box.length+0.5
    local node=createTransformGroup('cpHarvesterConnectorClearance')
    link(getRootNode(),node)
    local origin=pose(vehicle:getAIDirectionNode())
    return {course=course,vehicle=vehicle,node=node,box=box,ix=1,step=0,
        previous=origin,origin=origin,
        radius=math.sqrt((box.width+math.abs(box.xOffset))^2+(box.length+math.abs(box.zOffset))^2),
        detector=PathfinderCollisionDetector(vehicle,{}, {},false,CpUtil.getDefaultCollisionFlags())}
end

function R.clear(check,p)
    PathfinderUtil.setWorldPositionAndRotationOnTerrain(check.node,p.x,p.z,p.t,0.5)
    local rx,ry,rz=getWorldRotation(check.node)
    local b=check.box
    local x,y,z=localToWorld(check.node,b.xOffset,1,b.zOffset)
    local detector=check.detector
    detector.currentOverlapBoxPosition={pos={x,y,z},direction={math.sin(ry),math.cos(ry)},
        size=math.max(b.width,b.length)}
    detector.collidingShapes=0; detector.collidingShapesText='unknown'
    -- Use native filtering, without accumulating the pathfinder debug boxes.
    overlapBox(x,y+0.2,z,rx,ry,rz,b.width,1,b.length,'_overlapBoxCallback',detector,
        detector.collisionMask,true,true,true,true)
    return detector.collidingShapes==0,detector.collidingShapesText
end

-- Includes the approach from the current pose, every edge, both endpoints and
-- rotation of the full footprint. The 0.5 m buffer exceeds the maximum 0.25 m
-- displacement of any corner between samples; it is not a work-width circle.
function R.step(check)
    if not check.target then
        if check.ix>check.course:getNumberOfWaypoints() then return true,true end
        local x,_,z=check.course:getWaypointPosition(check.ix)
        local t=check.course:getWaypointYRotation(check.ix)
        if check.course:isReverseAt(check.ix) then t=t+math.pi end
        if not finite(x) or not finite(z) or not finite(t) then return true,false,'invalid connector waypoint' end
        check.target={x=x,z=z,t=t}
        local a=check.previous
        local travel=math.sqrt((x-a.x)^2+(z-a.z)^2)
        check.angle=delta(a.t,t)
        check.steps=math.max(1,math.ceil((travel+check.radius*math.abs(check.angle))/0.25))
        check.step=0
    end
    local a,b=check.previous,check.target
    local f=check.step/check.steps
    local p={x=a.x+(b.x-a.x)*f,z=a.z+(b.z-a.z)*f,t=a.t+check.angle*f}
    local clear,object=R.clear(check,p)
    if not clear then
        return true,false,string.format('waypoint %d at %.1f, %.1f: %s',check.ix,p.x,p.z,object)
    end
    check.step=check.step+1
    if check.step>check.steps then
        check.previous=b; check.target=nil; check.ix=check.ix+1
    end
    return false
end

function R.cancel(driver)
    local pending=driver.connectorClearance
    if pending then R.delete(pending.check); driver.connectorClearance=nil end
end

function R.reject(driver,fallback,reason)
    driver:debug('Connector clearance rejected: %s',reason)
    if fallback then
        driver:debug('Validating original connector fallback')
        R.begin(driver,fallback,nil)
    else
        driver:debug('No validated connector available; stopping before driving')
        driver.vehicle:stopCurrentAIJob(AIMessageCpErrorNoPathFound.new())
    end
end

function R.begin(driver,course,fallback)
    R.cancel(driver)
    driver.state=driver.states.WAITING_FOR_PATHFINDER
    driver:setMaxSpeed(0)
    driver:raiseImplements()
    if not course or course:getNumberOfWaypoints()<2 then
        R.reject(driver,fallback,'missing connector course'); return
    end
    -- StartRowOnly appends/adjusts entry waypoints. Do this once on a copy,
    -- then validate and install exactly that same prepared course.
    local starter=StartRowOnly(driver.vehicle,driver,driver.ppc,driver.turnContext,course:copy())
    driver.connectorClearance={starter=starter,fallback=fallback,context=driver.turnContext}
    driver:debug('Validating final connector with full harvester/header footprint')
end

function R.update(driver)
    local pending=driver.connectorClearance
    if not pending then return end
    if driver.state~=driver.states.WAITING_FOR_PATHFINDER or driver.turnContext~=pending.context then
        R.cancel(driver); return
    end
    driver:setMaxSpeed(0)
    local course=pending.starter:getCourse()
    driver:updateFieldworkOffset(course)
    local offsetX,offsetZ=course:getOffset()
    local current=pose(driver.vehicle:getAIDirectionNode())
    local check=pending.check
    local moving=driver.vehicle:getLastSpeed()>0.1
    if check and (moving or math.abs(current.x-check.origin.x)>0.05 or
            math.abs(current.z-check.origin.z)>0.05 or
            math.abs(delta(current.t,check.origin.t))>math.rad(0.5) or
            offsetX~=pending.offsetX or offsetZ~=pending.offsetZ) then
        R.delete(check); pending.check=nil
    end
    -- Braking changes the approach geometry. Capture it only once stopped;
    -- discard any partial scan if the vehicle or its fieldwork offset changes.
    if moving then return end
    if not pending.check then
        local reason
        pending.check,reason=R.new(driver.vehicle,course)
        if not pending.check then
            R.cancel(driver); R.reject(driver,pending.fallback,reason); return
        end
        pending.offsetX=offsetX; pending.offsetZ=offsetZ
    end
    -- Shared across harvesters: no more than one 2 ms slice per update frame.
    if R.frame==g_updateLoopIndex then return end
    R.frame=g_updateLoopIndex
    local timer=openIntervalTimer()
    local done,clear,reason
    local samples=0
    repeat
        done,clear,reason=R.step(pending.check)
        samples=samples+1
    until done or samples>=32 or readIntervalTimerMs(timer)>=2
    closeIntervalTimer(timer)
    if not done then return end
    R.cancel(driver)
    if not clear then R.reject(driver,pending.fallback,reason); return end
    driver:debug('Final connector clearance passed; starting validated course')
    driver.workStarter=pending.starter
    driver.state=driver.states.DRIVING_TO_WORK_START_WAYPOINT
    driver.ppc:setShortLookaheadDistance()
    driver:startCourse(pending.starter:getCourse(),1)
end

function C:onPathfindingDoneToConnectingPathEnd(controller,success,course,goalNodeInvalid)
    R.begin(self,success and course or self.workStarterCourse,
        success and course~=self.workStarterCourse and self.workStarterCourse or nil)
end

local failed=C.onPathfindingFailedToConnectingPathEnd
function C:onPathfindingFailedToConnectingPathEnd(controller,context,lastRetry,attempt)
    if lastRetry then R.begin(self,self.workStarterCourse,nil)
    else return failed(self,controller,context,lastRetry,attempt) end
end

local update=C.update
function C:update(dt)
    update(self,dt)
    R.update(self)
end

local remove=C.delete
function C:delete()
    R.cancel(self)
    return remove(self)
end

local last=C.onLastWaypointPassed
function C:onLastWaypointPassed(...)
    if self.connectorClearance then return end
    return last(self,...)
end
