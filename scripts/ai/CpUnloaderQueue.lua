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

-- Native release happens before a full rig has physically cleared the pipe.
-- An occupied stationary goal otherwise exhausts all native retries in a few
-- frames and stops the replacement's job. Decline this call without taking
-- ownership; the combine's normal three-second call cycle will try again.
function Q.waitingApproachBlocker(driver,combine)
    local system=g_currentMission.vehicleSystem
    if not system or not system.vehicles or driver.combineToUnload then return end
    -- Native call prefers direct aligned entry over pathfinding, even beyond
    -- its five-metre pathfinding range. Evaluate those read-only predicates
    -- against the proposed target without assigning the real driver.
    local candidate=setmetatable({combineToUnload=combine},{__index=driver})
    if candidate:isOkToStartUnloadingCombine() then return end
    local model=W.model(driver.vehicle)
    if not model then return end -- unsupported rigs retain native handling
    local harvester=combine:getCpDriveStrategy()
    local node=harvester:getPipeOffsetReferenceNode()
    local xOffset=driver:getPipeOffset(combine)
    local zOffset=-harvester:getMeasuredBackDistance()
    -- Match U.call's stationary target, including pulled-back and auto-aim
    -- harvesters. Read the passed harvester, never assign combineToUnload here.
    if harvester:isWaitingForUnloadAfterPulledBack() then
        zOffset=zOffset-10
    elseif harvester:hasAutoAimPipe() then
        if math.abs(driver:getAutoAimPipeOffsetX())<3 then
            local _,front=Markers.getFrontMarkerNode(driver.vehicle)
            zOffset=zOffset-front-2
        end
    else
        zOffset=zOffset-(math.abs(xOffset)>6 and 2 or 5)
    end
    -- Preserve native near-target handling as well as direct aligned entry.
    if not driver:isPathfindingNeeded(driver.vehicle,node,xOffset,zOffset) then return end
    local x,_,z=localToWorld(node,xOffset,0,zOffset)
    local poses=W.settledPoses(model,{x=x,z=z,t=H.math.heading(node)})
    local rectangles={}
    for i,body in ipairs(model.bodies) do rectangles[i]=W.rectangle(body,poses[i]) end
    local function root(vehicle)
        return vehicle.getRootVehicle and vehicle:getRootVehicle() or vehicle
    end
    local seen={[root(driver.vehicle)]=true,[root(combine)]=true}
    -- Use live physical rigs, not queue membership: the outgoing trailer may
    -- already belong to AD while it still occupies the replacement's goal.
    for _,vehicle in pairs(system.vehicles) do
        local other=root(vehicle)
        if not seen[other] then
            seen[other]=true
            for _,item in ipairs(W.currentBodies(other) or {}) do
                local rectangle=W.rectangle(item.body,item.pose)
                for _,incoming in ipairs(rectangles) do
                    if G.overlap(incoming,rectangle) then return other end
                end
            end
        end
    end
end

function Q.data(driver)
    if not driver.queueData then
        driver.queueData={generation=0,driver=driver,nextAttempt=0}
        Q.members[driver]=driver.queueData
    end
    return driver.queueData
end

function Q.reason(data,reason)
    if data.reason~=reason then
        data.reason=reason
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
    if data.goal and phase~='start' and phase~='world' then
        data.failedGoals=data.failedGoals or {}
        for key,expiry in pairs(data.failedGoals) do if expiry<=now() then data.failedGoals[key]=nil end end
        data.failedGoals[goalKey(data.goal)]=now()+15000
    end
    Q.reason(data,reason)
    data.nextAttempt=now()+3000
end

function Q.remove(driver)
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
    -- Like native MOVING_AWAY_FROM_OTHER_VEHICLE, yielding must not wait on
    -- the future path conflict it is clearing. Live proximity and full-train
    -- route/obstacle validation remain active.
    data.state={name='QUEUE_'..string.upper(operation),properties={collisionAvoidanceEnabled=operation~='yield'}}
    driver.state=data.state
    driver:setMaxSpeed(0)
    return data
end

function Q.release(driver)
    Q.cancel(driver)
    local data=driver.queueData
    if data then data.operation=nil end
    driver.state=driver.states.IDLE
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
            if driver.combineController then
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
        local _,eta=t.driver:getDistanceAndEteToVehicle(c.vehicle)
        return eta+12
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

function Q.target(driver)
    local data=Q.data(driver)
    local assignment=data.assignment
    if not assignment or assignment.future then return end
    if assignment.combine then
        local combine=Q.combines[assignment.combine]
        if not combine then return end
        local course,ix=Q.coursePosition(combine.driver,true)
        if not course then return end
        local lag=P.lag(combine,AIUtil.getLength(driver.vehicle),12,driver:getFieldSpeed()/3.6,
            assignment.successor and assignment.deadline or nil)
        if assignment.successor then lag=lag+AIUtil.getLength(driver.vehicle)+20 end
        for extra=0,40,10 do
            local targetIx=course:getPreviousWaypointIxWithinDistance(ix,lag+extra)
            if targetIx and targetIx>=1 then
                local p=point(course,targetIx)
                if Q.targetAvailable(driver,p) then return p end
            end
        end
    else
        -- Stable slots along harvested headland courses, outside the AD start's
        -- turning space. Search and density checks decide whether a slot is usable.
        local index=1
        for other in pairs(Q.members) do if id(other.vehicle)<id(driver.vehicle) then index=index+1 end end
        local marker=driver.invertedStartPositionMarkerNode
        local origin=marker and W.pose(marker) or W.pose(driver.vehicle:getAIDirectionNode())
        local best,score
        for _, combine in pairs(Q.combines or {}) do
            local course=combine.driver.fieldWorkCourse
            if course and driver:isServingPosition(combine.position.x,combine.position.z,10) then
                local spacing=math.max(22,AIUtil.getLength(driver.vehicle)+8)
                local accumulated=0
                for i=2,course:getNumberOfWaypoints() do
                    if course:isOnHeadland(i) and course:isOnHeadland(i-1) then
                        local p=point(course,i)
                        accumulated=accumulated+distance(p,point(course,i-1))
                        if accumulated>=index*spacing then
                            accumulated=0
                            local d=distance(p,origin)
                            if d>2*driver.turningRadius+spacing and Q.targetAvailable(driver,p)
                                    and (not score or d<score) then best,score=p,d end
                        end
                    else accumulated=0 end
                end
            end
        end
        return best
    end
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
    else data.search,reason,phase=S.new(world,goal,corridor) end
    data.searchGeneration=data.generation
    data.corridor=corridor
    if not data.search then Q.failed(data,reason,phase) end
    data.searchStarted=now()
    data.searchWorkMs=0

end

function Q.startRoute(data,path)
    if not Q.owns(data.driver) or data.searchGeneration~=data.generation then return end
    data.path=path; data.search=nil
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
    -- Foreground native calls keep their existing scheduling and take precedence.
    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        local d=vehicle.getCpDriveStrategy and vehicle:getCpDriveStrategy()
        if d and d.pathfinderController and d.pathfinderController.pathfinder then return end
    end
    local selected
    local priority={yield=0,prepare=1}
    for _, data in pairs(Q.members) do
        if data.search and Q.owns(data.driver) and data.searchGeneration==data.generation
                and (not selected or priority[data.operation]<priority[selected.operation]
                    or (priority[data.operation]==priority[selected.operation]
                        and (data.lastAdvance or 0)<(selected.lastAdvance or 0))) then selected=data end
    end
    if not selected then return end
    selected.lastAdvance=now()
    local timer=openIntervalTimer()
    local done,path,reason
    repeat done,path,reason=S.step(selected.search,1) until done or readIntervalTimerMs(timer)>=2
    local elapsed=readIntervalTimerMs(timer); closeIntervalTimer(timer)
    -- Charge measured computation, not the duration of a game frame. A low
    -- frame rate or another worker must not reduce this search's work allowance.
    selected.searchWorkMs=(selected.searchWorkMs or 0)+elapsed
    if elapsed>=8 then selected.driver:debug('Queue search advance %.1f ms',elapsed) end
    if done then
        selected.search=nil
        if path then Q.startRoute(selected,path)
        else Q.failed(selected,reason or 'no safe route') end
    elseif selected.searchWorkMs>(selected.operation=='prepare' and 15000 or 1000) then
        selected.search=nil; Q.failed(selected,'search budget exhausted; retaining CP control')
    end
end

function Q.onLast(driver)
    local data=driver.queueData
    if not Q.owns(driver) or driver.course~=data.course then return false end
    local destination=data.goal
    Q.cancel(driver)
    data.parkedGoal=destination
    data.nextAttempt=now()+1000
    Q.reason(data,'holding '..data.operation)
    return true
end

function Q.tick(driver)
    if not Q.enabled(driver) then
        if Q.owns(driver) then Q.release(driver) end
        Q.remove(driver); return
    end
    local data=Q.data(driver)
    if data.operation and not Q.owns(driver) then Q.cancel(driver); data.operation=nil end
    Q.refresh()
    if Q.owns(driver) and Q.holdForHarvesterBypass(driver) then return end
    if data.nativeDeparture and driver.state~=driver.states.IDLE then return end
    if driver.state==driver.states.IDLE then
        if data.nativeDeparture or driver:isDriveUnloadNowRequested() or Q.atDepartureThreshold(driver) then
            driver:startUnloadingTrailers(); return
        end
        Q.take(driver,'prepare')
    end
    if Q.owns(driver) then
        -- Full/manual departure outranks both preparation and a queue yield.
        -- From here CP owns obstacle clearance and return-marker travel.
        if driver:isDriveUnloadNowRequested() or Q.atDepartureThreshold(driver) then
            Q.release(driver); driver:startUnloadingTrailers(); return
        end
        if data.operation=='yield' and data.path then
            Q.yieldTarget(driver,true)
            if not Q.owns(driver) or data.operation~='yield' then return end
        end
        if data.path then
            local position=W.pose(driver.vehicle:getAIDirectionNode())
            if not data.progressPosition or distance(position,data.progressPosition)>1 then
                data.progressPosition=position; data.progressTime=now()
            elseif now()-data.progressTime>5000 then
                Q.cancel(driver); data.nextAttempt=now()+1000
                data.progressTime=now(); Q.reason(data,'route made no progress; replanning')
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
                local here=W.pose(driver.vehicle:getAIDirectionNode())
                local arrived=distance(here,goal)<(data.operation=='prepare' and 5 or 1.5)
                    and math.abs(H.math.delta(here.t,goal.t))<math.rad(10)
                local model=W.model(driver.vehicle)
                if arrived and model then
                    local poses=W.poses(model)
                    for _,p in ipairs(poses) do if math.abs(H.math.delta(p.t,goal.t))>math.rad(10) then arrived=false end end
                    if goal.accept and not goal.accept(poses,model) then arrived=false end
                elseif not model then arrived=false end
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
            for _, item in ipairs(bodies or {}) do
                if not W.bodyClear(data.world,item.body,item.pose,data.corridor) then clear=false; break end
            end
            -- Recheck a stopping-distance horizon from the current articulated
            -- pose. Native proximity still runs every frame, between these checks.
            local poses=W.poses(data.world.model)
            poses[1]=W.pose(driver.vehicle:getAIDirectionNode())
            local travelled=0
            local courseIx=math.max(1,driver.ppc:getRelevantWaypointIx())
            local ix=data.courseToPath and data.courseToPath[courseIx] or courseIx
            for i=ix,#data.path do
                if not clear or travelled>=7 then break end
                local p=data.path[i]
                local d=distance(poses[1],p)
                if d>=0.2 then
                    if d>2 then clear=false; break end
                    poses=H.advance(data.world.model,poses,p)
                    clear=W.clear(data.world,poses,data.corridor)
                    travelled=travelled+d
                end
            end
            data.liveClear=clear
        end
        if clear then
            speed=data.path.reverse and driver.settings.reverseSpeed:getValue() or math.min(15,driver:getFieldSpeed())
        else
            Q.cancel(driver); data.nextAttempt=now()+1500; Q.reason(data,'route obstructed; replanning')
        end
    end
    driver:setMaxSpeed(speed)
end

-- Preparation and priority manoeuvres use the same ownership and validation boundary.
-- Their implementations are kept in a separate file for review and testing.
