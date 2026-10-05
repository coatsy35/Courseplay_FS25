-- Re-entry-safe queue-only search. No native solver settings or coroutines.
CpUnloaderQueueSearch = {}
local S = CpUnloaderQueueSearch
local H = HeadlandLoopGeometry
local W = CpUnloaderQueueWorld

local function distance(a,b) return math.sqrt((a.x-b.x)^2+(a.z-b.z)^2) end
local function push(heap,node)
    local i=#heap+1
    while i>1 do
        local parent=math.floor(i/2)
        if heap[parent].cost<=node.cost then break end
        heap[i]=heap[parent]; i=parent
    end
    heap[i]=node
end
local function pop(heap)
    local first,last=heap[1],table.remove(heap)
    if #heap>0 then
        local i=1
        while i*2<=#heap do
            local child=i*2
            if child<#heap and heap[child+1].cost<heap[child].cost then child=child+1 end
            if last.cost<=heap[child].cost then break end
            heap[i]=heap[child]; i=child
        end
        heap[i]=last
    end
    return first
end
local function key(poses)
    local p=poses[1]
    local parts={math.floor(p.x),math.floor(p.z),math.floor((p.t%(2*math.pi))/math.rad(6))}
    for i=2,#poses do parts[#parts+1]=math.floor(H.math.delta(p.t,poses[i].t)/math.rad(10)) end
    return table.concat(parts,':')
end

function S.new(world,goal,corridor)
    local poses=W.poses(world.model)
    local clear,reason=W.clear(world,poses,corridor)
    if not clear then return nil,'start: '..reason,'start' end
    local parked=W.settledPoses(world.model,goal)
    clear,reason=W.clear(world,parked,corridor)
    if not clear then return nil,'destination: '..reason,'destination' end
    if goal.accept and not goal.accept(parked,world.model) then return nil,'whole train cannot occupy target' end
    local radius=H.minimumRadius(world.model,world.strategy.turningRadius)
    if not radius then return nil,'no supported turning radius' end
    local root={poses=poses,distance=0,cost=distance(poses[1],goal)}
    local search={world=world,goal=goal,corridor=corridor,radius=radius,open={root},seen={},expanded=0,root=root}
    local start=State3D(poses[1].x,-poses[1].z,CpMathUtil.angleFromGame(poses[1].t))
    local target=State3D(goal.x,-goal.z,CpMathUtil.angleFromGame(goal.t))
    local solution=not goal.reverse and DubinsSolver():solve(start,target,radius)
    if goal.reverse then
        local reference=world.strategy.ppc:getReverserNode(true)
        for i,link in ipairs(world.model.links) do
            if link.node==reference and not link.positionNode then search.trackingIndex=i+1 end
        end
        if reference==world.strategy.vehicle:getAIDirectionNode() then search.trackingIndex=1 end
        if not search.trackingIndex then return nil,'unsupported reverse tracking node' end
        for _,p in ipairs(poses) do
            if math.abs(H.math.delta(p.t,goal.t))>math.rad(2) then return nil,'reverse requires aligned train' end
        end
        search.reverse=true
        search.direct={start,target}
        search.directIx=2; search.directNode=root
    elseif solution and solution:getLength(radius)<math.max(100,3*distance(poses[1],goal)) then
        search.direct=solution:getWaypoints(start,radius)
        search.directIx=2
        search.directNode=root
    end
    return search
end

local function settled(search,poses)
    for _,pose in ipairs(poses) do
        if math.abs(H.math.delta(pose.t,search.goal.t))>math.rad(10) then return false end
    end
    return not search.goal.accept or search.goal.accept(poses,search.world.model)
end

local function route(node,search)
    local edges={}
    while node.parent do table.insert(edges,1,node.segment); node=node.parent end
    local result={{x=node.poses[1].x,z=node.poses[1].z,t=node.poses[1].t,clear=false}}
    if search.reverse then
        result.reverse=true
        result[1].trackX=node.poses[search.trackingIndex].x
        result[1].trackZ=node.poses[search.trackingIndex].z
    end
    for _, edge in ipairs(edges) do for _, pose in ipairs(edge) do result[#result+1]=pose end end
    return result
end

-- Each edge is sampled at <=0.5 m and <=2 degrees. Work can yield halfway
-- through an edge, so one complex train cannot consume a whole frame's search.
local function beginEdge(search,parent,target)
    local start=parent.poses[1]
    search.edge={parent=parent,target=target,poses=parent.poses,segment={},step=0,
        count=math.max(1,math.ceil(distance(start,target)/0.5),
            math.ceil(math.abs(H.math.delta(start.t,target.t))/math.rad(2)))}
end

function S.step(search,budget)
    if search.choices then return S.stepChoices(search,budget) end
    if search.done then return true,search.path,search.reason end
    for _=1,budget do
        if search.edge then
            local edge=search.edge
            edge.step=edge.step+1
            local f=edge.step/edge.count
            local a,b=edge.parent.poses[1],edge.target
            local root={x=a.x+(b.x-a.x)*f,z=a.z+(b.z-a.z)*f,t=a.t+H.math.delta(a.t,b.t)*f}
            local poses=H.advance(search.world.model,edge.poses,root)
            if search.reverse then
                root.trackX=poses[search.trackingIndex].x; root.trackZ=poses[search.trackingIndex].z
            end
            root.clear=true
            if search.goal.clearance then
                for i,body in ipairs(search.world.model.bodies) do
                    if CpUnloaderQueueGeometry.overlap(W.rectangle(body,poses[i]),search.goal.clearance) then root.clear=false end
                end
            end
            local swept=false
            for i,body in ipairs(search.world.model.bodies) do
                local before,after=W.rectangle(body,edge.poses[i],0),W.rectangle(body,poses[i],0)
                for j=1,4 do if distance(before[j],after[j])>0.25 then swept=true end end
            end
            if swept then
                edge.count=edge.count*2; edge.step=0; edge.poses=edge.parent.poses; edge.segment={}
                if edge.count>4096 then search.done=true; return true,nil,'unbounded rig movement' end
            else
            local ok,reason=W.clear(search.world,poses,search.corridor)
            if not ok then
                search.edge=nil; search.reason=reason
                if search.direct then search.direct=nil end
            else
                edge.poses=poses; edge.segment[#edge.segment+1]=root
                if edge.step==edge.count then
                    local travelled=edge.parent.distance+distance(a,b)
                    local node={poses=poses,parent=edge.parent,segment=edge.segment,distance=travelled,
                        cost=travelled+distance(root,search.goal)}
                    search.edge=nil
                    if search.direct then
                        search.directNode=node
                        search.directIx=search.directIx+1
                        if search.directIx>#search.direct then
                            if settled(search,poses) then
                                search.done=true; search.path=route(node,search); return true,search.path
                            end
                            search.direct=nil
                        end
                    elseif distance(root,search.goal)<1.5 and math.abs(H.math.delta(root.t,search.goal.t))<math.rad(6)
                            and settled(search,poses) then
                        search.done=true; search.path=route(node,search); return true,search.path
                    else
                        local k=key(poses)
                        if not search.seen[k] or travelled<search.seen[k] then
                            search.seen[k]=travelled; push(search.open,node)
                        end
                    end
                end
            end
            end
        elseif search.direct then
            local n=search.direct[search.directIx]
            if not n then search.direct=nil else
                beginEdge(search,search.directNode,{x=n.x,z=-n.y,t=CpMathUtil.angleToGame(n.t)})
            end
        else
            if search.directOnly or search.reverse then search.done=true; return true,nil,search.reason or 'no safe direct clearance' end
            if not search.parent or search.steer>1 then
                if #search.open==0 or search.expanded>=6000 then
                    search.done=true; return true,nil,search.reason or 'no safe queue route'
                end
                search.parent=pop(search.open); search.steer=-1; search.expanded=search.expanded+1
            end
            local a=search.parent.poses[1]
            local turn=search.steer*2/search.radius
            local t=a.t+turn
            local target
            if search.steer==0 then target={x=a.x+2*math.sin(a.t),z=a.z+2*math.cos(a.t),t=t}
            else
                local r=search.radius/search.steer
                target={x=a.x+r*(math.cos(a.t)-math.cos(t)),z=a.z+r*(math.sin(t)-math.sin(a.t)),t=t}
            end
            search.steer=search.steer+1
            if search.parent.distance<math.max(120,3*distance(search.root.poses[1],search.goal)) then
                beginEdge(search,search.parent,target)
            end
        end
    end
    return false
end

function S.choices(world,goals)
    return {world=world,choices=goals,index=1}
end

function S.stepChoices(search,budget)
    if search.index>#search.choices then
        if search.best then return true,search.best end
        -- If no simple manoeuvre fits, try a bounded obstacle-avoiding forward
        -- search. It retains precisely the same crop and whole-train checks.
        search.fallbackIndex=search.fallbackIndex or 1
        while not search.fallback and search.fallbackIndex<=#search.choices do
            local goal=search.choices[search.fallbackIndex]
            search.fallbackIndex=search.fallbackIndex+1
            if not goal.reverse then search.fallback,search.reason=S.new(search.world,goal) end
            return false
        end
        if not search.fallback then return true,nil,search.reason end
        local done,path,reason=S.step(search.fallback,budget)
        if done and not path then search.fallback=nil; search.reason=reason; return false end
        return done,path,reason
    end
    if not search.active then
        search.active,search.reason=S.new(search.world,search.choices[search.index])
        if not search.active then search.index=search.index+1; return false end
        search.active.directOnly=true
    end
    local done,path,reason=S.step(search.active,budget)
    if done then
        if path then
            local d,clearDistance,previousBlocked=0,0,true
            for i=2,#path do
                d=d+distance(path[i-1],path[i])
                if previousBlocked or not path[i].clear then clearDistance=d end
                previousBlocked=not path[i].clear
            end
            local speed=path.reverse and search.world.strategy.settings.reverseSpeed:getValue()/3.6
                or math.min(15,search.world.strategy:getFieldSpeed())/3.6
            local time=clearDistance/math.max(1,speed)
            if not search.bestTime or time<search.bestTime then search.best=path; search.bestTime=time end
        else search.reason=reason end
        search.active=nil; search.index=search.index+1
    end
    return false
end
