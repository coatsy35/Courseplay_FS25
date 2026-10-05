-- CP-owned clearance and departure. AutoDrive is queried, never controlled.
local Q = CpUnloaderQueue
local W = CpUnloaderQueueWorld
local G = CpUnloaderQueueGeometry
local H = HeadlandLoopGeometry
local function distance(a,b) return math.sqrt((a.x-b.x)^2+(a.z-b.z)^2) end
local function nearSegment(p,a,b,width)
    local dx,dz=b.x-a.x,b.z-a.z
    local f=math.max(0,math.min(1,((p.x-a.x)*dx+(p.z-a.z)*dz)/math.max(0.001,dx*dx+dz*dz)))
    return distance(p,{x=a.x+f*dx,z=a.z+f*dz})<=width
end
local function onHeadland(saved,p)
    for _, band in ipairs(saved.headlands) do
        for i=2,#band do if nearSegment(p,band[i-1],band[i],saved.width/2) then return true end end
    end
    return false
end
local function wholeHeadland(saved,rectangle)
    -- Edges are sampled too: the corners alone can bridge a concave crop edge.
    for i,a in ipairs(rectangle) do
        local b=rectangle[i%#rectangle+1]
        local count=math.max(1,math.ceil(distance(a,b)/0.5))
        for j=0,count do
            if not onHeadland(saved,{x=a.x+(b.x-a.x)*j/count,z=a.z+(b.z-a.z)*j/count}) then return false end
        end
    end
    return true
end

local function connectionSite(driver,saved,node)
    if onHeadland(saved,node) then return {x=node.x,z=node.z} end
    -- A perimeter connection may sit just outside the field. Interior nodes
    -- away from the headland never qualify, however close they are to a tractor.
    if G.inside(driver.vehicle:cpGetFieldPolygon(),node) then return end
    local best,nearest
    for _,band in ipairs(saved.headlands) do
        for i=2,#band do
            local a,b=band[i-1],band[i]
            local dx,dz=b.x-a.x,b.z-a.z
            local f=math.max(0,math.min(1,((node.x-a.x)*dx+(node.z-a.z)*dz)/math.max(0.001,dx*dx+dz*dz)))
            local p={x=a.x+f*dx,z=a.z+f*dz}
            local d=distance(node,p)
            if d<=20 and (not nearest or d<nearest) then best,nearest=p,d end
        end
    end
    return best
end

function Q.beginExit(driver)
    Q.capture(driver)
    driver:releaseCombine()
    local data=Q.take(driver,'exit')
    if not data.departure then Q.recoverDeparture(driver) end
    data.nextAttempt=0
    Q.reason(data,'CP owns departure until the whole train reaches a connected headland')
end

function Q.exitTarget(driver)
    local data=Q.data(driver)
    if not data.departure then Q.recoverDeparture(driver) end
    local saved=data.departure
    if not saved then Q.reason(data,'no saved harvested row; retaining CP control'); return end
    local start=saved.row[1]
    local radius=0
    for _, band in ipairs(saved.headlands) do
        for _,p in ipairs(band) do radius=math.max(radius,distance(start,p)) end
    end
    local node,heading,site=Q.connectedNode(driver,{x=start.x,z=start.z},saved,radius+21)
    local best
    if node then best={x=site.x,z=site.z,t=heading}
    else
        Q.reason(data,heading)
        local score
        for _,band in ipairs(saved.headlands) do
            for _,p in ipairs(band) do
                local d=distance(start,p)
                if d>AIUtil.getLength(driver.vehicle)+5 and (not score or d<score) then
                    best={x=p.x,z=p.z,t=p.t}; score=d
                end
            end
        end
        if not best then return end
    end
    best.accept=function(poses,model)
        for i,pose in ipairs(poses) do
            if not wholeHeadland(saved,W.rectangle(model.bodies[i],pose)) then return false end
        end
        return true
    end
    local function corridor(rectangle)
        for _,p in ipairs(rectangle) do
            local allowed=onHeadland(saved,p)
            for i=2,#saved.row do
                if nearSegment(p,saved.row[i-1],saved.row[i],saved.width) then allowed=true; break end
            end
            -- Room to turn back into the harvested row, never a field-wide shortcut.
            if distance(p,saved.position)<2*driver.turningRadius then allowed=true end
            if not allowed then return false end
        end
        return true
    end
    return best,corridor
end

function Q.connectedNode(driver,position,saved,range)
    local ad=FS25_AutoDrive
    local graph=ad and ad.ADGraphManager
    local state=driver.vehicle.ad and driver.vehicle.ad.stateModule
    if not graph or not state then return nil,'AD network unavailable' end
    local mode=state:getMode()
    if mode~=2 and mode~=5 then return nil,'AD delivery mode not supported for this exit' end
    local destination=state:getSecondWayPoint()
    if not destination or not graph:getWayPointById(destination) then return nil,'AD delivery destination unavailable' end
    -- AD's lower bound is exclusive; include a node directly under the tractor.
    local nodes=graph:getWayPointsInRange(position,-0.01,range or 20)
    local candidates={}
    for _,node in pairs(nodes or {}) do
        if type(node)=='number' then node=graph:getWayPointById(node) end
        local site=node and saved and connectionSite(driver,saved,node)
        local banned=node and driver.queueData and driver.queueData.failedConnections
            and (driver.queueData.failedConnections[node.id] or 0)>g_currentMission.time
        if site and not banned and Q.targetAvailable(driver,site) then candidates[#candidates+1]={node=node,site=site} end
    end
    table.sort(candidates,function(a,b) return distance(a.site,position)<distance(b.site,position) end)
    for i,candidate in ipairs(candidates) do
        if i>16 then break end
            local node=candidate.node
            local path=graph:pathFromTo(node.id,destination)
            -- AD 3.0.1.2 omits the start node from non-trivial paths. Validate
            -- the first outgoing edge too; also accept APIs that include it.
            local first=path and path[1] and path[1].id==node.id and 2 or 1
            if path and path[first] and path[#path].id==destination then
                local valid=true
                local previous=node
                for j=first,#path do
                    local linked=false
                    for _,out in pairs(previous.out or {}) do if out==path[j].id then linked=true end end
                    if not linked then valid=false; break end
                    previous=path[j]
                end
                local heading=math.atan2(path[first].x-node.x,path[first].z-node.z)
                if valid and (not position.t or math.abs(H.math.delta(position.t,heading))<math.rad(15)) then
                    return node,heading,candidate.site
                end
            end
    end
    return nil,'no connected AD route at the headland'
end

function Q.canFinishExit(driver)
    local data=Q.data(driver)
    if not data.departure then return false,'missing harvested-row evidence' end
    local world,reason=W.new(driver)
    if not world then return false,reason end
    local bodies=W.currentBodies(driver.vehicle)
    local clear=bodies~=nil
    for _,item in ipairs(bodies or {}) do
        if not wholeHeadland(data.departure,W.rectangle(item.body,item.pose))
                or not W.bodyClear(world,item.body,item.pose) then clear=false; break end
    end
    if not clear then W.delete(world); return false,'whole train has not cleared onto harvested headland' end
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    local node,why=Q.connectedNode(driver,here,data.departure,20)
    if node then
        -- Conservative swept boxes cover the short connection and turning room.
        -- They are validation only: CP stops on the headland, then native AD owns
        -- the journey. No AD task is created or modified here.
        local dx,dz=node.x-here.x,node.z-here.z
        for _,item in ipairs(bodies) do
            local x=dx*math.cos(item.pose.t)-dz*math.sin(item.pose.t)
            local z=dx*math.sin(item.pose.t)+dz*math.cos(item.pose.t)
            local margin=distance(here,node)>3 and driver.turningRadius or 0
            local body={left=item.body.left+math.max(0,x)+margin,right=item.body.right+math.min(0,x)-margin,
                front=item.body.front+math.max(0,z)+margin,back=item.body.back+math.min(0,z)-margin}
            if not W.bodyClear(world,body,item.pose,nil,true) then
                data.failedConnections=data.failedConnections or {}
                data.failedConnections[node.id]=g_currentMission.time+15000
                node=nil; why='perimeter connection obstructed'; break
            end
        end
    end
    W.delete(world)
    return node~=nil,why
end

function Q.finishExit(driver)
    local ok,reason=Q.canFinishExit(driver)
    if ok then
        Q.data(driver).handover=true
        driver:onTrailerFull()
    else
        local data=Q.data(driver)
        data.nextAttempt=g_currentMission.time+3000
        Q.reason(data,reason)
    end
end

function Q.priority(driver,combine)
    if not Q.enabled(driver) or not combine or not driver.vehicle:getIsCpActive()
            or not AIDriveStrategyCombineCourse.isActiveCpCombine(combine) then return false end
    -- Native continuous-harvester following already handles its own harvester's proximity
    -- and turns. Other queued/approaching trailers still yield to it normally.
    if driver.combineToUnload==combine and combine:getCpDriveStrategy():alwaysNeedsUnloader() and not Q.owns(driver) then
        return false
    end
    local data=Q.data(driver)
    if data.operation=='yield' and Q.owns(driver) then return true end
    data.resumeExit=Q.owns(driver) and data.operation=='exit'
    -- Native searches are advanced synchronously by this controller; removing
    -- its runner prevents a superseded callback after clearance. The next native
    -- call installs its own context/listeners in the ordinary way.
    if driver.pathfinderController then driver.pathfinderController.pathfinder=nil end
    Q.capture(driver)
    driver:releaseCombine()
    Q.take(driver,'yield')
    data.priorityCombine=combine
    data.nextAttempt=0
    data.yieldSide=nil
    return true
end

function Q.yieldTarget(driver,checkOnly)
    local data=Q.data(driver)
    local combine=data.priorityCombine
    if not combine or not combine:getIsCpActive() then
        if data.resumeExit then Q.take(driver,'exit') else Q.release(driver) end
        return
    end
    local pose=W.pose(combine:getAIDirectionNode())
    local width=combine:getCpDriveStrategy():getWorkWidth()+4
    local corridor=G.rectangle({x=pose.x,z=pose.z,heading=pose.t},
        {width=width,length=50,zOffset=20},0)
    local bodies=W.currentBodies(driver.vehicle)
    local blocked=false
    for _,item in ipairs(bodies or {}) do if G.overlap(W.rectangle(item.body,item.pose),corridor) then blocked=true end end
    if bodies and not blocked then
        if data.resumeExit then Q.take(driver,'exit') else Q.release(driver) end
        return
    end
    if checkOnly then return true end
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    local lateral=(here.x-pose.x)*math.cos(pose.t)-(here.z-pose.z)*math.sin(pose.t)
    local side=lateral>=0 and 1 or -1
    local function accepts(poses,model)
        for i,p in ipairs(poses) do if G.overlap(W.rectangle(model.bodies[i],p),corridor) then return false end end
        return true
    end
    local choices={}
    for _,lateralSide in ipairs({side,-side}) do
        local p=G.point({x=here.x,z=here.z,heading=here.t},lateralSide*(width/2+8),
            math.max(40,3*driver.turningRadius))
        p.t=here.t; p.accept=accepts; p.clearance=corridor
        choices[#choices+1]=p
    end
    for _,length in ipairs({10,20,40,60}) do
        local reverse=G.point({x=here.x,z=here.z,heading=here.t},0,-length)
        reverse.t=here.t; reverse.reverse=true; reverse.accept=accepts; reverse.clearance=corridor
        choices[#choices+1]=reverse
    end
    local target={x=choices[1].x,z=choices[1].z,t=here.t,choices=choices}
    return target
end
