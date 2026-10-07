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
    local index=saved.headlandIndex
    if not index or index.source~=saved.headlands or index.width~=saved.width then
        index={source=saved.headlands,width=saved.width,cells={}}
        local w=saved.width
        for _,band in ipairs(saved.headlands) do
            for i=2,#band do
                local a,b=band[i-1],band[i]
                for x=math.floor((math.min(a.x,b.x)-w/2)/w),math.floor((math.max(a.x,b.x)+w/2)/w) do
                    for z=math.floor((math.min(a.z,b.z)-w/2)/w),math.floor((math.max(a.z,b.z)+w/2)/w) do
                        local key=x..':'..z
                        index.cells[key]=index.cells[key] or {}
                        table.insert(index.cells[key],{a,b})
                    end
                end
            end
        end
        saved.headlandIndex=index
    end
    local segments=index.cells[math.floor(p.x/saved.width)..':'..math.floor(p.z/saved.width)]
    for _,segment in ipairs(segments or {}) do
        if nearSegment(p,segment[1],segment[2],saved.width/2) then return true end
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

-- Geometric guidance only. Every short leg is still searched and checked with
-- the live articulated rig, crop density, boundary and collision detector.
local function project(line,p)
    local best,total= nil,0
    for i=2,#line do
        local a,b=line[i-1],line[i]
        local length=distance(a,b)
        if length>0.001 then
            local f=math.max(0,math.min(1,((p.x-a.x)*(b.x-a.x)+(p.z-a.z)*(b.z-a.z))/(length*length)))
            local q={x=a.x+f*(b.x-a.x),z=a.z+f*(b.z-a.z)}
            local d=distance(p,q)
            if not best or d<best.distance then best={s=total+f*length,distance=d} end
            total=total+length
        end
    end
    return best,total
end

local function along(line,s,direction)
    for i=2,#line do
        local a,b=line[i-1],line[i]
        local length=distance(a,b)
        if length>0.001 then
            if s<=length or i==#line then
                local f=math.max(0,math.min(1,s/length))
                local heading=math.atan2(b.x-a.x,b.z-a.z)
                local entryBend,exitBend=0,0
                if i>2 then
                    local previous=line[i-2]
                    entryBend=math.abs(H.math.delta(heading,math.atan2(a.x-previous.x,a.z-previous.z)))
                end
                if i<#line then
                    local nextPoint=line[i+1]
                    exitBend=math.abs(H.math.delta(heading,math.atan2(nextPoint.x-b.x,nextPoint.z-b.z)))
                end
                return {x=a.x+f*(b.x-a.x),z=a.z+f*(b.z-a.z),
                    t=heading+(direction<0 and math.pi or 0),
                    entryDistance=direction>0 and s or length-s,
                    exitDistance=direction>0 and length-s or s,segment=i,
                    entryBend=direction>0 and entryBend or exitBend,
                    exitBend=direction>0 and exitBend or entryBend}
            end
            s=s-length
        end
    end
end

-- A small junction graph links adjoining headland bands. Long curved sections
-- remain polylines, not straight shortcuts between graph vertices.
local function headlandRoute(saved,from,to)
    local graph=saved.exitGraph
    if not graph or graph.source~=saved.headlands then
        graph={source=saved.headlands,bands={},nodes={},links={}}
        local function add(b,s)
            for _,id in ipairs(b.marks) do if math.abs(graph.nodes[id].s-s)<0.01 then return id end end
            local p=along(b.line,s,1)
            p.s=s; graph.nodes[#graph.nodes+1]=p
            local id=#graph.nodes; b.marks[#b.marks+1]=id; return id
        end
        for _,line in ipairs(saved.headlands) do
            local _,length=project(line,from)
            if length>0 then
                local b={line=line,length=length,marks={}}
                graph.bands[#graph.bands+1]=b
                b.first=add(b,0); b.last=add(b,length)
                if distance(line[1],line[#line])<=saved.width then
                    graph.links[#graph.links+1]={b.first,b.last}
                end
            end
        end
        for _,b in ipairs(graph.bands) do
            for _,endpoint in ipairs({b.first,b.last}) do
                for _,other in ipairs(graph.bands) do
                    if other~=b then
                        local p=project(other.line,graph.nodes[endpoint])
                        if p.distance<=saved.width+0.01 then
                            graph.links[#graph.links+1]={endpoint,add(other,p.s)}
                        end
                    end
                end
            end
        end
        saved.exitGraph=graph
    end
    local nodes,edges={},{}
    for i,p in ipairs(graph.nodes) do nodes[i]=p; edges[i]={} end
    local function add(p) nodes[#nodes+1]=p; edges[#nodes]={}; return #nodes end
    local start,finish=add(from),add(to)
    local function link(a,b,line)
        local cost=line and math.abs(nodes[b].s-nodes[a].s) or distance(nodes[a],nodes[b])
        edges[a][#edges[a]+1]={to=b,cost=cost,line=line}
        edges[b][#edges[b]+1]={to=a,cost=cost,line=line}
    end
    for _,pair in ipairs(graph.links) do link(pair[1],pair[2]) end
    for _,band in ipairs(graph.bands) do
        local marks={}
        for _,id in ipairs(band.marks) do marks[#marks+1]=id end
        for _,id in ipairs({start,finish}) do
            local q=project(band.line,nodes[id])
            if q.distance<=saved.width then
                local p=along(band.line,q.s,1); p.s=q.s
                local mark=add(p); marks[#marks+1]=mark; link(id,mark)
            end
        end
        table.sort(marks,function(a,b) return nodes[a].s<nodes[b].s end)
        for i=2,#marks do link(marks[i-1],marks[i],band.line) end
    end
    local cost,previous,visited={[start]=0},{},{}
    while true do
        local best
        for id,value in pairs(cost) do
            if not visited[id] and (not best or value<cost[best]) then best=id end
        end
        if not best then return end
        if best==finish then break end
        visited[best]=true
        for _,edge in ipairs(edges[best]) do
            local nextCost=cost[best]+edge.cost
            if not cost[edge.to] or nextCost<cost[edge.to] then
                cost[edge.to]=nextCost; previous[edge.to]={from=best,line=edge.line}
            end
        end
    end
    local chain,id={},finish
    while id~=start do
        local edge=previous[id]
        table.insert(chain,1,{a=nodes[edge.from],b=nodes[id],line=edge.line})
        id=edge.from
    end
    local route={from}
    local function append(p)
        if distance(route[#route],p)>0.01 then route[#route+1]={x=p.x,z=p.z} end
    end
    for _,edge in ipairs(chain) do
        if edge.line then
            local points,s={},0
            for i=2,#edge.line do
                s=s+distance(edge.line[i-1],edge.line[i])
                if s>math.min(edge.a.s,edge.b.s) and s<math.max(edge.a.s,edge.b.s) then
                    points[#points+1]=edge.line[i]
                end
            end
            if edge.b.s>=edge.a.s then for _,p in ipairs(points) do append(p) end
            else for i=#points,1,-1 do append(points[i]) end end
        end
        append(edge.b)
    end
    return route,cost[finish]
end

local function wholeTrain(saved,model,poses)
    for i,p in ipairs(poses) do
        if not wholeHeadland(saved,W.rectangle(model.bodies[i],p)) then return false end
    end
    return true
end

local function exitCorridor(driver,saved,model)
    -- Row-start waypoints stop short of the headland centreline. Join the two
    -- guide bands explicitly; otherwise a narrow work width leaves an impassable
    -- gap even on harvested ground. Live crop and collision checks still apply.
    local joins={}
    local start=saved.row[1]
    if start then
        for _,band in ipairs(saved.headlands) do
            local join=project(band,start)
            if join and join.distance<=2*saved.width then
                joins[#joins+1]={start,along(band,join.s,1)}
            end
        end
    end
    -- Native reverse/traffic clearance can leave the rig outside the saved
    -- combine-centred band. Admit a local re-entry from its actual position,
    -- frozen for this search, rather than rejecting every retry at its start.
    local origin=W.pose(driver.vehicle:getAIDirectionNode())
    local reach=2*driver.turningRadius
    for i,pose in ipairs(W.poses(model)) do
        for _,p in ipairs(W.rectangle(model.bodies[i],pose)) do reach=math.max(reach,distance(origin,p)+0.5) end
    end
    local row=project(saved.row,origin)
    local rejoin=row and row.distance<=reach+saved.width and along(saved.row,row.s,1)
    return function(rectangle)
        for _,p in ipairs(rectangle) do
            local allowed=onHeadland(saved,p)
            for i=2,#saved.row do
                if nearSegment(p,saved.row[i-1],saved.row[i],saved.width) then allowed=true; break end
            end
            for _,join in ipairs(joins) do
                if nearSegment(p,join[1],join[2],saved.width) then allowed=true; break end
            end
            if rejoin and nearSegment(p,origin,rejoin,reach) then allowed=true end
            if distance(p,saved.position)<2*driver.turningRadius then allowed=true end
            if not allowed then return false end
        end
        return true
    end
end

function Q.exitTarget(driver)
    local data=Q.data(driver)
    if not data.departure then Q.recoverDeparture(driver) end
    local saved=data.departure
    if not saved then Q.reason(data,'no saved harvested row; retaining CP control'); return end
    local model,why=W.model(driver.vehicle)
    if not model then Q.reason(data,why); return end
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    local runIn=0
    for _,link in ipairs(model.links) do runIn=runIn+link.length end
    runIn=math.max(10,3*runIn)
    local legLength=math.max(50,runIn+driver.turningRadius)
    local corridor=exitCorridor(driver,saved,model)
    local headland=wholeTrain(saved,model,W.poses(model))
    local accept=function(poses,m) return wholeTrain(saved,m,poses) end
    local function available(goal,onHeadlandRequired)
        if not goal or not Q.targetAvailable(driver,goal) then return false end
        if onHeadlandRequired and not accept(W.settledPoses(model,goal),model) then return false end
        goal.accept=onHeadlandRequired and accept or nil
        return true
    end
    if not headland then
        -- Return down the row in short legs before selecting a perimeter exit.
        local row=project(saved.row,here)
        local nearestHeadland
        for _,band in ipairs(saved.headlands) do
            local join=project(band,saved.row[1] or here)
            if join and (not nearestHeadland or join.distance<nearestHeadland) then nearestHeadland=join.distance end
        end
        -- A 50 m row leg is not permission to start a diagonal turn 50 m
        -- before the headland. First reach a fixed approach on the saved row,
        -- with the tractor's turning arc and front overhang near the join.
        local approach=math.max(0,driver.turningRadius+math.max(0,model.bodies[1].front)+0.3-(nearestHeadland or 0))
        if row and row.s>approach+1.5 then
            for _,length in ipairs({50,35,65}) do
                local goal=along(saved.row,math.max(approach,row.s-length),-1)
                if available(goal,false) then
                    goal.exitIntermediate=true; goal.exitStage=row.s>50 and 'row return' or 'row approach'
                    return goal,corridor
                end
            end
            Q.reason(data,'row return targets occupied or temporarily rejected'); return
        end
        -- Turn onto a headland tangent with room for the tail. Do not demand
        -- the road's outgoing heading while the trailer is still in the row.
        local best,score
        local entries={}
        local start=saved.row[1] or here
        for _,band in ipairs(saved.headlands) do
            local join,total=project(band,start)
            if join and join.distance<=2*saved.width then
                for _,direction in ipairs({1,-1}) do
                    local remaining=direction>0 and total-join.s or join.s
                    for _,length in ipairs({legLength,legLength+15,legLength+30,
                            math.max(0,math.min(legLength+30,remaining-5))}) do
                        local s=join.s+direction*length
                        if length>=runIn and s>=0 and s<=total then
                            local goal=along(band,s,direction)
                            local cost=distance(here,goal)+join.distance
                            if available(goal,true) then
                                entries[#entries+1]={goal=goal,cost=cost}
                                if not score or cost<score then best,score=goal,cost end
                            end
                        end
                    end
                end
            end
        end
        table.sort(entries,function(a,b) return a.cost<b.cost end)
        -- Prefer entering the lane/direction that already connects to AD. The
        -- nearest inner headland can otherwise leave the rig facing a needless
        -- lane-change loop after it has completed the turn out of the row.
        for i,entry in ipairs(entries) do
            if i>8 then break end
            if Q.connectedNode(driver,entry.goal,saved,20) then best=entry.goal; break end
        end
        if best then best.exitIntermediate=true; best.exitStage='headland entry'; return best,corridor end
        Q.reason(data,'no whole-train headland entry available'); return
    end

    local radius=0
    for _,band in ipairs(saved.headlands) do
        for _,p in ipairs(band) do radius=math.max(radius,distance(here,p)) end
    end
    local selected
    local function selectStage(node,heading,site)
        -- A node at the crop edge is not automatically a valid parking pose.
        -- Try nearby poses along its direction, always within handover range.
        for _,shift in ipairs({0,8,-8,16,-16}) do
            local terminal={x=site.x+shift*math.sin(heading),z=site.z+shift*math.cos(heading),t=heading}
            if distance(terminal,node)<=20 and available(terminal,true) then
                local best
                local guide,total=headlandRoute(saved,here,terminal)
                if guide then
                    for _,advance in ipairs({legLength,legLength+15,legLength+30,legLength-15}) do
                        local goal=terminal
                        local usable=true
                        if total>advance then
                            goal=along(guide,advance,1)
                            -- Avoid stopping just past a bend: there would be
                            -- insufficient straight distance to align the tail.
                            usable=goal and (goal.entryBend<math.rad(30) or goal.entryDistance>=runIn+driver.turningRadius)
                                and (goal.exitBend<math.rad(30) or goal.exitDistance>=driver.turningRadius)
                            if goal then goal.exitIntermediate=true; goal.exitStage='headland transit' end
                        end
                        if usable and available(goal,true) then best=goal; break end
                    end
                end
                if best then selected=best; return true end
            end
        end
        return false
    end
    local node,reason=Q.connectedNode(driver,{x=here.x,z=here.z},saved,radius+21,selectStage)
    if node then selected.exitStage=selected.exitStage or 'AD approach'; return selected,corridor end
    Q.reason(data,reason)
end

function Q.connectedNode(driver,position,saved,range,selectStage)
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
        if site and not banned and (selectStage or Q.targetAvailable(driver,site)) then
            candidates[#candidates+1]={node=node,site=site}
        end
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
                if valid and (not position.t or math.abs(H.math.delta(position.t,heading))<math.rad(15))
                        and (not selectStage or selectStage(node,heading,candidate.site)) then
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
        driver:debug('Queue: validated headland departure; invoking native full-trailer handover')
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
