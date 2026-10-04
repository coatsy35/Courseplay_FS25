--- CP owns the full trailer until it has returned along harvested work to the field access.
--- Every leg uses the normal pathfinder and the shared, articulated parking validator.
UnloaderFieldDeparture = {}
local D = UnloaderFieldDeparture
local function distance(a, b) return MathUtil.vector2Length(a.x-b.x, a.z-b.z) end
local function angle(a, b) return (a-b+math.pi) % (2*math.pi)-math.pi end
local function point(course, ix, backwards)
    local x, _, z = course:getWaypointPosition(ix)
    return {x=x, z=z, heading=course:getWaypointYRotation(ix)+(backwards and math.pi or 0)}
end

function D.capture(driver, combine)
    local strategy = combine and combine:getCpDriveStrategy()
    local course = strategy and strategy.getFieldworkCourse and strategy:getFieldworkCourse()
    local ix = strategy and strategy.getClosestFieldworkWaypointIx and strategy:getClosestFieldworkWaypointIx()
    if course and ix and not (driver.lastUnloadFieldRun and strategy.isTurning and strategy:isTurning()) then
        driver.lastUnloadFieldRun = {course=course, ix=ix}
    end
end

local function nearEdge(polygon, target, limit)
    local previous = polygon[#polygon]
    for _, p in ipairs(polygon) do
        local dx, dz = p.x-previous.x, p.z-previous.z
        local t = math.max(0, math.min(1, ((target.x-previous.x)*dx+(target.z-previous.z)*dz)/
            math.max(0.0001, dx*dx+dz*dz)))
        if MathUtil.vector2Length(target.x-previous.x-t*dx, target.z-previous.z-t*dz) <= limit then return true end
        previous = p
    end
    return false
end

function D.create(driver)
    local boundary = UnloaderParkingPlanner.getBoundary(driver.vehicle)
    local marker = driver.invertedStartPositionMarkerNode
    if not boundary or not (marker or driver.fieldEntryPose) then return nil, 'no surveyed field access' end
    local x,z,heading,markerY
    if marker then
        x,markerY,z=localToWorld(marker,driver.invertedGoalPositionOffset,0,0)
        heading=CpMathUtil.getNodeDirection(marker)
    else
        x,z,heading=driver.fieldEntryPose.x,driver.fieldEntryPose.z,driver.fieldEntryPose.heading+math.pi
    end
    local target = {x=x, z=z, heading=heading, exit=true}
    -- isPositionOk already validates the configured marker: anywhere inside the field,
    -- or up to 40 m outside it. Validate only the fallback against that same contract,
    -- before applying any lateral offset; an inside marker need not be near an edge.
    if not marker and not CpMathUtil.isPointInPolygon(boundary.polygon,x,z) and
            not nearEdge(boundary.polygon,target,40) then return nil, 'entry position is not serving this field' end
    local rig = FieldworkBoundary.captureRig(driver.vehicle)
    local length, width = UnloaderParkingPlanner.getRigLength(rig), 0
    for _, part in ipairs(rig) do width=math.max(width, 2*part.box.width) end
    -- CP's validated access marker can be on the headland or parallel to its edge.
    -- Its heading describes the handover alignment, not a promise that driving forwards
    -- will leave the field. Return to this known access; never invent an 80 m extension.
    local alignmentLength=math.max(25,length*1.5)
    local gate = {}
    for _, corner in ipairs({{-1,-1},{1,-1},{1,1},{-1,1}}) do
        local side, along = corner[1]*(width/2+4), corner[2]*(length+alignmentLength+4)
        gate[#gate+1] = {x=x+math.cos(target.heading)*side+math.sin(target.heading)*along,
            z=z-math.sin(target.heading)*side+math.cos(target.heading)*along}
    end
    boundary.exitGate = {polygon=gate, islands=boundary.islands, margin=0}
    local goals = {}
    local run = driver.lastUnloadFieldRun
    local at = {x=rig[1].x, z=rig[1].z}
    if run then
        local course, ix = run.course, math.min(run.ix, run.course:getNumberOfWaypoints())
        if not course:isOnHeadland(ix) and not course:isOnConnectingPath(ix) and not course:isReverseAt(ix) then
            -- Only the already cut part of this row is eligible; never use future work or an intervening turn.
            local first = ix
            while first > 1 and not course:getWaypoint(first):isRowStart() do
                if course:isOnHeadland(first-1) or course:isOnConnectingPath(first-1) or
                        course:isTurnStartAtIx(first-1) or course:isReverseAt(first-1) then break end
                first=first-1
            end
            local nearest, best = ix, math.huge
            for i=first,ix do local p=point(course,i,true); local d=distance(at,p)
                if d < best then nearest,best=i,d end
            end
            local last, travelled, path = at, 0, {at}
            for i=nearest,first,-1 do
                local p=point(course,i,true)
                path[#path+1]=p
                travelled=travelled+distance(last,p); last=p
                if travelled >= math.max(40, length*2) or i == first then
                    if distance(at,p) > 3 then p.path=path; goals[#goals+1]=p; at=p; path={p} end
                    travelled=0
                end
            end
        end
        -- Join the harvested outer headland, then follow it to the access. This prevents
        -- the final leg from taking a diagonal shortcut across a fully harvested field.
        -- Course:getHeadland returns generator coordinates (x,y=-z), not a driving Course.
        local polygon = course.getHeadland and course:getHeadland(1)
        local points = {}
        for i,p in ipairs(polygon or {}) do
            local nextPoint=polygon[i%#polygon+1]
            points[#points+1]={x=p.x,z=-p.y,heading=math.atan2(nextPoint.x-p.x,p.y-nextPoint.y)}
        end
        local headland = #points>2 and {
            getNumberOfWaypoints=function() return #points end,
            getWaypointPosition=function(_,i) return points[i].x,0,points[i].z end,
            getWaypointYRotation=function(_,i) return points[i].heading end,
        }
        if headland and headland:getNumberOfWaypoints() > 2 then
            local startIx, endIx, sd, ed = 1,1,math.huge,math.huge
            local n=headland:getNumberOfWaypoints()
            for i=1,n do local p=point(headland,i,false)
                local a,b=distance(at,p),distance(target,p)
                if a<sd then startIx,sd=i,a end
                if b<ed then endIx,ed=i,b end
            end
            local function route(step)
                local points, i, total = {}, startIx, 0
                local previous=point(headland,i,false)
                for count=1,n do
                    local p=point(headland,i,false); points[#points+1]=p
                    total=total+distance(previous,p); previous=p
                    if i==endIx then return points,total end
                    i=(i-1+step)%n+1
                end
                return points,math.huge
            end
            local a,ad=route(1); local b,bd=route(-1)
            local selected=ad<=bd and a or b
            local last,path=at,{at}
            for i,p in ipairs(selected) do
                local previous=selected[math.max(1,i-1)]
                if i==1 and #selected>1 then previous=p; local nextPoint=selected[2]
                    p.heading=math.atan2(nextPoint.x-p.x,nextPoint.z-p.z)
                    p.headlandJoin=true
                elseif i>1 then p.heading=math.atan2(p.x-previous.x,p.z-previous.z) end
                path[#path+1]=p
                if distance(last,p)>=40 or i==#selected then
                    if distance(at,p)>3 then p.path=path; goals[#goals+1]=p; at=p; path={p} end
                    last=p
                end
            end
        end
    end
    target.path={at,target}
    goals[#goals+1]=target
    return {goals=goals, ix=1, boundary=boundary, alignmentLength=alignmentLength,
        corridorWidth=math.max(width/2+4,driver.turningRadius*2)}
end

function D.legBoundary(driver, departure)
    local rig=FieldworkBoundary.captureRig(driver.vehicle)
    local path={{x=rig[1].x,z=rig[1].z}}
    local goal=departure.goals[departure.ix]
    local planned=goal.path
    if goal.exit then
        -- The pathfinder aims behind the marker so the whole train can align before
        -- handover. Include that run-in in the corridor even when the preceding
        -- headland checkpoint is closer to the marker than the alignment distance.
        planned={path[1],{x=goal.x-math.sin(goal.heading)*departure.alignmentLength,
            z=goal.z-math.cos(goal.heading)*departure.alignmentLength},goal}
    end
    local nearest,best=1,math.huge
    for i,p in ipairs(planned) do
        local d=distance(path[1],p)
        if d<best then nearest,best=i,d end
    end
    local first=goal.exit and 2 or math.min(#planned,nearest+1)
    -- A nearby alternative checkpoint must rejoin the sampled harvested route:
    -- retain its original corner in the next leg rather than trimming that corner.
    if not goal.exit and nearest==1 and distance(path[1],planned[1])<=12 then first=1 end
    for i=first,#planned do
        local p=planned[i]
        if distance(path[#path],p)>0.1 then path[#path+1]={x=p.x,z=p.z} end
    end
    if #path<2 then return departure.boundary end
    local left,right={},{}
    local width=departure.corridorWidth
    for i,p in ipairs(path) do
        local a,b=path[math.max(1,i-1)],path[math.min(#path,i+1)]
        local incoming=math.atan2(p.x-a.x,p.z-a.z)
        local outgoing=math.atan2(b.x-p.x,b.z-p.z)
        if i==1 then incoming=outgoing elseif i==#path then outgoing=incoming end
        local heading=incoming+angle(outgoing,incoming)/2
        local side=width/math.max(0.25,math.cos(angle(outgoing,incoming)/2))
        local along=i==1 and -width or i==#path and width or 0
        local x,z=p.x+math.sin(heading)*along,p.z+math.cos(heading)*along
        left[#left+1]={x=x-math.cos(heading)*side,z=z+math.sin(heading)*side}
        right[#right+1]={x=x+math.cos(heading)*side,z=z-math.sin(heading)*side}
    end
    local polygon=left
    for i=#right,1,-1 do polygon[#polygon+1]=right[i] end
    return {polygon=departure.boundary.polygon,margin=departure.boundary.margin,islands=departure.boundary.islands,
        exitGate=departure.boundary.exitGate,travelBoundary={polygon=polygon,margin=0,islands={}}}
end

-- Checkpoints are navigation aids, not mandatory parking poses. Keep the original
-- harvested corridor, but try a finite set of nearby poses when its endpoint is
-- invalid. The final handover marker itself must never move.
function D.getGoal(departure)
    return departure.activeGoal or departure.goals[departure.ix]
end

function D.clearGoalCandidate(departure)
    departure.activeGoal, departure.goalCandidate = nil, nil
end

function D.nextGoalCandidate(departure)
    local planned = departure.goals[departure.ix]
    local candidate = (departure.goalCandidate or 0) + 1
    local alternatives = planned.exit and {0.75, 0.5, 0.25, 0} or
        {{-2,0},{2,0},{0,-4},{-2,-4},{2,-4},{0,-8}}
    local offset = alternatives[candidate]
    if not offset then return false end
    departure.goalCandidate = candidate
    local goal = {}
    for key,value in pairs(planned) do goal[key] = value end
    if planned.exit then
        goal.runInLength = departure.alignmentLength * offset
    else
        goal.x = planned.x + math.cos(planned.heading)*offset[1] + math.sin(planned.heading)*offset[2]
        goal.z = planned.z - math.sin(planned.heading)*offset[1] + math.cos(planned.heading)*offset[2]
    end
    departure.activeGoal = goal
    return true
end

function D.isAligned(rig, goal)
    if math.abs(angle(rig[1].heading,goal.heading))>math.rad(10) then return false end
    for _,part in ipairs(rig) do
        if math.abs(angle(part.heading,goal.heading))>math.rad(12) then return false end
    end
    return true
end

function D.validationJob(driver, course, departure)
    local goal=D.getGoal(departure)
    local x,_,z=course:getWaypointPosition(course:getNumberOfWaypoints())
    -- The final straight segment is part of validation, including trailer offtracking and obstacles.
    if MathUtil.vector2Length(goal.x-x,goal.z-z)>0.1 then
        course:append(Course.createFromTwoWorldPositions(driver.vehicle,x,z,goal.x,goal.z,0,0,0,1,false))
    end
    local child, phase = UnloaderParkingPlanner.newPlanJob(UnloaderCoordinator.assignments), 'plan'
    local finalRig
    local job
    job={step=function()
        local done,result=UnloaderParkingPlanner.advance(child)
        if not done then return false end
        if phase=='plan' then
            child=UnloaderParkingPlanner.validateCourseJob(driver,course,result,departure.legBoundary)
            phase='validate'
        elseif phase=='validate' then
            if not result then return true end
            finalRig=FieldworkBoundary.captureRig(driver.vehicle)
            child=VehicleRouteConflict.createSweepJob(finalRig,course,driver.turningRadius)
            phase='sweep'
        else
            -- A shorter run-in is only usable if the actual articulated simulation
            -- reaches the unchanged marker aligned. Arrival still checks the live rig.
            if goal.exit and not D.isAligned(finalRig,goal) then
                job.rejectionReason='final alignment'
                return true
            end
            course.parkingOccupancySweep=result
            return true,course
        end
        return false
    end}
    return job
end

function D.atGoal(driver, goal)
    local rig=FieldworkBoundary.captureRig(driver.vehicle)
    if distance(rig[1],goal)>3 then return false end
    if goal.exit then
        if not D.isAligned(rig,goal) then return false end
        for _,part in ipairs(rig) do
            if FieldworkBoundary.boxOutsideDistance(driver.fullTrailerDeparture.boundary.exitGate,
                        part.x,part.z,part.heading,part.box)>0 then return false end
        end
    end
    return true
end

-- Refresh upcoming traffic incrementally during driving; proximity/collision warning also remain active.
function D.trafficJob(driver, course)
    local child,phase=UnloaderParkingPlanner.newPlanJob(UnloaderCoordinator.assignments),'plan'
    local plan,sweep,kind,index=nil,nil,'obstacles',1
    return {step=function()
        if child then
            local done,result=UnloaderParkingPlanner.advance(child)
            if done then
                if phase=='plan' then
                    plan=result
                    child=VehicleRouteConflict.createSweepJob(FieldworkBoundary.captureRig(driver.vehicle),course,driver.turningRadius)
                    phase='sweep'
                else sweep=result; child=nil end
            end
            return false
        end
        local other=plan[kind][index]
        if not other then
            if kind=='obstacles' then kind='traffic'
            elseif kind=='traffic' then kind='reservations'
            else return true,true end
            index=1; return false
        end
        index=index+1
        local vehicle=other.vehicle or other.owner
        if vehicle~=driver.vehicle and not (vehicle.getRootVehicle and vehicle:getRootVehicle()==driver.vehicle) then
            local conflict=kind=='obstacles' and VehicleRouteConflict.findConflict(sweep,other.rig) or
                kind~='obstacles' and VehicleRouteConflict.findSweepConflict(sweep,other.sweep or other.bay.corridor)
            if conflict then return true,false end
        end
        return false
    end}
end
