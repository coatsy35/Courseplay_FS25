--[[
Envelope-aware row turns. GPL-3.0-or-later, like the surrounding Courseplay code.

This module contains no GIANTS scene access. EnvelopeTurnGeometry supplies a
snapshot of the attached equipment; EnvelopeCourseTurn owns execution. Keeping
the numerical planner separate makes the EXACT Lua shipped in the mod testable
in the offline bench. The shared Dubins solver is deliberately unchanged.

Coordinates are GIANTS x/z, metres, radians; heading zero points along +z.
An implement marker is stored in the tractor frame (mounted), or relative to
the hitch in the trailer's heading (trailed). Both front AND rear work edges
must arrive on their nominal row lines. Tractor heading alone is insufficient.
]]
EnvelopeTurnPlanner = {}
local E = EnvelopeTurnPlanner
E.angleTolerance = math.rad(2)
-- Allow small tracking/settling differences without admitting a visibly
-- curved entry. Bound the width-relative lateral allowance; heading and
-- collision checks remain independent. Planning reserves 40%, repair 20%.
function E.entryTolerance(p)
    return math.max(0.1,math.min(0.25,p.width*0.05))
end
E.reserve = 0.5
-- Shared with the live lowering gate: align BEFORE stopping, not only at the
-- later boundary-crossing sample. The tractor brakes towards 0.5 m clearance.
E.loweringGateContact = -0.65

-- Use the same raised deployment allowance for speculative and live plans.
-- Try the full preparation allowance first, then a compact measured-lever
-- allowance. Every candidate still needs alignment and footprint validation.
function E.deploymentLead(p, initial)
    local front,back=-math.huge,math.huge
    for _,m in ipairs(p.work) do front=math.max(front,m.z);back=math.min(back,m.z) end
    -- Deployment space describes the machine and the row, not cruising speed.
    -- Brake along the incoming route; adding v^2/2 here moves the target into
    -- the outer boundary when the user raises CP's turn-speed setting.
    -- Keep a tracking lookahead at both transitions: arrival at the raised
    -- deployment pose and departure onto the working-position approach.
    local reserve=2*p.lookahead+math.abs(p.slope)*p.width/2
    local full=math.max(p.length or 0,front-back)+reserve
    if initial then return p.width/2+reserve end
    return full,math.max(p.width,p.length or 0)/2+reserve
end

-- Remaining course distance to a predicted stopping pose. PPC's current
-- waypoint leads the tractor; include that lead and subtract the stop's own
-- offset from its waypoint. Before the final straight, this includes the arc.
function E.distanceToStop(path,ix,state,stop,heading)
    local _,straight=E.localPoint(stop,{x=state.x,z=state.z,t=heading})
    if ix>stop.ix then return math.max(0,straight) end
    local point=path[ix]
    local distance=math.sqrt((point.x-state.x)^2+(point.z-state.z)^2)
    for i=ix,stop.ix-1 do
        local a,b=path[i],path[i+1]
        distance=distance+math.sqrt((b.x-a.x)^2+(b.z-a.z)^2)
    end
    local last=path[stop.ix]
    local _,offset=E.localPoint(stop,{x=last.x,z=last.z,t=heading})
    return math.max(0,distance+offset)
end

function E.wrap(a)
    return math.atan2(math.sin(a), math.cos(a))
end

function E.point(x, z, heading, across, along)
    return {x = x + across * math.cos(heading) + along * math.sin(heading),
        z = z - across * math.sin(heading) + along * math.cos(heading)}
end

function E.localPoint(p, reference)
    local dx, dz = p.x - reference.x, p.z - reference.z
    return dx * math.cos(reference.t) - dz * math.sin(reference.t),
        dx * math.sin(reference.t) + dz * math.cos(reference.t)
end

-- Deployment is a separate raised-state admission, shared by the predictor
-- and the live controller. A straight tractor with a jack-knifed implement
-- must keep drawing forwards; it must never trigger turnover at that point.
function E.canDeploy(p, state)
    local lateral=E.localPoint(state,p.goal)
    return math.abs(lateral)<=math.min(0.5,p.width*0.1)
        and math.abs(E.wrap(state.t-p.goal.t))<=E.angleTolerance
        and (not p.length or math.abs(E.wrap(state.phi-p.goal.t))<=E.angleTolerance)
end

-- Shared by prediction and live target conversion. CP's combination radius is
-- a minimum for this manoeuvre, not the tractor's unrestricted steering lock.
function E.pursuitCurvature(p,state,gx,gz)
    local dx,dz=gx-state.x,gz-state.z
    return math.max(-1/p.radius,math.min(1/p.radius,
        2*(dx*math.cos(state.t)-dz*math.sin(state.t))/math.max(0.01,dx*dx+dz*dz)))
end

function E.marker(p, state, marker)
    if marker.towed then
        local hitch = E.point(state.x, state.z, state.t, p.hitchX, p.hitchZ)
        return E.point(hitch.x, hitch.z, state.phi, marker.x, marker.z)
    end
    return E.point(state.x, state.z, state.t, marker.x, marker.z)
end

-- Compare each corner with where THAT corner belongs when the whole rig is
-- straight. This preserves asymmetric ploughs, front tools and tool offsets.
-- The work-start node already includes CP's next-row/plough side correction.
function E.assess(p, state)
    local error, angle, contact = 0, 0, -math.huge
    local rearError = 0
    local minError,maxError=math.huge,-math.huge
    for _, marker in ipairs(p.work) do
        local v = E.marker(p, state, marker)
        local x, z = E.localPoint(v, p.goal)
        local expectedX = marker.x + (marker.towed and p.hitchX or 0)
        local d = x - expectedX
        minError,maxError=math.min(minError,d),math.max(maxError,d)
        error = math.max(error, math.abs(d))
        angle = math.max(angle, math.abs(E.wrap((marker.towed and state.phi or state.t) - p.goal.t)))
        if marker.rear then rearError = d end
        -- Local inner boundary: z = slope * (x - workCentreX). On a pike the
        -- first soil-engaging corner reaches it before the centre of the tool.
        if not marker.rear then
            contact = math.max(contact, z - p.slope * (x - p.workCentreX))
        end
    end
    return error <= E.entryTolerance(p) and angle <= E.angleTolerance,
        error, angle, contact, rearError,(minError+maxError)/2,minError,maxError
end

local function segmentDistanceSquared(p, a, b)
    local dx, dz = b.x - a.x, b.z - a.z
    local t = math.max(0, math.min(1, ((p.x-a.x)*dx + (p.z-a.z)*dz) / math.max(1e-12, dx*dx+dz*dz)))
    return (p.x-a.x-t*dx)^2 + (p.z-a.z-t*dz)^2
end

-- Even/odd containment also works for concave fields. Do not replace this with
-- a bounding rectangle: that admits paths through the notch of an irregular field.
function E.inside(point, polygon, reserve)
    local inside = false
    local a = polygon[#polygon]
    for _, b in ipairs(polygon) do
        if reserve and segmentDistanceSquared(point, a, b) < reserve * reserve then return false end
        if (a.z > point.z) ~= (b.z > point.z) and
                point.x < (b.x-a.x)*(point.z-a.z)/(b.z-a.z)+a.x then
            inside = not inside
        end
        a = b
    end
    return inside
end

function E.outside(point, polygon, reserve)
    if E.inside(point,polygon) then return false end
    local a=polygon[#polygon]
    for _,b in ipairs(polygon) do
        if segmentDistanceSquared(point,a,b)<reserve*reserve then return false end
        a=b
    end
    return true
end

-- Index edges by horizontal bands once, rather than walking every field edge
-- for every tractor/tool sample. Both ray crossings and reserved-edge checks
-- can only involve segments whose z range reaches this band. No polygon
-- simplification, enlarged field or reduced clearance is involved.
function E.polygonChecker(polygon,reserve,wantInside)
    local bands={}
    local a=polygon[#polygon]
    for _,b in ipairs(polygon) do
        local edge={a,b}
        for band=math.floor((math.min(a.z,b.z)-reserve)/4),math.floor((math.max(a.z,b.z)+reserve)/4) do
            bands[band]=bands[band] or {}
            bands[band][#bands[band]+1]=edge
        end
        a=b
    end
    return function(point)
        local inside=false
        for _,edge in ipairs(bands[math.floor(point.z/4)] or {}) do
            local a,b=edge[1],edge[2]
            if segmentDistanceSquared(point,a,b)<reserve*reserve then return false end
            if (a.z>point.z)~=(b.z>point.z) and
                    point.x<(b.x-a.x)*(point.z-a.z)/(b.z-a.z)+a.x then inside=not inside end
        end
        return inside==wantInside
    end
end

-- Body edges are sampled too: four corners alone can straddle a concave hedge
-- or an island. The 0.5 m reserve covers the <=0.4 m spatial samples between
-- checks. The runtime adapter supplies the detected field polygon and island
-- exclusions; ground density is not a substitute for those boundaries.
function E.checkFootprint(p, state)
    -- Hundreds of sampled edge points share two rigid transforms. Calculate
    -- those once per pose, rather than repeating trigonometry and allocating
    -- a point table for every point in every candidate step.
    local st,ct=math.sin(state.t),math.cos(state.t)
    local sp,cp=math.sin(state.phi or state.t),math.cos(state.phi or state.t)
    local hx=state.x+(p.hitchX or 0)*ct+(p.hitchZ or 0)*st
    local hz=state.z-(p.hitchX or 0)*st+(p.hitchZ or 0)*ct
    for _, marker in ipairs(p.footprint) do
        local x,z
        if marker.towed then x,z=hx+marker.x*cp+marker.z*sp,hz-marker.x*sp+marker.z*cp
        else x,z=state.x+marker.x*ct+marker.z*st,state.z-marker.x*st+marker.z*ct end
        if not p.contains(x,z) then return false end
    end
    return true
end

local function addLine(path, from, to)
    local length = math.sqrt((to.x-from.x)^2+(to.z-from.z)^2)
    for i = 1, math.ceil(length / 0.5) do
        local u = math.min(1, i * 0.5 / length)
        path[#path+1] = {x=from.x+(to.x-from.x)*u, z=from.z+(to.z-from.z)*u}
    end
end

-- A bounded cubic joins a sideways-biased Dubins endpoint to the incoming row.
-- Its derivative is zero at both ends. |curvature| <= 6*|bias|/bend^2, allowing
-- rejection of impossible steering before running the trailer simulation.
function E.makePath(p, approach, straight, radius, extension, bias, loopSide)
    local start = E.point(p.start.x, p.start.z, p.start.t, 0, extension)
    start.t = p.start.t
    local goal = E.point(p.goal.x, p.goal.z, p.goal.t, bias, -p.front - approach)
    goal.t = p.goal.t
    local path = {{x=p.start.x, z=p.start.z}}
    addLine(path, p.start, start)
    local arc = p.dubins(start, goal, radius, loopSide)
    if not arc or #arc < 2 then return nil end
    for _, wp in ipairs(arc) do
        local last = path[#path]
        if (wp.x-last.x)^2+(wp.z-last.z)^2 > 1e-6 then path[#path+1] = {x=wp.x,z=wp.z} end
    end
    local bend = approach - straight
    local tailStart = #path
    -- Continue far enough for the front work edge to cross the entire pike.
    -- These final points are tracking support, not a claim of extra headland.
    local continuation = math.max(12, math.abs(p.slope)*p.width + 5)
    for d = 0.5, approach + continuation, 0.5 do
        local u = math.min(1, d / bend)
        local lateral = bias * (1-3*u*u+2*u*u*u)
        path[#path+1] = E.point(p.goal.x, p.goal.z, p.goal.t, lateral, -p.front-approach+d)
    end
    return path, tailStart
end

-- Forward-only planar transcription of PPC's findRelevantSegment/findGoalPoint.
-- Candidate paths have no offsets, reverse sections or callbacks. Keeping their
-- temporary frames as numbers avoids creating/destroying three GIANTS nodes per
-- sample. This is used ONLY to screen candidates; the production PPC still
-- verifies every accepted path and controls the actual vehicle. Parity tests
-- compare its waypoint and goal against PPC, including off-track/endpoint cases.
function E.newPlanarTracker(p,path)
    local frames={}
    for i,q in ipairs(path) do
        local next=path[i+1]
        local t=frames[i-1] and frames[i-1].t or 0
        if next and (next.x~=q.x or next.z~=q.z) then t=math.atan2(next.x-q.x,next.z-q.z) end
        frames[i]={x=q.x,z=q.z,t=t}
    end
    local n=#frames
    local relevant,nextIx,beforeGoal,current,lastPassed=1,1,1,1,nil
    local gx,gz=0,0
    return {delete=function() end,sample=function(_,s)
        local ref=frames[relevant]
        local across,along=E.localPoint(s,ref)
        local lookahead=math.min(p.lookahead+math.abs(across),2*p.lookahead)
        local projected=E.point(ref.x,ref.z,ref.t,0,along)
        for i=nextIx,math.max(nextIx,beforeGoal) do
            local q=frames[math.min(i,n)]
            local dx,dz=E.localPoint(s,q)
            if dz>=0 and dx*dx+dz*dz<(4*(p.trackingRadius or p.radius))^2 then
                lastPassed=math.min(i,n)
                relevant=lastPassed;nextIx=math.min(n,relevant+1)
                break
            end
        end
        for i=relevant,n do
            local a=frames[i]
            local b=frames[i+1] or E.point(a.x,a.z,frames[n-1].t,0,lookahead)
            local q1=math.sqrt((a.x-s.x)^2+(a.z-s.z)^2)
            local q2=math.sqrt((b.x-s.x)^2+(b.z-s.z)^2)
            if i==1 and i~=lastPassed and q1>=lookahead and q2>=lookahead then
                gx,gz=frames[relevant].x,frames[relevant].z
                current=math.max(current,relevant)
                break
            end
            if q1<=lookahead and q2>=lookahead then
                local length=math.sqrt((b.x-a.x)^2+(b.z-a.z)^2)
                if q1<0.0001 then q1=0.1 end -- same zero-distance handling as PPC
                local cosine=(q2*q2-q1*q1-length*length)/(-2*length*q1)
                local distance=q1*cosine+math.sqrt(q1*q1*(cosine*cosine-1)+lookahead*lookahead)
                local goal=E.point(a.x,a.z,a.t,0,distance)
                gx,gz=goal.x,goal.z;beforeGoal=i;current=math.max(current,math.min(n,i+1))
                break
            end
            if i==relevant and q1>=lookahead and q2>=lookahead then
                local distance=math.abs(across)<=lookahead and math.sqrt(lookahead*lookahead-across*across) or 0
                local goal=E.point(projected.x,projected.z,ref.t,0,distance)
                gx,gz=goal.x,goal.z;beforeGoal=i;current=math.max(current,math.min(n,i+1))
                break
            end
        end
        return current,gx,gz
    end}
end

-- A spatial-step pursuit model predicts trailer off-tracking. It is a candidate
-- filter, not GIANTS physics: execution checks live markers again before work.
-- Explicit resumable state: FS25 removes Lua's coroutine library. Each update
-- advances a bounded number of samples and retains the tracker between frames.
function E.newSimulation(p, path, tailStart, step, boundary, collect, optimiseEntry)
    local tracker=p.newTracker and p.newTracker(path,not collect)
    local function finish(result)
        if tracker then tracker:delete() end
        return result
    end
    local s = {x=p.start.x,z=p.start.z,t=p.start.t,phi=p.start.phi or p.start.t}
    local ix, travelled, entered, alignmentLead = 1, 0, false, 0
    local actualCurvature,speed=0,0
    local loweringGatePassed=false
    -- Local steering correction needs an objective over the SAME interval for
    -- every candidate. Stopping at its first failed sample changes the measured
    -- position with the bias, making optimisation chase a moving threshold.
    -- Continue failed alignment trials through entry, retaining every violation;
    -- this never bypasses acceptance, articulation or boundary checks.
    local entryFailure,entryMin,entryMax=nil,math.huge,-math.huge
    local frames = collect and {} or nil
    local maxArticulation, contactError, rearError = 0, math.huge, nil
    local maxDistance = 0
    for i=2,#path do maxDistance=maxDistance+math.sqrt((path[i].x-path[i-1].x)^2+(path[i].z-path[i-1].z)^2) end
    maxDistance = math.min(2000, maxDistance * 1.5 + 20)
    return {update=function(_,budget)
    local samples=0
    while travelled < maxDistance do
        if samples>=budget then return nil end
        samples=samples+1
        local gx,gz
        if tracker then
            ix,gx,gz=tracker:sample(s)
        else
            local bestDistance,nearest=math.huge,ix
            for i=ix,math.min(#path,ix+15) do
                local d=(path[i].x-s.x)^2+(path[i].z-s.z)^2
                if d<bestDistance then bestDistance,nearest=d,i end
            end
            ix=nearest
            local goalIx=ix
            while goalIx<#path and (path[goalIx].x-s.x)^2+(path[goalIx].z-s.z)^2<p.lookahead^2 do goalIx=goalIx+1 end
            gx,gz=path[goalIx].x,path[goalIx].z
        end
        local aligned, error, angle, contact, rear,balanced,minError,maxError = E.assess(p,s)
        -- A raised deployment target is not work admission. It needs a
        -- straight combination with room left for the measured working
        -- correction, not millimetre positioning of folded soil markers.
        local tolerance=p.deploymentTarget and math.min(0.5,p.width*0.1) or
            E.entryTolerance(p)*(p.validationOnly and 1 or (optimiseEntry and 0.8 or 0.6))
        aligned=angle<=E.angleTolerance and error<=tolerance
        if p.deploymentTarget then aligned=aligned and E.canDeploy(p,s) end
        local articulation=math.abs(E.wrap(s.t-s.phi))
        maxArticulation=math.max(maxArticulation,articulation)
        if p.length and articulation > p.maxArticulation then return finish({ok=false,reason='joint angle'}) end
        if boundary and not E.checkFootprint(p,s) then return finish({ok=false,reason='field boundary'}) end
        if collect and (not frames[#frames] or travelled-frames[#frames].distance >= 0.2) then
            frames[#frames+1]={x=s.x,z=s.z,t=s.t,phi=s.phi,distance=travelled,contact=contact,aligned=aligned,ix=ix}
        end
        if p.deploymentApproach and ix>=tailStart then
            local _,longitudinal=E.localPoint(s,p.goal)
            if E.canDeploy(p,s) then
                -- A stock approach can reach its straight too late to deploy
                -- and correct the working-side offset. Reject it while still
                -- raised, before spending that space or turning the plough.
                if p.deploymentLead and -longitudinal<p.deploymentLead then
                    return finish({ok=false,reason='insufficient deployment run-in'})
                end
                -- Only the raised route TO deployment is admitted here.
                -- Execution must stop for turnover and remeasure/revalidate
                -- the working shape before it may follow the remaining line.
                return finish({ok=true,path=path,tailStart=tailStart,frames=frames,entryError=error,
                    maxArticulation=maxArticulation,distance=travelled,requiresDeployment=true})
            end
        end
        if ix >= tailStart then
            alignmentLead = aligned and (alignmentLead+step) or 0
            if optimiseEntry and contact>=E.loweringGateContact then
                entryMin,entryMax=math.min(entryMin,minError),math.max(entryMax,maxError)
            end
            if contact>=E.loweringGateContact and not loweringGatePassed then
                if not aligned then
                    if optimiseEntry then entryFailure='lowering approach alignment'
                    else return finish({ok=false,reason='lowering approach alignment',error=error,rearError=rear,alignmentError=balanced}) end
                end
                loweringGatePassed=true
            end
            if loweringGatePassed and not aligned then
                if optimiseEntry then entryFailure=entryFailure or 'alignment lost after lowering gate'
                else return finish({ok=false,reason='alignment lost after lowering gate',error=error,rearError=rear,alignmentError=balanced}) end
            end
            if contact >= -0.1 and not entered then
                entered=true
                contactError,rearError=error,rear
                -- Hydraulic travel is handled by stopping BEFORE first contact.
                -- We still need a short aligned window in which to stop/lower.
                if not aligned or alignmentLead < p.loweringLead then
                    if optimiseEntry then entryFailure=entryFailure or 'entry alignment'
                    else return finish({ok=false,reason='entry alignment',error=error,rearError=rear,alignmentError=balanced}) end
                end
            end
            if entered and not aligned and not optimiseEntry then return finish({ok=false,reason='alignment lost',rearError=rear}) end
            if entered and contact > 4 then
                if entryFailure then
                    return finish({ok=false,reason=entryFailure,error=math.max(math.abs(entryMin),math.abs(entryMax)),
                        rearError=rearError,alignmentError=(entryMin+entryMax)/2})
                end
                return finish({ok=true,path=path,tailStart=tailStart,frames=frames,entryError=contactError,
                    maxArticulation=maxArticulation,distance=travelled,rearError=rearError,
                    alignmentError=optimiseEntry and (entryMin+entryMax)/2 or balanced,
                    maxEntryError=optimiseEntry and math.max(math.abs(entryMin),math.abs(entryMax)) or nil})
            end
        end
        if ix >= #path then break end
        local k=E.pursuitCurvature(p,s,gx,gz)
        -- Integrate the observed steering delay at the configured approach
        -- speed, including acceleration from rest and the entry braking curve.
        if p.steeringResponseTime then
            local target=(p.approachSpeed or 0)/3.6
            if not p.deploymentTarget then target=math.min(target,math.sqrt(math.max(0.01,2*(-contact-0.5)))) end
            local nextSpeed=math.min(target,math.sqrt(speed*speed+2*step))
            local dt=2*step/math.max(0.1,speed+nextSpeed)
            actualCurvature=actualCurvature+(k-actualCurvature)*(1-math.exp(-dt/p.steeringResponseTime))
            k=actualCurvature;speed=nextSpeed
        end
        local oldHitch=E.point(s.x,s.z,s.t,p.hitchX,p.hitchZ)
        s.x=s.x+step*math.sin(s.t+k*step/2)
        s.z=s.z+step*math.cos(s.t+k*step/2)
        s.t=E.wrap(s.t+k*step)
        if p.length then
            local hitch=E.point(s.x,s.z,s.t,p.hitchX,p.hitchZ)
            local hx,hz=hitch.x-oldHitch.x,hitch.z-oldHitch.z
            -- Exact heading evolution for a straight incremental hitch movement.
            local direction=math.atan2(hx,hz)
            local delta=E.wrap(s.phi-direction)
            s.phi=E.wrap(direction+2*math.atan(math.tan(delta/2)*math.exp(-math.sqrt(hx*hx+hz*hz)/(p.responseLength or p.length))))
        else s.phi=s.t end
        travelled=travelled+step
    end
    return finish({ok=false,reason='tracking did not finish',rearError=rearError})
    end}
end

function E.simulate(p,path,tailStart,step,boundary,collect)
    local simulation=E.newSimulation(p,path,tailStart,step,boundary,collect)
    local result
    repeat result=simulation:update(256) until result
    return result
end

-- Compare short stock-Dubins connections with independent outgoing and
-- incoming leads. This permits asymmetric turns without imposing a bulb shape.
-- Every shortlisted candidate is replayed with the actual implement envelope.
function E.newDirectSearch(p)
    local candidates={}
    -- Shorter connections retain the full measured deployment reserve. The
    -- established fallback alone owns its separately validated compact entry.
    local lead=p.deploymentLead
    local staged={};for k,v in pairs(p) do staged[k]=v end
    staged.goal=E.point(p.goal.x,p.goal.z,p.goal.t,0,-lead);staged.goal.t=p.goal.t
    staged.deploymentLead=nil;staged.deploymentTarget=true
    local lever=math.max(p.width,p.length or 0)
    local factors,families={1,1.25,1.5,2},{'LSL','RSR','LSR','RSL','LRL','RLR'}
    local generated,total=0,4*3*3*3*6
    local index,simulation,verified=1,nil,false
    local rejections={}
    return {getProgress=function() return index-1 end,update=function(_,budget)
        -- Generate one analytic candidate per batch as well as time-slicing
        -- simulation. Building the catalogue must not freeze a game frame.
        if generated<total then
            local n=generated
            local family=families[n%6+1];n=math.floor(n/6)
            local biasIndex=n%3;n=math.floor(n/3)
            local incoming=(n%3+1)*lever;n=math.floor(n/3)
            local outward=(n%3)*p.radius;n=math.floor(n/3)
            local radius=p.radius*factors[n+1]
            local biasLimit=math.min(p.width,incoming*incoming/(6*radius)*0.95)
            local bias=biasIndex==0 and 0 or (biasIndex==1 and -biasLimit or biasLimit)
            local path,tail=E.makePath(staged,incoming,4,radius,outward,bias,family)
            generated=generated+1
            if path then
                local length=lead
                for j=2,#path do length=length+math.sqrt((path[j].x-path[j-1].x)^2+(path[j].z-path[j-1].z)^2) end
                -- Reject analytically outside routes before replaying the
                -- articulated combination. This is screening only: survivors
                -- still require the full swept-envelope/PPC validation.
                local inside=not p.maxRouteLength or length<p.maxRouteLength
                if inside then
                    for _,point in ipairs(path) do
                        if not p.contains(point.x,point.z) then inside=false;break end
                    end
                end
                if inside then
                    candidates[#candidates+1]={path=path,tail=tail,length=length,family=family,bias=bias,
                        radius=radius,bend=incoming-4,straight=4,extension=outward,order=generated}
                end
            end
            if generated==total then
                table.sort(candidates,function(a,b) return a.length==b.length and a.order<b.order or a.length<b.length end)
            end
            return nil
        end
        local c=candidates[index]
        if not c then
            return {ok=false,reason='short connection shortlist exhausted',attempts=index-1,rejections=rejections}
        end
        if not simulation then simulation=E.newSimulation(staged,c.path,c.tail,0.15,true,false) end
        local result=simulation:update(budget)
        if not result then return nil end
        if result.ok and not verified then
            simulation=E.newSimulation(staged,c.path,c.tail,0.075,true,true)
            verified=true;return nil
        end
        simulation=nil;verified=false
        if not result.ok then rejections[result.reason]=(rejections[result.reason] or 0)+1 end
        if result.ok then
            result.attempts=index;result.radius=c.radius;result.bend=c.bend
            result.straight=c.straight;result.extension=c.extension;result.bias=c.bias
            result.deploymentLead=lead;result.directConnection=true;result.routeLength=c.length
            result.pathFamily=c.family
            return result
        end
        index=index+1
        return nil
    end}
end

-- Choose the raised arrival line with the measured deployment transform in
-- mind. Centring the folded tool on the row can leave an offset working tool
-- with no feasible pull-in. Preview the working correction before driving.
function E.newDeploymentSearch(p,working)
    local originalGoal=p.goal
    local _,compact=E.deploymentLead(p,false)
    local pose={x=originalGoal.x,z=originalGoal.z,t=originalGoal.t,
        phi=E.wrap(originalGoal.t+working.deploymentAngle)}
    local _,_,_,_,_,balanced=E.assess(working,pose)
    local offsets={0,-balanced/2,-balanced,balanced/2}
    local index,preview,search=1,nil,nil
    return {delete=function() if working.activeTracker then working.activeTracker:delete() end end,
        getProgress=function() return search and search:getProgress() or 0 end,
        update=function(_,budget)
            if search then return search:update(budget) end
            local offset=offsets[index]
            if offset==nil then
                -- The cached animation is only a prediction. Retain normal
                -- planning when it cannot provide a verified better arrival.
                p.goal=originalGoal;search=E.newSearch(p);return nil
            end
            if not preview then
                working.start=E.point(originalGoal.x,originalGoal.z,originalGoal.t,offset,-compact+p.lookahead)
                working.start.t=originalGoal.t;working.start.phi=pose.phi
                preview=E.newApproachSearch(working)
            end
            local result=preview:update(budget)
            if not result then return nil end
            if result.ok then
                p.goal=E.point(originalGoal.x,originalGoal.z,originalGoal.t,offset,0)
                p.goal.t=originalGoal.t;p.deploymentOffset=offset
                search=E.newSearch(p)
            else index=index+1;preview=nil end
            return nil
        end}
end

-- Search stages preserve the original zero/left/right/root-solved candidate
-- order without retaining a Lua call stack across game updates.
function E.newSearch(p)
    -- A centred reversible implement is not its working envelope. End the
    -- centred manoeuvre upstream, leaving one measured implement span to deploy
    -- and steer onto the original row. The runtime still measures and validates
    -- the working position; this target is never used as a lowering boundary.
    -- Every candidate retains the real field containment and joint limits.
    if p.deploymentLead and p.deploymentLead>0 then
        if not p.directSearchComplete and not (p.turnHint and p.turnHint.directConnection) and
                math.abs(E.wrap(p.start.t-p.goal.t))>=math.pi/2 then
            local broad={};for k,v in pairs(p) do broad[k]=v end
            broad.directSearchComplete=true
            local baselineSearch=E.newSearch(broad)
            local shorter={};for k,v in pairs(p) do shorter[k]=v end
            local direct=E.newDirectSearch(shorter)
            local baseline,connection
            local directNext=false
            local function routeLength(result)
                local length=0
                for i=2,#result.path do
                    local a,b=result.path[i-1],result.path[i]
                    length=length+math.sqrt((b.x-a.x)^2+(b.z-a.z)^2)
                end
                return length
            end
            return {getProgress=function()
                    return (baseline and baseline.attempts or baselineSearch:getProgress())+
                        (connection and connection.attempts or direct:getProgress())
                end,update=function(_,budget)
                    -- Interleave the two catalogues: a difficult broad search
                    -- must not prevent a short feasible route being considered.
                    directNext=not directNext
                    if not connection and (directNext or baseline) then
                        connection=direct:update(budget)
                    elseif not baseline then
                        baseline=baselineSearch:update(budget)
                        if baseline and baseline.ok then shorter.maxRouteLength=routeLength(baseline) end
                    end
                    if connection and connection.ok then
                        local finish=E.point(p.goal.x,p.goal.z,p.goal.t,0,-p.front+12)
                        addLine(connection.path,connection.path[#connection.path],finish)
                        if baseline and baseline.ok and routeLength(baseline)<routeLength(connection) then return baseline end
                        return connection
                    end
                    if not baseline or not connection then return nil end
                    if not baseline.ok then
                        baseline.attempts=(baseline.attempts or 0)+(connection.attempts or 0)
                        baseline.rejections=baseline.rejections or {}
                        for reason,count in pairs(connection.rejections or {}) do
                            baseline.rejections[reason]=(baseline.rejections[reason] or 0)+count
                        end
                    end
                    return baseline
                end}
        end
        local staged={}
        for k,v in pairs(p) do staged[k]=v end
        staged.goal=E.point(p.goal.x,p.goal.z,p.goal.t,0,-p.deploymentLead)
        staged.goal.t=p.goal.t
        staged.deploymentLead=nil
        staged.deploymentTarget=true
        -- A row-to-row reversal can deploy on its compact return straight.
        -- Initial same-direction recoveries retain their stronger settling
        -- target, which reserves room for their different entry geometry.
        staged.canCompactReturn=math.abs(E.wrap(p.start.t-p.goal.t))>=math.pi/2
        if p.newTracker then staged.newTracker=function(path,screening) return p.newTracker(path,screening) end end
        local _,compact=E.deploymentLead(p,false)
        local lead=p.deploymentLead
        local previousAttempts=0
        staged.maxCandidates=compact<lead and 32 or nil
        local search=E.newSearch(staged)
        return {getProgress=function() return previousAttempts+search:getProgress() end,update=function(_,budget)
            local result=search:update(budget)
            if result and not result.ok and compact<lead then
                previousAttempts=result.attempts or 0
                lead=compact
                staged.goal=E.point(p.goal.x,p.goal.z,p.goal.t,0,-lead)
                staged.goal.t=p.goal.t
                staged.maxCandidates=nil
                search=E.newSearch(staged)
                return nil
            end
            if result and result.ok then
                -- Continue towards the ORIGINAL work start. This part remains
                -- raised until the live working-envelope check approves it.
                local finish=E.point(p.goal.x,p.goal.z,p.goal.t,0,-p.front+12)
                local last=result.path[#result.path]
                local _,forward=E.localPoint(finish,{x=last.x,z=last.z,t=p.goal.t})
                if forward>0 then addLine(result.path,last,finish) end
                result.deploymentLead=lead
                result.attempts=(result.attempts or 0)+previousAttempts
            end
            return result
        end}
    end
    local straight=math.max(4,math.min(12,(p.headland-2*p.radius)*0.1))
    local extensions=straight>6 and {8,16,0,4,24} or {0,4,8,16}
    -- Refine the gap between the first two radii. The smaller can exceed a
    -- long trailer's joint limit while the larger crosses a sloping boundary;
    -- that does not mean every radius between them is infeasible.
    local bends,factors={8,12,16,20,28,36},{1.1,(1.1+1.25)/2,1.25,1}
    local rowSeparation=math.abs(E.localPoint(p.goal,p.start))
    local wideTransfer=rowSeparation>2*p.radius
    if p.deploymentTarget or (p.length and (rowSeparation<p.length or wideTransfer)) then
        -- Start near the measured trailer's settling distance, then retain
        -- every existing compact candidate as a fallback. Short seed bends
        -- repeatedly fail for long centred implements and waste stopped time.
        -- This changes search priority only, never radius/clearance admission.
        -- Closely spaced rows need trailer settling even without turnover.
        -- A same-heading recovery has a complete bulb to settle; opposite
        -- rows start with the shorter lead. A transfer wider than a turning
        -- diameter also needs settling after its transverse section; ordinary
        -- gaps between those cases retain compact priority.
        local sameHeading=math.abs(E.wrap(p.start.t-p.goal.t))<math.pi/2
        local lead=(p.length or p.width)*((p.deploymentTarget or sameHeading or wideTransfer) and 1.8 or 1.5)
        table.sort(bends,function(a,b)
            local da,db=math.abs(a-lead),math.abs(b-lead)
            return da==db and a<b or da<db
        end)
    end
    local families={false}
    if p.deploymentTarget and math.abs(E.wrap(p.start.t-p.goal.t))>=math.pi/2 then
        families={'LSL','RSR',false}
        if p.workedSide==1 then families[1],families[2]='RSR','LSL' end
        if p.length and p.length>p.radius then factors={1.25,1.175,1.1,1} end
    end
    local familyIndex=1
    local bi,fi,ei=1,1,1
    -- Try compact worked-side bulbs before the unrestricted shortest path.
    -- Limit the preference to the first three bend lengths so it cannot spend
    -- a full second search pursuing increasingly long detours on that side.
    local preferWorked=p.workedSide==-1 or p.workedSide==1
    local attempts,lastReason=0,'no candidate'
    local rejections={}
    local stage,bias,iterations='zero',0,0
    local lo,hi,a,b,simulation,path,tail,verified
    local hint=p.turnHint
    local usingHint=hint and hint.bendRatio and hint.radiusRatio and hint.biasRatio and hint.extensionRatio
        and hint.bendRatio>0 and hint.bendRatio<=10 and hint.radiusRatio>=1 and hint.radiusRatio<=2
        and math.abs(hint.biasRatio)<=2 and hint.extensionRatio>=0 and hint.extensionRatio<=10
        and hint.workedSideRelative==(p.workedSide and p.workedSide*E.turnSide(p) or nil)
    if usingHint then bias=hint.biasRatio*p.width*E.turnSide(p) end
    -- An already bent initial arrival must draw forwards before curling back.
    -- Otherwise the shortest bulb immediately tightens the existing hitch
    -- angle. Seed a compact return with a geometry-derived outgoing lead;
    -- simulation still checks the complete footprint and joint limits.
    local initialRecovery=p.deploymentTarget and p.initialApproachRecovery
    local recoveryLead=initialRecovery and math.max(p.radius,
        (p.length or 0)*math.abs(math.sin(E.wrap(p.start.t-p.start.phi)))) or 0
    local compactSeed,compactPending=initialRecovery,p.canCompactReturn
    local compactUseful=false
    local compactIndex=1
    local initial=true
    local function nextGroup()
        if compactSeed then
            compactIndex=compactIndex+1
            if compactIndex<=2 then stage,bias,iterations='zero',0,0;return end
            compactSeed=false;stage,iterations='zero',0
            bias=usingHint and hint.biasRatio*p.width*E.turnSide(p) or 0
            return
        end
        -- First retain a normally settled candidate if it fits. A compact
        -- raised return is the bounded alternative, before exhausting dozens
        -- of longer families against a tight/sloping boundary.
        if compactPending and compactUseful then
            compactPending=false;compactSeed=true;stage,bias,iterations='zero',0,0
            return
        end
        if usingHint then usingHint=false;stage,bias,iterations='zero',0,0;return end
        familyIndex=familyIndex+1
        if familyIndex<=#families then stage,bias,iterations='zero',0,0;return end
        familyIndex=1
        ei=ei+1
        if ei>#extensions then ei=1; fi=fi+1 end
        if fi>#factors then fi=1; bi=bi+1 end
        if preferWorked and bi>3 then preferWorked=false;bi,fi,ei=1,1,1 end
        stage,bias,iterations='zero',0,0
    end
    return {getProgress=function() return attempts end,update=function(_,budget)
        if initial then
            initial=false
            if not E.checkFootprint(p,p.start) then
                return {ok=false,reason='starting footprint lacks field clearance',attempts=0}
            end
        end
        if bi>#bends or (p.maxCandidates and attempts>=p.maxCandidates and not simulation) then return {ok=false,reason=lastReason or 'no aligned candidate',attempts=attempts,rejections=rejections} end
        local bend=compactSeed and (initialRecovery and (compactIndex==1 and 8 or 12) or
            (compactIndex==1 and 12 or 8)) or (usingHint and hint.bendRatio*p.width or bends[bi])
        local radius=p.radius*(compactSeed and 1.1 or (usingHint and hint.radiusRatio or factors[fi]))
        local extension=compactSeed and recoveryLead or (usingHint and hint.extensionRatio*p.width or extensions[ei])
        local loopSide=not compactSeed and (usingHint and hint.preferWorked and p.workedSide or
            (not usingHint and preferWorked and p.workedSide or nil)) or nil
        local result
        if not simulation then
            path,tail=E.makePath(p,straight+bend,straight,radius,extension,bias,
                (usingHint and hint.pathFamily) or families[familyIndex] or loopSide)
            attempts=attempts+1
            verified=false
            if path then simulation=E.newSimulation(p,path,tail,0.15,true,false)
            else result={ok=false,reason='no analytic path'} end
        end
        result=result or simulation:update(budget)
        if not result then return nil end
        if result.ok and not verified then
            simulation=E.newSimulation(p,path,tail,0.075,true,true)
            verified=true
            return nil
        end
        simulation=nil
        if result.ok then
            result.attempts,result.straight,result.bend=attempts,straight,bend
            result.radius,result.extension,result.bias=radius,extension,bias
            result.usedTurnHint=not compactSeed and usingHint and true or false
            result.directConnection=result.usedTurnHint and hint.directConnection or nil
            result.preferWorked=loopSide~=nil and not families[familyIndex]
            result.pathFamily=(usingHint and hint.pathFamily) or families[familyIndex]
            return result
        end
        lastReason=result.reason
        compactUseful=compactUseful or result.reason=='field boundary'
        rejections[lastReason or 'unknown']=(rejections[lastReason or 'unknown'] or 0)+1
        local err=result.rearError
        if stage=='zero' then
            hi=math.min(6,bend*bend/(6*radius)*0.95); lo=-hi
            stage,bias='left',lo
        elseif stage=='left' then
            a=err; stage,bias='right',hi
        elseif stage=='right' then
            b=err
            if a and b and a*b<0 then stage='root'; bias=lo-a*(hi-lo)/(b-a)
            else nextGroup() end
        else
            iterations=iterations+1
            if not err or iterations>=6 then nextGroup()
            else
                if a*err<=0 then hi,b=bias,err else lo,a=bias,err end
                bias=lo-a*(hi-lo)/(b-a)
            end
        end
        return nil
    end}
end

function E.turnSide(p)
    local x=E.localPoint(p.goal,p.start)
    return x<0 and -1 or 1
end

function E.turnHint(p,result)
    return {directConnection=result.directConnection,pathFamily=result.pathFamily,bendRatio=result.bend/p.width,radiusRatio=result.radius/p.radius,
        biasRatio=result.bias/(p.width*E.turnSide(p)),extensionRatio=result.extension/p.width,
        preferWorked=result.preferWorked,
        workedSideRelative=p.workedSide and p.workedSide*E.turnSide(p) or nil}
end

function E.plan(p)
    local search=E.newSearch(p)
    local result
    repeat result=search:update(256) until result
    return result
end

-- Repair an incoming approach after a tool changes working position. This
-- family only progresses towards the row: it cannot send a deployed plough
-- around another bulb. Tangent lengths vary with the remaining distance,
-- rather than prescribing a long straight or a model-specific correction.
function E.approachSide(p)
    return E.wrap(p.start.t-p.goal.t)<0 and -1 or 1
end

-- Find the contiguous final run towards the row, ignoring earlier segments
-- which happen to have the same bearing on the outward part of an approach.
function E.approachTailStart(p,path)
    local first=#path
    for i=#path-1,1,-1 do
        local dx,dz=path[i+1].x-path[i].x,path[i+1].z-path[i].z
        if dx*dx+dz*dz>1e-8 then
            if math.abs(E.wrap(math.atan2(dx,dz)-p.goal.t))>math.rad(30) then break end
            first=i
        end
    end
    return math.max(2,first)
end

function E.straightTailStart(p,path)
    local first=#path
    for i=#path-1,1,-1 do
        local a,b=path[i],path[i+1]
        if (b.x-a.x)^2+(b.z-a.z)^2>1e-8 then
            if math.abs(E.wrap(math.atan2(b.x-a.x,b.z-a.z)-p.goal.t))>E.angleTolerance then break end
            first=i
        end
    end
    return math.max(2,first)
end

function E.newApproachSearch(p)
    local factors={0.1,0.2,0.3,0.4,0.5,0.6}
    local straights={4,2,0,8}
    local ai,bi,si,attempts=1,1,1,0
    -- Interleave nearby pull-in tangents and straight lengths. Exhausting all
    -- six tangents at each straight used the entire 96-trial budget before a
    -- shorter run-in was considered, even when that was the feasible shape.
    -- Include both compact and broader entry tangents in the quick screen.
    -- A nearly straight initial approach needs a different cubic from a tool
    -- arriving with substantial residual yaw after a bulb.
    -- Screen a balanced cubic before strongly asymmetric tangents. It avoids
    -- exhausting the stopped budget on several sharp leads when the measured
    -- working envelope needs a smooth lateral correction.
    local families={{1,1,1},{1,2,1},{2,4,1},{1,1,2},{1,2,2},{1,4,4}}
    if math.abs(E.wrap(p.start.t-p.goal.t))<=E.angleTolerance then
        table.insert(families,1,{3,3,1})
    else
        -- A tractor still pointing across the row needs its measured tangent
        -- respected first; preserve the established asymmetric correction.
        families[#families+1]={3,3,1}
    end
    ai,bi,si=families[1][1],families[1][2],families[1][3]
    local fastFamilyCount=#families
    local seen={}
    for _,f in ipairs(families) do seen[f[1]..':'..f[2]..':'..f[3]]=true end
    for a=1,#factors do
        for firstB=1,#factors,2 do
            for s=1,#straights do
                for b=firstB,math.min(firstB+1,#factors) do
                    if not seen[a..':'..b..':'..s] then families[#families+1]={a,b,s} end
                end
            end
        end
    end
    local familyIndex=1
    local fastPass=true
    local simulation,path,verified,fineGroup
    local fineVerificationStart
    local bias,stage,iterations=0,'zero',0
    local lo,hi,c,d,fc,fd,biasLimit,initialBiasLimit,widened
    local golden=(math.sqrt(5)-1)/2
    -- A previous completed turn supplies a starting guess, never a reusable
    -- approved path. Rebuild it from the new pose/width and validate it afresh.
    local hint=p.approachHint
    local usingHint=hint and hint.factorA and hint.factorB and hint.straightRatio and hint.biasRatio
        and hint.factorA>=0.1 and hint.factorA<=0.6 and hint.factorB>=0.1 and hint.factorB<=0.6
        and hint.straightRatio>=0 and hint.straightRatio*p.width<=12 and math.abs(hint.biasRatio)<=0.5
    if usingHint then bias=hint.biasRatio*p.width*E.approachSide(p) end
    local bestError=math.huge
    local bestVerified
    local hintMarginError
    local zeroAlignment,previousBias,previousAlignment,secantIterations
    local lastReason='no forward approach'
    local function advance()
        familyIndex=familyIndex+1
        if fastPass and familyIndex>fastFamilyCount then familyIndex=1;fastPass=false end
        local family=families[familyIndex]
        if family then ai,bi,si=family[1],family[2],family[3]
        else ai=#factors+1 end
        bias,stage,iterations=0,'zero',0
        fineGroup=false
        fineVerificationStart=false
        widened=false
    end
    local function makeApproach()
        local straight=usingHint and hint.straightRatio*p.width or straights[si]
        local factorA=usingHint and hint.factorA or factors[ai]
        local factorB=usingHint and hint.factorB or factors[bi]
        local finish=E.point(p.goal.x,p.goal.z,p.goal.t,0,-p.front-straight)
        local _,remaining=E.localPoint(finish,{x=p.start.x,z=p.start.z,t=p.goal.t})
        if remaining<=0 or math.abs(E.wrap(p.start.t-p.goal.t))>=math.pi/2 then return nil end
        -- This is a steering target, not a curve the axle must follow exactly.
        -- The former remaining^2/(24*radius) bound treated it as an isolated
        -- bend and excluded useful leads once the measured starting tangent
        -- and trailer angle were included (v0.13's 53-degree articulation).
        -- Bound the search spatially, then let the tracked simulation enforce
        -- CP's radius, joint limits and footprint for the complete correction.
        biasLimit=math.min(p.width/2,remaining/3,3)
        -- Start with the old compact bracket so ordinary entries retain their
        -- established correction. Widen this bracket before changing tangents
        -- if it cannot align the measured trailer.
        initialBiasLimit=math.min(biasLimit,remaining*remaining/(24*p.radius))
        if math.abs(bias)>biasLimit then return nil end
        local a=E.point(p.start.x,p.start.z,p.start.t,0,remaining*factorA)
        local b=E.point(finish.x,finish.z,p.goal.t,0,-remaining*factorB)
        local points={}
        local steps=math.max(2,math.ceil(remaining*8))
        for i=0,steps do
            local u=i/steps;local v=1-u
            local q={x=v^3*p.start.x+3*v*v*u*a.x+3*v*u*u*b.x+u^3*finish.x,
                z=v^3*p.start.z+3*v*v*u*a.z+3*v*u*u*b.z+u^3*finish.z}
            -- A lateral lead in the middle pulls the trailer onto line before
            -- the tractor settles. This quartic is zero with zero derivative
            -- at BOTH ends, preserving the measured start and incoming tangent.
            -- Merely changing cubic tangent lengths cannot always provide this
            -- steering lead (the v0.7 live working-position snapshot is one).
            local lead=16*bias*u*u*v*v
            q.x=q.x+lead*math.cos(p.goal.t)
            q.z=q.z-lead*math.sin(p.goal.t)
            if #points>0 then
                local previous=points[#points]
                local dx,dz=E.localPoint(q,{x=previous.x,z=previous.z,t=p.goal.t})
                -- Disallow backwards progress and sideways hooks. Physical
                -- steering limits and the actual tracked footprint are checked
                -- by the same fine simulation used for the original turn.
                if dz<=0 or math.abs(dx)>dz then return nil end
            end
            points[#points+1]=q
        end
        for d=0.5,straight+math.max(12,math.abs(p.slope)*p.width+5),0.5 do
            points[#points+1]=E.point(finish.x,finish.z,p.goal.t,0,d)
        end
        return points
    end
    return {update=function(_,budget)
        if attempts==0 and not E.checkFootprint(p,p.start) then
            return {ok=false,reason='local approach: starting footprint lacks field clearance',attempts=0}
        end
        -- Recovery at row entry must remain bounded; an exhausted search must
        -- not leave the tractor parked for minutes or launch another full loop.
        if ai>#factors or (attempts>=96 and not simulation) then
            if bestVerified then bestVerified.attempts=attempts;return bestVerified end
            return {ok=false,reason='local approach: '..lastReason,attempts=attempts,bestError=bestError}
        end
        local result
        if not simulation then
            attempts=attempts+1
            path=makeApproach()
            if path then simulation=E.newSimulation(p,path,2,fineGroup and 0.075 or 0.15,fineGroup or false,fineGroup or false,true)
            else result={ok=false,reason='local curve exceeds forward approach bounds'} end
            verified=fineGroup or false
        end
        result=result or simulation:update(budget)
        if not result then return nil end
        -- Coarse stepping can overestimate a near-threshold entry. Use it to
        -- screen shapes, never to reject a promising shape without running the
        -- production tracker. Only the unchanged fine tolerance admits a path.
        if not verified and (result.ok or (result.alignmentError and
                (result.error or math.huge)<=E.entryTolerance(p)*1.5)) then
            simulation=E.newSimulation(p,path,2,0.075,true,true,true)
            verified,fineGroup,fineVerificationStart=true,true,true;return nil
        end
        simulation=nil
        if result.ok then
            result.attempts,result.straight,result.bend=attempts,usingHint and hint.straightRatio*p.width or straights[si],0
            result.radius,result.extension,result.bias=p.radius,0,bias
            result.repairedApproach=true
            result.factorA,result.factorB=usingHint and hint.factorA or factors[ai],usingHint and hint.factorB or factors[bi]
            result.usedHint=usingHint and true or false
            if usingHint and result.maxEntryError>(E.entryTolerance(p)*0.6) then hintMarginError=result.maxEntryError end
            result.hintMarginError=hintMarginError
            if not bestVerified or result.maxEntryError<bestVerified.maxEntryError then bestVerified=result end
            -- A remembered shape is a search seed, not a reason to accept less
            -- tracking margin. The v0.12 field stop predicted 6.4 cm here but
            -- reached 10.2 cm live. Keep this verified candidate as a fallback,
            -- then run the same bounded refinement used for a fresh shape.
            -- Well-aligned cached shapes still return after their first trial.
            if result.maxEntryError<=(E.entryTolerance(p)*0.6) or
                    (fastPass and stage=='secant' and verified and result.maxEntryError<=(E.entryTolerance(p)*0.8)) then
                bestVerified.attempts=attempts
                bestVerified.hintMarginError=hintMarginError
                return bestVerified
            end
        end
        if usingHint then
            usingHint=false;bias,stage,iterations,fineGroup=0,'zero',0,false
            return nil
        end
        if fineVerificationStart then
            fineVerificationStart=false
            -- Fine validation can jump directly from the zero probe into a
            -- secant. Initialise its fallback bracket before that transition.
            if stage=='zero' then lo,hi=-initialBiasLimit,initialBiasLimit end
            if result.alignmentError then
                -- Do not fit a secant through a coarse-tracker sample and a
                -- production-PPC sample: their small discretisation offset
                -- matters at this tolerance. Obtain a second FINE sample.
                previousBias,previousAlignment=bias,result.alignmentError
                local probe=p.width*0.05*(result.alignmentError>0 and -1 or 1)
                local nextBias=math.max(-biasLimit,math.min(biasLimit,bias+probe))
                if math.abs(nextBias-bias)>0.001 then
                    stage,bias,secantIterations='secant',nextBias,0
                    return nil
                end
            end
        end
        lastReason=result.reason or 'preferred alignment margin not reached'
        bestError=math.min(bestError,result.maxEntryError or result.error or math.huge)
        -- Minimise the worst edge error over the whole admission interval.
        -- A zero of signed average error need not minimise the worst corner:
        -- front/rear extrema respond differently to a steering lead.
        local objective=result.maxEntryError or result.error or math.huge
        if stage=='zero' then
            if not path then advance();return nil end
            lo,hi=-initialBiasLimit,initialBiasLimit
            zeroAlignment=result.alignmentError
            if zeroAlignment and initialBiasLimit>0.001 then
                local across=E.localPoint(p.start,p.goal)
                local probe=math.min(initialBiasLimit,p.width*0.1)
                stage,bias='probe',across>0 and -probe or probe
                return nil
            end
            c,d=hi-golden*(hi-lo),lo+golden*(hi-lo)
            fc,fd=nil,nil
            stage,bias='c',c
        elseif stage=='probe' or stage=='secant' then
            -- Lateral response is locally near-linear. Two samples usually
            -- locate a useful steering lead without twelve minimisation steps.
            -- Fine PPC/footprint validation still decides admission; a poor
            -- linear estimate falls back to the original bounded minimiser.
            local oldBias=stage=='probe' and 0 or previousBias
            local oldError=stage=='probe' and zeroAlignment or previousAlignment
            local currentError=result.alignmentError
            secantIterations=stage=='probe' and 0 or secantIterations
            if fastPass and stage=='secant' and secantIterations>=2 then
                -- Screen the compact shape families before refining one.
                -- If none works, advance() returns to the original minimiser;
                -- the search budget and fine acceptance are unchanged.
                advance()
                return nil
            end
            if stage=='secant' and currentError and math.abs(currentError)<(E.entryTolerance(p)*0.6)/4 and
                    objective>(E.entryTolerance(p)*0.8) then
                -- The two sides are already balanced, but their spread is too
                -- wide: another lateral shift cannot fix that tangent shape.
                -- Try a different pull-in/straight instead of spending twelve
                -- more trials minimising the same rejected shape.
                advance()
                return nil
            end
            if oldError and currentError and math.abs(currentError-oldError)>1e-6 and secantIterations<2 then
                local nextBias=bias-currentError*(bias-oldBias)/(currentError-oldError)
                nextBias=math.max(-biasLimit,math.min(biasLimit,nextBias))
                if math.abs(nextBias-bias)>0.001 then
                    previousBias,previousAlignment=bias,currentError
                    secantIterations=secantIterations+1
                    stage,bias='secant',nextBias
                    return nil
                end
            end
            c,d=hi-golden*(hi-lo),lo+golden*(hi-lo)
            fc,fd=nil,nil;stage,bias='c',c
        else
            if stage=='c' then fc=objective else fd=objective end
            if not fd then stage,bias='d',d;return nil end
            iterations=iterations+1
            if iterations>=12 or hi-lo<0.001 then
                if bestVerified then bestVerified.attempts=attempts;return bestVerified end
                -- Only expand when minimisation is pressing against the old
                -- bracket edge. An interior minimum needs different tangents;
                -- repeating a wider search there just delays known solutions.
                if not widened and biasLimit>initialBiasLimit+0.001 and
                        math.abs((lo+hi)/2)>initialBiasLimit*0.9 then
                    widened=true;iterations=0
                    lo,hi=-biasLimit,biasLimit
                    c,d=hi-golden*(hi-lo),lo+golden*(hi-lo)
                    fc,fd=nil,nil;stage,bias='c',c
                    return nil
                end
                advance();return nil
            end
            if fc<fd then
                hi,d,fd=d,c,fc
                c=hi-golden*(hi-lo)
                stage,bias='c',c
            else
                lo,c,fc=c,d,fd
                d=lo+golden*(hi-lo)
                stage,bias='d',d
            end
        end
        return nil
    end}
end
