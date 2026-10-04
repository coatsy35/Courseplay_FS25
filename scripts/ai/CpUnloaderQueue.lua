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
    return driver.settings and driver.settings.unloaderQueue and driver.settings.unloaderQueue:getValue()
        and not driver.augerWagon and not driver.fieldUnloadPositionNode and not driver.useGiantsUnload
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

function Q.failed(data,reason)
    if data.goal then
        data.failedGoals=data.failedGoals or {}
        for key,expiry in pairs(data.failedGoals) do if expiry<=now() then data.failedGoals[key]=nil end end
        data.failedGoals[goalKey(data.goal)]=now()+15000
    end
    Q.reason(data,reason)
    data.nextAttempt=now()+3000
end

function Q.remove(driver)
    Q.cancel(driver); Q.members[driver]=nil; driver.queueData=nil
    if next(Q.members)==nil then Q.nextPlan=0; Q.plan=nil; Q.combines=nil; Q.nextDeparture=0 end
end

function Q.owns(driver)
    return driver.queueData and driver.state==driver.queueData.state
end

function Q.take(driver,operation)
    local data=Q.data(driver)
    Q.cancel(driver)
    data.operation=operation
    data.state={name='QUEUE_'..string.upper(operation),properties={collisionAvoidanceEnabled=true}}
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

function Q.coursePosition(combine)
    local course=combine.fieldWorkCourse
    if not course then return end
    local ix
    if combine.course==course then ix=combine:getClosestFieldworkWaypointIx()
    else ix=course:getLastPassedWaypointIx() or course:getCurrentWaypointIx() end
    if not ix then return end
    ix=math.max(1,math.min(course:getNumberOfWaypoints(),ix))
    return course,ix
end

function Q.headlands(course)
    local result,band,pass={}
    for i=1,course:getNumberOfWaypoints() do
        local wp=course:getWaypoint(i)
        local currentPass=course:getHeadlandNumber(i)
        if course:isOnHeadland(i) and wp:getBoundaryId()=='F' and not wp:isHeadlandTransition()
                and not wp:isOnConnectingPath() and not wp.attributes:isIslandBypass() then
            if not band or currentPass~=pass then band={}; result[#result+1]=band end
            band[#band+1]=point(course,i); pass=currentPass
        else band=nil end
    end
    return result
end

function Q.departureFor(course,ix)
    local first=ix
    while first>1 and not course:getWaypoint(first):isRowStart() and not course:isOnHeadland(first) do first=first-1 end
    local saved={row={},headlands={},width=course:getWorkWidth(),position=point(course,ix),
        headlandOrigin=course:isOnHeadland(ix)}
    if not saved.width or saved.width<=0 then return end
    for i=first,ix do saved.row[#saved.row+1]=point(course,i) end
    saved.headlands=Q.headlands(course)
    if (#saved.row>=2 or saved.headlandOrigin or course:getWaypoint(first):isRowStart())
            and #saved.headlands>0 then return saved end
end

-- Save immutable positions BEFORE native release clears combineJustUnloaded.
function Q.capture(driver)
    local vehicle=driver.combineToUnload
    if not vehicle or not vehicle:getIsCpActive() then return end
    local course,ix=Q.coursePosition(vehicle:getCpDriveStrategy())
    Q.data(driver).departure=course and Q.departureFor(course,ix) or nil
end

function Q.recoverDeparture(driver)
    if not Q.combines or next(Q.combines)==nil then return end
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    local best,nearest
    for _,combine in pairs(Q.combines or {}) do
        local course=combine.driver.fieldWorkCourse
        if course and driver:isServingPosition(combine.position.x,combine.position.z,10) then
            for i=1,course:getNumberOfWaypoints() do
                local wp=course:getWaypoint(i)
                if not wp:isOnConnectingPath() and not wp:isHeadlandTransition() then
                    local d=distance(here,point(course,i))
                    if d<course:getWorkWidth()/2 and (not nearest or d<nearest) then
                        best,nearest={course=course,ix=i},d
                    end
                end
            end
        end
    end
    -- This is only a candidate corridor for a resumed/full rig. The complete
    -- route still has to pass live crop and whole-train validation before moving.
    if best then
        local saved=Q.departureFor(best.course,best.ix)
        if saved then saved.position=here; Q.data(driver).departure=saved end
    end
end

local function capacity(driver,fillType)
    local total,fill,seen=0,0,{}
    for _, target in pairs(driver.trailerNodes or {}) do
        local object,ix=target.trailer,target.fillUnitIx
        seen[object]=seen[object] or {}
        if not seen[object][ix] then
            seen[object][ix]=true
            if fillType==nil or (fillType~=FillType.UNKNOWN and object:getFillUnitAllowsFillType(ix,fillType)) then
                total=total+object:getFillUnitCapacity(ix)
                fill=fill+object:getFillUnitFillLevel(ix)
            end
        end
    end
    return total,fill
end

function Q.refresh()
    if now()<Q.nextPlan then return end
    Q.nextPlan=now()+1000
    local combines,trailers,byId={}, {}, {}
    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if AIDriveStrategyCombineCourse.isActiveCpCombine(vehicle) then
            local driver=vehicle:getCpDriveStrategy()
            if driver.combineController and not driver:isChopper() then
                local total=driver.combineController:getCapacity()
                if total>0 then
                    local owner=driver.unloader:get()
                    local c={id=id(vehicle),driver=driver,vehicle=vehicle,capacity=total,
                        fill=driver.combineController:getFillLevel(),rate=math.max(0,driver.litersPerSecond or 0),
                        callPercent=driver.settings.callUnloaderPercent:getValue(),waiting=driver:isWaitingForUnload(),
                        owner=owner and owner.vehicle and id(owner.vehicle),position=W.pose(vehicle:getAIDirectionNode())}
                    combines[#combines+1]=c; byId[c.id]=c
                end
            end
        end
    end
    for driver,data in pairs(Q.members) do
        if Q.enabled(driver) and driver.vehicle:getIsCpActive() then
            local total,fill=capacity(driver)
            local elapsed=data.sampleTime and (now()-data.sampleTime)/1000 or 0
            local transfer=elapsed>0 and math.max(0,(fill-(data.lastFill or fill))/elapsed) or 0
            data.sampleTime=now(); data.lastFill=fill
            local t={id=id(driver.vehicle),driver=driver,capacity=total,fill=fill,enabled=true,
                departPercent=driver.settings.fullThreshold:getValue(),compatible={},
                available=driver.state==driver.states.IDLE or (Q.owns(driver) and data.operation=='prepare'),
                owner=driver.combineToUnload and id(driver.combineToUnload),transferring=transfer>0,
                transferRate=transfer,reservedFor=data.assignment and data.assignment.combine,
                position=W.pose(driver.vehicle:getAIDirectionNode())}
            for _, c in ipairs(combines) do
                local compatible,loaded=capacity(driver,c.driver:getFillType())
                t.compatible[c.id]=compatible-loaded>0 and driver:isServingPosition(c.position.x,c.position.z,10)
                -- Mixed-capacity trains must not reserve more than the compatible units can hold.
                if compatible~=total then t.compatible[c.id]=false end
            end
            trailers[#trailers+1]=t
        end
    end
    Q.plan=P.plan(combines,trailers,function(t,c)
        if not t.compatible[c.id] then return math.huge end
        local _,eta=t.driver:getDistanceAndEteToVehicle(c.vehicle)
        return eta+12
    end)
    Q.combines=byId
    for _, t in ipairs(trailers) do Q.members[t.driver].assignment=Q.plan.trailers[t.id] end
end

function Q.findUnloader(combine,stopped,waypoint)
    Q.refresh()
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
        local course,ix=Q.coursePosition(combine.driver)
        if not course then return end
        local lag=P.lag(combine,AIUtil.getLength(driver.vehicle),12,driver:getFieldSpeed()/3.6)
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
    if not world then Q.failed(data,reason); return end
    data.world=world
    if goal.choices then data.search=S.choices(world,goal.choices)
    else data.search,reason=S.new(world,goal,corridor) end
    data.searchGeneration=data.generation
    data.corridor=corridor
    if not data.search then Q.failed(data,reason) end
    data.searchStarted=now()
end

function Q.startRoute(data,path)
    if not Q.owns(data.driver) or data.searchGeneration~=data.generation then return end
    data.path=path; data.search=nil
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
    for _, data in pairs(Q.members) do
        if data.search and Q.owns(data.driver) and data.searchGeneration==data.generation
                and (not selected or (data.lastAdvance or 0)<(selected.lastAdvance or 0)) then selected=data end
    end
    if not selected then return end
    selected.lastAdvance=now()
    local timer=openIntervalTimer()
    local done,path,reason
    repeat done,path,reason=S.step(selected.search,1) until done or readIntervalTimerMs(timer)>=2
    local elapsed=readIntervalTimerMs(timer); closeIntervalTimer(timer)
    if elapsed>=8 then selected.driver:debug('Queue search advance %.1f ms',elapsed) end
    if done then
        selected.search=nil
        if path then Q.startRoute(selected,path)
        else Q.failed(selected,reason or 'no safe route') end
    elseif now()-selected.searchStarted>15000 then
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
    if driver.state==driver.states.IDLE and not driver:isDriveUnloadNowRequested()
            and not driver:getAllTrailersFull(driver.settings.fullThreshold:getValue()) then
        Q.take(driver,'prepare')
    end
    if Q.owns(driver) then
        if data.operation=='yield' and data.path then
            Q.yieldTarget(driver,true)
            if not Q.owns(driver) then return end
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
        if data.operation=='prepare' and (driver:isDriveUnloadNowRequested()
                or driver:getAllTrailersFull(driver.settings.fullThreshold:getValue())) then
            Q.release(driver); driver:startUnloadingTrailers(); return
        end
        if not data.search and not data.path and now()>=data.nextAttempt then
            local goal,corridor
            if data.operation=='exit' then goal,corridor=Q.exitTarget(driver)
            elseif data.operation=='yield' then goal=Q.yieldTarget(driver)
            else goal=Q.target(driver) end
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
                elseif data.operation=='exit' then Q.finishExit(driver)
                elseif data.operation=='yield' then Q.release(driver)
                else data.parkedGoal=goal; data.nextAttempt=now()+2000 end
            else data.nextAttempt=now()+3000; Q.reason(data,'no verified '..data.operation..' destination') end
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

-- Exit and priority manoeuvres use the same ownership and validation boundary.
-- Their implementations are kept in a separate file for review and testing.
