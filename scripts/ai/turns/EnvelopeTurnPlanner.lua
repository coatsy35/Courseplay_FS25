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
        error, angle, contact, rearError,(minError+maxError)/2
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
function E.makePath(p, approach, straight, radius, extension, bias)
    local start = E.point(p.start.x, p.start.z, p.start.t, 0, extension)
    start.t = p.start.t
    local goal = E.point(p.goal.x, p.goal.z, p.goal.t, bias, -p.front - approach)
    goal.t = p.goal.t
    local path = {{x=p.start.x, z=p.start.z}}
    addLine(path, p.start, start)
    local arc = p.dubins(start, goal, radius)
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

-- A spatial-step pursuit model predicts trailer off-tracking. It is a candidate
-- filter, not GIANTS physics: execution checks live markers again before work.
-- Explicit resumable state: FS25 removes Lua's coroutine library. Each update
-- advances a bounded number of samples and retains the tracker between frames.
function E.newSimulation(p, path, tailStart, step, boundary, collect)
    local tracker=p.newTracker and p.newTracker(path)
    local function finish(result)
        if tracker then tracker:delete() end
        return result
    end
    local s = {x=p.start.x,z=p.start.z,t=p.start.t,phi=p.start.phi or p.start.t}
    local ix, travelled, entered, alignmentLead = 1, 0, false, 0
    local loweringGatePassed=false
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
        local aligned, error, angle, contact, rear,balanced = E.assess(p,s)
        aligned=aligned and error<=E.planningEdgeTolerance
        local articulation=math.abs(E.wrap(s.t-s.phi))
        maxArticulation=math.max(maxArticulation,articulation)
        if p.length and articulation > p.maxArticulation then return finish({ok=false,reason='joint angle'}) end
        if boundary and not E.checkFootprint(p,s) then return finish({ok=false,reason='field boundary'}) end
        if collect and (not frames[#frames] or travelled-frames[#frames].distance >= 0.2) then
            frames[#frames+1]={x=s.x,z=s.z,t=s.t,phi=s.phi,distance=travelled,contact=contact,aligned=aligned,ix=ix}
        end
        if ix >= tailStart then
            alignmentLead = aligned and (alignmentLead+step) or 0
            if contact>=E.loweringGateContact and not loweringGatePassed then
                if not aligned then
                    return finish({ok=false,reason='lowering approach alignment',error=error,rearError=rear,alignmentError=balanced})
                end
                loweringGatePassed=true
            end
            if loweringGatePassed and not aligned then
                return finish({ok=false,reason='alignment lost after lowering gate',error=error,rearError=rear,alignmentError=balanced})
            end
            if contact >= -0.1 and not entered then
                entered=true
                contactError,rearError=error,rear
                -- Hydraulic travel is handled by stopping BEFORE first contact.
                -- We still need a short aligned window in which to stop/lower.
                if not aligned or alignmentLead < p.loweringLead then
                    return finish({ok=false,reason='entry alignment',error=error,rearError=rear,alignmentError=balanced})
                end
            end
            if entered and not aligned then return finish({ok=false,reason='alignment lost',rearError=rear}) end
            if entered and contact > 4 then
                return finish({ok=true,path=path,tailStart=tailStart,frames=frames,entryError=contactError,
                    maxArticulation=maxArticulation,distance=travelled,rearError=rearError})
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
            s.phi=E.wrap(direction+2*math.atan(math.tan(delta/2)*math.exp(-math.sqrt(hx*hx+hz*hz)/p.length)))
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
    local straight=math.max(4,math.min(12,(p.headland-2*p.radius)*0.1))
    local extensions=straight>6 and {8,16,0,4,24} or {0,4,8,16}
    local bends,factors={8,12,16,20,28,36},{1.1,1.25,1}
    local bi,fi,ei=1,1,1
    local attempts,lastReason=0,'no candidate'
    local stage,bias,iterations='zero',0,0
    local lo,hi,a,b,simulation,path,tail,verified
    local initial=true
    local function nextGroup()
        ei=ei+1
        if ei>#extensions then ei=1; fi=fi+1 end
        if fi>#factors then fi=1; bi=bi+1 end
        stage,bias,iterations='zero',0,0
    end
    return {update=function(_,budget)
        if initial then
            initial=false
            if not E.checkFootprint(p,p.start) then
                return {ok=false,reason='starting footprint lacks field clearance',attempts=0}
            end
        end
        if bi>#bends then return {ok=false,reason=lastReason or 'no aligned candidate',attempts=attempts} end
        local bend,radius,extension=bends[bi],p.radius*factors[fi],extensions[ei]
        local result
        if not simulation then
            path,tail=E.makePath(p,straight+bend,straight,radius,extension,bias)
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
            return result
        end
        lastReason=result.reason
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
function E.newApproachSearch(p)
    local factors={0.1,0.2,0.3,0.4,0.5,0.6}
    local straights={2,0,4,8}
    local ai,bi,si,attempts=1,1,1,0
    local simulation,path,verified
    local bias,stage,iterations=0,'zero',0
    local lo,hi,loError,hiError,zeroError,biasLimit
    local bestError=math.huge
    local lastReason='no forward approach'
    local function advance()
        -- Interleave remaining straight lengths so a bounded search samples
        -- each one instead of spending its whole budget on the first length.
        si=si+1
        if si>#straights then si=1;bi=bi+1 end
        if bi>#factors then bi=1;ai=ai+1 end
        bias,stage,iterations=0,'zero',0
    end
    local function makeApproach()
        local finish=E.point(p.goal.x,p.goal.z,p.goal.t,0,-p.front-straights[si])
        local _,remaining=E.localPoint(finish,{x=p.start.x,z=p.start.z,t=p.goal.t})
        if remaining<=0 or math.abs(E.wrap(p.start.t-p.goal.t))>=math.pi/2 then return nil end
        biasLimit=math.min(p.width/2,remaining*remaining/(24*p.radius),3)
        local a=E.point(p.start.x,p.start.z,p.start.t,0,remaining*factors[ai])
        local b=E.point(finish.x,finish.z,p.goal.t,0,-remaining*factors[bi])
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
        for d=0.5,straights[si]+math.max(12,math.abs(p.slope)*p.width+5),0.5 do
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
            return {ok=false,reason='local approach: '..lastReason,attempts=attempts,bestError=bestError}
        end
        local result
        if not simulation then
            attempts=attempts+1
            path=makeApproach()
            if path then simulation=E.newSimulation(p,path,2,0.15,false,false)
            else result={ok=false,reason='local curve exceeds forward approach bounds'} end
            verified=false
        end
        result=result or simulation:update(budget)
        if not result then return nil end
        if result.ok and not verified then
            simulation=E.newSimulation(p,path,2,0.075,true,true)
            verified=true;return nil
        end
        simulation=nil
        if result.ok then
            result.attempts,result.straight,result.bend=attempts,straights[si],0
            result.radius,result.extension,result.bias=p.radius,0,bias
            result.repairedApproach=true
            return result
        end
        lastReason=result.reason
        bestError=math.min(bestError,result.error or math.huge)
        -- Balance the most negative/positive working-edge displacement, rather
        -- than forcing just one rear corner onto its line. That can leave the
        -- front outside tolerance until too late to stop before work entry.
        -- Solve this signed error rather than trying
        -- hundreds of nearly identical cubic curves. Fine verification still
        -- requires every working edge and the full footprint to pass.
        local err=result.alignmentError or result.rearError
        if stage=='zero' then
            if not path then advance();return nil end
            zeroError=err
            lo,hi=-biasLimit,biasLimit
            stage,bias='left',lo
        elseif stage=='left' then
            loError=err;stage,bias='right',hi
        elseif stage=='right' then
            hiError=err
            -- One extreme can exceed the forward-only shape bounds. Keep the
            -- valid zero-bias sample as a bracket endpoint on the other side.
            if not loError and zeroError then lo,loError=0,zeroError end
            if not hiError and zeroError then hi,hiError=0,zeroError end
            if loError and hiError and loError*hiError<0 then
                stage='root';bias=lo-loError*(hi-lo)/(hiError-loError)
            else advance() end
        else
            iterations=iterations+1
            if not err or iterations>=6 then advance()
            else
                if loError*err<=0 then hi,hiError=bias,err else lo,loError=bias,err end
                bias=lo-loError*(hi-lo)/(hiError-loError)
            end
        end
        return nil
    end}
end
