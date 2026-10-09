-- Queue clearance only. Native CP owns full-trailer departure and AD handover.
local Q = CpUnloaderQueue
local W = CpUnloaderQueueWorld
local G = CpUnloaderQueueGeometry
local H = HeadlandLoopGeometry
local function distance(a,b) return math.sqrt((a.x-b.x)^2+(a.z-b.z)^2) end

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
            reservation={turn=turn,course=turn.turnCourse,area=area}
            Q.turnTraffic[combine]=reservation
            Q.turnTrafficRevision=Q.turnTrafficRevision+1
        end
    end
    return reservation
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
        if intersects(wait.area,wait.driver.vehicle) or traffic then
            wait.clearSince=nil
            -- Native traffic retains its job. Retry a checked route if it
            -- remains stationary; never wait forever for a coupled manoeuvre.
            if (not Q.owns(wait.driver) or (traffic and AIUtil.isStopped(traffic.vehicle)))
                    and g_currentMission.time>=(wait.retryAt or 0) then
                wait.retryAt=g_currentMission.time+5000
                turn.state=turn.states.PREPARING_RECOVERY
                combine.queueTrailerWait=nil
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
            local bypass={turn=turn,vehicle=driver.vehicle,driver=driver,combine=combine,
                area=wait.area,untilTime=g_currentMission.time+120000}
            combine.queueBypass=bypass; driver.queueData.bypass=bypass
        end
        turn.state=turn.states.PREPARING_RECOVERY
        return true
    end
    local active=combine.queueBypass
    if active and active.turn==turn then
        if traffic and not active.braking and turn.queueBypassFailed
                and (turn.state==turn.states.TURNING or turn.state==turn.states.ENDING_TURN) then
            if AIUtil.isStopped(combine.vehicle) and AIUtil.isStopped(traffic.vehicle) then
                -- A different native rig may stop on an already checked route.
                -- Recheck the same target before advancing, retaining both jobs.
                turn.state=turn.states.PREPARING_RECOVERY
                active.untilTime=g_currentMission.time+120000
            end
            return true
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
    if result.done then return turn:onPathfindingDone(result.path) end
    turn.state=turn.states.WAITING_FOR_PATHFINDER
    turn.driveStrategy:setPathfindingDoneCallback(turn,turn.onPathfindingDone)
end

function Q.validateHarvesterBypass(turn)
    local course,constraints=turn.turnCourse,turn.queueBypassConstraints
    if not course or not constraints then return false end
    local previous,count=nil,0
    for i=1,course:getNumberOfWaypoints() do
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
    if not data or (Q.owns(driver) and not parked and data.operation~='yield') or nativeFollower(driver,combine)
            or not AIUtil.isStopped(vehicle) or not AIUtil.isStopped(combine.vehicle) then return false end
    -- A second harvester may need this trailer to yield instead of holding still.
    for other in pairs(data.yieldRequests or {}) do
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
        if parked and Q.priority(driver,combine.vehicle) then
            local request=driver.queueData.yieldRequests and driver.queueData.yieldRequests[combine.vehicle]
            if not request then return end
            request.turnClearance=area
            request.preferForward=true
            driver.queueData.nextAttempt=0
        end
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

function Q.priority(driver,combine)
    if (driver.queueData and driver.queueData.nativeDeparture)
            or driver.state==driver.states.MOVING_BACK_WITH_TRAILER_FULL then return false end
    if not Q.enabled(driver) or not combine or not driver.vehicle:getIsCpActive()
            or not AIDriveStrategyCombineCourse.isActiveCpCombine(combine) then return false end
    if Q.atDepartureThreshold(driver) or driver:isDriveUnloadNowRequested() then return false end
    local strategy=combine:getCpDriveStrategy()
    if ordinaryTravelTurn(strategy) then
        if Q.holdIncomingTurn(driver) then return true end
        if driver.state==driver.states.BACKING_UP_FOR_REVERSING_COMBINE
                or driver.state==driver.states.MOVING_AWAY_FROM_OTHER_VEHICLE then return false end
    end
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
    if not Q.owns(driver) and ordinaryTravelTurn(strategy) then
        -- A native manoeuvre must survive a queue start that is already
        -- invalid (for example standing crop). Probe before releasing the
        -- assignment or cancelling its native pathfinder.
        local probe=setmetatable({queueData={operation='yield'}},{__index=driver})
        local world,reason=W.new(probe)
        local clear=false
        if world then clear,reason=W.clear(world,W.poses(world.model)); W.delete(world) end
        if not clear then
            Q.reason(data,'native clearance retained: '..tostring(reason))
            return false
        end
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
    local target={x=choices[1].x,z=choices[1].z,t=here.t,choices=choices}
    return target
end
