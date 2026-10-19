-- Queue clearance only. Native CP owns full-trailer departure and AD handover.
local Q = CpUnloaderQueue
local W = CpUnloaderQueueWorld
local G = CpUnloaderQueueGeometry
local H = HeadlandLoopGeometry
local function distance(a,b) return math.sqrt((a.x-b.x)^2+(a.z-b.z)^2) end

-- Only an empty harvester at the original course end may cross crop to park.
-- Forward candidates retain the complete mounted-header sweep, field boundary
-- and native collision filtering. No ordinary harvesting route is changed.
local function finishEnd(combine)
    return combine.unloadState==combine.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED
        or (combine.state==combine.states.WORKING and combine.course==combine.fieldWorkCourse
            and combine.course:getCurrentWaypointIx()>=combine.course:getNumberOfWaypoints())
end

local function rigidRectangles(model,root,buffer)
    local result={}
    for i,body in ipairs(model.bodies) do
        local r=model.relative[i]
        local x,z=H.math.position(root,r.x,r.z)
        result[#result+1]=W.rectangle(body,{x=x,z=z,t=root.t+r.t},buffer)
    end
    return result
end

local function rigidCorner(model)
    local corner=0
    for _,rect in ipairs(rigidRectangles(model,{x=0,z=0,t=0},0)) do
        for _,p in ipairs(rect) do corner=math.max(corner,math.sqrt(p.x*p.x+p.z*p.z)) end
    end
    return corner
end

local function coursePose(course,ix)
    local x,_,z=course:getWaypointPosition(ix)
    return {x=x,z=z,t=course:getWaypointYRotation(ix)}
end

-- Reserve the finish before adjacent headers get there together. Only the final
-- straight of the original grain-harvesting course participates: the physically
-- leading harvester unloads and parks first, then the next may finish its row.
local function finalApproach(combine)
    local vehicle,course=combine.vehicle,combine.fieldWorkCourse
    if not vehicle.spec_combine or not course or not combine.settings
            or not combine.settings.restartCourseAtEnd or not combine.settings.selfUnload
            or combine.settings.restartCourseAtEnd:getValue() or combine.settings.selfUnload:getValue()
            or combine:isAttachedHarvester() or combine:isChopper() then return end
    local _,steeringLength=AIUtil.getSteeringParameters(vehicle)
    if steeringLength~=0 then return end
    local last=course:getNumberOfWaypoints()
    local goal=coursePose(course,last)
    if combine.queueFinishClearance or finishEnd(combine) then return 0,goal end
    if combine.state~=combine.states.WORKING or combine.course~=course or combine:isTurning() then return end
    local ix=course:getCurrentWaypointIx()
    if course:getDistanceToLastWaypoint(ix)>120 then return end
    for i=ix,last do
        if course:isOnHeadland(i) or course:isOnConnectingPath(i) or course:isTurnStartAtIx(i)
                or math.abs(H.math.delta(course:getWaypointYRotation(i),goal.t))>math.rad(5) then return end
    end
    local remaining=distance(W.pose(vehicle:getAIDirectionNode()),goal)
    if remaining<=120 then return remaining,goal end
end

-- Queue parking must leave the final straight, unloading lane and header exit
-- free before the combine reaches its last waypoint. Native unloaders may still
-- service that space; this is a waiting-slot reservation, not a collision bypass.
function Q.finishLane(combine)
    if not combine or not combine.vehicle or not combine.vehicle.getIsCpActive
            or not combine.states or not combine.isAttachedHarvester
            or not combine.isChopper or not combine.isTurning or not combine.vehicle:getIsCpActive() then return end
    local remaining,goal=finalApproach(combine)
    if not remaining then return end
    local model=W.rigidModel(combine.vehicle)
    if not model then return end
    local radius=combine.turningRadius or 0
    local left,right=-math.huge,math.huge
    for _,rect in ipairs(rigidRectangles(model,{x=0,z=0,t=0},0)) do
        for _,p in ipairs(rect) do left=math.max(left,p.x); right=math.min(right,p.x) end
    end
    local back=model.back-math.max(remaining,35)
    local front=model.front+40+radius
    local area=G.rectangle({x=goal.x,z=goal.z,heading=goal.t},
        {width=left-right+2*radius,length=front-back,xOffset=(left+right)/2,zOffset=(front+back)/2},2)
    return function(rectangle) return G.overlap(rectangle,area) end
end

function Q.finishLanes()
    local areas={}
    for _,vehicle in pairs(g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles or {}) do
        if vehicle.spec_combine and vehicle.getCpDriveStrategy then
            local area=Q.finishLane(vehicle:getCpDriveStrategy())
            if area then areas[#areas+1]=area end
        end
    end
    return areas
end

function Q.holdFinalApproach(combine)
    local remaining,goal=finalApproach(combine)
    if not remaining or remaining==0 then return end
    -- The following header must also stay behind the outgoing trailer's full
    -- 15 m reverse clearance, not merely behind the lead harvester's chassis.
    local rigLength=0
    for _,vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        local driver=vehicle.getCpDriveStrategy and vehicle:getCpDriveStrategy()
        if driver and driver.startUnloadingStoppedCombine and driver.isServingPosition
                and driver:isServingPosition(goal.x,goal.z,10) then
            rigLength=math.max(rigLength,AIUtil.getLength(vehicle))
        end
    end
    local clearance=math.max(35,(combine:getWorkWidth() or 0)+(combine.turningRadius or 0),
        15+rigLength+(combine.vehicle.size.length or 10)+5)
    if remaining>clearance then return end
    local here=W.pose(combine.vehicle:getAIDirectionNode())
    for _,vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle~=combine.vehicle and AIDriveStrategyCombineCourse.isActiveCpCombine(vehicle)
                and combine.fieldWorkerProximityController
                and combine.fieldWorkerProximityController:hasSameCourse(vehicle) then
            local other=vehicle:getCpDriveStrategy()
            local ahead,otherGoal=finalApproach(other)
            if ahead and distance(goal,otherGoal)<2*clearance
                    and math.abs(H.math.delta(goal.t,otherGoal.t))<math.rad(10) then
                local there=W.pose(vehicle:getAIDirectionNode())
                local forward=(there.x-here.x)*math.sin(goal.t)+(there.z-here.z)*math.cos(goal.t)
                if other.queueFinishClearance or forward>0 or (forward==0
                        and tostring(vehicle.rootNode)<tostring(combine.vehicle.rootNode)) then return vehicle end
            end
        end
    end
end

local function finishCandidates(data,combine)
    data.corner=rigidCorner(data.world.model)
    data.origin=W.pose(combine.vehicle:getAIDirectionNode())
    local model,course=data.world.model,combine.fieldWorkCourse
    local candidates={}
    local inset=math.max(model.front,-model.back)+10
    local last=course:getNumberOfWaypoints()
    local final=coursePose(course,last)
    local travelled=0
    -- Previously worked straight centre runs only. Keep the full parked header
    -- away from the final run and inset from row ends, turns and connectors.
    for ix=2,last-1 do
        travelled=travelled+distance(coursePose(course,ix),coursePose(course,ix-1))
        if travelled>=10 then
            travelled=0
            local p=coursePose(course,ix)
            local lateral=math.abs((p.x-final.x)*math.cos(final.t)-(p.z-final.z)*math.sin(final.t))
            local d=distance(data.origin,p)
            if d>=20 and d<=150 and lateral>model.width+5
                    and not course:isOnHeadland(ix) and not course:isOnConnectingPath(ix) then
                local first=course:getPreviousWaypointIxWithinDistance(ix,inset)
                local finish=course:getNextWaypointIxWithinDistance(ix,inset)
                local valid=first and finish and distance(coursePose(course,first),p)>=inset
                    and distance(coursePose(course,finish),p)>=inset
                if valid then
                    for i=first,finish do
                        if course:isOnHeadland(i) or course:isOnConnectingPath(i)
                                or course:isTurnStartAtIx(i) or course:isTurnEndAtIx(i)
                                or math.abs(H.math.delta(course:getWaypointYRotation(i),p.t))>math.rad(5) then
                            valid=false; break
                        end
                    end
                end
                if valid then
                    -- Either heading along the completed row is suitable.
                    for _,turn in ipairs({0,math.pi}) do
                        candidates[#candidates+1]={goal={x=p.x,z=p.z,t=p.t+turn},ix=ix,distance=d}
                    end
                end
            end
        end
    end
    table.sort(candidates,function(a,b)
        if a.distance~=b.distance then return a.distance<b.distance end
        if a.ix~=b.ix then return a.ix<b.ix end
        return a.goal.t<b.goal.t
    end)
    data.candidates=candidates; data.candidate=1; data.sample=0
end

-- Prefer an explicit headland straight between the two turns. The entire
-- prefix and connection are swept; direct curves remain checked fallbacks when
-- the boundary/header cannot accommodate the extra headland travel.
local function finishRouteOptions(data,combine,route)
    local radius=combine.turningRadius
    if not radius or not H.math.finite(radius) or radius<=0 then return {} end
    local origin,goal=data.origin,route.goal
    local target=State3D(goal.x,-goal.z,CpMathUtil.angleFromGame(goal.t))
    local lateral=(goal.x-origin.x)*math.cos(origin.t)-(goal.z-origin.z)*math.sin(origin.t)
    local options,seen={},{}
    local function add(lead,types,priority,headland)
        local x,z=H.math.position(origin,0,lead)
        local heading,prefix=origin.t,lead
        local side=lateral>=0 and 1 or -1
        if headland then
            x,z=H.math.position({x=x,z=z,t=heading},side*radius,radius)
            heading=heading+side*math.pi/2
            x,z=H.math.position({x=x,z=z,t=heading},0,headland)
            prefix=prefix+radius*math.pi/2+headland
        end
        local start=State3D(x,-z,CpMathUtil.angleFromGame(heading))
        local solution,word=DubinsSolver(types):solve(start,target,radius)
        if not solution then return end
        local length=solution:getLength(radius)
        local key=string.format('%.2f:%.2f:%s',lead,headland or 0,word)
        if prefix+length<=200 and not seen[key] then
            seen[key]=true
            options[#options+1]={solution=solution,lead=lead,length=length,word=word,priority=priority,
                prefix=prefix,headland=headland,side=side}
        end
    end
    -- Room for a quarter turn at each end and at least eight metres parallel
    -- to the headland. A close row cannot satisfy that geometry without a loop.
    if math.abs(lateral)>=2*radius+8 then add(3,nil,0,math.min(20,math.abs(lateral)-2*radius)) end
    add(3,nil,1)
    local length=data.world.model.front-data.world.model.back
    local leads={3,0,math.min(40,math.max(8,length)),math.min(40,math.max(8,length)+radius)}
    for _,lead in ipairs(leads) do
        for pathType=DubinsSolver.PathType.LSL,DubinsSolver.PathType.LRL do add(lead,{pathType},2) end
    end
    table.sort(options,function(a,b)
        if a.priority~=b.priority then return a.priority<b.priority end
        if a.prefix+a.length~=b.prefix+b.length then return a.prefix+a.length<b.prefix+b.length end
        if a.lead~=b.lead then return a.lead<b.lead end
        return a.word<b.word
    end)
    return options
end

-- Sample the actual curve, including the entire straight lead-out and header.
function Q.finishRoute(data,combine,route)
    if route.points then return true end
    route.options=route.options or finishRouteOptions(data,combine,route)
    route.option=route.option or 1
    local option=route.options[route.option]
    if not option then return false end
    local radius,origin,goal=combine.turningRadius,data.origin,route.goal
    local points={}
    local count=math.max(1,math.ceil(option.lead/0.5))
    for i=0,count do
        local s=option.lead*i/count
        local x,z=H.math.position(origin,0,s)
        if i==0 or s>0 then points[#points+1]={x=x,z=z,t=origin.t,s=s} end
    end
    local step=0.25/(1+data.corner/radius)
    if option.headland then
        local start=points[#points]
        local arc=radius*math.pi/2
        count=math.ceil(arc/step)
        for i=1,count do
            local angle=math.pi/2*i/count
            local x,z=H.math.position(start,option.side*radius*(1-math.cos(angle)),radius*math.sin(angle))
            points[#points+1]={x=x,z=z,t=start.t+option.side*angle,s=option.lead+arc*i/count}
        end
        start=points[#points]; count=math.ceil(option.headland/0.25)
        for i=1,count do
            local length=option.headland*i/count
            local x,z=H.math.position(start,0,length)
            points[#points+1]={x=x,z=z,t=start.t,s=start.s+length}
        end
    end
    local samples=dubins_path_sample_many(option.solution.pathDescriptor,step)
    local distances=CpMathUtil.getSeries(0,option.length,step)
    for i=2,#samples do
        local p=samples[i]
        points[#points+1]={x=p.x,z=-p.y,t=CpMathUtil.angleToGame(p.t),s=option.prefix+distances[i]}
    end
    if distance(points[#points],goal)<0.000001 then table.remove(points) end
    points[#points+1]={x=goal.x,z=goal.z,t=goal.t,s=option.prefix+option.length}
    route.points=points; route.goal=points[#points]
    route.angle=H.math.delta(goal.t,origin.t)
    return true
end

-- Keep terminal chassis/header footprints out of the other worker's body and
-- pipe lane, including whole-train rear entry and native 15 m reverse exit.
-- Use actual local unloader dimensions and configured pipe offsets.
function Q.finishParkingClear(combine,model,pose)
    local rectangles=rigidRectangles(model,pose,1)
    local vehicles=g_currentMission.vehicleSystem.vehicles
    local function overlaps(area)
        for _,rect in ipairs(rectangles) do if G.overlap(rect,area) then return true end end
        return false
    end
    for _,vehicle in pairs(vehicles) do
        if vehicle~=combine.vehicle and AIDriveStrategyCombineCourse.isActiveCpCombine(vehicle)
                and combine.fieldWorkerProximityController:hasSameCourse(vehicle) then
            local other=vehicle:getCpDriveStrategy()
            local otherModel=W.rigidModel(vehicle)
            if not otherModel then return false,'neighbour geometry unavailable' end
            local targets={{pose=otherModel.root}}
            -- Reserve the following worker's end unloading space now, even if
            -- it is still harvesting more than 100 m away or currently empty.
            if not other.queueFinishClearance and other.fieldWorkCourse then
                local course=other.fieldWorkCourse
                targets[#targets+1]={pose=coursePose(course,course:getNumberOfWaypoints()),future=true}
            end
            for _,target in ipairs(targets) do
                if distance(pose,target.pose)<100 then
                    for _,rect in ipairs(rigidRectangles(otherModel,target.pose,target.future and 6 or 1)) do
                        if overlaps(rect) then return false,'neighbour header/body clearance' end
                    end
                    if not other.queueFinishClearance and (target.future or other.combineController:getFillLevel()>=0.01) then
                        local found=false
                        for _,tractor in pairs(vehicles) do
                            local driver=tractor.getCpDriveStrategy and tractor:getCpDriveStrategy()
                            if driver and driver.startUnloadingStoppedCombine and driver.settings
                                    and driver.settings.combineOffsetX and driver.settings.combineOffsetZ
                                    and ((driver.isServingPosition and driver:isServingPosition(otherModel.root.x,otherModel.root.z,10))
                                        or distance(otherModel.root,W.pose(tractor:getAIDirectionNode()))<150) then
                                local rig=W.model(tractor)
                                if not rig then return false,'unloader geometry unavailable' end
                                found=true
                                local x,z=other:getPipeOffset(-driver.settings.combineOffsetX:getValue(),driver.settings.combineOffsetZ:getValue())
                                local reference=W.pose(other:getPipeOffsetReferenceNode())
                                if target.future then
                                    local root=otherModel.root
                                    local dx,dz=reference.x-root.x,reference.z-root.z
                                    local x,z=H.math.position(target.pose,dx*math.cos(root.t)-dz*math.sin(root.t),
                                        dx*math.sin(root.t)+dz*math.cos(root.t))
                                    reference={x=x,z=z,t=target.pose.t+H.math.delta(reference.t,root.t)}
                                end
                                local poses=W.settledPoses(rig,{x=0,z=0,t=0})
                                local left,right,front,back=-math.huge,math.huge,-math.huge,math.huge
                                local length=0
                                for _,link in ipairs(rig.links) do length=length+math.abs(link.length) end
                                for i,body in ipairs(rig.bodies) do
                                    for _,p in ipairs(W.rectangle(body,poses[i],0)) do
                                        left=math.max(left,p.x); right=math.min(right,p.x)
                                        front=math.max(front,p.z); back=math.min(back,p.z)
                                    end
                                end
                                -- A whole-train length ahead covers filling any trailer
                                -- compartment; the rear lane covers entry and reversing.
                                local neighbourBack=math.huge
                                for _,rect in ipairs(rigidRectangles(otherModel,target.pose,0)) do
                                    for _,p in ipairs(rect) do
                                        local along=(p.x-reference.x)*math.sin(reference.t)+(p.z-reference.z)*math.cos(reference.t)
                                        neighbourBack=math.min(neighbourBack,along)
                                    end
                                end
                                local rear=math.min(z,neighbourBack-5)-math.max(15,3*length)
                                local lane={left=x+left,right=x+right,front=z+front+front-back,back=rear+back}
                                if overlaps(W.rectangle(lane,reference,1)) then return false,'neighbour unloading access' end
                            end
                        end
                        if not found then return false,'neighbour unloader geometry unavailable' end
                    end
                end
            end
        end
    end
    return true
end

local function finishDestinationClear(combine,model,pose)
    -- Crop crossing is allowed on the final approach, not at the parked centre
    -- position: the complete unfolded footprint must be on harvested ground.
    for _,rectangle in ipairs(rigidRectangles(model,pose,0)) do
        local clear,reason=W.cropFree(combine.queueFinishClearance.world,rectangle)
        if not clear then return false,reason end
    end
    return Q.finishParkingClear(combine,model,pose)
end

function Q.beginFinishClearance(combine)
    if combine.queueFinishAttempted or combine.queueFinishClearance or not finishEnd(combine) then return false end
    if not combine.vehicle.spec_combine or combine:isAttachedHarvester() or combine:isChopper()
            or combine.settings.selfUnload:getValue() or combine.combineController:getFillLevel()>=0.01
            or combine.settings.restartCourseAtEnd:getValue() then return false end
    local _,steeringLength=AIUtil.getSteeringParameters(combine.vehicle)
    if steeringLength~=0 then return false end
    local origin=W.pose(combine.vehicle:getAIDirectionNode())
    local model,reason=W.rigidModel(combine.vehicle)
    local world
    if model then world,reason=W.new(combine,model) end
    combine.queueFinishAttempted=true
    local data={world=world,origin=origin,started=g_currentMission.time,
        progressTime=g_currentMission.time,progress=origin}
    combine.queueFinishClearance=data
    -- Take final-state ownership even when geometry is temporarily unavailable;
    -- a last-waypoint callback alone cannot hold the vehicle on later updates.
    if world then
        world.finalParking=data
        finishCandidates(data,combine)
    else
        data.reason=reason or 'geometry unavailable'
        data.retryAt=g_currentMission.time+3000
        combine:debug('Queue: final parking waiting unfolded: %s',data.reason)
    end
    combine.aiOffsetX=0; combine.aiOffsetZ=0; combine.tightTurnOffset=0
    combine.state=combine.states.UNLOADING_ON_FIELD
    combine.unloadState={name='CLEARING_FINAL_UNLOAD',properties={}}
    combine:raiseImplements()
    combine:setMaxSpeed(0)
    combine:debug('Queue: parking on a completed centre run after final unload; waiting for trailer clearance')
    return true
end

function Q.clearFinishClearance(combine)
    local data=combine.queueFinishClearance
    if data then W.delete(data.world); combine.queueFinishClearance=nil end
end

local function retryFinishClearance(combine,reason)
    local data=combine.queueFinishClearance
    if not data then return end
    if data.reason~=reason then
        data.reason=reason
        combine:debug('Queue: final parking waiting unfolded: %s',reason)
    end
    data.driving=nil; data.route=nil; data.goal=nil; data.nearest=nil
    data.nextCheck=nil; data.clear=nil
    data.clearanceStarted=nil; data.progressTime=g_currentMission.time
    data.progress=W.pose(combine.vehicle:getAIDirectionNode())
    data.retryAt=g_currentMission.time+3000
    data.candidates=nil
    combine:setMaxSpeed(0)
end

function Q.completeFinishClearance(combine,reason)
    if reason~='completed' then retryFinishClearance(combine,reason); return end
    if not combine.queueFinishClearance then return end
    combine:debug('Queue: final parking clearance %s',reason)
    Q.clearFinishClearance(combine)
    combine.state=combine.states.UNLOADING_ON_FIELD
    combine.unloadState=combine.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED
    combine:setMaxSpeed(0)
    AIDriveStrategyFieldWorkCourse.finishFieldWork(combine)
end

local function finishNearClear(data,here,nearest)
    if not W.rigidClear(data.world,here) then return false end
    local previous=here
    for i=nearest,#data.route.points do
        local p=data.route.points[i]
        if p.s-data.route.points[nearest].s>4 then break end
        local yaw=H.math.delta(p.t,previous.t)
        local count=math.max(1,math.ceil((distance(previous,p)+data.corner*math.abs(yaw))/0.5))
        for j=1,count do
            local f=j/count
            if not W.rigidClear(data.world,{x=previous.x+(p.x-previous.x)*f,
                    z=previous.z+(p.z-previous.z)*f,t=previous.t+yaw*f}) then return false end
        end
        previous=p
    end
    return true
end

function Q.driveFinishClearance(combine)
    local data=combine.queueFinishClearance
    if not data then return end
    local time=g_currentMission.time
    if combine.combineController:getFillLevel()>=0.01 then
        Q.clearFinishClearance(combine)
        combine.queueFinishAttempted=nil
        combine.state=combine.states.UNLOADING_ON_FIELD
        combine.unloadState=combine.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED
        combine:setMaxSpeed(0)
        return
    end
    if not data.driving and data.retryAt and time<data.retryAt then combine:setMaxSpeed(0); return end
    if not data.driving then
        -- Releasing the assignment starts native reverse clearance; it does not
        -- mean the trailer is clear. Let that manoeuvre finish before parking.
        for _,vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
            local driver=vehicle.getCpDriveStrategy and vehicle:getCpDriveStrategy()
            local states=driver and driver.states
            local backing=states and (driver.state==states.MOVING_BACK
                or driver.state==states.MOVING_BACK_WITH_TRAILER_FULL)
            if driver and (driver.combineToUnload==combine.vehicle
                    or (backing and driver.state.properties.vehicle==combine.vehicle)) then
                local pose=W.pose(vehicle:getAIDirectionNode())
                local wait=data.waitingTrailer
                if not wait or wait.vehicle~=vehicle or distance(pose,wait.pose)>0.5 then
                    wait={vehicle=vehicle,pose=pose,time=time}; data.waitingTrailer=wait
                end
                if time-wait.time>120000 then
                    Q.completeFinishClearance(combine,'unloader clearance made no progress'); return
                end
                combine:setMaxSpeed(0); return
            end
        end
        data.waitingTrailer=nil
        if Q.clearFinishTraffic(combine) then combine:setMaxSpeed(0); return end
        data.clearanceStarted=data.clearanceStarted or time
    end
    local here=W.pose(combine.vehicle:getAIDirectionNode())
    local model=W.rigidModel(combine.vehicle)
    if not model then Q.completeFinishClearance(combine,'geometry unavailable'); return end
    if not data.world then
        local reason
        data.world,reason=W.new(combine,model)
        if not data.world then retryFinishClearance(combine,reason or 'world unavailable'); return end
        data.world.finalParking=data
    end
    local changed=not W.sameRigidShape(data.world.model,model)
    data.world.model=model
    if data.driving then
        if changed then data.corner=rigidCorner(model) end
        if distance(here,data.progress)>0.5 then data.progress=here; data.progressTime=time end
        if time-data.progressTime>10000 then Q.completeFinishClearance(combine,'stopped by an obstruction'); return end
        if distance(here,data.goal)<=1 and math.abs(H.math.delta(here.t,data.goal.t))<=math.rad(5) then
            if W.rigidClear(data.world,here) and finishDestinationClear(combine,model,here) then
                Q.completeFinishClearance(combine,'completed'); return
            end
            if distance(here,data.goal)<0.1 then combine:setMaxSpeed(0); return end
            -- A near-goal pose may still overlap the reserved lane or crop
            -- edge. Continue the checked final metre rather than stop short.
        end
        local nearest,best=data.nearest or 1,math.huge
        for i=nearest,math.min(#data.route.points,nearest+40) do
            local d=distance(here,data.route.points[i])
            if d<best then best=d; nearest=i end
        end
        data.nearest=nearest
        if best>1 or math.abs(H.math.delta(here.t,data.route.points[nearest].t))>math.rad(10) then
            Q.completeFinishClearance(combine,'aborted after route deviation'); return
        end
        if changed or not data.nextCheck or time>=data.nextCheck then
            data.nextCheck=time+200
            data.clear=finishNearClear(data,here,nearest)
        end
        combine:setMaxSpeed(data.clear and 5 or 0)
        return
    end
    combine:setMaxSpeed(0)
    if data.retryAt and time<data.retryAt then return end
    if changed or not data.candidates then finishCandidates(data,combine) end
    local route=data.candidates[data.candidate]
    if not route then retryFinishClearance(combine,'no completed centre-run destination available'); return end
    if not Q.finishRoute(data,combine,route) then
        data.candidate=data.candidate+1; data.sample=0; return
    end
    local timer=openIntervalTimer()
    local reason
    for checked=1,8 do
        local clear
        clear,reason=W.rigidClear(data.world,route.points[data.sample+1])
        if not clear then break end
        data.sample=data.sample+1
        if data.sample==#route.points or readIntervalTimerMs(timer)>=2 then break end
    end
    closeIntervalTimer(timer)
    if not reason and data.sample==#route.points then
        local clear
        clear,reason=finishDestinationClear(combine,model,route.goal)
        if clear then
            data.route=route; data.goal=route.goal; data.driving=true; data.progressTime=time
            local points={}
            for _,p in ipairs(route.points) do points[#points+1]={x=p.x,z=p.z} end
            combine.ppc:setShortLookaheadDistance()
            combine:startCourse(Course(combine.vehicle,points,true),1)
            combine:debug('Queue: final parking %.1f m to completed centre waypoint %d, lead-out %.1f m, turn %s',
                route.goal.s,route.ix,route.options[route.option].lead,route.options[route.option].word)
            return
        end
    end
    if reason then
        local detail=data.world.failureDetail or reason
        combine:debug('Queue: final parking candidate %d route %d rejected after %.1f m: %s',
            data.candidate,route.option,route.points[math.min(data.sample+1,#route.points)].s,detail)
        -- Every route starts at the same pose. A blocked start needs clearance,
        -- not another full candidate cycle or permission to cross the obstacle.
        if data.sample==0 then retryFinishClearance(combine,'start blocked: '..detail); return end
        local destinationRejected=data.sample==#route.points
        route.points=nil
        route.option=route.option+1; data.sample=0
        if destinationRejected or route.option>#route.options then data.candidate=data.candidate+1 end
        if data.candidate>#data.candidates then
            retryFinishClearance(combine,'no checked route to a completed centre run')
        end
    end
end

-- Final loads always hand over through native reverse clearance, including a
-- moving rendezvous that emptied at course end or a successful job stop that
-- already removed the combine strategy. Departure and AutoDrive stay native.
function Q.hasRemainingCombine(driver,finished)
    for _,vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle~=finished and AIDriveStrategyCombineCourse.isActiveCpCombine(vehicle) then
            local combine=vehicle:getCpDriveStrategy()
            local x,_,z=getWorldTranslation(vehicle.rootNode)
            if not combine.queueFinishClearance and driver:isServingPosition(x,z,10) then return true end
        end
    end
    return false
end

function Q.releaseFinishedCombine(driver)
    local combine=driver.combineToUnload
    if not Q.enabled(driver) or not combine or (driver.state~=driver.states.UNLOADING_STOPPED_COMBINE
            and driver.state~=driver.states.UNLOADING_MOVING_COMBINE) then return false end
    if combine:getIsCpActive() then
        local c=combine:getCpDriveStrategy()
        if not c or not c.isWaitingForUnloadAfterCourseEnded or not c.combineController
                or c.combineController:getFillLevel()>=0.01 or c:alwaysNeedsUnloader() then return false end
        local nearing=Q.finishLane(c)~=nil
        if not c:isWaitingForUnloadAfterCourseEnded() and not nearing then return false end
        local model=nearing and W.rigidModel(combine)
        if model then
            Q.data(driver).finalRelease={vehicle=combine,strategy=c,course=c.fieldWorkCourse,
                origin=W.pose(combine:getAIDirectionNode()),length=model.front-model.back}
        end
    elseif not combine.queueFinishedEmptyCombine then return false end
    local leave=Q.atDepartureThreshold(driver) or driver:isDriveUnloadNowRequested()
    if not leave then
        local c=combine:getIsCpActive() and combine:getCpDriveStrategy()
        local stillHarvesting=c and not c:isWaitingForUnloadAfterCourseEnded()
        leave=not stillHarvesting and not Q.hasRemainingCombine(driver,combine)
    end
    Q.cancel(driver)
    local data=driver.queueData
    if data then
        data.assignment=nil; data.waitingApproach=nil; data.approachRetryAt=nil
        data.operation=nil; data.yieldRequests=nil; data.priorityCombine=nil
    end
    driver.ppc:setNormalLookaheadDistance()
    driver:releaseCombine()
    driver:debug('Queue: finished combine released; reversing clear before %s',leave and 'native departure' or 'waiting for another combine')
    driver:startMovingBackFromCombine(leave and driver.states.MOVING_BACK_WITH_TRAILER_FULL
        or driver.states.MOVING_BACK,combine,false)
    return true
end

-- Reverse clearance remains native. Afterwards the released rig waits until
-- the harvester has moved a complete body/header length or completed parking.
-- A new stationary unload request releases the wait, avoiding a single-trailer
-- deadlock when only a short piece of the final row remains to harvest.
function Q.holdFinalRelease(driver)
    local data=driver.queueData
    local pause=data and data.finalRelease
    if not pause then return false end
    local combine=pause.vehicle:getCpDriveStrategy()
    local clear=not pause.vehicle:getIsCpActive() or combine~=pause.strategy
        or combine.fieldWorkCourse~=pause.course
    if not clear then
        local here=W.pose(pause.vehicle:getAIDirectionNode())
        local progress=(here.x-pause.origin.x)*math.sin(pause.origin.t)
            +(here.z-pause.origin.z)*math.cos(pause.origin.t)
        local needsUnload=combine.combineController:getFillLevel()>=0.01
            and combine.isWaitingForUnload and combine:isWaitingForUnload()
        clear=progress>=pause.length or needsUnload
    end
    if clear then data.finalRelease=nil; return false end
    return not Q.nativeClearanceActive(driver)
end

-- Preserve the serviced combine across native release/reversing/pathfinding.
-- The native pocket substate survives resuming work; only the outer unloading
-- state makes it an active pocket. Never arm a new hold from that stale substate.
function Q.capturePocketDeparture(driver,vehicle,onlyIfFull)
    if not Q.enabled(driver) then return end
    local data=Q.data(driver)
    if data.pocketDeparturePause then return end
    local combine=vehicle and vehicle:getCpDriveStrategy()
    if not combine or not combine.states or combine.state~=combine.states.UNLOADING_ON_FIELD
            or not combine.isAboutToReturnFromPocket or not combine:isAboutToReturnFromPocket() then return end
    if onlyIfFull and not (driver:isDriveUnloadNowRequested() or driver:getAllTrailersFull()) then return end
    local course,ix=Q.coursePosition(combine)
    local model=W.rigidModel(vehicle)
    local length=model and model.front-model.back
    if not course or not ix or course:getNumberOfWaypoints()<2 or not length or length<=0 then
        Q.reason(data,'pocket departure geometry unavailable; retaining native departure checks')
        return
    end
    data.pocketDeparturePause={vehicle=vehicle,strategy=combine,course=course,length=length}
end

local function pocketRowProgress(combine,pause,pose)
    if combine.state~=combine.states.WORKING or combine.course~=pause.course
            or (combine.aiOffsetX or 0)~=0 then return end
    local course,ix=Q.coursePosition(combine)
    if not course or not ix then return end
    -- Wait for the normal working offset to reach the course too. A frozen
    -- pocket position includes aiOffsetX and is not the row we must rejoin.
    local offsetX,offsetZ=course:getOffset()
    local normalX=combine.settings.toolOffsetX:getValue()+(combine.tightTurnOffset or 0)
    if math.abs(offsetX-normalX)>0.01 or math.abs(offsetZ-(combine.aiOffsetZ or 0))>0.01 then return end
    local nearest,progress
    -- PPC's relevant waypoint can be just ahead. Inspect only its neighbouring
    -- segments, never a globally nearest row which may belong to another pass.
    for i=math.max(1,ix-2),math.min(course:getNumberOfWaypoints()-1,ix+1) do
        local ax,_,az=course:getWaypointPosition(i)
        local bx,_,bz=course:getWaypointPosition(i+1)
        local dx,dz=bx-ax,bz-az
        local lengthSquared=dx*dx+dz*dz
        if lengthSquared>0.01 then
            local fraction=math.max(0,math.min(1,((pose.x-ax)*dx+(pose.z-az)*dz)/lengthSquared))
            local ex,ez=pose.x-ax-fraction*dx,pose.z-az-fraction*dz
            local gap=ex*ex+ez*ez
            if gap<=1.5^2 and (not nearest or gap<nearest)
                    and math.abs(H.math.delta(pose.t,math.atan2(dx,dz)))<=math.rad(15) then
                nearest=gap
                progress=course:getDistanceFromFirstWaypoint(i)+fraction*course:getDistanceToNextWaypoint(i)
            end
        end
    end
    return progress
end

function Q.holdPocketDeparture(driver,forwards,speed)
    local data=driver.queueData
    local pause=data and data.pocketDeparturePause
    if not pause then return false end
    if not Q.enabled(driver) then data.pocketDeparturePause=nil; return false end
    local vehicle=pause.vehicle
    if not vehicle:getIsCpActive() or vehicle:getCpDriveStrategy()~=pause.strategy
            or pause.strategy.fieldWorkCourse~=pause.course then
        -- A stopped/replaced job or course cannot complete this pocket exit.
        -- Native collision/proximity checks still govern departure past it.
        data.pocketDeparturePause=nil; return false
    end
    local pose=W.pose(vehicle:getAIDirectionNode())
    local progress=pocketRowProgress(pause.strategy,pause,pose)
    if progress then
        if not pause.exitPose or progress<(pause.lastProgress or progress)-0.05 then
            pause.exitPose=pose; pause.exitProgress=progress
        end
        pause.lastProgress=progress
        -- Net physical displacement cannot count oscillation, changed offsets
        -- or waypoint progress as travel. On a curve this is conservative: the
        -- actual forward path is at least as long as this measured clearance.
        local travelled=distance(pose,pause.exitPose)
        if progress-pause.exitProgress>=pause.length and travelled>=pause.length then
            driver:debug('Queue: combine left pocket and advanced %.1f m; departure released',travelled)
            data.pocketDeparturePause=nil; return false
        end
    else pause.exitPose=nil; pause.exitProgress=nil; pause.lastProgress=nil end
    if not data.nativeDeparture or driver.state~=driver.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL
            or not forwards then return false end
    if not pause.reported then
        driver:debug('Queue: holding pocket departure for physical exit and one full combine length')
        pause.reported=true
    end
    return true
end

-- Native marker travel remains native. Replan a motionless course from its
-- actual pose, without overriding obstacle brakes or fabricating an AD event.
function Q.watchNativeDeparture(driver,speed,held,forwards)
    local data=driver.queueData
    if not data or not data.nativeDeparture or Q.owns(driver)
            or driver.state~=driver.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL then return false end
    local time=g_currentMission.time
    local pose=W.pose(driver.vehicle:getAIDirectionNode())
    local watch=data.departureWatch
    if not watch then watch={pose=pose,time=time,attempts=0}; data.departureWatch=watch end
    if distance(pose,watch.pose)>1 then watch.pose=pose; watch.time=time; watch.attempts=0 end
    if held or (driver.isBeingHeld and driver:isBeingHeld()) then watch.time=time; return false end
    if time-watch.time<30000 or time-(watch.reported or 0)<30000 then return false end
    watch.reported=time
    local collision=driver.collisionAvoidanceController
    local warning=collision and collision:isCollisionWarningActive()
    local proximity=driver.proximityController
    local gap,vehicle,object,terrain
    if proximity then
        if forwards==false then gap,vehicle,object,terrain=proximity:checkBlockingVehicleBack()
        else gap,vehicle,object,terrain=proximity:checkBlockingVehicleFront() end
    end
    local staticObstacle=not vehicle and (object~=nil or terrain==true)
    if not vehicle and not staticObstacle and proximity and gap then
        local pack=forwards==false and proximity.backwardLookingProximitySensorPack
            or proximity.forwardLookingProximitySensorPack
        -- Map trees/buildings may have a raycast shape but no mission node object.
        -- Require the actual nearest sensor hit; an unclassified distance alone
        -- must not turn a vehicle/priority wait into a recovery attempt.
        for _,sensor in ipairs(pack and pack.sensors or {}) do
            if sensor.objectId and math.abs(sensor:getClosestObjectDistance()-gap)<0.01
                    and not sensor:getClosestRootVehicle() then staticObstacle=true; break end
        end
    end
    local ix=driver.ppc and driver.ppc:getRelevantWaypointIx()
    driver:debug('Queue: native departure stalled %.1f s at %.1f, %.1f waypoint %s speed %s collision %s obstacle %s (%s); retry %d/2',
        (time-watch.time)/1000,pose.x,pose.z,tostring(ix),tostring(speed),tostring(warning),tostring(gap),
        vehicle and 'vehicle' or staticObstacle and 'static' or 'unknown',watch.attempts)
    if warning or (gap and gap<15 and not staticObstacle) or watch.attempts>=2 then return false end
    watch.attempts=watch.attempts+1; watch.time=time
    driver:setMaxSpeed(0)
    driver:startUnloadingTrailers()
    return true
end

local function parkedQueueTrailer(driver)
    local data=driver and driver.queueData
    return data and Q.owns(driver) and data.operation=='prepare' and not data.nativeDeparture
        and not Q.atDepartureThreshold(driver) and not driver:isDriveUnloadNowRequested()
        and not driver.combineToUnload and AIUtil.isStopped(driver.vehicle)
end

-- A rig parked before the finish reservation became active must be asked to
-- clear explicitly: a stationary combine may never fire a proximity callback.
function Q.clearFinishTraffic(combine)
    local area=Q.finishLane(combine)
    if not area then return false end
    local pending=false
    for driver,data in pairs(Q.members) do
        local request=data.yieldRequests and data.yieldRequests[combine.vehicle]
        local released=data.finalRelease and data.finalRelease.strategy==combine
            and not Q.nativeClearanceActive(driver) and AIUtil.isStopped(driver.vehicle)
        if not request and (parkedQueueTrailer(driver) or released) then
            local blocked=false
            for _,item in ipairs(W.currentBodies(driver.vehicle) or {}) do
                if area(W.rectangle(item.body,item.pose)) then blocked=true end
            end
            if blocked then
                if data.nativeDeparture then Q.requestDepartureClearance(combine,driver,area)
                else Q.priority(driver,combine.vehicle) end
                request=data.yieldRequests and data.yieldRequests[combine.vehicle]
                if request then
                    data.finalRelease=nil
                    request.finishCourse=combine.fieldWorkCourse
                    request.turnClearance=area; request.checked=nil
                    request.turn=nil; request.turnContext=nil
                    data.nextAttempt=0
                    driver:debug('Queue: clearing reserved final lane for %s',CpUtil.getName(combine.vehicle))
                end
            end
        end
        pending=pending or (request and request.finishCourse==combine.fieldWorkCourse) or false
    end
    return pending
end

local function ordinaryTravelTurn(combine)
    local turn=combine.aiTurn
    return combine.states and combine.state==combine.states.TURNING and turn
        and combine.turnContext and turn.turnContext==combine.turnContext
        and not turn.callbackFunction and turn.startRecoveryTurn
        and not (turn.turnContext.isHeadlandCorner and turn.turnContext:isHeadlandCorner())
end

local function intersects(area,vehicle)
    local bodies=W.currentBodies(vehicle)
    if not bodies or not area then return true end -- unknown geometry cannot establish clearance
    for _,item in ipairs(bodies) do
        if area(W.rectangle(item.body,item.pose,0)) then return true end
    end
    return false
end

local function centreTransfer(combine)
    local states,context,course=combine.states,combine.turnContext,combine.fieldWorkCourse
    local ix=context and context.turnStartWpIx
    return states and states.DRIVING_TO_WORK_START_WAYPOINT
        and combine.state==states.DRIVING_TO_WORK_START_WAYPOINT and ix and ix>1 and course
        and not course:isOnHeadland(ix) and course:isOnConnectingPath(ix-1)
end

-- The native headland-to-centre connector is a travel course, not an ordinary
-- row turn. Check its full body/header braking sweep against occupied space.
-- A headland hold does not mean the follower has physically cleared that space.
function Q.holdCentreTransfer(combine,speed)
    if not centreTransfer(combine) then combine.queueTransferHold=nil; return false end
    local course=combine:getCurrentCourse()
    if not course or not combine.ppc then combine.queueTransferHold=nil; return false end
    local prior=combine.queueTransferHold
    local velocity=math.max((combine.vehicle.lastSpeedReal or 0)*1000,(speed or 0)/3.6,
        prior and prior.course==course and prior.velocity or 0)
    local area=Q.yieldArea(combine.vehicle,course,math.max(12,velocity*velocity/4+velocity+8),300)
    if not area then return true end -- do not approve an unmeasured header sweep
    for _,vehicle in pairs(g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles or {}) do
        if vehicle~=combine.vehicle and vehicle.spec_combine and vehicle.getIsCpFieldWorkActive
                and vehicle:getIsCpFieldWorkActive() and intersects(area,vehicle) then
            if not prior then combine:debug('Queue: centre transfer waiting for occupied header sweep to clear') end
            combine.queueTransferHold={course=course,area=area,velocity=velocity}
            return true
        end
    end
    if prior then combine:debug('Queue: occupied centre-transfer sweep clear; continuing native connector') end
    combine.queueTransferHold=nil
    return false
end

local function canClearCentreTransfer(combine,lead)
    local hold=lead.queueTransferHold
    if not hold or not centreTransfer(lead) or hold.course~=lead:getCurrentCourse()
            or not AIUtil.isStopped(lead.vehicle) or not intersects(hold.area,combine.vehicle) then return false end
    -- Permit the occupant's existing course only when it clears every physical
    -- harvester, including the stopped lead. Native crop/obstacle checks remain.
    local velocity=math.max((combine.vehicle.lastSpeedReal or 0)*1000,
        combine.settings and combine.settings.fieldSpeed and combine.settings.fieldSpeed:getValue()/3.6 or 0)
    local area=Q.yieldArea(combine.vehicle,nil,math.max(12,velocity*velocity/4+velocity+8),300)
    if not area then return false end
    for _,vehicle in pairs(g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles or {}) do
        if vehicle~=combine.vehicle and vehicle.spec_combine and intersects(area,vehicle) then return false end
    end
    return true
end

-- A centre-entry U-turn/reverse can bring the lead back towards its own
-- historical trail. During that transition, do not use trail distance to
-- decide whether a follower may enter a nearby headland corner. Keep the
-- configured convoy separation in physical space until the lead clears it.
-- The centre-entry machine has priority unless a physically occupying follower
-- must first clear its route under the transfer sweep checks above.
function Q.holdHeadlandCorner(combine)
    local states,course=combine.states,combine.fieldWorkCourse
    local proximity=combine.fieldWorkerProximityController
    local setting=combine.settings and combine.settings.convoyDistance
    if not states or not course or not proximity or not setting then return false end
    local limit=setting:getValue()
    if limit<=0 then return false end
    local corner=combine.state==states.TURNING and combine.turnContext
        and combine.turnContext.fieldWorkCourse==course and combine.turnContext.turnStartWpIx
        and course:isOnHeadland(combine.turnContext.turnStartWpIx)
        and combine.turnContext.isHeadlandCorner and combine.turnContext:isHeadlandCorner()
    if not corner then
        if combine.state~=states.WORKING or combine:getCurrentCourse()~=course then return false end
        local ix=combine.ppc:getRelevantWaypointIx()
        if not course:isOnHeadland(ix) then return false end
        local last=course:getNextWaypointIxWithinDistance(ix,limit)
        for i=ix,last do
            if course:isHeadlandTurnAtIx(i) then corner=true; break end
        end
    end
    if not corner then return false end
    local here=W.pose(combine.vehicle:getAIDirectionNode())
    for _,vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle~=combine.vehicle and vehicle.spec_combine and proximity:hasSameCourse(vehicle)
                and vehicle.getIsCpFieldWorkActive and vehicle:getIsCpFieldWorkActive() then
            local lead=vehicle:getCpDriveStrategy()
            local ix=lead and lead.turnContext and lead.turnContext.turnStartWpIx
            local entering=ix and ix>1 and lead.fieldWorkCourse
                and not lead.fieldWorkCourse:isOnHeadland(ix) and lead.fieldWorkCourse:isOnConnectingPath(ix-1)
                and (lead.connectorEntry or (lead.states and lead.state==lead.states.DRIVING_TO_WORK_START_WAYPOINT))
            if entering and distance(here,W.pose(vehicle:getAIDirectionNode()))<limit
                    and not canClearCentreTransfer(combine,lead) then
                return vehicle
            end
        end
    end
    return false
end

-- Reservations observe native traffic; they never transfer its controller.
Q.turnTraffic=setmetatable({}, {__mode='k'})
Q.turnTrafficRevision=0
local function dropReservation(combine)
    if Q.turnTraffic[combine] then
        Q.turnTraffic[combine]=nil
        Q.turnTrafficRevision=Q.turnTrafficRevision+1
    end
end
local function liveTurn(combine,reservation)
    return combine.vehicle:getIsCpActive() and ordinaryTravelTurn(combine)
        and combine.aiTurn==reservation.turn
end

function Q.pruneTurnReservations()
    for combine,reservation in pairs(Q.turnTraffic) do
        if not liveTurn(combine,reservation) then dropReservation(combine) end
    end
end

local function nativeFollower(driver,combine)
    -- These states move in step with this harvester. Requiring the follower
    -- to clear the complete future turn would stop both indefinitely.
    return not Q.owns(driver) and driver.combineToUnload==combine.vehicle
        and (driver.state==driver.states.UNLOADING_MOVING_COMBINE
            or driver.state==driver.states.UNLOADING_STOPPED_COMBINE
            or driver.state==driver.states.WAITING_FOR_MANEUVERING_COMBINE
            or driver.state==driver.states.BACKING_UP_FOR_REVERSING_COMBINE
            or driver.state==driver.states.FOLLOW_CHOPPER_THROUGH_TURN)
end

local function reserveTurn(combine)
    local turn=combine.aiTurn
    local reservation=Q.turnTraffic[combine]
    if reservation and not liveTurn(combine,reservation) then
        dropReservation(combine); reservation=nil
    end
    if turn.turnCourse and combine:getCurrentCourse()==turn.turnCourse
            and (not reservation or reservation.course~=turn.turnCourse) then
        local area=Q.yieldArea(combine.vehicle,turn.turnCourse,math.huge,1600)
        if area then
            reservation={turn=turn,course=turn.turnCourse,area=area,time=g_currentMission.time}
            Q.turnTraffic[combine]=reservation
            Q.turnTrafficRevision=Q.turnTrafficRevision+1
        end
    end
    -- A reservation covers the remaining sweep, not places already passed.
    if reservation and g_currentMission.time-(reservation.time or 0)>=250 then
        reservation.area=Q.yieldArea(combine.vehicle,reservation.course,math.huge,1600) or reservation.area
        reservation.time=g_currentMission.time
        Q.turnTrafficRevision=Q.turnTrafficRevision+1
    end
    return reservation
end

-- Ordinary row turns can cross another combine's row even when native convoy
-- trail distance is infinite. Priority is frozen from fieldwork progress;
-- temporary turn waypoint indices must never reverse it.
function Q.holdCombineTurn(combine,speed)
    local vehicles=g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles or {}
    local proximity=combine.fieldWorkerProximityController
    if not proximity or not combine.fieldWorkCourse then return false end
    if not (combine.states and combine.state==combine.states.WORKING) and not ordinaryTravelTurn(combine) then
        combine.queueCombineHold=nil
        return false
    end
    -- A blocker released to clear an occupied turn exit keeps that brief
    -- priority across the fleet. A third combine must not recreate the wait
    -- cycle; native proximity/collision brakes still apply to every vehicle.
    for _,vehicle in pairs(vehicles) do
        local holder=vehicle.getCpDriveStrategy and vehicle:getCpDriveStrategy()
        local clearing=holder and holder.queueCombineHold
        if clearing and clearing.clearing and clearing.lead==combine
                and holder.aiTurn==clearing.turn and vehicle:getIsCpActive()
                and combine.fieldWorkCourse==clearing.course and intersects(clearing.area,combine.vehicle) then
            return false
        end
    end
    local pair=combine.queueCombineHold
    if pair and pair.clearing then
        local lead=pair.lead
        if lead.vehicle:getIsCpActive() and lead.fieldWorkCourse==pair.course
                and intersects(pair.area,lead.vehicle) then return true end
        combine.queueCombineHold=nil
        return false
    end
    if pair then
        local lead=pair.lead
        if not lead.vehicle:getIsCpActive() or not ordinaryTravelTurn(lead)
                or lead.turnContext~=pair.context or lead.fieldWorkCourse~=pair.course
                or not proximity:hasSameCourse(lead.vehicle) then
            combine.queueCombineHold=nil
        else
            local reservation=reserveTurn(lead)
            local velocity=math.max((combine.vehicle.lastSpeedReal or 0)*1000,(speed or 0)/3.6)
            local _,_,sweep=Q.yieldArea(combine.vehicle,nil,math.max(12,velocity*velocity/4+velocity+8),300)
            local conflict=not reservation or not sweep
            for _,r in ipairs(sweep or {}) do if reservation and reservation.area(r) then conflict=true; break end end
            if conflict then
                if reservation and intersects(reservation.area,combine.vehicle)
                        and not lead.queueBypass and not lead.queueTrailerWait
                        and AIUtil.isStopped(combine.vehicle) and AIUtil.isStopped(lead.vehicle) then
                    Q.tryHarvesterBypass(lead,combine.vehicle,false,reservation.area)
                end
                return true
            end
            combine.queueCombineHold=nil
        end
    end
    local ownCourse,ownIx=Q.coursePosition(combine)
    if not ownCourse then return false end
    ownIx=ordinaryTravelTurn(combine) and combine.turnContext.turnStartWpIx or ownIx
    for _,vehicle in pairs(vehicles) do
        if vehicle~=combine.vehicle and vehicle.spec_combine and vehicle.getIsCpFieldWorkActive
                and vehicle:getIsCpFieldWorkActive() and proximity:hasSameCourse(vehicle) then
            local lead=vehicle:getCpDriveStrategy()
            local ix=lead and ordinaryTravelTurn(lead) and lead.turnContext.turnStartWpIx
            if ix and ownIx and not lead.queueCombineHold and
                    (ix>ownIx or (ix==ownIx and tostring(vehicle.rootNode)<tostring(combine.vehicle.rootNode))) then
                local reservation=reserveTurn(lead)
                if reservation then
                    local velocity=math.max((combine.vehicle.lastSpeedReal or 0)*1000,(speed or 0)/3.6)
                    local _,_,sweep=Q.yieldArea(combine.vehicle,nil,math.max(12,velocity*velocity/4+velocity+8),300)
                    for _,r in ipairs(sweep or {}) do
                        if reservation.area(r) then
                            combine.queueCombineHold={lead=lead,context=lead.turnContext,course=lead.fieldWorkCourse}
                            combine:debug('Queue: yielding crossing row turn to %s',CpUtil.getName(vehicle))
                            return Q.holdCombineTurn(combine,speed)
                        end
                    end
                end
            end
        end
    end
    return false
end

function Q.checkCombineTurns(combine,speed)
    if ordinaryTravelTurn(combine) and not combine.queueCombineHold then
        for _,vehicle in pairs(g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles or {}) do
            if vehicle~=combine.vehicle and vehicle.spec_combine and vehicle.getIsCpFieldWorkActive
                    and vehicle:getIsCpFieldWorkActive() then
                local other=vehicle:getCpDriveStrategy()
                if other then Q.holdCombineTurn(other) end
            end
        end
    end
    return Q.holdCombineTurn(combine,speed)
end

local function nativeTrafficInTurn(combine,reservation)
    if not reservation then return false end
    local stationary
    -- Examine every rig before selecting a parked trailer for a detour. In
    -- particular a departing rig must not disappear from obstacle detection.
    for driver in pairs(Q.members) do
        if driver.vehicle~=combine.vehicle and driver.vehicle:getIsCpActive()
                and not parkedQueueTrailer(driver) and not nativeFollower(driver,combine)
                and intersects(reservation.area,driver.vehicle) then
            if not AIUtil.isStopped(driver.vehicle) then return driver end
            -- Stationary native traffic can be planned around without taking
            -- its job away. Scan all rigs first so moving exits win precedence.
            stationary=driver
        end
    end
    for _,vehicle in pairs(g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles or {}) do
        local driver=vehicle.getCpDriveStrategy and vehicle:getCpDriveStrategy()
        local pair=driver and driver.queueCombineHold
        if pair and not pair.clearing and pair.lead==combine and pair.context==combine.turnContext
                and vehicle:getIsCpActive() and intersects(reservation.area,vehicle) then
            if not AIUtil.isStopped(vehicle) then return driver end
            stationary=driver
        end
    end
    return stationary
end

-- Only incoming preparation/approach traffic waits at a turn reservation.
-- Rigs already inside, unloading, backing out or departing must remain free
-- to clear it. Project the complete rig along its existing approach course.
function Q.holdIncomingTurn(driver,speed)
    local data=driver.queueData
    if not data then return false end
    data.turnHold=nil
    if data.nativeDeparture or Q.atDepartureThreshold(driver) then return false end
    local states=driver.states
    local state=driver.state
    if state==states.WAITING_FOR_MANEUVERING_COMBINE then state=driver.stateAfterWaitingForManeuveringCombine end
    if not (Q.owns(driver) and data.operation=='prepare')
            and not (states.DRIVING_TO_COMBINE and state==states.DRIVING_TO_COMBINE)
            and not (states.DRIVING_TO_MOVING_COMBINE and state==states.DRIVING_TO_MOVING_COMBINE) then return false end
    local course=driver.getCurrentCourse and driver:getCurrentCourse()
    if not course then return false end
    local velocity=math.max((driver.vehicle.lastSpeedReal or 0)*1000,(speed or 0)/3.6)
    local horizon=math.max(12,velocity*velocity/4+velocity+8)
    local cached=data.turnApproachCheck
    if cached and cached.revision==Q.turnTrafficRevision and cached.course==course and velocity<=cached.velocity
            and g_currentMission.time-cached.time<100 then
        if not cached.hold then return false end
        local reservation=Q.turnTraffic[cached.hold]
        if reservation and reservation==cached.reservation and liveTurn(cached.hold,reservation) then
            data.turnHold=cached.hold; return true
        end
    end
    data.turnApproachCheck={course=course,velocity=velocity,time=g_currentMission.time,revision=Q.turnTrafficRevision}
    local projected
    for combine,reservation in pairs(Q.turnTraffic) do
        if not liveTurn(combine,reservation) then dropReservation(combine)
        elseif not intersects(reservation.area,driver.vehicle) then
            if not projected then
                local _,_,rectangles=Q.yieldArea(driver.vehicle,course,horizon,300)
                projected=rectangles
            end
            if projected then
                for _,rectangle in ipairs(projected) do
                    if reservation.area(rectangle) then
                        data.turnHold=combine
                        data.turnApproachCheck.hold=combine
                        data.turnApproachCheck.reservation=reservation
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- Only actual row-to-row travel courses qualify. Finishing-row extensions,
-- headland corners, centre-work connectors and other combines retain native CP.
-- Called after native drive data, so a newly installed turn is checked in the
-- same update, before its first movement. Native speed limits can only decrease.
local function resumeBypass(combine,wait)
    local bypass={turn=wait.turn,vehicle=wait.driver.vehicle,driver=wait.driver,combine=combine,
        area=wait.area,untilTime=g_currentMission.time+120000}
    combine.queueBypass=bypass
    if parkedQueueTrailer(wait.driver) then wait.driver.queueData.bypass=bypass end
    wait.turn.state=wait.turn.states.PREPARING_RECOVERY
end

-- A combine waiting for its failed detour is not reversing. Let an existing
-- native backup request expire so its saved departure retry can resume.
function Q.deferStationaryTurnBackup(driver,vehicle)
    if not driver.queueData or not driver.queueData.nativeDeparture then return false end
    local combine=vehicle and vehicle.getCpDriveStrategy and vehicle:getCpDriveStrategy()
    if not combine or not ordinaryTravelTurn(combine) or not AIUtil.isStopped(vehicle) then return false end
    local wait=combine.queueTrailerWait or combine.queueBypass
    local turn=combine.aiTurn
    return wait and wait.driver==driver and wait.turn==turn
        and (turn.state==turn.states.WAITING_FOR_PATHFINDER or turn.state==turn.states.PREPARING_RECOVERY)
end

-- Departure keeps native ownership except for this bounded, checked escape.
-- A failed combine detour plus ten seconds without physical progress is required;
-- passing departures, native reverse clearance and foreground searches are untouched.
function Q.departureClearanceActive(driver)
    return Q.owns(driver) and driver.queueData.departureClearance==true
end

function Q.resumeNativeDeparture(driver,reason)
    local data=driver.queueData
    if not data then return end
    if Q.owns(driver) then Q.release(driver) else Q.cancel(driver) end
    data.departureClearance=nil; data.departureConflicts=nil
    data.priorityCombine=nil; data.yieldRequests=nil; data.operation=nil
    data.departureRetryAt=g_currentMission.time+30000
    -- Controller runners advance synchronously. Detaching the old runner and
    -- installing fresh native listeners prevents a cancelled result resuming it.
    if driver.pathfinderController then
        driver.pathfinderController.pathfinder=nil
        if driver.pathfinderController.reset then driver.pathfinderController:reset() end
    end
    driver:debug('Queue: %s; replanning native departure from current pose',reason)
    driver:startPathfindingToInvertedGoalPositionMarker()
end

function Q.requestDepartureClearance(combine,driver,area)
    local data=driver.queueData
    if not data or not data.nativeDeparture or not Q.enabled(driver)
            or not driver.vehicle:getIsCpActive() then return false end
    if Q.departureClearanceActive(driver) then
        -- A second turning combine joins the existing escape; never restart it.
        if not data.yieldRequests[combine.vehicle] then
            data.yieldRequests[combine.vehicle]={turnClearance=area,preferForward=true,
                turn=combine.aiTurn,turnContext=combine.turnContext}
        end
        return false
    end
    if driver.state~=driver.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL
            or not driver.invertedStartPositionMarkerNode
            or (driver.pathfinderController and driver.pathfinderController.pathfinder)
            or (driver.isBeingHeld and driver:isBeingHeld()) then
        data.departureConflicts=nil; return false
    end
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    local time=g_currentMission.time
    data.departureConflicts=data.departureConflicts or setmetatable({}, {__mode='k'})
    local watch=data.departureConflicts[combine]
    if not watch or watch.context~=combine.turnContext
            or watch.course~=driver.course or distance(here,watch.pose)>0.5
            or math.abs(H.math.delta(here.t,watch.pose.t))>math.rad(5)
            or not AIUtil.isStopped(driver.vehicle) then
        data.departureConflicts[combine]={context=combine.turnContext,course=driver.course,pose=here,time=time}
        return false
    end
    if time-watch.time<10000 or time<(data.departureRetryAt or 0)
            or not AIUtil.isStopped(combine.vehicle) or not intersects(area,driver.vehicle) then return false end
    local probe=setmetatable({queueData={operation='yield'}},{__index=driver})
    local world,reason=W.new(probe)
    local clear=false
    if world then clear,reason=W.clear(world,W.poses(world.model)); W.delete(world) end
    if not clear then
        -- Do not force movement from an invalid pose. Native pathfinding retains
        -- its own obstacle-at-start handling and return-marker retry policy.
        Q.resumeNativeDeparture(driver,'departure clearance unavailable: '..tostring(reason))
        return true
    end
    if driver.pathfinderController then driver.pathfinderController.pathfinder=nil end
    Q.take(driver,'yield')
    data.departureClearance=true; data.departureConflicts=nil
    data.priorityCombine=combine.vehicle
    data.yieldRequests={[combine.vehicle]={turnClearance=area,preferForward=true,
        turn=combine.aiTurn,turnContext=combine.turnContext}}
    data.nextAttempt=0
    driver:debug('Queue: stalled native departure conflicts with %s turn; checking whole-rig clearance',
        CpUtil.getName(combine.vehicle))
    return true
end

-- A native reverse can finish while the combine searches or waits. Use the
-- rig's current ownership, not its classification when the detour started.
-- An existing request must keep its search, progress and clearance timer.
local function requestTurnClearance(combine,driver,area)
    local data=driver.queueData
    if data and data.nativeDeparture then return Q.requestDepartureClearance(combine,driver,area) end
    if not data or not Q.owns(driver)
            or (data.operation~='yield' and not parkedQueueTrailer(driver)) then return false end
    local request=data.yieldRequests and data.yieldRequests[combine.vehicle]
    if data.operation=='yield' and request and request.turnClearance==area then return false end
    if not Q.priority(driver,combine.vehicle) then
        if Q.owns(driver) and (data.nativeYieldUntil or 0)>g_currentMission.time and Q.nativeMoveAway then
            Q.nativeMoveAway(driver,combine.vehicle)
            return Q.nativeClearanceActive(driver)
        end
        return false
    end
    request=data.yieldRequests and data.yieldRequests[combine.vehicle]
    if not request then return false end -- an incoming turn hold retained control
    request.turnClearance=area; request.preferForward=true
    request.turn=combine.aiTurn; request.turnContext=combine.turnContext
    request.checked=nil
    data.nextAttempt=0
    return true
end

function Q.checkParkedTrailerTravel(combine)
    if combine.queueCombineHold and combine.queueCombineHold.clearing then return true end
    local stale=combine.queueBypass
    if stale and (stale.turn~=combine.aiTurn or not ordinaryTravelTurn(combine)) then
        Q.clearHarvesterBypass(stale.driver)
        combine.queueBypass=nil
    end
    if not ordinaryTravelTurn(combine) then dropReservation(combine); return false end
    local turn=combine.aiTurn
    local reservation=reserveTurn(combine)
    -- Native clearance/departure takes precedence over starting a separate
    -- parked-trailer manoeuvre, including after native calculated fallback.
    local traffic=nativeTrafficInTurn(combine,reservation)
    if traffic and not combine.queueTrailerWait and not combine.queueBypass then
        if AIUtil.isStopped(traffic.vehicle) and AIUtil.isStopped(combine.vehicle) then
            Q.tryHarvesterBypass(combine,traffic.vehicle,false,reservation.area)
        end
        return true
    end
    if turn.queueYieldReason then
        if AIUtil.isStopped(combine.vehicle) then
            local reason=turn.queueYieldReason
            turn.queueYieldReason=nil
            turn:queueBypassFailed(reason)
        end
        return true
    end
    local wait=combine.queueTrailerWait
    if wait and wait.turn~=turn then combine.queueTrailerWait=nil; wait=nil end
    if wait then
        local blocked=intersects(wait.area,wait.driver.vehicle)
        if blocked or traffic then
            wait.clearSince=nil
            if blocked and requestTurnClearance(combine,wait.driver,wait.area) then
                -- Allow the newly requested clearance to start before retrying
                -- the detour. Later updates must not postpone this deadline.
                wait.retryAt=g_currentMission.time+5000
            end
            -- The frozen clearance area can differ from the rejected route's
            -- reservation. Its blocker must remain eligible for retries after
            -- returning to the queue, but moving clearance/departures go first.
            local stationary=(not blocked or AIUtil.isStopped(wait.driver.vehicle))
                and (not traffic or AIUtil.isStopped(traffic.vehicle))
            local departureBusy=Q.departureClearanceActive(wait.driver)
                or (wait.driver.queueData and wait.driver.queueData.nativeDeparture
                    and ((wait.driver.pathfinderController and wait.driver.pathfinderController.pathfinder)
                        or Q.nativeClearanceActive(wait.driver)))
            if stationary and not departureBusy and g_currentMission.time>=(wait.retryAt or 0) then
                wait.retryAt=g_currentMission.time+5000
                combine.queueTrailerWait=nil
                resumeBypass(combine,wait)
            end
            return true
        end
        for other in pairs(wait.driver.queueData and wait.driver.queueData.yieldRequests or {}) do
            if other~=combine.vehicle and AIDriveStrategyCombineCourse.isActiveCpCombine(other) then return true end
        end
        wait.clearSince=wait.clearSince or g_currentMission.time
        if g_currentMission.time-wait.clearSince<2000 then return true end
        combine.queueTrailerWait=nil
        combine:debug('Queue: whole trailer clear of reserved turn; replanning original row entry')
        -- Recheck the route from the stopped pose after the entire rig clears.
        -- Never skip to the next row or restart the obstructed calculated turn.
        local driver=wait.driver
        if Q.owns(driver) and not driver.queueData.nativeDeparture
                and not Q.atDepartureThreshold(driver) and not driver:isDriveUnloadNowRequested() then
            Q.take(driver,'prepare')
            driver.queueData.yieldRequests=nil; driver.queueData.priorityCombine=nil
        end
        resumeBypass(combine,wait)
        return true
    end
    local active=combine.queueBypass
    if active and active.turn==turn then
        if traffic and not active.braking and turn.queueBypassFailed
                and (turn.state==turn.states.TURNING or turn.state==turn.states.ENDING_TURN) then
            -- A broad traffic reservation is not proof that the accepted
            -- detour is blocked. Validate the remaining route before replacing
            -- it, with bounded retries through the existing wait lifecycle.
            if not active.checkedAt or g_currentMission.time-active.checkedAt>=500 then
                active.checkedAt=g_currentMission.time
                active.clear=Q.validateHarvesterBypass(turn,true)
            end
            if not active.clear then
                turn:queueBypassFailed('accepted detour no longer clear')
                return true
            end
        end
        if g_currentMission.time>=active.untilTime and turn.queueBypassFailed
                and (turn.state==turn.states.PREPARING_RECOVERY or turn.state==turn.states.WAITING_FOR_PATHFINDER) then
            turn:queueBypassFailed('search timed out'); return true
        end
        if active.braking then
            if not parkedQueueTrailer(active.driver) then Q.clearHarvesterBypass(active.driver); return true end
            if AIUtil.isStopped(combine.vehicle) then
                Q.tryHarvesterBypass(combine,active.vehicle,false,active.area)
            end
            return true
        end
        return turn.state==turn.states.PREPARING_RECOVERY or turn.state==turn.states.WAITING_FOR_PATHFINDER
            or (traffic and not AIUtil.isStopped(traffic.vehicle)) or false
    end
    if turn.state~=turn.states.TURNING or not turn.turnCourse
            or combine:getCurrentCourse()~=turn.turnCourse then return false end
    local time=g_currentMission.time
    local checked=combine.queueTrailerChecked
    if checked and checked.course==turn.turnCourse and time-checked.time<200 then return false end
    local firstCheck=not checked or checked.course~=turn.turnCourse
    combine.queueTrailerChecked={course=turn.turnCourse,time=time}
    local area
    for driver in pairs(Q.members) do
        if driver.vehicle~=combine.vehicle and parkedQueueTrailer(driver)
                and not driver.queueData.bypass then
            area=area or Q.yieldArea(combine.vehicle,turn.turnCourse,firstCheck and math.huge or 30,
                firstCheck and 1600 or 160)
            if area and intersects(area,driver.vehicle) then
                -- Clearance must cover the full turn, even after a local approach check.
                area=Q.yieldArea(combine.vehicle,turn.turnCourse,math.huge,1600) or area
                Q.take(driver,'prepare') -- reserve and stop its queue movement during planning
                local bypass={turn=turn,vehicle=driver.vehicle,driver=driver,combine=combine,
                    area=area,braking=true,untilTime=time+120000}
                combine.queueBypass=bypass; driver.queueData.bypass=bypass
                combine:debug('Queue: parked trailer intersects planned row turn; stopping to plan around it')
                if AIUtil.isStopped(combine.vehicle) then Q.tryHarvesterBypass(combine,driver.vehicle,false,area) end
                return true
            end
        end
    end
    return false
end

-- Native forward/reverse proximity callbacks may run before drive data. Keep
-- their trailer requests behind the same plan-first decision, only in scope.
function Q.deferTrailerYield(driver,vehicle)
    local combine=vehicle and vehicle.getCpDriveStrategy and vehicle:getCpDriveStrategy()
    if not combine or not ordinaryTravelTurn(combine) then return false end
    if Q.holdIncomingTurn(driver) then return true end
    local data=driver.queueData
    if not data or data.nativeDeparture or Q.atDepartureThreshold(driver) or driver:isDriveUnloadNowRequested() then return false end
    if data and data.bypass and data.bypass.combine==combine then return true end
    if combine.queueTrailerWait and combine.queueTrailerWait.driver==driver then return true end
    if parkedQueueTrailer(driver) then
        Q.checkParkedTrailerTravel(combine)
        return data.bypass~=nil and data.bypass.combine==combine
    end
    return false
end

-- Use CP's collision-aware hybrid planner for the entire short bypass. Its
-- fast A* middle section smooths using penalties only, so it can straighten a
-- route back through a parked vehicle. Do not change that planner globally.
function Q.generateHarvesterBypass(turn)
    local target,offset=turn.turnContext:getTurnEndNodeAndOffsets(turn.steeringLength)
    local x,z,t=PathfinderUtil.getNodePositionAndDirection(turn.vehicle:getAIDirectionNode(),0,0)
    local start=State3D(x,-z,CpMathUtil.angleFromGame(t))
    x,z,t=PathfinderUtil.getNodePositionAndDirection(target,0,offset)
    local goal=State3D(x,-z,CpMathUtil.angleFromGame(t))
    local context=PathfinderContext(turn.vehicle):useFieldNum(CpFieldUtil.getFieldNumUnderVehicle(turn.vehicle))
    context:offFieldPenalty(turn.driveStrategy:isTurnOnFieldActive() and 10 or context._offFieldPenalty)
    if not turn.vehicle.spec_combine then context._fieldworkBoundary=FieldworkBoundary.forVehicle(turn.vehicle,turn.workWidth) end
    local constraints=PathfinderConstraints(context)
    turn.queueBypassConstraints=constraints
    local pathfinder=HybridAStar(turn.vehicle,200,10000,true)
    pathfinder.analyticSolver=ReedsSheppSolver(ReedsShepp.ForwardEndingPathWords)
    turn.driveStrategy.pathfinder=pathfinder
    turn.pathfindingStartedAt=g_currentMission.time
    local result=pathfinder:start(start,goal,turn.turningRadius,
        turn.driveStrategy:getAllowReversePathfinding(),constraints,constraints.trailerHitchLength)
    if result.done then
        -- An analytic solution can finish inside start(), leaving the native
        -- planner marked active. Detach it before the callback: the next
        -- strategy update must not resume that completed search without args.
        if turn.driveStrategy.pathfinder==pathfinder then turn.driveStrategy.pathfinder=nil end
        return turn:onPathfindingDone(result.path)
    end
    turn.state=turn.states.WAITING_FOR_PATHFINDER
    turn.driveStrategy:setPathfindingDoneCallback(turn,turn.onPathfindingDone)
end

function Q.validateHarvesterBypass(turn,remaining)
    local course,constraints=turn.turnCourse,turn.queueBypassConstraints
    if not course or not constraints then return false end
    local previous,count=nil,0
    local first=1
    if remaining then
        previous=W.pose(turn.vehicle:getAIDirectionNode())
        first=math.max(1,turn.ppc:getRelevantWaypointIx()+1)
    end
    for i=first,course:getNumberOfWaypoints() do
        local x,_,z=course:getWaypointPosition(i)
        local reverse=(course:isReverseAt(i) and not course:switchingToForwardAt(i)) or course:switchingToReverseAt(i)
        local t=course:getWaypointYRotation(i)+(reverse and math.pi or 0)
        local point={x=x,z=z,t=t}
        previous=previous or point
        local delta=H.math.delta(t,previous.t)
        local samples=math.max(1,math.ceil(distance(previous,point)/0.5),math.ceil(math.abs(delta)/math.rad(3)))
        for j=0,samples do
            count=count+1
            if count>3000 then return false end
            local f=j/samples
            local node=State3D(previous.x+(x-previous.x)*f,-(previous.z+(z-previous.z)*f),
                CpMathUtil.angleFromGame(previous.t+delta*f))
            if not constraints:isValidNode(node,false,true) then return false end
        end
        previous=point
    end
    return true
end

-- Called by route preflight or native proximity's vehicle-block callback.
-- Retain CP's target, implement preparation, pathfinder and collision geometry.
function Q.tryHarvesterBypass(combine,vehicle,isBack,area)
    local turn=combine.aiTurn
    if isBack or not ordinaryTravelTurn(combine) then return false end
    if combine.queueTrailerWait and combine.queueTrailerWait.turn==turn then return true end
    local active=combine.queueBypass
    if active and active.turn==turn and not active.braking then
        if active.vehicle~=vehicle then return false end
        if turn.state==turn.states.TURNING or turn.state==turn.states.ENDING_TURN then
            turn:queueBypassFailed('accepted detour persistently blocked by reserved trailer')
        end
        return true
    end
    if turn.state~=turn.states.TURNING or (combine.pathfinder and combine.pathfinder:isActive())
            or (combine.pathfinderController and combine.pathfinderController.pathfinder) then return false end
    local driver=vehicle and vehicle.getCpDriveStrategy and vehicle:getCpDriveStrategy()
    local data=driver and driver.queueData
    local parked=driver and parkedQueueTrailer(driver)
    local pair=driver and driver.queueCombineHold
    local combineBlocker=pair and not pair.clearing and pair.lead==combine and pair.context==combine.turnContext
    if (not data and not combineBlocker) or (Q.owns(driver) and not parked and data.operation~='yield') or nativeFollower(driver,combine)
            or not AIUtil.isStopped(vehicle) or not AIUtil.isStopped(combine.vehicle) then return false end
    -- A second harvester may need this trailer to yield instead of holding still.
    for other in pairs(data and data.yieldRequests or {}) do
        if parked and other~=combine.vehicle then return false end
    end
    local time=g_currentMission.time
    if not area and combine.queueBypassAttempt and time-combine.queueBypassAttempt<15000 then return false end
    combine.queueBypassAttempt=time
    area=area or (turn.turnCourse and Q.yieldArea(combine.vehicle,turn.turnCourse,math.huge,1600))
    turn:startRecoveryTurn(combine.turningRadius)
    local recovery=combine.aiTurn
    if recovery==turn then return false end
    local reservation=Q.turnTraffic[combine]
    if reservation then reservation.turn=recovery end
    if parked then
        Q.take(driver,'prepare')
        data.yieldRequests=nil; data.priorityCombine=nil
    end
    local bypass={turn=recovery,vehicle=vehicle,driver=driver,combine=combine,area=area,untilTime=time+120000}
    combine.queueBypass=bypass
    if parked then data.bypass=bypass end
    recovery.generatePathfinderTurn=Q.generateHarvesterBypass
    -- Unlike generic recovery, never perform an unchecked reverse first when
    -- reverse pathfinding is disabled. The checked planner honours that setting.
    recovery.startPreparedRecovery=function(self) self:generatePathfinderTurn() end
    local function failed(self,reason)
        if combine.aiTurn~=self or combine.state~=combine.states.TURNING then return end
        self.state=self.states.WAITING_FOR_PATHFINDER
        combine.pathfinder=nil
        if not AIUtil.isStopped(combine.vehicle) then
            self.queueYieldReason=reason
            return -- brake before permitting the parked rig to start moving
        end
        combine:debug('Queue: parked-trailer bypass failed: %s; holding for trailer clearance',reason)
        Q.clearHarvesterBypass(driver)
        combine.queueBypass=nil
        combine.queueTrailerWait={turn=self,driver=driver,area=area,retryAt=g_currentMission.time+5000}
        if combineBlocker and driver.queueCombineHold==pair
                and pair.context==combine.turnContext and pair.course==combine.fieldWorkCourse then
            -- The losing combine may already occupy the winning turn's exit.
            -- Check its immediate native sweep, then let it clear first. Do not
            -- send a harvester a trailer-only yield request it cannot fulfil.
            local clearance=Q.yieldArea(driver.vehicle,nil,12,300)
            if clearance and not intersects(clearance,combine.vehicle) then
                driver.queueCombineHold=nil
                combine.queueCombineHold={lead=driver,clearing=true,area=area,
                    course=driver.fieldWorkCourse,context=driver.turnContext,turn=self}
                dropReservation(combine)
                combine:debug('Queue: blocked turn exit; letting %s clear before retrying',CpUtil.getName(driver.vehicle))
                return
            end
        end
        requestTurnClearance(combine,driver,area)
    end
    local completed=recovery.onPathfindingDone
    recovery.queueBypassFailed=failed
    recovery.onPathfindingDone=function(self,path)
        if combine.aiTurn~=self or combine.state~=combine.states.TURNING
                or combine.queueTrailerWait or self.queueYieldReason then return end
        if not path or #path<=2 then failed(self,'no collision-checked route'); return end
        completed(self,path)
        -- Native completion appends alignment and adjusts reversing points.
        -- Check that final course before the next drive update can use it.
        if not Q.validateHarvesterBypass(self) then failed(self,'final route clearance'); return end
        combine:debug('Queue: checked parked-trailer detour accepted; original row entry retained')
    end
    recovery.onBlocked=function(self)
        if self.state==self.states.PREPARING_RECOVERY or self.state==self.states.WAITING_FOR_PATHFINDER then return end
        failed(self,'recovery route blocked')
    end
    -- RecoveryTurn registered its original method during construction.
    recovery.proximityController:registerBlockingObjectListener(recovery,recovery.onBlocked)
    combine:debug('Queue: routing around parked %s to original turn end %d',
        CpUtil.getName(vehicle),combine.turnContext.turnEndWpIx)
    return true
end

function Q.clearHarvesterBypass(driver)
    local data=driver.queueData
    local bypass=data and data.bypass
    if not bypass then return end
    if bypass.combine.queueBypass==bypass then bypass.combine.queueBypass=nil end
    data.bypass=nil; data.nextAttempt=0
end

function Q.holdForHarvesterBypass(driver)
    local data=driver.queueData
    local bypass=data and data.bypass
    if not bypass then return false end
    local combine=bypass.combine
    if Q.atDepartureThreshold(driver) or driver:isDriveUnloadNowRequested()
            or not combine.vehicle:getIsCpActive() or combine.aiTurn~=bypass.turn
            or combine.state~=combine.states.TURNING then
        Q.clearHarvesterBypass(driver)
        return false
    end
    if g_currentMission.time>=bypass.untilTime and
            (bypass.turn.state==bypass.turn.states.PREPARING_RECOVERY
                or bypass.turn.state==bypass.turn.states.WAITING_FOR_PATHFINDER) then
        if bypass.turn.queueBypassFailed then
            bypass.turn:queueBypassFailed('search timed out')
        end
        if data.bypass then
            driver:setMaxSpeed(0)
            return true
        end
        return false
    end
    driver:setMaxSpeed(0)
    return true
end

-- Read CP's current route; never create or replace a harvester course here.
-- The envelope includes the attached header, relative to the AI direction node.
function Q.yieldArea(combine,travelCourse,horizon,sampleLimit)
    horizon=horizon or 30; sampleLimit=sampleLimit or 160
    local strategy=combine:getCpDriveStrategy()
    local origin=W.pose(combine:getAIDirectionNode())
    local bodies=W.currentBodies(combine)
    if not bodies then return nil,'harvester body geometry unavailable' end
    local left,right,front,back=-math.huge,math.huge,-math.huge,math.huge
    for _,item in ipairs(bodies) do
        for _,p in ipairs(W.rectangle(item.body,item.pose,0)) do
            local dx,dz=p.x-origin.x,p.z-origin.z
            local x,z=dx*math.cos(origin.t)-dz*math.sin(origin.t),dx*math.sin(origin.t)+dz*math.cos(origin.t)
            left=math.max(left,x); right=math.min(right,x)
            front=math.max(front,z); back=math.min(back,z)
        end
    end
    local box={width=left-right,length=front-back,xOffset=(left+right)/2,zOffset=(front+back)/2}
    local rectangles={}
    local function add(p)
        local r=G.rectangle({x=p.x,z=p.z,heading=p.t},box,1)
        r.minX=math.huge; r.maxX=-math.huge; r.minZ=math.huge; r.maxZ=-math.huge
        for _,q in ipairs(r) do
            r.minX=math.min(r.minX,q.x); r.maxX=math.max(r.maxX,q.x)
            r.minZ=math.min(r.minZ,q.z); r.maxZ=math.max(r.maxZ,q.z)
        end
        rectangles[#rectangles+1]=r
    end
    add(origin)
    local course=travelCourse or (strategy.getCurrentCourse and strategy:getCurrentCourse())
    local ix=strategy.ppc and strategy.ppc:getRelevantWaypointIx()
    if course and ix and course:getNumberOfWaypoints()>1 then
        local previous,travelled,sinceSample=origin,0,0
        -- A local horizon covers the immediate turn without reserving an
        -- entire fieldwork row. Bound both travel and sample count.
        local cornerRadius=math.sqrt(math.max(left*left,right*right)+math.max(front*front,back*back))
        for i=math.max(1,ix),course:getNumberOfWaypoints() do
            local x,_,z=course:getWaypointPosition(i)
            -- Waypoint yaw describes the outgoing segment. At a gear change,
            -- use the same physical heading convention as Course's offsets.
            local reverse=(course:isReverseAt(i) and not course:switchingToForwardAt(i))
                or course:switchingToReverseAt(i)
            local t=course:getWaypointYRotation(i)+(reverse and math.pi or 0)
            local d=distance(previous,{x=x,z=z})
            local fraction=d>0 and math.min(1,(horizon-travelled)/d) or 1
            local target={x=previous.x+(x-previous.x)*fraction,z=previous.z+(z-previous.z)*fraction,
                t=previous.t+H.math.delta(t,previous.t)*fraction}
            local motion=d*fraction+cornerRadius*math.abs(H.math.delta(target.t,previous.t))
            -- Carry the corner-travel allowance across waypoint boundaries.
            -- One sample per tiny waypoint would exhaust the limit even on a
            -- straight route. One metre of padding covers the unsampled sweep.
            local sampleAt=1-sinceSample
            while sampleAt<=motion and motion>0 do
                if #rectangles>=sampleLimit then return nil,'harvester route envelope sample limit' end
                local f=sampleAt/motion
                add({x=previous.x+(target.x-previous.x)*f,z=previous.z+(target.z-previous.z)*f,
                    t=previous.t+H.math.delta(target.t,previous.t)*f})
                sampleAt=sampleAt+1
            end
            sinceSample=motion-(sampleAt-1)
            previous=target; travelled=travelled+d*fraction
            if travelled>=horizon then break end
        end
        if sinceSample>0.000001 then
            if #rectangles>=sampleLimit then return nil,'harvester route envelope sample limit' end
            add(previous)
        end
    end
    local function overlaps(rectangle)
        local minX,maxX,minZ,maxZ=math.huge,-math.huge,math.huge,-math.huge
        for _,p in ipairs(rectangle) do
            minX=math.min(minX,p.x); maxX=math.max(maxX,p.x)
            minZ=math.min(minZ,p.z); maxZ=math.max(maxZ,p.z)
        end
        for _,r in ipairs(rectangles) do
            if minX<=r.maxX and maxX>=r.minX and minZ<=r.maxZ and maxZ>=r.minZ
                    and G.overlap(rectangle,r) then return true end
        end
        return false
    end
    return overlaps,nil,rectangles
end

-- A loaded trailer's native marker route can converge with a working header
-- even when route centrelines do not cross. Yield before entering that sweep;
-- never stop a rig already inside it, which must retain native clearance.
function Q.holdWorkingDeparture(driver,forwards,speed)
    local data=driver.queueData
    if not data or not data.nativeDeparture or not Q.enabled(driver) or Q.owns(driver)
            or driver.state~=driver.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL or not forwards then
        if data then data.workingDepartureCheck=nil; data.workingDepartureHold=nil end
        return false
    end
    local course=driver.getCurrentCourse and driver:getCurrentCourse()
    if not course or not driver.ppc then return false end
    local prior=data.workingDepartureCheck
    if not prior or prior.course~=course then
        data.workingDepartureHold=nil; data.workingDepartureClearSince=nil
    end
    local velocity=math.max((driver.vehicle.lastSpeedReal or 0)*1000,driver:getFieldSpeed()/3.6,(speed or 0)/3.6,
        data.workingDepartureHold and prior and prior.velocity or 0)
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    local cached=data.workingDepartureCheck
    if cached and cached.course==course and velocity<=cached.velocity
            and distance(here,cached.pose)<0.5 and g_currentMission.time-cached.time<100 then return cached.hold end
    cached={course=course,velocity=velocity,pose=here,time=g_currentMission.time,hold=false}
    data.workingDepartureCheck=cached
    -- Braking at 2 m/s², plus reaction time and clearance. The trailer length
    -- contributes to the combine's prediction until the complete rig passes.
    local horizon=math.max(12,velocity*velocity/4+velocity+8)
    local projected,crossingTime
    for _,vehicle in pairs(g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles or {}) do
        if vehicle~=driver.vehicle and AIDriveStrategyCombineCourse.isActiveCpCombine(vehicle) then
            local combine=vehicle:getCpDriveStrategy()
            if combine.states and combine.state==combine.states.WORKING and combine.course
                    and ((vehicle.lastSpeedReal or 0)*3600>0.5 or data.workingDepartureHold==vehicle)
                    and distance(here,W.pose(vehicle:getAIDirectionNode()))<100 then
                if not projected then
                    local _,_,rectangles=Q.yieldArea(driver.vehicle,course,horizon,300)
                    projected=rectangles
                    if not projected or not projected[1] then return false end
                    -- The first rectangle encloses every attached body at the
                    -- current pose. AIUtil length can describe only the tractor.
                    local wholeLength=distance(projected[1][1],projected[1][4])
                    crossingTime=2+(horizon+wholeLength)/math.max(1,velocity)
                end
                local travel=math.min(50,math.max(0,(vehicle.lastSpeedReal or 0)*1000)*crossingTime)
                local area=Q.yieldArea(vehicle,combine.course,travel,300)
                if area and (data.workingDepartureHold==vehicle or not intersects(area,driver.vehicle)) then
                    for _,rectangle in ipairs(projected) do
                        if area(rectangle) then cached.hold=vehicle; break end
                    end
                end
            end
        end
        if cached.hold then break end
    end
    -- One clear frame is insufficient: a changing header sweep or native speed
    -- must not make a stopped departure repeatedly accelerate into the crossing.
    local held=data.workingDepartureHold
    if cached.hold then
        data.workingDepartureClearSince=nil
    elseif held and AIDriveStrategyCombineCourse.isActiveCpCombine(held) then
        data.workingDepartureClearSince=data.workingDepartureClearSince or g_currentMission.time
        if g_currentMission.time-data.workingDepartureClearSince<2000 then cached.hold=held end
    end
    if cached.hold~=data.workingDepartureHold then
        driver:debug(cached.hold and 'Queue: holding native departure before working combine/header crossing'
            or 'Queue: working combine/header crossing clear; resuming native departure')
        data.workingDepartureHold=cached.hold
    end
    return cached.hold
end

-- Unloader-to-unloader clearance is separate from harvester end parking.
-- Keep a live combine reservation until the complete rig reaches a parallel slot.
local function trafficEligible(driver)
    if not driver or not Q.members[driver] or not Q.enabled(driver) or driver.queueData.nativeDeparture
            or Q.nativeClearanceActive(driver) or Q.atDepartureThreshold(driver)
            or (driver.driveUnloadNowRequested and driver.driveUnloadNowRequested:get()) or not driver.vehicle:getIsCpActive() then return false end
    local combine=driver.combineToUnload
    if combine then
        local c=combine:getIsCpActive() and combine:getCpDriveStrategy()
        if not c or not c.alwaysNeedsUnloader or not c.hasAutoAimPipe or not c.isDischarging
                or c:alwaysNeedsUnloader() or c:hasAutoAimPipe() or c:isDischarging() then return false end
    end
    return driver.state==driver.states.IDLE or (Q.owns(driver) and driver.queueData.operation=='prepare')
        or driver.state==driver.states.DRIVING_TO_COMBINE
        or driver.state==driver.states.DRIVING_TO_MOVING_COMBINE
        or driver.state==driver.states.UNLOADING_MOVING_COMBINE
end

function Q.clearTrailerTraffic(driver)
    local data=driver.queueData
    local waiting=data and data.trailerWait
    if waiting then
        local other=waiting.queueData
        if other and other.trailerTraffic and other.trailerTraffic.other==driver then other.trailerTraffic.cancelled=true end
        data.trailerWait=nil
    end
    local traffic=data and data.trailerTraffic
    if traffic then
        local other=traffic.other.queueData
        if other and other.trailerWait==driver then other.trailerWait=nil end
        data.trailerTraffic=nil
    end
end

function Q.trailerTrafficHold(driver)
    local data=driver.queueData
    local yielding=data and data.trailerWait
    if not yielding then return false end
    if data.nativeDeparture or Q.atDepartureThreshold(driver) or (driver.driveUnloadNowRequested and driver.driveUnloadNowRequested:get()) then
        Q.clearTrailerTraffic(driver); return false
    end
    local other=yielding.queueData
    if not yielding.vehicle:getIsCpActive() or not other or not Q.owns(yielding)
            or not other.trailerTraffic or other.trailerTraffic.other~=driver
            or other.trailerTraffic.waitingOwner~=driver.combineToUnload then
        Q.clearTrailerTraffic(driver); return false
    end
    return true
end

function Q.beginTrailerTraffic(driver,vehicle)
    local other=vehicle and vehicle.getCpDriveStrategy and vehicle:getCpDriveStrategy()
    if not other or other==driver or not Q.members[other] then return false end
    local data=Q.data(driver)
    if data.trailerTraffic or Q.trailerTrafficHold(driver) then return true end
    if not trafficEligible(driver) or not trafficEligible(other) then return false end
    if (data.trafficRetryAt or 0)>g_currentMission.time then return false end
    if driver.combineToUnload and driver.combineToUnload==other.combineToUnload then return false end
    if other.queueData.trailerTraffic or Q.trailerTrafficHold(other) then return false end
    -- A parked unloader gives way to one with a call; otherwise the requester
    -- yields. The reciprocal wait fixes the decision in either update order.
    local parked=other.state==other.states.IDLE or Q.owns(other)
    local yielding,waiting=driver,other
    if parked and driver.combineToUnload then yielding,waiting=other,driver end
    local probe=setmetatable({queueData={operation='yield'}},{__index=yielding})
    local world=W.new(probe)
    if not world then return false end
    local clear=W.clear(world,W.poses(world.model)); W.delete(world)
    if not clear then return false end -- no unchecked escape from overlapping bodies
    local area=Q.yieldArea(waiting.vehicle,nil,30,240)
    if not area then return false end
    local goal=Q.poolTarget(yielding,false,area)
    if not goal then return false end
    if yielding.pathfinderController then yielding.pathfinderController.pathfinder=nil end
    Q.clearStoppedApproach(yielding); Q.clearFinalUnload(yielding)
    local owner=yielding.combineToUnload
    local yd=Q.take(yielding,'yield')
    yd.trailerTraffic={other=waiting,owner=owner,waitingOwner=waiting.combineToUnload,area=area,goal=goal,started=g_currentMission.time,
        progress=W.pose(yielding.vehicle:getAIDirectionNode()),progressAt=g_currentMission.time}
    Q.data(waiting).trailerWait=yielding
    yd.nextAttempt=0
    Q.reason(yd,'checked parallel clearance for '..CpUtil.getName(waiting.vehicle))
    return true
end

function Q.updateTrailerTraffic(driver)
    local data=driver.queueData
    local traffic=data and data.trailerTraffic
    if not traffic then return false end
    if not Q.owns(driver) then Q.clearTrailerTraffic(driver); return false end
    local finished=data.parkedGoal and Q.arrived(driver,data.parkedGoal)
    local cancelled=traffic.cancelled or not traffic.other.vehicle:getIsCpActive()
        or traffic.other.combineToUnload~=traffic.waitingOwner
        or driver.combineToUnload~=traffic.owner
        or (traffic.owner and not traffic.owner:getIsCpActive())
    local pose=W.pose(driver.vehicle:getAIDirectionNode())
    if distance(pose,traffic.progress)>1 then traffic.progress=pose; traffic.progressAt=g_currentMission.time end
    local failed=data.yieldFailed or g_currentMission.time-traffic.progressAt>60000
    if not finished and not cancelled and not failed then return false end
    local parked=finished and data.parkedGoal
    Q.clearTrailerTraffic(driver)
    Q.release(driver)
    driver:startWaitingForSomethingToDo() -- native deregistration and fresh call geometry
    data.parkedGoal=parked
    data.trafficRetryAt=g_currentMission.time+10000
    data.nextAttempt=0
    driver:debug('Queue: trailer clearance %s; native assignment released',finished and 'parked parallel' or 'cancelled for replanning')
    return true
end

-- Only a stopped unloader actually occupying the immediate forward route can
-- request early clearance. Do not reserve intersecting routes across the field.
function Q.checkTrailerTraffic(driver)
    local data=driver.queueData
    if not data or data.trailerTraffic or Q.trailerTrafficHold(driver) or not trafficEligible(driver) then return end
    local time=g_currentMission.time
    if time<(data.trafficCheckAt or 0) or time<(data.trafficRetryAt or 0) then return end
    data.trafficCheckAt=time+500
    if not driver.combineToUnload or not driver.course then return end
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    for other,member in pairs(Q.members) do
        if other~=driver and trafficEligible(other) and (other.vehicle.lastSpeedReal or 0)*3600<0.5 then
            local pose=W.pose(other.vehicle:getAIDirectionNode())
            local dz=(pose.x-here.x)*math.sin(here.t)+(pose.z-here.z)*math.cos(here.t)
            if distance(here,pose)<35 and dz>0 then
                local area=Q.yieldArea(driver.vehicle,driver.course,12,160)
                if area then
                    for _,item in ipairs(W.currentBodies(other.vehicle) or {}) do
                        if area(W.rectangle(item.body,item.pose,2)) then
                            if Q.beginTrailerTraffic(driver,other.vehicle) then return end
                        end
                    end
                end
            end
        end
    end
end

function Q.resumeAfterYield(driver)
    local data=Q.data(driver)
    data.priorityCombine=nil; data.yieldRequests=nil
    if Q.departureClearanceActive(driver) then
        Q.resumeNativeDeparture(driver,'whole rig clear of harvester turn'); return
    end
    Q.take(driver,'prepare')
    data.nextAttempt=0
    Q.reason(data,'clear of harvester manoeuvre; resuming prepare')
end

-- Preserve native clearance until it finishes, regardless of the combine's state.
function Q.nativeClearanceActive(driver)
    local state,states=driver.state,driver.states
    if not state then return false end
    for _,name in ipairs({'MOVING_AWAY_FROM_OTHER_VEHICLE','BACKING_UP_FOR_REVERSING_COMBINE',
            'MOVING_BACK','MOVING_BACK_WITH_TRAILER_FULL','MOVING_BACK_BEFORE_PATHFINDING','MOVING_BACK_FOR_HEADLAND_TURN'}) do
        if states[name] and state==states[name] then return true end
    end
    return false
end

-- A failed queue search must not monopolise clearance. Native proximity and
-- move-away steering remain responsible for the handback; never skip W.clear.
function Q.updateYieldRecovery(driver)
    local data=driver.queueData
    if not data or data.operation~='yield' or not Q.owns(driver) then return false end
    if data.trailerTraffic then return Q.updateTrailerTraffic(driver) end
    Q.yieldTarget(driver,true)
    if data.operation~='yield' or not Q.owns(driver) then return false end
    local time=g_currentMission.time
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    if not data.yieldProgress then
        data.yieldProgress=here; data.yieldProgressTime=data.yieldProgressTime or time
    elseif distance(here,data.yieldProgress)>1 then
        data.yieldProgress=here; data.yieldProgressTime=time; data.yieldFailed=nil
    end
    local timeout=data.yieldFailed and 15000 or 60000
    if time-data.yieldProgressTime<timeout or not Q.nativeMoveAway
            or (driver.isBeingHeld and driver:isBeingHeld()) then return false end
    if Q.departureClearanceActive(driver) then
        Q.resumeNativeDeparture(driver,'checked departure clearance made no progress'); return true
    end
    local vehicle=data.priorityCombine
    if not vehicle or not (data.yieldRequests and data.yieldRequests[vehicle])
            or not AIDriveStrategyCombineCourse.isActiveCpCombine(vehicle) then
        vehicle=nil
        for other in pairs(data.yieldRequests or {}) do
            if AIDriveStrategyCombineCourse.isActiveCpCombine(other) then vehicle=other; break end
        end
    end
    if not vehicle then return false end
    Q.reason(data,'yield made no progress; returning clearance to native CP')
    Q.release(driver)
    data.priorityCombine=nil; data.yieldRequests=nil
    data.nativeYieldUntil=time+15000
    Q.nativeMoveAway(driver,vehicle)
    return true
end

function Q.priority(driver,combine)
    if (driver.queueData and driver.queueData.nativeDeparture)
            or driver.state==driver.states.MOVING_BACK_WITH_TRAILER_FULL then return false end
    if not Q.enabled(driver) or not combine or not driver.vehicle:getIsCpActive()
            or not AIDriveStrategyCombineCourse.isActiveCpCombine(combine) then return false end
    if Q.atDepartureThreshold(driver) or driver:isDriveUnloadNowRequested() then return false end
    if Q.nativeClearanceActive(driver) or (driver.queueData
            and (driver.queueData.nativeYieldUntil or 0)>g_currentMission.time) then return false end
    local strategy=combine:getCpDriveStrategy()
    if ordinaryTravelTurn(strategy) and Q.holdIncomingTurn(driver) then return true end
    -- Native continuous-harvester following already handles its own harvester's proximity
    -- and turns. Other queued/approaching trailers still yield to it normally.
    if driver.combineToUnload==combine and combine:getCpDriveStrategy():alwaysNeedsUnloader() and not Q.owns(driver) then
        return false
    end
    local data=Q.data(driver)
    if data.bypass and data.bypass.combine.vehicle==combine then return true end
    Q.clearHarvesterBypass(driver)
    if data.operation=='yield' and Q.owns(driver) and not data.trailerTraffic then
        data.yieldRequests[combine]=data.yieldRequests[combine] or {}
        data.yieldRequests[combine].clearSince=nil
        return true
    end
    -- Preflight every takeover, including straight fieldwork and queue parking.
    -- An invalid start prevents all search candidates, not just the first goal.
    local probe=setmetatable({queueData={operation='yield'}},{__index=driver})
    local world,reason=W.new(probe)
    local clear=false
    if world then clear,reason=W.clear(world,W.poses(world.model)); W.delete(world) end
    if not clear then
        data.nativeYieldUntil=g_currentMission.time+15000
        Q.reason(data,'native clearance retained: '..tostring(reason))
        return false
    end
    -- Native searches are advanced synchronously by this controller; removing
    -- its runner prevents a superseded callback after clearance. The next native
    -- call installs its own context/listeners in the ordinary way.
    Q.clearTrailerTraffic(driver)
    if driver.pathfinderController then driver.pathfinderController.pathfinder=nil end
    driver:releaseCombine()
    Q.take(driver,'yield')
    data.priorityCombine=combine
    data.yieldRequests={[combine]={}}
    data.nextAttempt=0
    Q.reason(data,'yield requested by '..CpUtil.getName(combine))
    return true
end

function Q.yieldTarget(driver,checkOnly)
    local data=Q.data(driver)
    if data.trailerTraffic then return checkOnly and true or data.trailerTraffic.goal end
    local bodies=W.currentBodies(driver.vehicle)
    local areas,combine,anyBlocked,preferForward={},nil,false,false
    local time=g_currentMission.time
    for vehicle,request in pairs(data.yieldRequests or {}) do
        if not AIDriveStrategyCombineCourse.isActiveCpCombine(vehicle)
                or (request.finishCourse and (vehicle:getCpDriveStrategy().fieldWorkCourse~=request.finishCourse
                    or not Q.finishLane(vehicle:getCpDriveStrategy()))) then
            data.yieldRequests[vehicle]=nil
        else
            local strategy=vehicle:getCpDriveStrategy()
            if request.turnClearance and request.turn and (strategy.aiTurn~=request.turn
                    or strategy.turnContext~=request.turnContext or not ordinaryTravelTurn(strategy)) then
                request.turnClearance=nil; request.turn=nil; request.turnContext=nil
                request.preferForward=nil; request.checked=nil; request.area=nil; request.clearSince=nil
            end
            preferForward=preferForward or request.preferForward
            if not request.checked or time-request.checked>=200 then
                if request.turnClearance then request.area=request.turnClearance
                else request.area,request.reason=Q.yieldArea(vehicle) end
                request.checked=time
            end
            local blocked=not bodies or not request.area or strategy:isVehicleInProximity(driver.vehicle)
            for _,item in ipairs(bodies or {}) do
                if request.area and request.area(W.rectangle(item.body,item.pose)) then blocked=true end
            end
            anyBlocked=anyBlocked or blocked
            if blocked then request.clearSince=nil else request.clearSince=request.clearSince or time end
            if request.clearSince and time-request.clearSince>=2000 then
                data.yieldRequests[vehicle]=nil
            else
                combine=combine or vehicle
                if not request.area then
                    Q.reason(data,'harvester clearance unavailable: '..(request.reason or 'unknown geometry'))
                    return
                end
                areas[#areas+1]=request.area
            end
        end
    end
    if not combine then Q.resumeAfterYield(driver); return end
    if checkOnly then return true end
    if not anyBlocked then return end -- let the existing safe pass finish without starting another move
    local pose=W.pose(combine:getAIDirectionNode())
    local width=combine:getCpDriveStrategy():getWorkWidth()+4
    local function corridor(rectangle)
        for _,area in ipairs(areas) do if area(rectangle) then return true end end
        return false
    end
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    local lateral=(here.x-pose.x)*math.cos(pose.t)-(here.z-pose.z)*math.sin(pose.t)
    local side=lateral>=0 and 1 or -1
    local function accepts(poses,model)
        for i,p in ipairs(poses) do if corridor(W.rectangle(model.bodies[i],p)) then return false end end
        return true
    end
    local choices={}
    if preferForward then
        for _,length in ipairs({10,20,40,60}) do
            local p=G.point({x=here.x,z=here.z,heading=here.t},0,length)
            p.t=here.t; p.accept=accepts; p.clearance=corridor
            choices[#choices+1]=p
        end
    end
    for _,lateralSide in ipairs({side,-side}) do
        local p=G.point({x=here.x,z=here.z,heading=here.t},lateralSide*(width/2+8),
            math.max(40,3*driver.turningRadius))
        p.t=here.t; p.accept=accepts; p.clearance=corridor
        choices[#choices+1]=p
        -- A quarter turn followed by a straight clearance leg can fit where
        -- returning immediately to the original heading would swing the
        -- trailer across the header. The search still validates the full rig.
        local lateral=G.point({x=here.x,z=here.z,heading=here.t},
            lateralSide*(2*driver.turningRadius+2*AIUtil.getLength(driver.vehicle)),driver.turningRadius)
        lateral.t=here.t+lateralSide*math.pi/2
        lateral.accept=accepts; lateral.clearance=corridor
        choices[#choices+1]=lateral
    end
    for _,length in ipairs({10,20,40,60}) do
        local reverse=G.point({x=here.x,z=here.z,heading=here.t},0,-length)
        reverse.t=here.t; reverse.reverse=true; reverse.accept=accepts; reverse.clearance=corridor
        choices[#choices+1]=reverse
    end
    -- If all fixed destinations are outside the field or obstructed, search
    -- for a reachable clear footprint instead of repeating those destinations.
    local target={x=choices[1].x,z=choices[1].z,t=here.t,choices=choices,escape=accepts}
    return target
end

-- A final, stationary unload has no harvesting progress to rescue a failed pipe
-- approach. Recover only after both the rig and the grain transfer stop.
function Q.clearFinalUnload(driver)
    local data=driver.queueFinalUnload
    if data then W.delete(data.world); driver.queueFinalUnload=nil end
end

local function finalUnloadTarget(driver)
    local vehicle=driver.combineToUnload
    if not Q.enabled(driver) or not vehicle or not vehicle:getIsCpActive() then return nil end
    local combine=vehicle:getCpDriveStrategy()
    if not combine or not combine.isWaitingForUnloadAfterCourseEnded
            or not combine:isWaitingForUnloadAfterCourseEnded()
            or not combine.combineController then return nil end
    return combine,combine.combineController:getFillLevel()
end

local function stopFinalUnload(driver,reason)
    driver:debug('Queue: final unload recovery stopped safely: %s',reason)
    Q.clearFinalUnload(driver)
    driver:setMaxSpeed(0)
    driver.vehicle:stopCurrentAIJob(AIMessageCpErrorNoPathFound.new())
end

local function finalDeparting(driver)
    return driver:isDriveUnloadNowRequested() or Q.atDepartureThreshold(driver)
end

local function beginFinalReverse(driver,data)
    if data.attempts>=2 then stopFinalUnload(driver,'two approaches made no progress'); return end
    W.delete(data.world)
    local world,reason=W.new(driver)
    if not world then stopFinalUnload(driver,reason); return end
    data.world=world
    local origin=world.model.root
    local x,z=H.math.position(origin,0,-15)
    data.search,reason=CpUnloaderQueueSearch.new(world,{x=x,z=z,t=origin.t,reverse=true})
    if not data.search then stopFinalUnload(driver,'reverse clearance: '..reason); return end
    data.attempts=data.attempts+1; data.phase='checkingReverse'; data.started=g_currentMission.time
    data.origin=origin; data.goal={x=x,z=z,t=origin.t}
    driver:debug('Queue: final unload made no movement or transfer for 12 s; checking reverse recovery %d/2',data.attempts)
end

function Q.watchFinalUnload(driver)
    if not driver.state or driver.state~=driver.states.UNLOADING_STOPPED_COMBINE then return false end
    local combine,fill=finalUnloadTarget(driver)
    if not combine or fill<0.01 or finalDeparting(driver) then
        Q.clearFinalUnload(driver); return false
    end
    local time=g_currentMission.time
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    local data=driver.queueFinalUnload
    if not data or data.combine~=driver.combineToUnload then
        Q.clearFinalUnload(driver)
        data={combine=driver.combineToUnload,phase='watching',attempts=0,progress=here,fill=fill,progressTime=time}
        driver.queueFinalUnload=data
    end
    if data.phase=='checkingReverse' then driver:setMaxSpeed(0); return true end
    if data.phase~='watching' then return false end
    if distance(here,data.progress)>0.5 or data.fill-fill>1 then
        data.progress=here; data.fill=fill; data.progressTime=time
    end
    if time-data.progressTime>=12000 then
        beginFinalReverse(driver,data); driver:setMaxSpeed(0); return true
    end
    return false
end

-- A recovery must reach its checked run-in before native CP resumes the final
-- straight pipe approach. Check the whole articulated rig, including headers
-- of neighbouring combines through the ordinary native collision detector.
function Q.deferFinalPipeApproach(driver)
    local data=driver.queueFinalUnload
    if not data or data.combine~=driver.combineToUnload then return false end
    if data.phase=='checkingLane' then driver:setMaxSpeed(0); return true end
    if data.phase~='replanning' then return false end
    if driver.course:getDistanceToLastWaypoint(driver.ppc:getCurrentWaypointIx())>3 then return true end
    if finalDeparting(driver) then
        Q.clearFinalUnload(driver); driver:changeToUnloadWhenTrailerFull(); return true
    end
    local world,reason=W.new(driver)
    if not world then stopFinalUnload(driver,reason); return true end
    data.world=world
    local reference=driver:getPipeOffsetReferenceNode()
    local offsetX=driver:getPipeOffset(driver.combineToUnload)
    local _,_,z=localToLocal(driver.vehicle:getAIDirectionNode(),reference,0,0,0)
    local remaining=driver:getBestTargetNodeDistanceFromPipe()
    if not remaining or remaining<0 or remaining>40 then
        stopFinalUnload(driver,'final fill-node alignment unavailable'); return true
    end
    local x,_,gz=localToWorld(reference,offsetX,0,z+remaining)
    data.laneOrigin=world.model.root; data.laneGoal={x=x,z=gz,t=H.math.heading(reference)}
    data.lanePoses=W.poses(world.model)
    for _,pose in ipairs(data.lanePoses) do
        if math.abs(H.math.delta(pose.t,data.laneGoal.t))>math.rad(10) then
            stopFinalUnload(driver,'complete rig not aligned for final pipe approach'); return true
        end
    end
    data.laneCount=math.max(1,math.ceil(distance(data.laneOrigin,data.laneGoal)/0.25))
    data.laneStep=0; data.phase='checkingLane'; data.started=g_currentMission.time
    driver:setMaxSpeed(0)
    return true
end

function Q.finishFinalReverse(driver)
    local data=driver.queueFinalUnload
    if not data or data.phase~='reversing' or driver.state~=driver.states.MOVING_BACK_BEFORE_PATHFINDING
            or driver.course~=data.course then return false end
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    if distance(here,data.goal)>2 then stopFinalUnload(driver,'reverse ended before clearance'); return true end
    W.delete(data.world); data.world=nil; data.course=nil
    -- The native button request expires after one second. Retain the accepted
    -- intent while finishing our checked reverse, then re-enter native departure.
    if data.departing and not finalDeparting(driver) then driver:requestDriveUnloadNow() end
    local combine,fill=finalUnloadTarget(driver)
    if not combine then
        Q.clearFinalUnload(driver)
        if data.combine.queueFinishedEmptyCombine then
            driver:setNewState(driver.states.UNLOADING_STOPPED_COMBINE)
            Q.releaseFinishedCombine(driver)
        else driver:startWaitingForSomethingToDo() end
        return true
    end
    if finalDeparting(driver) then
        Q.clearFinalUnload(driver)
        driver:changeToUnloadWhenTrailerFull()
        return true
    end
    if fill<0.01 then
        Q.clearFinalUnload(driver); driver:setNewState(driver.states.UNLOADING_STOPPED_COMBINE)
        driver:unloadStoppedCombine(); return true
    end
    local x,z=driver:getPipeOffset(driver.combineToUnload)
    -- Negative local Z is behind the pipe reference, with room for the trailer
    -- to settle. A second attempt uses a longer run-in, never the same goal.
    z=math.min(z-15-10*(data.attempts-1),-driver:getCombinesMeasuredBackDistance()-10)
    data.phase='replanning'; data.started=g_currentMission.time
    data.controller=driver.pathfinderController
    driver:setNewState(driver.states.WAITING_FOR_PATHFINDER)
    driver:debug('Queue: final unload recovery %d/2, native replan at pipe offset %.1f, %.1f',data.attempts,x,z)
    driver:startPathfindingToWaitingCombine(x,z)
    return true
end

-- Native obstacle-at-start retries temporarily reverse with the same controller
-- and context. Retain only that recovery, never an unrelated manoeuvre.
function Q.isRecoveryBackup(driver,data)
    local properties=driver.state and driver.state.properties
    local controller=data.controller
    return (data.phase=='pathfinding' or data.phase=='replanning')
        and controller and controller==driver.pathfinderController
        and driver.state==driver.states.MOVING_BACK_BEFORE_PATHFINDING and properties
        and properties.pathfinderController==controller and properties.pathfinderContext
        and properties.pathfinderContext==data.context and data.context==controller.currentContext
end

-- A completed or stopped target must not survive as a pending retry. A
-- successful finish may wait for the current native reverse to reach its end.
function Q.releaseLostRecoveryTarget(driver,data)
    if data.combine~=driver.combineToUnload then return false end
    if data.combine:getIsCpActive() then return false end
    if data.controller and driver.pathfinderController==data.controller then driver.pathfinderController.pathfinder=nil end
    local properties=driver.state and driver.state.properties
    if properties and properties.pathfinderController==data.controller then
        properties.pathfinderController=nil; properties.pathfinderContext=nil
    end
    if driver.queueData then driver.queueData.waitingApproach=nil; driver.queueData.deferredApproach=nil end
    Q.clearStoppedApproach(driver); Q.clearFinalUnload(driver)
    driver:setMaxSpeed(0)
    if data.departing and not finalDeparting(driver) then driver:requestDriveUnloadNow() end
    if data.combine.queueFinishedEmptyCombine then
        driver:setNewState(driver.states.UNLOADING_STOPPED_COMBINE)
        Q.releaseFinishedCombine(driver)
    else driver:startWaitingForSomethingToDo() end
    return true
end

function Q.finishRecoveryBackup(driver)
    local data=driver.queueStoppedApproach or driver.queueFinalUnload
    if data and Q.isRecoveryBackup(driver,data) then return Q.releaseLostRecoveryTarget(driver,data) end
    return false
end

function Q.updateFinalUnload(driver)
    local data=driver.queueFinalUnload
    if not data then return end
    local combine=finalUnloadTarget(driver)
    local phase=data.phase
    local watching=driver.state==driver.states.UNLOADING_STOPPED_COMBINE
    local reversing=driver.state==driver.states.MOVING_BACK_BEFORE_PATHFINDING and driver.course==data.course
    local nativeBackup=phase=='replanning' and Q.isRecoveryBackup(driver,data)
    if data.combine==driver.combineToUnload and not data.combine:getIsCpActive() and not reversing then
        if nativeBackup and data.combine.queueFinishedEmptyCombine then
            data.departing=data.departing or finalDeparting(driver)
            if g_currentMission.time-data.started>90000 then stopFinalUnload(driver,'recovery timed out') end
        else Q.releaseLostRecoveryTarget(driver,data) end
        return
    end
    local approaching=nativeBackup or driver.state==driver.states.WAITING_FOR_PATHFINDER
        or driver.state==driver.states.DRIVING_TO_COMBINE
    -- A successful job stop may remove the combine strategy mid-reverse.
    -- Finish the already checked course before native release/departure.
    local finishedWhileReversing=not combine and reversing and data.combine==driver.combineToUnload
        and data.combine.queueFinishedEmptyCombine
    if not combine and data.combine==driver.combineToUnload and reversing and not finishedWhileReversing then
        Q.clearFinalUnload(driver); driver:setMaxSpeed(0); driver:startWaitingForSomethingToDo(); return
    end
    if data.combine~=driver.combineToUnload or not combine and not finishedWhileReversing
            or (phase=='watching' or phase=='checkingReverse') and not watching
            or phase=='reversing' and not reversing
            or (phase=='replanning' or phase=='checkingLane') and not approaching then
        Q.clearFinalUnload(driver); return
    end
    data.departing=data.departing or finalDeparting(driver)
    if phase=='watching' then return end
    local time=g_currentMission.time
    if time-data.started>90000 then stopFinalUnload(driver,'recovery timed out'); return end
    if nativeBackup then return end -- finish native clearance before acting on latched departure
    if phase~='reversing' and data.departing and not finalDeparting(driver) then driver:requestDriveUnloadNow() end
    if phase=='replanning' then
        if data.departing then
            -- The controller coroutine only resumes in the subsequent native
            -- update. Retire this owned replan before native departure starts.
            if driver.pathfinderController then driver.pathfinderController.pathfinder=nil end
            if driver.queueData then
                driver.queueData.waitingApproach=nil; driver.queueData.deferredApproach=nil
            end
            Q.clearFinalUnload(driver)
            driver:changeToUnloadWhenTrailerFull()
        end
        return
    end
    if phase=='checkingReverse' or phase=='checkingLane' then
        driver:setMaxSpeed(0)
        if data.departing then
            Q.clearFinalUnload(driver); driver:changeToUnloadWhenTrailerFull(); return
        end
        local timer=openIntervalTimer()
        local done,path,reason
        for i=1,8 do
            if phase=='checkingReverse' then
                done,path,reason=CpUnloaderQueueSearch.step(data.search,1)
            else
                local a,b=data.laneOrigin,data.laneGoal
                local f=data.laneStep/data.laneCount
                local pose={x=a.x+(b.x-a.x)*f,z=a.z+(b.z-a.z)*f,t=a.t+H.math.delta(b.t,a.t)*f}
                local poses=H.advance(data.world.model,data.lanePoses,pose)
                local clear
                clear,reason=W.clear(data.world,poses)
                if not clear then done=true else
                    data.lanePoses=poses; data.laneStep=data.laneStep+1
                    done=data.laneStep>data.laneCount; path=done and true or nil
                end
            end
            if done or readIntervalTimerMs(timer)>=2 then break end
        end
        closeIntervalTimer(timer)
        if done and not path then stopFinalUnload(driver,'checked '..phase..': '..(reason or 'unavailable')); return end
        if not done then return end
        if phase=='checkingLane' then
            W.delete(data.world); data.world=nil
            data.phase='watching'; data.progress=W.pose(driver.vehicle:getAIDirectionNode())
            data.fill=combine.combineController:getFillLevel(); data.progressTime=time
            driver:startUnloadingStoppedCombine()
            return
        end
        local points={}
        for i,p in ipairs(path) do
            if i==1 or i==#path or i%4==0 then points[#points+1]={x=p.trackX,z=p.trackZ,rev=true} end
        end
        data.search=nil; data.phase='reversing'; data.started=time
        data.progressTime=time; data.progress=W.pose(driver.vehicle:getAIDirectionNode())
        data.course=Course(driver.vehicle,points,true)
        driver.ppc:setShortLookaheadDistance()
        driver:startCourse(data.course,1)
        driver:setNewState(driver.states.MOVING_BACK_BEFORE_PATHFINDING)
        return
    end
    -- Live reverse sweep and native proximity are both required. Never reverse
    -- further on the basis of the old search if another vehicle has arrived.
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    if distance(here,data.progress)>0.5 then data.progress=here; data.progressTime=time end
    if time-data.progressTime>12000 then stopFinalUnload(driver,'reverse made no progress'); return end
    local dx,dz=here.x-data.origin.x,here.z-data.origin.z
    if math.abs(dx*math.cos(data.origin.t)-dz*math.sin(data.origin.t))>1
            or math.abs(H.math.delta(here.t,data.origin.t))>math.rad(2) then
        stopFinalUnload(driver,'reverse deviated from checked route'); return
    end
    local model,reason=W.model(driver.vehicle)
    if not model then stopFinalUnload(driver,reason); return end
    data.world.model=model
    local poses=W.poses(model)
    data.clear=true
    for step=0,8 do
        local x,z=H.math.position(here,0,-math.min(step*0.5,distance(here,data.goal)))
        poses=H.advance(model,poses,{x=x,z=z,t=here.t})
        local clear=W.clear(data.world,poses)
        if not clear then data.clear=false; break end
    end
end

function Q.finalUnloadSpeed(driver,speed)
    local data=driver.queueFinalUnload
    if not data then return speed end
    if data.phase=='checkingReverse' or data.phase=='checkingLane' then return 0 end
    if data.phase=='reversing' then return data.clear and math.min(speed,5) or 0 end
    return speed
end

-- A full grain combine may stop during a moving rendezvous even with
-- stopForUnload disabled. A fill node already ahead of its pipe cannot be
-- reached by waiting for the combine to catch up. Preserve native release/recall,
-- then constrain the recovery outside the header before returning behind.
-- This is independent of finished-harvester parking and adds no driver state.
function Q.ordinaryStoppedTarget(driver)
    local vehicle=driver.combineToUnload
    if not Q.enabled(driver) or not vehicle or not vehicle.getIsCpActive or not vehicle:getIsCpActive() then return false end
    local c=vehicle:getCpDriveStrategy()
    if not c or not c.states or c.state~=c.states.UNLOADING_ON_FIELD
            or c.unloadState~=c.states.WAITING_FOR_UNLOAD_ON_FIELD
            or c:alwaysNeedsUnloader() or c:hasAutoAimPipe()
            or c:isDischarging() or c:isPipeMoving()
            or (vehicle.lastSpeedReal or 0)*3600>=0.5
            or (driver.vehicle.lastSpeedReal or 0)*3600>=0.5 then return false end
    return c
end

function Q.hasStoppedRendezvousOvershoot(driver)
    local c=Q.ordinaryStoppedTarget(driver)
    if not c then return false end
    -- A distant tractor can be longitudinally ahead without being stranded
    -- beside the header. Leave its field entry to native rear pathfinding.
    local gap=distance(W.pose(driver.vehicle:getAIDirectionNode()),W.pose(driver.combineToUnload:getAIDirectionNode()))
    if gap>math.max(40,3*driver.turningRadius+AIUtil.getLength(driver.vehicle)) then return false end
    local dz=driver:getBestTargetNodeDistanceFromPipe()
    return (not c:willWaitForUnloadToFinish() and dz~=nil and dz < -0.5)
        or driver.queueStoppedRecovery==driver.combineToUnload
end

-- Extra alignment/recovery belongs only to the remaining end-of-course load.
-- Ordinary waits retain the 3031 native approach unless the separate exact
-- front-overshoot condition above explicitly starts a checked rear entry.
function Q.finalApproachTarget(driver)
    local vehicle=driver.combineToUnload
    if not Q.enabled(driver) or not vehicle or not vehicle.getIsCpActive or not vehicle:getIsCpActive() then return end
    local c=vehicle:getCpDriveStrategy()
    if c and c.isWaitingForUnloadAfterCourseEnded and c:isWaitingForUnloadAfterCourseEnded()
            and c.isWaitingForUnload and c.alwaysNeedsUnloader and c.hasAutoAimPipe
            and c:isWaitingForUnload() and not c:alwaysNeedsUnloader() and not c:hasAutoAimPipe()
            and (vehicle.lastSpeedReal or 0)*3600<0.5 then return c end
end

-- A stored overshoot attempt may reuse the checked rear-entry phases, but
-- cannot acquire final-unload/parking authority or affect other ordinary calls.
function Q.checkedRearEntryTarget(driver)
    local final=Q.finalApproachTarget(driver)
    if final then return final end
    local data=driver.queueStoppedApproach
    local vehicle=driver.combineToUnload
    if not data or not data.overshoot or data.combine~=vehicle or not Q.enabled(driver)
            or not vehicle or not vehicle:getIsCpActive() then return end
    local c=vehicle:getCpDriveStrategy()
    if c and c.states and c.state==c.states.UNLOADING_ON_FIELD
            and c.unloadState==c.states.WAITING_FOR_UNLOAD_ON_FIELD
            and not c:alwaysNeedsUnloader() and not c:hasAutoAimPipe()
            and (vehicle.lastSpeedReal or 0)*3600<0.5 then return c end
end

local function forwardRunIn(search,heading,runIn)
    -- The direct candidate ends with its reserved straight alignment section.
    -- Reject loops/backtracking; do not fall back to a local search around the pipe.
    local points=search.direct
    if not points or #points<2 then return false end
    local a,b=points[#points-1],points[#points]
    if math.sqrt((a.x-b.x)^2+(a.y-b.y)^2)<runIn-1 then return false end
    local previous
    for _,p in ipairs(points) do
        if math.abs(H.math.delta(CpMathUtil.angleToGame(p.t),heading))>math.rad(45) then return false end
        local forward=p.x*math.sin(heading)-p.y*math.cos(heading)
        if previous and forward<previous-0.01 then return false end
        previous=forward
    end
    return true
end

function Q.pipeEntryAligned(driver)
    local model=W.model(driver.vehicle)
    if not model then return false end
    local reference=driver:getPipeOffsetReferenceNode()
    local heading=H.math.heading(reference)
    for _,pose in ipairs(W.poses(model)) do
        if math.abs(H.math.delta(pose.t,heading))>math.rad(10) then return false end
    end
    local x=localToLocal(driver.vehicle:getAIDirectionNode(),reference,0,0,0)
    local offset=driver:getPipeOffset(driver.combineToUnload)
    local dz=driver:getBestTargetNodeDistanceFromPipe()
    return math.abs(x-offset)<=1 and dz~=nil and dz>=-0.5 and dz<=40
end

function Q.clearStoppedApproach(driver)
    local data=driver.queueStoppedApproach
    if data then W.delete(data.world); driver.queueStoppedApproach=nil end
    driver.queueStoppedRecovery=nil
end

local function stoppedApproachFailed(driver,reason)
    local entry=driver.queueStoppedApproach
    local ordinary=(entry and entry.overshoot) or Q.ordinaryStoppedTarget(driver)
    if entry and entry.outward and (entry.escapeAttempt or 0)<3 and entry.phase=='checking' then
        W.delete(entry.world); entry.world=nil; entry.search=nil
        Q.beginStoppedEscape(driver); return
    end
    driver:debug('Queue: stopped-combine approach rejected safely: %s',reason)
    Q.clearStoppedApproach(driver); driver:setMaxSpeed(0)
    if ordinary then
        -- A failed candidate does not make this worker unusable. Release its
        -- reservation so another rig can serve, with a bounded recall delay.
        if driver.pathfinderController then driver.pathfinderController.pathfinder=nil end
        local data=Q.data(driver)
        data.approachRetryAt=g_currentMission.time+30000
        data.waitingApproach=nil; data.deferredApproach=nil
        driver:startWaitingForSomethingToDo()
    else driver.vehicle:stopCurrentAIJob(AIMessageCpErrorNoPathFound.new()) end
end

function Q.stoppedApproachGoal(driver,x,z)
    -- Existing final-unload reverse recovery already owns its checked lane.
    local overshoot=Q.hasStoppedRendezvousOvershoot(driver)
    if driver.queueFinalUnload or (not overshoot and not Q.checkedRearEntryTarget(driver)) then return x,z end
    local data=driver.queueStoppedApproach
    if data and data.combine==driver.combineToUnload then return data.x,data.farZ end
    Q.clearStoppedApproach(driver)
    local model,reason=W.model(driver.vehicle)
    if not model then
        if overshoot then
            stoppedApproachFailed(driver,reason or 'whole-rig geometry unavailable'); return x,z,false
        end
        return x,z -- preserve the existing final-only fallback
    end
    local length=0
    for _,link in ipairs(model.links) do length=length+math.abs(link.length) end
    local rearZ=math.min(z or 0,-driver:getCombinesMeasuredBackDistance()-5)
    local runIn=math.max(12,3*length)
    local turnRoom=overshoot and 2*driver.turningRadius or 0
    data={combine=driver.combineToUnload,phase='pathfinding',x=x or 0,rearZ=rearZ,
        farZ=rearZ-runIn-turnRoom,overshoot=overshoot,runIn=runIn,
        started=g_currentMission.time,controller=driver.pathfinderController}
    driver.queueStoppedApproach=data
    driver:debug('Queue: %s rear entry %.1f, %.1f; %.1f m whole-rig run-in',
        overshoot and 'overshot rendezvous' or 'final-combine',data.x,data.farZ,runIn)
    return data.x,data.farZ
end

-- A stranded ordinary rendezvous must leave on the pipe side, travel back
-- outside the header, and only then turn into its straight rear run-in.
function Q.beginStoppedEscape(driver)
    local data=driver.queueStoppedApproach
    if not data or not data.overshoot then return false end
    data.escapeAttempt=(data.escapeAttempt or 0)+1
    data.outward=true; data.phase='checking'
    local world,reason=W.new(driver)
    if not world then stoppedApproachFailed(driver,reason); return true end
    data.world=world
    local reference=driver:getPipeOffsetReferenceNode()
    local frame=W.pose(reference)
    local function localPoint(p)
        local dx,dz=p.x-frame.x,p.z-frame.z
        return dx*math.cos(frame.t)-dz*math.sin(frame.t),dx*math.sin(frame.t)+dz*math.cos(frame.t)
    end
    local side=data.x>=0 and 1 or -1
    local bodies=W.currentBodies(data.combine)
    if not bodies then stoppedApproachFailed(driver,'combine/header geometry unavailable'); return true end
    local headerSide,back=-math.huge,math.huge
    local obstacles={}
    for _,item in ipairs(bodies) do
        local rectangle=W.rectangle(item.body,item.pose,1)
        obstacles[#obstacles+1]=rectangle
        for _,p in ipairs(rectangle) do
            local x,z=localPoint(p)
            headerSide=math.max(headerSide,side*x); back=math.min(back,z)
        end
    end
    local nearest=math.huge
    for i,body in ipairs(world.model.bodies) do
        for _,p in ipairs(W.rectangle(body,world.startPoses[i])) do
            local x=localPoint(p); nearest=math.min(nearest,side*x)
        end
    end
    local guard=math.min(nearest,headerSide+1)
    data.corridor=function(rectangle)
        local minSide,maxZ=math.huge,-math.huge
        for _,p in ipairs(rectangle) do
            local x,z=localPoint(p); minSide=math.min(minSide,side*x); maxZ=math.max(maxZ,z)
        end
        if maxZ>back-2 and minSide<guard-0.05 then return false end
        for _,obstacle in ipairs(obstacles) do
            if G.overlap(rectangle,obstacle) then return false end
        end
        return true
    end
    local here=world.startPoses[1]
    local x,z=localPoint(here)
    local radius=H.minimumRadius(world.model,driver.turningRadius)
    if not radius then stoppedApproachFailed(driver,'unsupported outward turning radius'); return true end
    local extra=(data.escapeAttempt-1)*radius
    local out=side*(math.max(side*x,headerSide)+2*radius+4+extra)
    local rear=data.rearZ-data.runIn-extra
    local function pose(x,z,t)
        local wx,wz=H.math.position(frame,x,z)
        return {x=wx,z=wz,t=frame.t+t}
    end
    local goals={pose(out,z,math.pi),pose(out,rear-2*radius-data.runIn,math.pi),
        pose(data.x,rear,0),pose(data.x,data.rearZ,0)}
    data.goal=goals[#goals]
    data.search,reason=CpUnloaderQueueSearch.via(world,goals,data.corridor)
    if not data.search then stoppedApproachFailed(driver,reason); return true end
    data.phase='checking'; data.work=0; data.outward=true
    driver:setNewState(driver.states.WAITING_FOR_PATHFINDER); driver:setMaxSpeed(0)
    driver:debug('Queue: checking outward escape, behind combine, then straight rear run-in')
    return true
end

function Q.stoppedApproachPath(driver,success,course)
    local data=driver.queueStoppedApproach
    if not data then return end
    if not success or data.combine~=driver.combineToUnload or driver.state~=driver.states.WAITING_FOR_PATHFINDER then
        Q.clearStoppedApproach(driver); return
    end
    data.course=course; data.phase='approaching'
    data.progress=W.pose(driver.vehicle:getAIDirectionNode()); data.progressTime=g_currentMission.time
end

function Q.stoppedAdmission(driver)
    if not Q.checkedRearEntryTarget(driver) then return end
    local data=driver.queueStoppedApproach
    if data and data.combine==driver.combineToUnload and data.phase~='ready' then return false end
    return Q.pipeEntryAligned(driver)
end

local function beginStoppedRunIn(driver,data)
    local world,reason=W.new(driver)
    if not world then stoppedApproachFailed(driver,reason); return true end
    data.world=world
    local reference=driver:getPipeOffsetReferenceNode()
    local x,_,z=localToWorld(reference,data.x,0,data.rearZ)
    data.goal={x=x,z=z,t=H.math.heading(reference)}
    data.search,reason=CpUnloaderQueueSearch.new(world,data.goal)
    if not data.search then stoppedApproachFailed(driver,reason); return true end
    if data.overshoot then
        data.search.directOnly=true
        if not forwardRunIn(data.search,data.goal.t,data.runIn) then
            stoppedApproachFailed(driver,'no forward rear run-in without circling'); return true
        end
    end
    data.phase='checking'; data.work=0
    return true
end

-- Brake before capturing a whole-rig search origin. The endpoint callback can
-- run while the tractor is still rolling and the trailer is straightening.
local function settleStoppedRunIn(driver,data)
    driver:setMaxSpeed(0)
    if g_currentMission.time>data.settleDeadline then
        stoppedApproachFailed(driver,'rig did not settle before rear run-in'); return
    end
    local model,reason=W.model(driver.vehicle)
    if not model then stoppedApproachFailed(driver,reason); return end
    local poses=W.poses(model)
    local stable=data.settlePoses and #poses==#data.settlePoses
        and (driver.vehicle.lastSpeedReal or 0)*3600<0.1
    for i,p in ipairs(poses) do
        local before=data.settlePoses and data.settlePoses[i]
        if not before or distance(p,before)>0.05 or math.abs(H.math.delta(p.t,before.t))>math.rad(0.5) then stable=false end
    end
    if not stable then
        data.settlePoses=poses; data.settleSince=g_currentMission.time; return
    end
    if g_currentMission.time-data.settleSince<500 then return end
    data.settlePoses=nil; data.settleSince=nil
    beginStoppedRunIn(driver,data)
end

function Q.stoppedApproachLast(driver)
    local data=driver.queueStoppedApproach
    if not data or driver.course~=data.course or driver.state~=driver.states.DRIVING_TO_COMBINE then return false end
    if data.combine~=driver.combineToUnload then Q.clearStoppedApproach(driver); return false end
    if not Q.checkedRearEntryTarget(driver) then
        -- The native endpoint can arrive before update. Hand back with the
        -- same departure intent and native mode selection as the update path.
        Q.updateStoppedApproach(driver); return true
    end
    driver:setMaxSpeed(0)
    if data.phase=='driving' then
        if not Q.arrived(driver,data.goal) or not Q.pipeEntryAligned(driver) then
            stoppedApproachFailed(driver,'whole rig did not reach the checked pipe entry'); return true
        end
        data.phase='ready'
        if driver:isOkToStartUnloadingCombine() then
            Q.clearStoppedApproach(driver); driver:startUnloadingCombine()
        else stoppedApproachFailed(driver,'combine no longer ready at pipe entry') end
        return true
    end
    if data.phase~='approaching' then return true end
    data.phase='settling'; data.settleDeadline=g_currentMission.time+10000
    return true
end

function Q.updateStoppedApproach(driver)
    local data=driver.queueStoppedApproach
    if not data then return end
    local state=driver.state
    local nativeBackup=data.phase=='pathfinding' and Q.isRecoveryBackup(driver,data)
    if data.combine==driver.combineToUnload and not data.combine:getIsCpActive() then
        if nativeBackup and data.combine.queueFinishedEmptyCombine then
            data.departing=data.departing or finalDeparting(driver)
        else Q.releaseLostRecoveryTarget(driver,data) end
        return
    end
    if data.combine~=driver.combineToUnload or (state~=driver.states.WAITING_FOR_PATHFINDER
            and state~=driver.states.DRIVING_TO_COMBINE and not nativeBackup) then Q.clearStoppedApproach(driver); return end
    data.departing=data.departing or finalDeparting(driver)
    if nativeBackup then
        -- Do not interrupt an accepted native reverse when the target resumes.
        -- Its callback retains the intent until the next update/endpoint.
        return
    end
    if data.departing and not finalDeparting(driver) then driver:requestDriveUnloadNow() end
    if finalDeparting(driver) or not Q.checkedRearEntryTarget(driver) then
        if state==driver.states.WAITING_FOR_PATHFINDER and driver.pathfinderController then
            driver.pathfinderController.pathfinder=nil
        end
        if driver.queueData then driver.queueData.waitingApproach=nil; driver.queueData.deferredApproach=nil end
        Q.clearStoppedApproach(driver); driver:setMaxSpeed(0)
        if finalDeparting(driver) then driver:changeToUnloadWhenTrailerFull()
        elseif state==driver.states.DRIVING_TO_COMBINE and Q.pipeEntryAligned(driver)
                and driver:isOkToStartUnloadingCombine() then
            driver:startUnloadingCombine()
        else driver:startWaitingForSomethingToDo() end
        return
    end
    -- Native search and its matching backup retain their own lifecycle. Once
    -- travelling, measure lack of movement rather than total rendezvous time.
    if data.phase=='approaching' then
        local here=W.pose(driver.vehicle:getAIDirectionNode())
        if distance(here,data.progress)>0.5 then
            data.progress=here; data.progressTime=g_currentMission.time
        end
        if g_currentMission.time-data.progressTime>90000 then
            stoppedApproachFailed(driver,'rear entry made no progress'); return
        end
    end
    if data.phase=='settling' then settleStoppedRunIn(driver,data); return end
    if data.phase=='checking' then
        driver:setMaxSpeed(0)
        local timer=openIntervalTimer()
        local done,path,reason
        repeat done,path,reason=CpUnloaderQueueSearch.step(data.search,1)
        until done or readIntervalTimerMs(timer)>=2
        data.work=data.work+readIntervalTimerMs(timer); closeIntervalTimer(timer)
        if not done and data.work<(data.outward and 10000 or 1000) then return end
        if not path then stoppedApproachFailed(driver,reason or 'run-in search budget exhausted'); return end
        local live=W.poses(data.world.model)
        for i,p in ipairs(live) do
            local initial=data.world.startPoses[i]
            if distance(p,initial)>0.25 or math.abs(H.math.delta(p.t,initial.t))>math.rad(2) then
                if not data.outward and (data.settleRetries or 0)<2 then
                    data.settleRetries=(data.settleRetries or 0)+1
                    W.delete(data.world); data.world=nil; data.search=nil
                    data.phase='settling'; data.settleDeadline=g_currentMission.time+10000
                    driver:debug('Queue: rear run-in origin moved; braking and checking again')
                else stoppedApproachFailed(driver,'rig moved while its outward/run-in route was being checked') end
                return
            end
        end
        local points={}
        -- Retain every checked point: thinning a curve introduces unchecked chords.
        for _,p in ipairs(path) do points[#points+1]={x=p.x,z=p.z} end
        data.path=path; data.search=nil; data.phase='driving'
        data.course=Course(driver.vehicle,points,true)
        data.progress=W.pose(driver.vehicle:getAIDirectionNode()); data.progressTime=g_currentMission.time
        driver:setNewState(driver.states.DRIVING_TO_COMBINE)
        driver.ppc:setShortLookaheadDistance(); driver:startCourse(data.course,1)
    elseif data.phase=='driving' then
        local here=W.pose(driver.vehicle:getAIDirectionNode())
        if distance(here,data.progress)>0.5 then data.progress=here; data.progressTime=g_currentMission.time end
        if g_currentMission.time-data.progressTime>12000 then stoppedApproachFailed(driver,'checked run-in made no progress'); return end
        -- Reuse the live whole-train and seven-metre stopping horizon. Native
        -- proximity remains enabled between these bounded periodic checks.
        if not data.liveChecked or g_currentMission.time-data.liveChecked>=200 then
            data.liveChecked=g_currentMission.time
            local model,reason=W.model(driver.vehicle)
            if not model then stoppedApproachFailed(driver,reason); return end
            data.world.model=model
            local poses=W.poses(model)
            data.clear=W.clear(data.world,poses,data.corridor)
            if data.clear then data.clear=Q.routeClear(data,poses,driver.ppc:getRelevantWaypointIx()) end
        end
    end
end

function Q.stoppedApproachSpeed(driver,speed)
    local data=driver.queueStoppedApproach
    if not data or not Q.checkedRearEntryTarget(driver) then return speed end
    if data.phase=='checking' or data.phase=='settling' then return 0 end
    if data.phase=='driving' then return data.clear and math.min(speed,5) or 0 end
    return speed
end

-- Watch actual movement/transfer at a stationary grain rendezvous. Ordinary
-- catches recover only when misaligned; moving and productive unloads stay native.
function Q.watchStoppedMovingUnload(driver)
    local c=Q.finalApproachTarget(driver)
    local ordinary=not c and Q.ordinaryStoppedTarget(driver)
    c=c or ordinary
    if not c or (ordinary and Q.pipeEntryAligned(driver)) or finalDeparting(driver)
            or not c.combineController then driver.queueStoppedWatch=nil; return false end
    local fill=c.combineController:getFillLevel()
    if fill<0.01 then driver.queueStoppedWatch=nil; return false end
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    local data=driver.queueStoppedWatch
    if not data or data.combine~=driver.combineToUnload then
        data={combine=driver.combineToUnload,pose=here,fill=fill,time=g_currentMission.time,attempts=0}
        driver.queueStoppedWatch=data
    end
    if distance(here,data.pose)>0.5 or data.fill-fill>1 then
        data.pose=here; data.fill=fill; data.time=g_currentMission.time
    end
    if g_currentMission.time-data.time<12000 then return false end
    if data.attempts>=2 then stoppedApproachFailed(driver,'two stopped rendezvous retries made no progress'); return true end
    data.attempts=data.attempts+1; data.time=g_currentMission.time
    local x,z=driver:getPipeOffset(driver.combineToUnload)
    if ordinary then driver.queueStoppedRecovery=driver.combineToUnload end
    driver:setMaxSpeed(0); driver:setNewState(driver.states.WAITING_FOR_PATHFINDER)
    driver:debug('Queue: stopped rendezvous made no transfer or movement; replan rear entry %d/2',data.attempts)
    driver:startPathfindingToWaitingCombine(x,z)
    return true
end
