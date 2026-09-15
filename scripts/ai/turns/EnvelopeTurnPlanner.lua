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
E.edgeTolerance = 0.1
-- Reserve half the live allowance for physical tracking and hydraulic settling.
-- Candidate acceptance must not aim at the same threshold that stops the rig.
E.planningEdgeTolerance = E.edgeTolerance / 2
-- The preferred margin is an optimisation target. Local repair may retain a
-- finely verified result with at least a quarter of the live allowance spare.
-- Do not turn a fraction of a millimetre above the target into "no path".
E.repairEdgeTolerance = E.edgeTolerance * 0.75
E.reserve = 0.5
-- Shared with the live lowering gate: align BEFORE stopping, not only at the
-- later boundary-crossing sample. The tractor brakes towards 0.5 m clearance.
E.loweringGateContact = -0.65

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
    return error <= E.edgeTolerance and angle <= E.angleTolerance,
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

-- Body edges are sampled too: four corners alone can straddle a concave hedge
-- or an island. The 0.5 m reserve covers the <=0.4 m spatial samples between
-- checks. Field polygons are complemented by GIANTS field-density queries in
-- the runtime adapter, so an interior non-field patch is not silently ignored.
function E.checkFootprint(p, state)
    for _, marker in ipairs(p.footprint) do
        local q = E.marker(p, state, marker)
        if not p.contains(q.x, q.z) then return false end
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
    local tracker=p.newTracker and p.newTracker(path,not boundary)
    local function finish(result)
        if tracker then tracker:delete() end
        return result
    end
    local s = {x=p.start.x,z=p.start.z,t=p.start.t,phi=p.start.phi or p.start.t}
    local ix, travelled, entered, alignmentLead = 1, 0, false, 0
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
            (optimiseEntry and E.repairEdgeTolerance or E.planningEdgeTolerance)
        aligned=angle<=E.angleTolerance and error<=tolerance
        local articulation=math.abs(E.wrap(s.t-s.phi))
        maxArticulation=math.max(maxArticulation,articulation)
        if p.length and articulation > p.maxArticulation then return finish({ok=false,reason='joint angle'}) end
        if boundary and not E.checkFootprint(p,s) then return finish({ok=false,reason='field boundary'}) end
        if collect and (not frames[#frames] or travelled-frames[#frames].distance >= 0.2) then
            frames[#frames+1]={x=s.x,z=s.z,t=s.t,phi=s.phi,distance=travelled,contact=contact,aligned=aligned,ix=ix}
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
                    maxEntryError=optimiseEntry and math.max(math.abs(entryMin),math.abs(entryMax)) or nil})
            end
        end
        if ix >= #path then break end
        local k=E.pursuitCurvature(p,s,gx,gz)
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

-- Search stages preserve the original zero/left/right/root-solved candidate
-- order without retaining a Lua call stack across game updates.
function E.newSearch(p)
    -- A centred reversible implement is not its working envelope. End the
    -- centred manoeuvre upstream, leaving one measured implement span to deploy
    -- and steer onto the original row. The runtime still measures and validates
    -- the working position; this target is never used as a lowering boundary.
    -- Every candidate retains the real field containment and joint limits.
    if p.deploymentLead and p.deploymentLead>0 then
        local staged={}
        for k,v in pairs(p) do staged[k]=v end
        staged.goal=E.point(p.goal.x,p.goal.z,p.goal.t,0,-p.deploymentLead)
        staged.goal.t=p.goal.t
        staged.deploymentLead=nil
        staged.deploymentTarget=true
        if p.newTracker then staged.newTracker=function(path,screening) return p.newTracker(path,screening) end end
        local search=E.newSearch(staged)
        return {getProgress=function() return search:getProgress() end,update=function(_,budget)
            local result=search:update(budget)
            if result and result.ok then
                -- Continue towards the ORIGINAL work start. This part remains
                -- raised until the live working-envelope check approves it.
                local finish=E.point(p.goal.x,p.goal.z,p.goal.t,0,-p.front+12)
                local last=result.path[#result.path]
                local _,forward=E.localPoint(finish,{x=last.x,z=last.z,t=p.goal.t})
                if forward>0 then addLine(result.path,last,finish) end
                result.deploymentLead=p.deploymentLead
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
    if p.deploymentTarget then
        -- Start near the measured trailer's settling distance, then retain
        -- every existing compact candidate as a fallback. Short seed bends
        -- repeatedly fail for long centred implements and waste stopped time.
        -- This changes search priority only, never radius/clearance admission.
        local lead=(p.length or p.width)*1.8
        table.sort(bends,function(a,b)
            local da,db=math.abs(a-lead),math.abs(b-lead)
            return da==db and a<b or da<db
        end)
    end
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
    local initial=true
    local function nextGroup()
        if usingHint then usingHint=false;stage,bias,iterations='zero',0,0;return end
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
        if bi>#bends then return {ok=false,reason=lastReason or 'no aligned candidate',attempts=attempts,rejections=rejections} end
        local bend=usingHint and hint.bendRatio*p.width or bends[bi]
        local radius=p.radius*(usingHint and hint.radiusRatio or factors[fi])
        local extension=usingHint and hint.extensionRatio*p.width or extensions[ei]
        local loopSide=usingHint and hint.preferWorked and p.workedSide or
            (not usingHint and preferWorked and p.workedSide or nil)
        local result
        if not simulation then
            path,tail=E.makePath(p,straight+bend,straight,radius,extension,bias,loopSide)
            attempts=attempts+1
            verified=false
            if path then simulation=E.newSimulation(p,path,tail,0.15,false,false)
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
            result.usedTurnHint=usingHint and true or false
            result.preferWorked=loopSide~=nil
            return result
        end
        lastReason=result.reason
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
    return {bendRatio=result.bend/p.width,radiusRatio=result.radius/p.radius,
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

function E.newApproachSearch(p)
    local factors={0.1,0.2,0.3,0.4,0.5,0.6}
    local straights={4,2,0,8}
    local ai,bi,si,attempts=1,1,1,0
    local simulation,path,verified,fineGroup
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
    local lastReason='no forward approach'
    local function advance()
        -- Vary the pull-in tangent before extending the straight: changing the
        -- steering lead can settle a long trailer without a longer run-in.
        bi=bi+1
        if bi>#factors then bi=1;si=si+1 end
        if si>#straights then si=1;ai=ai+1 end
        bias,stage,iterations=0,'zero',0
        fineGroup=false
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
        if result.ok and not verified then
            simulation=E.newSimulation(p,path,2,0.075,true,true,true)
            verified,fineGroup=true,true;return nil
        end
        simulation=nil
        if result.ok then
            result.attempts,result.straight,result.bend=attempts,usingHint and hint.straightRatio*p.width or straights[si],0
            result.radius,result.extension,result.bias=p.radius,0,bias
            result.repairedApproach=true
            result.factorA,result.factorB=usingHint and hint.factorA or factors[ai],usingHint and hint.factorB or factors[bi]
            result.usedHint=usingHint and true or false
            if usingHint and result.maxEntryError>E.planningEdgeTolerance then hintMarginError=result.maxEntryError end
            result.hintMarginError=hintMarginError
            if not bestVerified or result.maxEntryError<bestVerified.maxEntryError then bestVerified=result end
            -- A remembered shape is a search seed, not a reason to accept less
            -- tracking margin. The v0.12 field stop predicted 6.4 cm here but
            -- reached 10.2 cm live. Keep this verified candidate as a fallback,
            -- then run the same bounded refinement used for a fresh shape.
            -- Well-aligned cached shapes still return after their first trial.
            if result.maxEntryError<=E.planningEdgeTolerance then return result end
        end
        if usingHint then
            usingHint=false;bias,stage,iterations,fineGroup=0,'zero',0,false
            return nil
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
            c,d=hi-golden*(hi-lo),lo+golden*(hi-lo)
            fc,fd=nil,nil
            stage,bias='c',c
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
