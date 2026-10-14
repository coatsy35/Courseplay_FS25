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

local function finishCandidates(data,radius)
    local corner=rigidCorner(data.world.model)
    data.corner=corner
    local candidates={}
    local function candidate(angle)
        local points={{x=data.origin.x,z=data.origin.z,t=data.origin.t,s=0}}
        local function segment(length,curvature)
            local start=points[#points]
            -- At most 0.5 m of motion at ANY rigid corner between samples.
            -- The 0.3 m collision padding covers either half of that sweep.
            local count=math.ceil(length*(1+corner*math.abs(curvature))/0.5)
            for i=1,count do
                local s=length*i/count
                local t=start.t+s*curvature
                local x,z
                if curvature==0 then x,z=H.math.position(start,0,s)
                else
                    x=start.x+(math.cos(start.t)-math.cos(t))/curvature
                    z=start.z+(math.sin(t)-math.sin(start.t))/curvature
                end
                points[#points+1]={x=x,z=z,t=t,s=start.s+s}
            end
        end
        if angle==0 then segment(data.length,0)
        else
            segment(3,0)
            segment(radius*math.abs(angle),angle>0 and 1/radius or -1/radius)
            segment(math.max(8,data.length-3-radius*math.abs(angle)),0)
        end
        candidates[#candidates+1]={points=points,angle=angle,goal=points[#points]}
    end
    candidate(0)
    if radius and H.math.finite(radius) and radius>0 and radius<=25 then
        for _,angle in ipairs({math.pi/4,-math.pi/4,math.pi/2,-math.pi/2}) do candidate(angle) end
    end
    data.candidates=candidates; data.candidate=1; data.sample=0
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
                and combine.fieldWorkerProximityController:hasSameCourse(vehicle)
                and distance(pose,W.pose(vehicle:getAIDirectionNode()))<100 then
            local other=vehicle:getCpDriveStrategy()
            local otherModel=W.rigidModel(vehicle)
            if not otherModel then return false,'neighbour geometry unavailable' end
            for _,rect in ipairs(rigidRectangles(otherModel,otherModel.root,1)) do
                if overlaps(rect) then return false,'neighbour header/body clearance' end
            end
            if not other.queueFinishClearance and other.combineController:getFillLevel()>=0.01 then
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
                        for _,rect in ipairs(rigidRectangles(otherModel,otherModel.root,0)) do
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
    return true
end

function Q.beginFinishClearance(combine)
    if combine.queueFinishAttempted or combine.queueFinishClearance or not finishEnd(combine) then return false end
    combine.queueFinishAttempted=true
    if not combine.vehicle.spec_combine or combine:isAttachedHarvester() or combine:isChopper()
            or combine.settings.selfUnload:getValue() or combine.combineController:getFillLevel()>=0.01
            or combine.settings.restartCourseAtEnd:getValue() then return false end
    local _,steeringLength=AIUtil.getSteeringParameters(combine.vehicle)
    if steeringLength~=0 then return false end
    local origin=W.pose(combine.vehicle:getAIDirectionNode())
    local neighbour=false
    for _,vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle~=combine.vehicle and AIDriveStrategyCombineCourse.isActiveCpCombine(vehicle)
                and combine.fieldWorkerProximityController:hasSameCourse(vehicle)
                and distance(origin,W.pose(vehicle:getAIDirectionNode()))<100 then neighbour=true; break end
    end
    if not neighbour then return false end
    local model,reason=W.rigidModel(combine.vehicle)
    if not model then return false end
    local world
    world,reason=W.new(combine,model)
    if not world then combine:debug('Queue: final clearance unavailable: %s',reason); return false end
    local length=math.min(25,math.max(20,model.front-model.back+8))
    local data={world=world,origin=origin,length=length,started=g_currentMission.time,
        progressTime=g_currentMission.time,progress=origin}
    combine.queueFinishClearance=data
    -- This capability is valid only while this exact empty final manoeuvre owns
    -- the world. Deleting or reusing a world cannot relax ordinary crop checks.
    world.finalParking=data
    finishCandidates(data,combine.turningRadius)
    combine.aiOffsetX=0; combine.aiOffsetZ=0; combine.tightTurnOffset=0
    combine.state=combine.states.UNLOADING_ON_FIELD
    combine.unloadState={name='CLEARING_FINAL_UNLOAD',properties={}}
    combine:raiseImplements()
    combine:setMaxSpeed(0)
    combine:debug('Queue: checking forward/turn-away final parking; crop crossing permitted only after emptying at course end')
    return true
end

function Q.clearFinishClearance(combine)
    local data=combine.queueFinishClearance
    if data then W.delete(data.world); combine.queueFinishClearance=nil end
end

function Q.completeFinishClearance(combine,reason)
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
    if time-data.started>60000 then Q.completeFinishClearance(combine,'timed out safely'); return end
    local here=W.pose(combine.vehicle:getAIDirectionNode())
    local model=W.rigidModel(combine.vehicle)
    if not model then Q.completeFinishClearance(combine,'geometry unavailable'); return end
    local changed=not W.sameRigidShape(data.world.model,model)
    data.world.model=model
    if data.driving then
        if changed then data.corner=rigidCorner(model) end
        if distance(here,data.progress)>0.5 then data.progress=here; data.progressTime=time end
        if time-data.progressTime>10000 then Q.completeFinishClearance(combine,'stopped by an obstruction'); return end
        if distance(here,data.goal)<=1 then
            if W.rigidClear(data.world,here) and Q.finishParkingClear(combine,model,here) then
                Q.completeFinishClearance(combine,'completed')
            else combine:setMaxSpeed(0) end
            return
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
    if changed then finishCandidates(data,combine.turningRadius) end
    combine:setMaxSpeed(0)
    if data.retryAt and time<data.retryAt then return end
    for _,vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        local driver=vehicle.getCpDriveStrategy and vehicle:getCpDriveStrategy()
        if driver and driver.combineToUnload==combine.vehicle then return end
    end
    local route=data.candidates[data.candidate]
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
        clear,reason=Q.finishParkingClear(combine,model,route.goal)
        if clear then
            data.route=route; data.goal=route.goal; data.driving=true; data.progressTime=time
            local points={}
            for _,p in ipairs(route.points) do points[#points+1]={x=p.x,z=p.z} end
            combine.ppc:setShortLookaheadDistance()
            combine:startCourse(Course(combine.vehicle,points,true),1)
            combine:debug('Queue: final parking %.1f m, turn %.0f degrees',route.goal.s,math.deg(route.angle))
            return
        end
    end
    if reason then
        combine:debug('Queue: final parking candidate %d rejected: %s',data.candidate,data.world.failureDetail or reason)
        data.candidate=data.candidate+1; data.sample=0
        if data.candidate>#data.candidates then
            if time-data.started<15000 then data.candidate=1; data.retryAt=time+1000
            else Q.completeFinishClearance(combine,'no checked forward/turn-away route available') end
        end
    end
end

-- Complete the native stopped-unloading transition even when the combine's
-- successful job stop has already removed its strategy. Keep the vehicle for
-- native marker-based reverse clearance; releaseCombine cannot retain it once
-- CP is inactive. Departure and AutoDrive handover remain entirely native.
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
    if not Q.enabled(driver) or driver.state~=driver.states.UNLOADING_STOPPED_COMBINE
            or not combine or not combine.queueFinishedEmptyCombine or combine:getIsCpActive() then return false end
    local leave=Q.atDepartureThreshold(driver) or driver:isDriveUnloadNowRequested()
    if not leave then leave=not Q.hasRemainingCombine(driver,combine) end
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

-- Give the combine two extra seconds to clear its pocket before a full
-- unloader starts turning forwards onto its native departure route.
function Q.holdPocketDeparture(driver,forwards,speed)
    local data=driver.queueData
    local pause=data and data.pocketDeparturePause
    if not pause then return false end
    local states=driver.states
    if not Q.enabled(driver) or not data.nativeDeparture then
        data.pocketDeparturePause=nil
        return false
    end
    if driver.state~=states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL then
        if driver.state~=states.WAITING_FOR_PATHFINDER
                and driver.state~=states.MOVING_BACK_BEFORE_PATHFINDING then
            data.pocketDeparturePause=nil
        end
        return false
    end
    if not forwards or not speed or speed<=0 then return false end
    local now=g_currentMission.time
    if not pause.untilTime then
        pause.untilTime=now+2000
        driver:debug('Queue: waiting two seconds before forward departure from unloading pocket')
    end
    if now<pause.untilTime then return true end
    data.pocketDeparturePause=nil
    return false
end

local function parkedQueueTrailer(driver)
    local data=driver and driver.queueData
    return data and Q.owns(driver) and data.operation=='prepare' and not data.nativeDeparture
        and not Q.atDepartureThreshold(driver) and not driver:isDriveUnloadNowRequested()
        and not driver.combineToUnload and AIUtil.isStopped(driver.vehicle)
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

-- A centre-entry U-turn/reverse can bring the lead back towards its own
-- historical trail. During that transition, do not use trail distance to
-- decide whether a follower may enter a nearby headland corner. Keep the
-- configured convoy separation in physical space until the lead clears it.
-- Only the headland follower is held; the centre-entry machine keeps priority.
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
            if entering and distance(here,W.pose(vehicle:getAIDirectionNode()))<limit then
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
    local pair=combine.queueCombineHold
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
        if pair and pair.lead==combine and pair.context==combine.turnContext
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

-- A native reverse can finish while the combine searches or waits. Use the
-- rig's current ownership, not its classification when the detour started.
-- An existing request must keep its search, progress and clearance timer.
local function requestTurnClearance(combine,driver,area)
    local data=driver.queueData
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
            if stationary and g_currentMission.time>=(wait.retryAt or 0) then
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
        if Q.owns(driver) and not Q.atDepartureThreshold(driver) and not driver:isDriveUnloadNowRequested() then
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
    local combineBlocker=pair and pair.lead==combine and pair.context==combine.turnContext
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

function Q.resumeAfterYield(driver)
    local data=Q.data(driver)
    data.priorityCombine=nil; data.yieldRequests=nil
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
    if data.operation=='yield' and Q.owns(driver) then
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
    local bodies=W.currentBodies(driver.vehicle)
    local areas,combine,anyBlocked,preferForward={},nil,false,false
    local time=g_currentMission.time
    for vehicle,request in pairs(data.yieldRequests or {}) do
        if not AIDriveStrategyCombineCourse.isActiveCpCombine(vehicle) then
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

-- Extra alignment/recovery belongs only to the remaining end-of-course load.
-- An ordinary pocket/full-tank wait must retain the 3031 native approach,
-- admission and retries, even when the combine is stationary for a long time.
function Q.finalApproachTarget(driver)
    local vehicle=driver.combineToUnload
    if not Q.enabled(driver) or not vehicle or not vehicle.getIsCpActive or not vehicle:getIsCpActive() then return end
    local c=vehicle:getCpDriveStrategy()
    if c and c.isWaitingForUnloadAfterCourseEnded and c:isWaitingForUnloadAfterCourseEnded()
            and c.isWaitingForUnload and c.alwaysNeedsUnloader and c.hasAutoAimPipe
            and c:isWaitingForUnload() and not c:alwaysNeedsUnloader() and not c:hasAutoAimPipe()
            and (vehicle.lastSpeedReal or 0)*3600<0.5 then return c end
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
end

local function stoppedApproachFailed(driver,reason)
    driver:debug('Queue: stopped-combine approach stopped safely: %s',reason)
    Q.clearStoppedApproach(driver); driver:setMaxSpeed(0)
    driver.vehicle:stopCurrentAIJob(AIMessageCpErrorNoPathFound.new())
end

function Q.stoppedApproachGoal(driver,x,z)
    -- Existing final-unload reverse recovery already owns its checked lane.
    if driver.queueFinalUnload or not Q.finalApproachTarget(driver) then return x,z end
    local data=driver.queueStoppedApproach
    if data and data.combine==driver.combineToUnload then return data.x,data.farZ end
    Q.clearStoppedApproach(driver)
    local model=W.model(driver.vehicle)
    if not model then return x,z end -- native path remains available for unsupported rigs
    local length=0
    for _,link in ipairs(model.links) do length=length+math.abs(link.length) end
    local rearZ=math.min(z or 0,-driver:getCombinesMeasuredBackDistance()-5)
    local runIn=math.max(12,3*length)
    data={combine=driver.combineToUnload,phase='pathfinding',x=x or 0,rearZ=rearZ,
        farZ=rearZ-runIn,started=g_currentMission.time,controller=driver.pathfinderController}
    driver.queueStoppedApproach=data
    driver:debug('Queue: final-combine rear entry %.1f, %.1f; %.1f m whole-rig run-in',data.x,data.farZ,runIn)
    return data.x,data.farZ
end

function Q.stoppedApproachPath(driver,success,course)
    local data=driver.queueStoppedApproach
    if not data then return end
    if not success or data.combine~=driver.combineToUnload or driver.state~=driver.states.WAITING_FOR_PATHFINDER then
        Q.clearStoppedApproach(driver); return
    end
    data.course=course; data.phase='approaching'
end

function Q.stoppedAdmission(driver)
    if not Q.finalApproachTarget(driver) then return end
    local data=driver.queueStoppedApproach
    if data and data.combine==driver.combineToUnload and data.phase~='ready' then return false end
    return Q.pipeEntryAligned(driver)
end

function Q.stoppedApproachLast(driver)
    local data=driver.queueStoppedApproach
    if not data or driver.course~=data.course or driver.state~=driver.states.DRIVING_TO_COMBINE then return false end
    if data.combine~=driver.combineToUnload then Q.clearStoppedApproach(driver); return false end
    if not Q.finalApproachTarget(driver) then
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
    local world,reason=W.new(driver)
    if not world then stoppedApproachFailed(driver,reason); return true end
    data.world=world
    local reference=driver:getPipeOffsetReferenceNode()
    local x,_,z=localToWorld(reference,data.x,0,data.rearZ)
    data.goal={x=x,z=z,t=H.math.heading(reference)}
    data.search,reason=CpUnloaderQueueSearch.new(world,data.goal)
    if not data.search then stoppedApproachFailed(driver,reason); return true end
    data.phase='checking'; data.work=0
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
            if g_currentMission.time-data.started>90000 then stoppedApproachFailed(driver,'rear entry timed out') end
        else Q.releaseLostRecoveryTarget(driver,data) end
        return
    end
    if data.combine~=driver.combineToUnload or (state~=driver.states.WAITING_FOR_PATHFINDER
            and state~=driver.states.DRIVING_TO_COMBINE and not nativeBackup) then Q.clearStoppedApproach(driver); return end
    data.departing=data.departing or finalDeparting(driver)
    if nativeBackup then
        -- Do not interrupt an accepted native reverse when the target resumes.
        -- Its callback retains the intent until the next update/endpoint.
        if Q.finalApproachTarget(driver) and g_currentMission.time-data.started>90000 then
            stoppedApproachFailed(driver,'rear entry timed out')
        end
        return
    end
    if data.departing and not finalDeparting(driver) then driver:requestDriveUnloadNow() end
    if finalDeparting(driver) or not Q.finalApproachTarget(driver) then
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
    if g_currentMission.time-data.started>90000 then stoppedApproachFailed(driver,'rear entry timed out'); return end
    if data.phase=='checking' then
        driver:setMaxSpeed(0)
        local timer=openIntervalTimer()
        local done,path,reason
        repeat done,path,reason=CpUnloaderQueueSearch.step(data.search,1)
        until done or readIntervalTimerMs(timer)>=2
        data.work=data.work+readIntervalTimerMs(timer); closeIntervalTimer(timer)
        if not done and data.work<1000 then return end
        if not path then stoppedApproachFailed(driver,reason or 'run-in search budget exhausted'); return end
        local points={}
        -- Retain every checked point: thinning a curve introduces unchecked chords.
        for _,p in ipairs(path) do points[#points+1]={x=p.x,z=p.z} end
        data.path=path; data.search=nil; data.phase='driving'
        data.course=Course(driver.vehicle,points,true)
        data.progress=W.pose(driver.vehicle:getAIDirectionNode()); data.progressTime=g_currentMission.time
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
            data.clear=W.clear(data.world,poses)
            if data.clear then data.clear=Q.routeClear(data,poses,driver.ppc:getRelevantWaypointIx()) end
        end
    end
end

function Q.stoppedApproachSpeed(driver,speed)
    local data=driver.queueStoppedApproach
    if not data or not Q.finalApproachTarget(driver) then return speed end
    if data.phase=='checking' then return 0 end
    if data.phase=='driving' then return data.clear and math.min(speed,5) or 0 end
    return speed
end

-- A rendezvous may reach the last waypoint before its remaining grain transfers.
-- Ordinary moving/full-tank unloading remains entirely with native CP.
function Q.watchStoppedMovingUnload(driver)
    local c=Q.finalApproachTarget(driver)
    if not c or finalDeparting(driver) or not c.combineController then driver.queueStoppedWatch=nil; return false end
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
    driver:setMaxSpeed(0); driver:setNewState(driver.states.WAITING_FOR_PATHFINDER)
    driver:debug('Queue: stopped rendezvous made no transfer or movement; replan rear entry %d/2',data.attempts)
    driver:startPathfindingToWaitingCombine(x,z)
    return true
end
