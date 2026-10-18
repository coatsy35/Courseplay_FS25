-- Queue ownership ends at a native CP call. This module does not drive a pipe
-- approach, change combine readiness or instruct AutoDrive to do anything.
CpUnloaderQueue = {members={}, nextPlan=0, nextDeparture=0}
local Q = CpUnloaderQueue
local W = CpUnloaderQueueWorld
local G = CpUnloaderQueueGeometry
local P = CpUnloaderQueuePolicy
local H = HeadlandLoopGeometry
local S = CpUnloaderQueueSearch

local function now() return g_currentMission.time end
local function distance(a,b) return math.sqrt((a.x-b.x)^2+(a.z-b.z)^2) end
local function id(vehicle) return tostring(vehicle.rootNode) end
local function point(course,ix)
    local x,_,z=course:getWaypointPosition(ix)
    return {x=x,z=z,t=course:getWaypointYRotation(ix)}
end

function Q.enabled(driver)
    -- The native combine-unloading strategy is the entry point: no separate opt-in.
    return not driver.augerWagon and not driver.fieldUnloadPositionNode and not driver.useGiantsUnload
end

function Q.atDepartureThreshold(driver)
    local setting=driver.settings and driver.settings.fullThreshold
    return setting and driver:getAllTrailersFull(setting:getValue()) or false
end

function Q.data(driver)
    if not driver.queueData then
        driver.queueData={generation=0,driver=driver,nextAttempt=0}
        Q.members[driver]=driver.queueData
    end
    return driver.queueData
end

function Q.reason(data,reason)
    if data.reason~=reason or (data.operation=='yield' and now()-(data.reasonTime or 0)>=30000) then
        data.reason=reason
        data.reasonTime=now()
        data.driver:debug('Queue: %s',reason)
    end
end

function Q.cancel(driver)
    local data=driver.queueData
    if not data then return end
    data.generation=data.generation+1
    data.search=nil; data.path=nil; data.course=nil; data.goal=nil
    data.parkedGoal=nil
    Q.clearHarvesterBypass(driver)
    data.liveChecked=nil; data.liveClear=nil
    W.delete(data.world); data.world=nil
end

local function goalKey(p) return math.floor(p.x/4)..':'..math.floor(p.z/4) end

-- Capture each job's physical arrival once. The configured native return
-- marker may belong to an earlier AD destination and must remain unchanged.
function Q.captureArrival(driver)
    local origin=W.pose(driver.vehicle:getAIDirectionNode())
    local data=Q.data(driver)
    data.arrivalOrigin=origin; data.arrivalDeparted=nil; data.arrivalExitRetry=nil
    driver:debug('Queue: captured arrival position %.1f, %.1f',origin.x,origin.z)
end

local function arrivalOrigin(driver)
    return driver.queueData and driver.queueData.arrivalOrigin
        or (driver.invertedStartPositionMarkerNode and W.pose(driver.invertedStartPositionMarkerNode))
end

function Q.targetAvailable(driver,p)
    local data=driver.queueData
    if data and data.failedGoals and (data.failedGoals[goalKey(p)] or 0)>now() then return false end
    for other,member in pairs(Q.members) do
        local reserved=member.goal or member.parkedGoal
        if other~=driver and reserved and distance(p,reserved)<
                math.max(AIUtil.getLength(driver.vehicle),AIUtil.getLength(other.vehicle))+8 then return false end
    end
    return true
end

function Q.failed(data,reason,phase)
    if data.operation=='yield' then data.yieldFailed=true end
    if data.goal and phase~='start' and phase~='world' then
        data.failedGoals=data.failedGoals or {}
        for key,expiry in pairs(data.failedGoals) do if expiry<=now() then data.failedGoals[key]=nil end end
        data.failedGoals[goalKey(data.goal)]=now()+15000
        if data.goal.arrival then
            for _,goal in ipairs(data.goal.choices or {}) do data.failedGoals[goalKey(goal)]=now()+15000 end
        end
    end
    if data.goal and data.goal.transit then data.arrivalExitRetry=now()+15000 end
    Q.reason(data,reason)
    data.nextAttempt=now()+3000
end

function Q.remove(driver)
    Q.clearTrailerTraffic(driver)
    Q.cancel(driver); Q.members[driver]=nil; driver.queueData=nil
    if next(Q.members)==nil then
        Q.nextPlan=0; Q.plan=nil; Q.combines=nil; Q.nextDeparture=0; Q.schedulerTime=nil
    end
end

function Q.owns(driver)
    return driver.queueData and driver.state==driver.queueData.state
end

function Q.take(driver,operation)
    assert(operation=='prepare' or operation=='yield', 'Queue cannot own native departure')
    local data=Q.data(driver)
    Q.cancel(driver)
    data.operation=operation
    data.yieldProgress=nil; data.yieldProgressTime=now(); data.yieldFailed=nil
    -- Like native MOVING_AWAY_FROM_OTHER_VEHICLE, yielding must not wait on
    -- the future path conflict it is clearing. Live proximity and full-train
    -- route/obstacle validation remain active.
    data.state={name='QUEUE_'..string.upper(operation),properties={collisionAvoidanceEnabled=operation~='yield'}}
    driver.state=data.state
    driver:setMaxSpeed(0)
    return data
end

function Q.release(driver)
    Q.clearTrailerTraffic(driver)
    Q.cancel(driver)
    local data=driver.queueData
    if data then data.operation=nil; data.stage=nil; data.departureClearance=nil end
    driver.state=driver.states.IDLE
end

-- Estimate preparation at the speed the queue actually permits, including
-- measured search latency and time to straighten the whole train.
function Q.preparationEta(driver,combine)
    local metres,eta=driver:getDistanceAndEteToVehicle(combine.vehicle)
    local speed=math.max(0.5,math.min(15,driver:getFieldSpeed())/3.6)
    local data=driver.queueData
    local length=AIUtil.getLength(driver.vehicle)
    return math.max(eta or 0,(metres or 0)/speed+3)+math.max(12,3*length/speed)
        +math.min(30,data and data.searchLatency or 0)
end

-- Ordinary approaches defer only for outgoing traffic. The checked final rear
-- entry also recognises parked vehicle footprints, so one blocked goal cannot
-- stop each replacement job in turn. Crop and non-vehicle failures stay native.
function Q.waitingGoalOccupied(driver,x,z,finalEntry)
    if not Q.enabled(driver) or not driver.combineToUnload then return false end
    local departing={}
    for other,data in pairs(Q.members) do
        local states=other.states
        local backing=(states.MOVING_BACK_WITH_TRAILER_FULL and other.state==states.MOVING_BACK_WITH_TRAILER_FULL)
            or (states.MOVING_BACK and other.state==states.MOVING_BACK)
        if other~=driver and other.vehicle:getIsCpActive() and (data.nativeDeparture or backing) then
            departing[#departing+1]=other.vehicle
        end
    end
    if finalEntry then
        departing={}
        local seen={}
        for _,vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
            local root=vehicle.getRootVehicle and vehicle:getRootVehicle() or vehicle
            if root~=driver.vehicle and root~=driver.combineToUnload and not seen[root] then
                seen[root]=true; departing[#departing+1]=root
            end
        end
    end
    if #departing==0 then return false end
    local model=W.model(driver.vehicle)
    if not model then return false end
    local node=driver:getPipeOffsetReferenceNode()
    local px,_,pz=localToWorld(node,x or 0,0,z or 0)
    local poses=W.settledPoses(model,{x=px,z=pz,t=W.pose(node).t})
    for _,vehicle in ipairs(departing) do
        for _,item in ipairs(W.currentBodies(vehicle) or {}) do
            local obstacle=W.rectangle(item.body,item.pose,1)
            for i,body in ipairs(model.bodies) do
                if G.overlap(obstacle,W.rectangle(body,poses[i],1)) then return vehicle end
            end
        end
    end
    return false
end

function Q.deferWaitingApproach(driver,x,z)
    local occupied=Q.waitingGoalOccupied(driver,x,z)
    local goalX,goalZ=x,z
    local final=Q.finalApproachTarget(driver)~=nil
    local entry=driver.queueStoppedApproach
    local rear=not occupied and final and entry and entry.combine==driver.combineToUnload
    if rear then
        goalX,goalZ=entry.x,entry.farZ
        occupied=Q.waitingGoalOccupied(driver,goalX,goalZ,true)
    end
    if not occupied then return false end
    local data=Q.data(driver)
    local pending=data.deferredApproach
    if not pending or pending.combine~=driver.combineToUnload then
        pending={combine=driver.combineToUnload,started=now(),pose=W.pose(driver:getPipeOffsetReferenceNode())}
        data.deferredApproach=pending
        driver:debug('Queue: unloading goal occupied by a vehicle; retaining native assignment')
    end
    pending.x=x; pending.z=z; pending.retryAt=now()+1000
    pending.goalX=goalX; pending.goalZ=goalZ; pending.final=final; pending.rear=rear
    driver:setMaxSpeed(0)
    return true
end

function Q.resumeWaitingApproach(driver)
    local data=driver.queueData
    local pending=data and data.deferredApproach
    if not pending then return end
    if driver.combineToUnload~=pending.combine or driver.state~=driver.states.WAITING_FOR_PATHFINDER then
        data.deferredApproach=nil; data.waitingApproach=nil
        return
    end
    if not pending.combine:getIsCpActive() or Q.atDepartureThreshold(driver) or driver:isDriveUnloadNowRequested() then
        data.deferredApproach=nil; data.waitingApproach=nil
        driver:startWaitingForSomethingToDo()
        return -- the ordinary idle/full path retains departure ownership
    end
    local combine=pending.combine:getCpDriveStrategy()
    local pose=W.pose(driver:getPipeOffsetReferenceNode())
    if not combine or distance(pose,pending.pose)>3 or math.abs(H.math.delta(pose.t,pending.pose.t))>math.rad(10)
            or (combine.isWaitingForUnload and not combine:isWaitingForUnload()
                and not (combine.alwaysNeedsUnloader and combine:alwaysNeedsUnloader())) then
        data.deferredApproach=nil; data.waitingApproach=nil
        driver:startWaitingForSomethingToDo()
        return -- a fresh native call must calculate the new approach/offsets
    end
    driver:setMaxSpeed(0)
    if now()<pending.retryAt then return end
    if now()-pending.started>=(pending.final and 120000 or 60000) then
        data.deferredApproach=nil; data.waitingApproach=nil; data.approachRetryAt=now()+10000
        if pending.final then
            Q.clearStoppedApproach(driver)
            driver:debug('Queue: final goal remains occupied; keeping job available after retry delay')
        end
        driver:startWaitingForSomethingToDo()
        return
    end
    if Q.waitingGoalOccupied(driver,pending.goalX,pending.goalZ,pending.rear) then pending.retryAt=now()+1000; return end
    data.deferredApproach=nil
    driver:debug('Queue: vehicle cleared unloading goal; resuming native approach')
    driver:startPathfindingToWaitingCombine(pending.x,pending.z)
end

function Q.coursePosition(combine, preparing)
    local course=combine.fieldWorkCourse
    if not course then return end
    local ix
    if combine.course==course then ix=combine:getClosestFieldworkWaypointIx()
    else
        -- A connector can take the harvester far from its last working waypoint.
        -- Prepare near CP's chosen next row, without changing its route or the
        -- actual fieldwork position used by native CP.
        local entry=combine.turnContext and combine.turnContext.turnEndWpIx
        if preparing and combine.states and combine.states.DRIVING_TO_WORK_START_WAYPOINT
                and combine.state==combine.states.DRIVING_TO_WORK_START_WAYPOINT
                and type(entry)=='number' and entry%1==0 and entry>=1 and entry<=course:getNumberOfWaypoints() then
            ix=entry
        else ix=course:getLastPassedWaypointIx() or course:getCurrentWaypointIx() end
    end
    if not ix then return end
    ix=math.max(1,math.min(course:getNumberOfWaypoints(),ix))
    return course,ix
end

local function capacity(driver,fillType)
    local total,fill,free,seen=0,0,0,{}
    for _, target in pairs(driver.trailerNodes or {}) do
        local object,ix=target.trailer,target.fillUnitIx
        seen[object]=seen[object] or {}
        if not seen[object][ix] then
            seen[object][ix]=true
            if fillType==nil or (fillType~=FillType.UNKNOWN and object:getFillUnitAllowsFillType(ix,fillType)) then
                total=total+object:getFillUnitCapacity(ix)
                fill=fill+object:getFillUnitFillLevel(ix)
                free=free+object:getFillUnitFreeCapacity(ix)
            end
        end
    end
    return total,fill,free
end

-- Empty forage harvesters may not know their output yet. Preparation can use
-- their actual discharge unit's supported types, but native dispatch stays in
-- charge until the output is known. Never assume forage always means chaff.
function Q.compatibleCapacity(driver,harvester)
    if harvester.fillType and harvester.fillType~=FillType.UNKNOWN then
        return capacity(driver,harvester.fillType)
    end
    if harvester.continuous then
        local source=harvester.driver.pipeController and harvester.driver.pipeController.implement
        local node=source and harvester.driver:getCurrentDischargeNode()
        local types=node and source:getFillUnitSupportedFillTypes(node.fillUnitIndex)
        local best,loaded,free=0,0,0
        for fillType,supported in pairs(types or {}) do
            if supported and fillType~=FillType.UNKNOWN then
                local c,f,a=capacity(driver,fillType)
                if c>best or (c==best and a>free) then best,loaded,free=c,f,a end
            end
        end
        return best,loaded,free
    end
    return 0,0,0
end

function Q.refresh()
    if now()<Q.nextPlan then return end
    Q.nextPlan=now()+1000
    local combines,trailers,byId={}, {}, {}
    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if AIDriveStrategyCombineCourse.isActiveCpCombine(vehicle) then
            local driver=vehicle:getCpDriveStrategy()
            if driver.combineController and not driver.queueFinishClearance then
                local continuous=driver:alwaysNeedsUnloader()
                local total=continuous and 0 or driver.combineController:getCapacity()
                if continuous or total>0 then
                    local owner=driver.unloader:get()
                    local c={id=id(vehicle),driver=driver,vehicle=vehicle,capacity=total,continuous=continuous,
                        fillType=driver:getFillType(),
                        fill=continuous and 0 or driver.combineController:getFillLevel(),rate=math.max(0,driver.litersPerSecond or 0),
                        callPercent=driver.settings.callUnloaderPercent:getValue(),waiting=driver:isWaitingForUnload(),
                        owner=owner and owner.vehicle and id(owner.vehicle),position=W.pose(vehicle:getAIDirectionNode()),
                        sampleTime=now()}
                    combines[#combines+1]=c; byId[c.id]=c
                end
            end
        end
    end
    for driver,data in pairs(Q.members) do
        if Q.enabled(driver) and driver.vehicle:getIsCpActive() then
            local total,fill,free=capacity(driver)
            local elapsed=data.sampleTime and (now()-data.sampleTime)/1000 or 0
            local transfer=elapsed>0 and math.max(0,(fill-(data.lastFill or fill))/elapsed) or 0
            local owner=driver.combineToUnload and id(driver.combineToUnload)
            local stableOwner=owner~=nil and data.lastOwner==owner and elapsed>0 and elapsed<=3
            data.sampleTime=now(); data.lastFill=fill
            data.lastOwner=owner
            local t={id=id(driver.vehicle),driver=driver,capacity=total,fill=fill,freeCapacity=free,enabled=true,
                departPercent=driver.settings.fullThreshold:getValue(),compatible={},
                available=not data.nativeDeparture and not Q.atDepartureThreshold(driver) and
                    (driver.state==driver.states.IDLE or (Q.owns(driver) and data.operation=='prepare')),
                owner=owner,transferring=stableOwner and transfer>0,
                transferRate=transfer,reservedFor=data.assignment and data.assignment.combine,
                position=W.pose(driver.vehicle:getAIDirectionNode())}
            for _, c in ipairs(combines) do
                local compatible,loaded,available=Q.compatibleCapacity(driver,c)
                t.compatible[c.id]=available>0 and driver:isServingPosition(c.position.x,c.position.z,10)
                -- Mixed-capacity trains must not reserve more than the compatible units can hold.
                if compatible~=total then t.compatible[c.id]=false end
            end
            -- A native accepted call owns the trailer immediately, before the
            -- harvester's next registration update. Do not prepare a duplicate.
            if owner and byId[owner] and not byId[owner].owner then byId[owner].owner=t.id end
            trailers[#trailers+1]=t
        end
    end
    Q.accountForTransfer(combines,trailers,Q.combines or {})
    Q.plan=P.plan(combines,trailers,function(t,c)
        if not t.compatible[c.id] then return math.huge end
        return Q.preparationEta(t.driver,c)
    end)
    Q.combines=byId
    for _, t in ipairs(trailers) do Q.members[t.driver].assignment=Q.plan.trailers[t.id] end
end

function Q.accountForTransfer(combines,trailers,previous)
    local unloaders={}
    for _,trailer in ipairs(trailers) do unloaders[trailer.id]=trailer end
    for _,combine in ipairs(combines) do
        local trailer=unloaders[combine.owner]
        local before=previous[combine.id]
        if trailer and trailer.transferring and not combine.continuous then
            local elapsed=before and (combine.sampleTime-before.sampleTime)/1000 or 0
            if before and before.owner==combine.owner and elapsed>0 and elapsed<=3 then
                -- Native litres/second may reset when the tank falls. Conservation
                -- of grain recovers harvest intake during the measured transfer.
                combine.rate=math.max(combine.rate,(combine.fill-before.fill)/elapsed+trailer.transferRate,0)
            else
                -- An ownership change is not a measured finish-time estimate.
                trailer.transferring=false
            end
        end
    end
end

function Q.findUnloader(combine,stopped,waypoint)
    Q.refresh()
    local snapshot=Q.combines and Q.combines[id(combine.vehicle)]
    if snapshot and snapshot.continuous and (not snapshot.fillType or snapshot.fillType==FillType.UNKNOWN) then
        return false -- native output discovery/call rules remain authoritative
    end
    local lead=Q.plan and Q.plan.leads[id(combine.vehicle)]
    if not lead then return false end
    for driver,data in pairs(Q.members) do
        if id(driver.vehicle)==lead.trailer and Q.enabled(driver) then
            if lead.future then return true,nil,nil end
            if driver:isAllowedToBeCalled() then
                local _,eta
                if stopped then _,eta=driver:getDistanceAndEteToVehicle(stopped)
                else _,eta=driver:getDistanceAndEteToWaypoint(waypoint) end
                return true,driver.vehicle,eta
            end
        end
    end
    return false
end

function Q.stagingClear(driver,poses,model,arrivalRadius)
    Q.pruneTurnReservations()
    local origin=arrivalOrigin(driver)
    local marker=driver.invertedStartPositionMarkerNode
    local returnOrigin=marker and W.pose(marker)
    for i,body in ipairs(model.bodies) do
        local rectangle=W.rectangle(body,poses[i],1)
        for index,markerOrigin in ipairs({origin or false,returnOrigin or false}) do
            if markerOrigin then
                -- Closest point on the complete oriented body, including edges
                -- and containment; checking corners alone misses circle crossings.
                local pose=poses[i]
                local dx,dz=markerOrigin.x-pose.x,markerOrigin.z-pose.z
                local x=dx*math.cos(pose.t)-dz*math.sin(pose.t)
                local z=dx*math.sin(pose.t)+dz*math.cos(pose.t)
                local nearestX=math.max(body.right-1,math.min(body.left+1,x))
                local nearestZ=math.max(body.back-1,math.min(body.front+1,z))
                local sameArrival=index==1 or (origin and distance(origin,markerOrigin)<1)
                local radius=sameArrival and arrivalRadius or 2*driver.turningRadius+4
                if math.sqrt((x-nearestX)^2+(z-nearestZ)^2)<radius then return false end
            end
        end
        for _,reservation in pairs(Q.turnTraffic or {}) do
            if reservation.area(rectangle) then return false end
        end
    end
    return true
end

function Q.stagingCandidate(driver,course,ix,opposite,context)
    local p=point(course,ix)
    local length=AIUtil.getLength(driver.vehicle)
    -- Reject bends/row ends within the parked train and manoeuvring space.
    local behind=opposite and driver.turningRadius+5 or length+4
    local ahead=opposite and length+4 or driver.turningRadius+5
    local first=course:getPreviousWaypointIxWithinDistance(ix,behind)
    local last=course:getNextWaypointIxWithinDistance(ix,ahead)
    if not first or not last or (context and context.completed and last>context.completed)
            or distance(point(course,first),p)<(opposite and driver.turningRadius or length)
            or distance(point(course,last),p)<(opposite and length or driver.turningRadius) then return end
    for i=first,last do
        if math.abs(H.math.delta(course:getWaypointYRotation(i),p.t))>math.rad(10)
                or (course.isTurnStartAtIx and course:isTurnStartAtIx(i))
                or (course.isOnConnectingPath and course:isOnConnectingPath(i)) then return end
    end
    if course:isOnHeadland(ix) then
        local boundary=context and context.boundary or FieldworkBoundary.forVehicle(driver.vehicle,0)
        if not boundary then return end
        local nearest,heading
        for i,a in ipairs(boundary.polygon) do
            local b=boundary.polygon[i%#boundary.polygon+1]
            local dx,dz=b.x-a.x,b.z-a.z
            local f=math.max(0,math.min(1,((p.x-a.x)*dx+(p.z-a.z)*dz)/math.max(.001,dx*dx+dz*dz)))
            local d=distance(p,{x=a.x+f*dx,z=a.z+f*dz})
            if not nearest or d<nearest then nearest=d; heading=math.atan2(dx,dz) end
        end
        if not heading or math.min(math.abs(H.math.delta(p.t,heading)),
                math.abs(H.math.delta(p.t,heading+math.pi)))>math.rad(10) then return end
    end
    if opposite then p.t=p.t+math.pi end
    local model=context and context.model or W.model(driver.vehicle)
    if not model then return end
    p.accept=function(poses,m) return Q.stagingClear(driver,poses,m) end
    if not p.accept(W.settledPoses(model,p),model) or not Q.targetAvailable(driver,p) then return end
    return p
end

function Q.target(driver)
    local data=Q.data(driver)
    -- Clear the arrival lane before investing in a distant assigned stage.
    -- A native unloading call may still take ownership immediately.
    if not data.arrivalDeparted and not Q.arrivalClear(driver) then
        return Q.arrivalExit(driver) or Q.poolTarget(driver,true)
    end
    local assignment=data.assignment
    if not assignment or assignment.future then return Q.poolTarget(driver) end
    if assignment.combine then
        local combine=Q.combines[assignment.combine]
        if not combine then return end
        local course,ix=Q.coursePosition(combine.driver,true)
        if not course then return end
        local eta=Q.preparationEta(driver,combine)
        local deadline=assignment.successor and assignment.deadline or P.deadline(combine)
        local stage=deadline<=eta+15 and 3 or (deadline<=2*eta+30 and 2 or 1)
        local saved=data.stage
        if saved and saved.combine==assignment.combine and saved.course==course
                and saved.successor==assignment.successor then
            stage=math.max(stage,saved.phase) -- no oscillation as measured intake varies
            if stage==saved.phase and saved.goal and Q.targetAvailable(driver,saved.goal) then return saved.goal end
        end
        local gap=distance(W.pose(driver.vehicle:getAIDirectionNode()),combine.position)
        local lag=stage==3 and math.max(27,AIUtil.getLength(driver.vehicle)+8)
            or stage==2 and math.max(60,AIUtil.getLength(driver.vehicle)+20) or math.max(90,gap/2)
        if assignment.successor then lag=lag+AIUtil.getLength(driver.vehicle)+20 end
        -- A moving harvester advances while the rig travels and straightens.
        -- Target its predicted trigger position where already harvested ground
        -- permits it. Destination/route crop checks still reject unopened crop.
        if stage==3 and deadline>0 and deadline<90 then
            local travel=math.min(120,math.max(0,(combine.vehicle.lastSpeedReal or 0)*1000)*deadline)
            local future=course:getNextWaypointIxWithinDistance(ix,travel)
            if travel>0 and future and not course:isTurnBetween(ix,future) then ix=future end
        end
        for extra=0,100,10 do
            local targetIx=course:getPreviousWaypointIxWithinDistance(ix,lag+extra)
            if targetIx and targetIx>=1 then
                local p=Q.stagingCandidate(driver,course,targetIx)
                if p then
                    data.stage={combine=assignment.combine,course=course,successor=assignment.successor,phase=stage,goal=p}
                    return p
                end
            end
        end
    end
    -- Early work may not yet have enough course behind it for an assigned
    -- stage. A checked headland slot still clears AD and keeps the rig nearby.
    return Q.poolTarget(driver)
end

function Q.arrivalClear(driver)
    local origin=arrivalOrigin(driver)
    if not origin then return true end
    local bodies=W.currentBodies(driver.vehicle)
    if not bodies then return false end
    for _,item in ipairs(bodies) do
        local body,pose=item.body,item.pose
        local dx,dz=origin.x-pose.x,origin.z-pose.z
        local x=dx*math.cos(pose.t)-dz*math.sin(pose.t)
        local z=dx*math.sin(pose.t)+dz*math.cos(pose.t)
        local nx=math.max(body.right-1,math.min(body.left+1,x))
        local nz=math.max(body.back-1,math.min(body.front+1,z))
        if math.sqrt((x-nx)^2+(z-nz)^2)<2*driver.turningRadius+4 then return false end
    end
    return true
end

-- An entry is a transit point, not a parking space. Clear it with one checked
-- straight movement before selecting a combine/parallel waiting row. Never
-- retain this temporary endpoint as parkedGoal.
function Q.arrivalExit(driver)
    local data=Q.data(driver)
    if (data.arrivalExitRetry or 0)>now() then return end
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    local length=AIUtil.getLength(driver.vehicle)
    local travel=math.max(length+6,2*driver.turningRadius+8)
    local x,z=H.math.position(here,0,travel)
    local goal={x=x,z=z,t=here.t,arrival=true,transit=true,straight=true}
    if not Q.targetAvailable(driver,goal) then return end
    goal.accept=function(poses,model) return Q.stagingClear(driver,poses,model,4) end
    return goal
end

-- Waiting slots use either parallel direction, never the rig's arbitrary current
-- heading. Include completed centre rows: density checks decide what is harvested.
function Q.poolTarget(driver,arrival,clearance)
    local data=Q.data(driver)
    local parked=data.parkedGoal
    if not clearance and not arrival and parked and Q.targetAvailable(driver,parked)
            and Q.arrived(driver,parked) then return parked end
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    local origin=arrival and arrivalOrigin(driver) or here
    local candidates,visited={},{}
    local model=W.model(driver.vehicle)
    if not model then return end
    local function order(a,b)
        if a.score~=b.score then return a.score<b.score end
        if a.goal.x~=b.goal.x then return a.goal.x<b.goal.x end
        if a.goal.z~=b.goal.z then return a.goal.z<b.goal.z end
        return a.goal.t<b.goal.t
    end
    local boundary=FieldworkBoundary.forVehicle(driver.vehicle,0)
    local spacing=math.max(22,AIUtil.getLength(driver.vehicle)+8)
    for _,combine in pairs(Q.combines or {}) do
        local course=combine.driver.fieldWorkCourse
        local completed
        if course and combine.driver.getClosestFieldworkWaypointIx then
            local _,ix=Q.coursePosition(combine.driver)
            completed=ix
        end
        local context={model=model,boundary=boundary,completed=completed}
        if course and driver:isServingPosition(combine.position.x,combine.position.z,10) then
            local accumulated=0
            for i=2,completed or course:getNumberOfWaypoints() do
                local p=point(course,i)
                accumulated=accumulated+distance(p,point(course,i-1))
                if accumulated>=10 then
                    accumulated=0
                    local d=distance(p,origin)
                    local limit=arrival and math.max(100,2*driver.turningRadius+2*spacing) or 150
                    if d<=limit and (not arrival or d>2*driver.turningRadius+spacing) then
                        local key=string.format('%.1f:%.1f:%.2f',p.x,p.z,p.t)
                        if not visited[key] then
                            visited[key]=true
                            for _,opposite in ipairs({false,true}) do
                                local score=d+driver.turningRadius*math.abs(H.math.delta(here.t,p.t+(opposite and math.pi or 0)))
                                if #candidates<12 or score<=candidates[#candidates].score then
                                    local candidate=Q.stagingCandidate(driver,course,i,opposite,context)
                                    if candidate then
                                        local accept=candidate.accept
                                        candidate.accept=function(poses,model)
                                            if not accept(poses,model) then return false end
                                            if clearance then
                                                for j,body in ipairs(model.bodies) do
                                                    if clearance(W.rectangle(body,poses[j],2)) then return false end
                                                end
                                            end
                                            return true
                                        end
                                        if candidate.accept(W.settledPoses(model,candidate),model) then
                                            -- Travel/turning cost keeps easy parallel entries ahead of
                                            -- a closer slot that requires a hairpin at the boundary.
                                            candidates[#candidates+1]={goal=candidate,score=score}
                                            table.sort(candidates,order)
                                            if #candidates>12 then table.remove(candidates) end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local choices={}
    for i=1,math.min(12,#candidates) do choices[i]=candidates[i].goal end
    if #choices==0 then return end
    local best=choices[1]
    return {x=best.x,z=best.z,t=best.t,choices=choices,firstValid=true,arrival=arrival or nil,parking=true}
end

function Q.request(driver,goal,corridor)
    local data=Q.data(driver)
    Q.cancel(driver)
    data.goal=goal
    local world,reason=W.new(driver)
    if not world then Q.failed(data,reason,'world'); return end
    data.world=world
    local phase
    if goal.choices then
        data.search,reason,phase=S.choices(world,goal.choices,corridor)
        if data.search then
            data.search.firstValid=goal.firstValid
            data.search.escape=goal.escape
            data.search.arrival=goal.arrival or goal.parking
        end
    else data.search,reason,phase=S.new(world,goal,corridor) end
    data.searchGeneration=data.generation
    data.corridor=corridor
    if not data.search then Q.failed(data,reason,phase) end
    data.searchStarted=now()
    data.lastAdvance=nil
    data.searchAssignment=data.assignment and data.assignment.combine
    data.searchSuccessor=data.assignment and data.assignment.successor
    data.searchFuture=data.assignment and data.assignment.future
    data.searchStage=data.stage and data.stage.phase
    data.searchWorkMs=0
    driver:debug('Queue: %s target %.1f, %.1f, %.1f m away%s',data.operation,goal.x,goal.z,
        distance(W.pose(driver.vehicle:getAIDirectionNode()),goal),goal.arrival and ' (clear AD arrival)' or '')

end

function Q.startRoute(data,path)
    if not Q.owns(data.driver) or data.searchGeneration~=data.generation then return end
    local initial=data.world and data.world.startPoses
    if initial then
        local live=W.poses(data.world.model)
        live[1]=W.pose(data.driver.vehicle:getAIDirectionNode())
        for i,p in ipairs(live) do
            if distance(p,initial[i])>0.25 or math.abs(H.math.delta(p.t,initial[i].t))>math.rad(2) then
                Q.failed(data,'rig moved during parking search; replanning from current pose','start')
                Q.cancel(data.driver); return
            end
        end
    end
    data.path=path; data.search=nil
    data.searchLatency=math.max(0,(now()-(data.searchStarted or now()))/1000)
    data.goal=path.goal or data.goal
    data.progressPosition=W.pose(data.driver.vehicle:getAIDirectionNode())
    data.progressTime=now()
    local points,mapping={},{}
    local previous
    for i,p in ipairs(path) do
        if not previous or i==#path or distance(previous,p)>=1
                or math.abs(H.math.delta(previous.t,p.t))>=math.rad(5) then
            points[#points+1]={x=p.trackX or p.x,z=p.trackZ or p.z,rev=path.reverse or false}
            mapping[#points]=i; previous=p
        end
    end
    data.courseToPath=mapping
    data.course=Course(data.driver.vehicle,points,true)
    data.driver:startCourse(data.course,1)
    Q.reason(data,'driving '..data.operation)
end

function Q.schedule()
    if Q.frame==g_updateLoopIndex then return end
    Q.frame=g_updateLoopIndex
    -- Foreground native calls keep precedence, while background parking retains
    -- a small bounded slice instead of starving throughout repeated native work.
    local foreground=false
    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        local d=vehicle.getCpDriveStrategy and vehicle:getCpDriveStrategy()
        if d and d.pathfinderController and d.pathfinderController.pathfinder then foreground=true; break end
    end
    local selected
    local time=now()
    local function priority(data)
        if data.operation=='yield' then return 0 end
        local assignment=data.assignment
        local combine=assignment and Q.combines and Q.combines[assignment.combine]
        if combine and not assignment.future then
            local deadline=assignment.successor and assignment.deadline or P.deadline(combine)
            if deadline and deadline<=Q.preparationEta(data.driver,combine)+15 then return 1 end
        end
        return data.goal and data.goal.arrival and 2 or 3
    end
    local function before(a,b)
        local at=a.lastAdvance or a.searchStarted or time
        local bt=b.lastAdvance or b.searchStarted or time
        -- A priority request may borrow slices, never monopolise them. Every
        -- eligible rig gets service after 250 ms, oldest first across classes.
        local agedA,agedB=time-at>=250,time-bt>=250
        if agedA~=agedB then return agedA end
        if agedA and at~=bt then return at<bt end
        local ap,bp=priority(a),priority(b)
        if ap~=bp then return ap<bp end
        if at~=bt then return at<bt end
        return id(a.driver.vehicle)<id(b.driver.vehicle)
    end
    for _, data in pairs(Q.members) do
        if data.search and Q.owns(data.driver) and data.searchGeneration==data.generation
                and (not foreground or (data.goal and (data.goal.arrival or data.goal.parking))
                    or data.trailerTraffic or data.operation=='prepare')
                and (not selected or before(data,selected)) then selected=data end
    end
    if not selected then return end
    local arrival=selected.goal and (selected.goal.arrival or selected.goal.parking)
    selected.lastAdvance=now()
    local workPhase=S.choicePhase(selected.search)
    local timer=openIntervalTimer()
    local done,path,reason
    repeat done,path,reason=S.step(selected.search,1) until done or readIntervalTimerMs(timer)>=(foreground and 0.5 or 2)
    local elapsed=readIntervalTimerMs(timer); closeIntervalTimer(timer)
    -- Charge measured computation, not the duration of a game frame. A low
    -- frame rate or another worker must not reduce this search's work allowance.
    selected.searchWorkMs=(selected.searchWorkMs or 0)+elapsed
    if elapsed>=8 then selected.driver:debug('Queue search advance %.1f ms',elapsed) end
    if not done and now()-(selected.searchReport or selected.searchStarted or now())>=15000 then
        selected.searchReport=now()
        local search=selected.search
        local slot=search.slots and search.slots[search.index]
        selected.driver:debug('Queue: parking search pending %.1f s, CPU %.1f ms, candidate %s, nodes %d, last rejection %s, foreground %s',
            (now()-selected.searchStarted)/1000,selected.searchWorkMs,tostring(workPhase or search.index or 1),
            search.shared and search.shared.expanded or slot and slot.state and slot.state.expanded or search.expanded or 0,tostring(search.reason),tostring(foreground))
    end
    if done then
        selected.search=nil
        if path then Q.startRoute(selected,path)
        else Q.failed(selected,reason or 'no safe route') end
    -- Difficult arrival trees must also end: reject these candidates briefly
    -- so the next attempt can select another cleared row rather than run all night.
    elseif selected.searchWorkMs>(selected.operation=='prepare' and 15000 or 1000)
            or (arrival and now()-selected.searchStarted>180000) then
        Q.failed(selected,'search budget exhausted; selecting another cleared position')
        Q.cancel(selected.driver); selected.stage=nil
    elseif selected.operation=='yield' or arrival then
        local phaseReason=S.chargeChoices(selected.search,elapsed,workPhase)
        if phaseReason then Q.reason(selected,phaseReason) end
    end
end

function Q.arrived(driver,goal)
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    if distance(here,goal)>1.5 or math.abs(H.math.delta(here.t,goal.t))>math.rad(10) then return false end
    local model=W.model(driver.vehicle)
    if not model then return false end
    local poses=W.poses(model)
    for _,p in ipairs(poses) do if math.abs(H.math.delta(p.t,goal.t))>math.rad(10) then return false end end
    return not goal.accept or goal.accept(poses,model)
end

function Q.onLast(driver)
    local data=driver.queueData
    if not Q.owns(driver) or driver.course~=data.course then return false end
    local destination=data.goal
    if not destination or not Q.arrived(driver,destination) then
        Q.failed(data,'whole train not aligned at destination')
        Q.cancel(driver)
        return true
    end
    Q.cancel(driver)
    if destination.transit then data.arrivalDeparted=true end
    data.parkedGoal=not destination.transit and destination or nil
    data.nextAttempt=destination.transit and now() or now()+1000
    Q.reason(data,'holding '..data.operation)
    return true
end

function Q.tick(driver)
    if not Q.enabled(driver) then
        if Q.owns(driver) then Q.release(driver) end
        Q.remove(driver); return
    end
    local data=Q.data(driver)
    if data.operation and not Q.owns(driver) then
        Q.clearTrailerTraffic(driver)
        Q.cancel(driver); data.operation=nil; data.departureClearance=nil
    end
    Q.refresh()
    if Q.owns(driver) and Q.holdForHarvesterBypass(driver) then return end
    local departureClearance=Q.departureClearanceActive(driver)
    if data.nativeDeparture and driver.state~=driver.states.IDLE and not departureClearance then return end
    if driver.state==driver.states.IDLE then
        if data.nativeDeparture or driver:isDriveUnloadNowRequested() or Q.atDepartureThreshold(driver) then
            driver:startUnloadingTrailers(); return
        end
        Q.take(driver,'prepare')
    end
    if Q.owns(driver) then
        -- Full/manual departure outranks ordinary queue work. Only a checked
        -- escape from its blocked departure may finish before native replanning.
        if not departureClearance and (driver:isDriveUnloadNowRequested() or Q.atDepartureThreshold(driver)) then
            Q.release(driver); driver:startUnloadingTrailers(); return
        end
        -- Arrival searches retain partial work while native pathfinding owns
        -- the frame. The shared update slice and individual searches remain bounded.
        if data.operation=='yield' and Q.updateYieldRecovery(driver) then return end
        if data.search and data.operation=='prepare' and not (data.goal and data.goal.arrival)
                and now()-(data.searchRetargetAt or data.searchStarted)>=3000 then
            data.searchRetargetAt=now()
            local assignment=data.assignment
            local combine=assignment and Q.combines and Q.combines[assignment.combine]
            local deadline=combine and (assignment.successor and assignment.deadline or P.deadline(combine))
            local urgent=deadline and not assignment.future and deadline<=Q.preparationEta(driver,combine)+15
            if (assignment and assignment.combine)~=data.searchAssignment
                    or (assignment and assignment.successor)~=data.searchSuccessor
                    or (assignment and assignment.future)~=data.searchFuture
                    or (urgent and data.searchStage and data.searchStage<3) then
                Q.cancel(driver); data.stage=nil; data.nextAttempt=now()
                Q.reason(data,'preparation assignment/deadline changed; refreshing destination')
            end
        end
        if data.path then
            local position=W.pose(driver.vehicle:getAIDirectionNode())
            if not data.progressPosition or distance(position,data.progressPosition)>1 then
                data.progressPosition=position; data.progressTime=now()
            elseif data.turnHold then
                -- An explicit turn reservation is a deliberate wait. Ordinary
                -- proximity stops must still reach the stalled-route retry.
                data.progressTime=now()
            elseif now()-data.progressTime>10000 then
                Q.failed(data,'route made no progress; trying another waiting position')
                Q.cancel(driver); data.progressTime=now()
            end
        end
        if not data.search and not data.path and now()>=data.nextAttempt then
            local goal,corridor
            if data.operation=='yield' then goal=Q.yieldTarget(driver)
            else goal=Q.target(driver) end
            -- A clearance check may resume preparation or release to native
            -- idle. Do not use the old operation/goal after that transition.
            if not Q.owns(driver) then return end
            if goal then
                local arrived=Q.arrived(driver,goal)
                if not arrived then
                    if now()>=Q.nextDeparture or data.operation~='prepare' then
                        Q.request(driver,goal,corridor); Q.nextDeparture=now()+3000
                    end
                elseif data.operation=='yield' then
                    -- Recheck live clearance; reaching a frozen target is not
                    -- proof that the combine's manoeuvre is still clear.
                    Q.yieldTarget(driver,true); data.nextAttempt=now()+1000
                else data.parkedGoal=goal; data.nextAttempt=now()+2000 end
            else
                data.nextAttempt=now()+(data.operation=='yield' and 200 or 3000)
                if data.operation~='yield' then
                    Q.reason(data,'no verified '..data.operation..' destination')
                end
            end
        end
    end
    Q.schedule()
end

-- PPC's relevant waypoint is the start of a segment, often behind the tractor.
-- Project onto a bounded local forward segment instead of driving the collision
-- probe backwards to that waypoint or treating normal spacing as an obstacle.
function Q.projectRoute(path,pose,ix)
    local best,score
    for i=math.max(1,ix-4),math.min(#path-1,ix+24) do
        local a,b=path[i],path[i+1]
        local dx,dz=b.x-a.x,b.z-a.z
        local length=dx*dx+dz*dz
        local f=length>0 and math.max(0,math.min(1,((pose.x-a.x)*dx+(pose.z-a.z)*dz)/length)) or 0
        local p={x=a.x+f*dx,z=a.z+f*dz,t=a.t+H.math.delta(b.t,a.t)*f}
        local d=distance(p,pose)
        if d<=1.5 and math.abs(H.math.delta(p.t,pose.t))<=math.rad(20) and (not score or d<score) then
            best={index=i,point=p}; score=d
        end
    end
    return best
end

function Q.routeClear(data,poses,ix)
    local projection=Q.projectRoute(data.path,poses[1],ix)
    if not projection then return false,'path deviation' end
    local travelled=0
    for i=projection.index,#data.path do
        if travelled>=7 then break end
        local target=i==projection.index and projection.point or data.path[i]
        local start=poses[1]
        local d=distance(start,target)
        local delta=H.math.delta(target.t,start.t)
        local samples=math.max(1,math.ceil(d/0.5),math.ceil(math.abs(delta)/math.rad(2)))
        for j=1,samples do
            local p={x=start.x+(target.x-start.x)*j/samples,z=start.z+(target.z-start.z)*j/samples,t=start.t+delta*j/samples}
            poses=W.advance(data.world.model,poses,p)
            local clear,reason=W.clear(data.world,poses,data.corridor)
            if not clear then return false,reason end
        end
        travelled=travelled+d
    end
    return true
end

function Q.speed(driver)
    local data=driver.queueData
    if not Q.owns(driver) then return end
    local speed=0
    if data.path and data.world then
        -- Revalidate actual articulated bodies and a stopping-distance horizon.
        -- Native proximity/collision controllers also remain active below.
        local clear=data.liveClear
        if not data.liveChecked or now()-data.liveChecked>=200 then
            data.liveChecked=now()
            local bodies=W.currentBodies(driver.vehicle)
            clear=bodies~=nil
            local reason
            for _, item in ipairs(bodies or {}) do
                clear,reason=W.bodyClear(data.world,item.body,item.pose,data.corridor)
                if not clear then break end
            end
            -- Recheck a stopping-distance horizon from the current articulated
            -- pose. Native proximity still runs every frame, between these checks.
            local poses=W.poses(data.world.model)
            poses[1]=W.pose(driver.vehicle:getAIDirectionNode())
            local courseIx=math.max(1,driver.ppc:getRelevantWaypointIx())
            local ix=data.courseToPath and data.courseToPath[courseIx] or courseIx
            if clear then clear,reason=Q.routeClear(data,poses,ix) end
            data.liveReason=reason
            data.liveClear=clear
        end
        if clear then
            speed=data.path.reverse and driver.settings.reverseSpeed:getValue() or math.min(15,driver:getFieldSpeed())
        else
            Q.failed(data,'route rejected: '..(data.liveReason or 'body geometry unavailable'),
                data.liveReason=='path deviation' and 'start' or nil)
            Q.cancel(driver)
        end
    end
    driver:setMaxSpeed(speed)
end

-- Preparation and priority manoeuvres use the same ownership and validation boundary.
-- Their implementations are kept in a separate file for review and testing.
