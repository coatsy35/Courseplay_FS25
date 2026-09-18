-- Test-only planar GIANTS adapters. Production algorithms are loaded, not copied.
package.path = ROOT .. '/scripts/?.lua;' .. ROOT .. '/scripts/util/?.lua;'
    .. ROOT .. '/scripts/geometry/?.lua;' .. ROOT .. '/scripts/courseGenerator/?.lua;'
    .. ROOT .. '/scripts/pathfinder/?.lua;' .. ROOT .. '/scripts/ai/util/?.lua;'
    .. ROOT .. '/scripts/ai/turns/?.lua;' .. ROOT .. '/scripts/ai/?.lua;' .. package.path
require('CpObject')
g_time = 0
-- CP uses this flag to select standalone logging instead of GIANTS log helpers.
g_currentMission = { terrainRootNode = 0, mock = true }
CpDebug = { DBG_TURN = 1, DBG_COURSES = 2, DBG_PATHFINDER = 3 }
CpDebug.isChannelActive = function() return false end
CpUtil = { debugVehicle = function() end, getCurrentVehicle = function() end,
    getName = function() return 'Test implement' end }
CourseGenerator = { cRowWaypointDistance = 5 }
function getTerrainHeightAtWorldPos() return 0 end
math.sign = function(x) return x < 0 and -1 or (x > 0 and 1 or 0) end
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end
table.clone = function(t) local c = {}; for k,v in pairs(t) do c[k] = v end; return c end
MathUtil = {
    vector2Length = function(x,z) return math.sqrt(x*x+z*z) end,
    vector2Normalize = function(x,z) local d=math.sqrt(x*x+z*z); return x/d,z/d end,
    getPointPointDistance = function(x,z,u,v) return math.sqrt((x-u)^2+(z-v)^2) end,
    getYRotationFromDirection = function(x,z) return math.atan2(x,z) end,
    getDirectionFromYRotation = function(t) return math.sin(t),math.cos(t) end,
    clamp = math.clamp
}
function localDirectionToWorld(n,x,y,z)
    return x*math.cos(n.t)+z*math.sin(n.t),y,-x*math.sin(n.t)+z*math.cos(n.t)
end
function localToWorld(n,x,y,z)
    local u,v,w=localDirectionToWorld(n,x,y,z); return n.x+u,v,n.z+w
end
function worldToLocal(n,x,y,z)
    local u,w=x-n.x,z-n.z
    return u*math.cos(n.t)-w*math.sin(n.t),y,u*math.sin(n.t)+w*math.cos(n.t)
end
function localToLocal(a,b,x,y,z) return worldToLocal(b,localToWorld(a,x,y,z)) end
function localDirectionToLocal(a,b,x,y,z)
    local u,v,w=localDirectionToWorld(a,x,y,z)
    return u*math.cos(b.t)-w*math.sin(b.t),v,u*math.sin(b.t)+w*math.cos(b.t)
end
function getWorldTranslation(n) return n.x,0,n.z end
function getWorldRotation(n) return 0,n.t,0 end
function getRotation(n) return 0,n.t-(n.parent and n.parent.t or 0),0 end
-- Corner manoeuvres use temporary parented GIANTS nodes.
CpUtil.createNode=function(name,x,z,t,parent)
    if parent then local wx,_,wz=localToWorld(parent,x,0,z); return {x=wx,z=wz,t=parent.t+t,parent=parent} end
    return {x=x,z=z,t=t}
end
CpUtil.destroyNode=function() end
function createTransformGroup() return {x=0,z=0,t=0} end
function link(parent,node) if type(parent)=="table" then node.parent=parent end end
function delete() end
function unlink(n) n.parent=nil end
function setTranslation(n,x,y,z)
    if n.parent then n.x,_,n.z=localToWorld(n.parent,x,y,z) else n.x,n.z=x,z end
end
function setRotation(n,x,t,z) n.t=t+(n.parent and n.parent.t or 0) end
require('CpMathUtil')
require('Logger')
Logger.debug = function() end
Logger.debugSparse = function() end
require('Vector')
require('State3D')
require('AnalyticSolution')
require('Dubins')
require('ReedsShepp')
require('ReedsSheppSolver')
require('WaypointAttributes')
require('Waypoint')
require('Course')
require('AIUtil')
require('PathfinderUtil')
require('Corner')
require('TurnContext')
require('TurnManeuver')
require('AITurn')
require('AIReverseDriver')
require('WorkStartHandler')
require('WorkEndHandler')
require('RowPattern')

function rowSequence(name,count,rowsPerLand,circles,skip,clockwise,inside)
    local pattern
    if name == 'spiral' then pattern=CourseGenerator.RowPatternSpiral(clockwise,inside)
    elseif name == 'lands' then pattern=CourseGenerator.RowPatternLands(clockwise == nil or clockwise,rowsPerLand)
    elseif name == 'racetrack' then pattern=CourseGenerator.RowPatternRacetrack(circles)
    elseif (skip or 0)>0 then pattern=CourseGenerator.RowPatternSkip(skip,false)
    else pattern=CourseGenerator.RowPatternAlternating() end
    return pattern:getSequence(count)
end

-- Configuration and vehicle access are mocked; all path/offset/lowering maths stays in CP.
g_vehicleConfigurations = {
    getRecursively = function(_, vehicle, key)
        if key == 'tightTurnOffsetDistanceInTurns' then return vehicle.tightDistance end
    end
}
AIUtil.canReverse = function(vehicle) return vehicle.allowReverse end
AIUtil.getReverserNode = function(vehicle) return vehicle.reverser,'bench implement axle' end
local getRuntimeTowBarLength=AIUtil.getTowBarLength
AIUtil.getTowBarLength=function(vehicle)
    if vehicle.benchTowBarLength~=nil then return vehicle.benchTowBarLength or nil end
    return getRuntimeTowBarLength(vehicle)
end
SowingMachine = {}
AIUtil.hasAIImplementWithSpecialization = function(v) return v.drill end
WorkWidthUtil = { getAIMarkers = function(object) return object.left,object.right,object.back end }
local function setting(value) return {getValue=function() return value end} end

function makeRig(p)
    local steeringLength=p.mounted and 0 or p.hitch+p.length
    local node={x=p.turnX or 0,z=p.turnZ or (p.clearance+p.extension),t=p.turnTheta or 0}
    local vehicle={lastSpeed=p.speed/1000, drill=p.drill, tightDistance=p.tightDistance,
        allowReverse=p.allowReverse,
        reverser={x=node.x-math.sin(node.t)*(p.hitch+(p.mounted and 0 or p.length)),z=node.z-math.cos(node.t)*(p.hitch+(p.mounted and 0 or p.length)),t=node.t},
        getAIDirectionNode=function() return node end}
    if p.articulated then vehicle.spec_articulatedAxis={componentJoint=true} end
    local workStart={x=(p.targetExplicit or (p.targetX or 0)~=0) and p.targetX or p.side*((p.rowSpacing or 0)>0 and p.rowSpacing or p.width),z=p.targetZ or 0,t=math.rad(p.targetHeading or 180)}
    if p.turnType == 'headlandLoop' then
        workStart={x=0,z=-p.width/2,t=p.side*math.pi/2}
    end
    local endX,_,endZ=localToWorld(workStart,0,0,p.front)
    local context=setmetatable({frontMarkerDistance=-p.front,backMarkerDistance=-p.back,
        turnEndForwardOffset=p.front,workStartNode=workStart,
        vehicleAtTurnEndNode={x=endX,z=endZ,t=workStart.t}},TurnContext)
    context.isLeftTurn=function() return p.side < 0 end
    context.getHeadlandAngle=function() return math.pi/2 end
    context.getTurnEndForwardOffset=function(self) return self.turnEndForwardOffset end
    local course
    if p.entry then
        local points={}
        for z=10,-80,-1 do table.insert(points,{x=workStart.x,z=z}) end
        course=Course(vehicle,points,true)
        TurnManeuver.setLowerImplements(course,course:getLength(),true)
    else
        local turnClass=({dubins=DubinsTurnManeuver,headlandLoop=LoopTurnManeuver,
            reedsShepp=ReedsSheppTurnManeuver})[p.turnType or 'dubins']
        local available=(p.enforceBoundary or p.allowReverse) and (p.headland-node.z) or math.huge
        local manoeuvre=turnClass(vehicle,context,node,p.radius,p.width,steeringLength,available)
        course=manoeuvre:getCourse()
        -- Continue onto a straight synthetic field row after CP's generated turn.
        local last=course.waypoints[#course.waypoints]
        local continuation={}
        for d=1,(p.turnType == 'dubins' and math.max(80, p.fieldLength or 0) or 0) do
            continuation[d]={x=last.x+d*math.sin(workStart.t),z=last.z+d*math.cos(workStart.t),
                turnControls={[TurnManeuver.LOWER_IMPLEMENT_AT_TURN_END]=true}}
        end
        course:appendWaypoints(continuation)
    end
    local turn=setmetatable({vehicle=vehicle,steeringLength=steeringLength,
        turnCourse=course,enableTightTurnOffset=p.tight,debug=function() end},CourseTurn)
    local handler=setmetatable({vehicle=vehicle,settings={turnSpeed=setting(p.speed*3.6)},
        logger={debugSparse=function() end},driveStrategy={
            getLoweringDurationMs=function() return p.lowerSeconds*1000 end,
            getImplementLowerEarly=function() return p.lowerEarly end}},WorkStartHandler)
    local endHandler=setmetatable({logger={debugSparse=function() end},driveStrategy={
        getImplementRaiseLate=function() return p.raiseLate end}},WorkEndHandler)
    return {course=course,turn=turn,handler=handler,endHandler=endHandler,
        workStart=workStart,vehicle=vehicle,node=node}
end

function reverseCorrection(length,crossTrack,orientation,hitchAngle)
    local driver=setmetatable({steeringLength=length},AIReverseDriver)
    return driver:calculateHitchCorrectionAngle(crossTrack,orientation,0,hitchAngle)
end

function readPath(rig)
    local result={}
    for i,wp in ipairs(rig.course.waypoints) do
        result[i]={x=wp.x,z=wp.z,t=wp.yRot,reverse=wp.rev or false,lower=TurnManeuver.hasTurnControl(rig.course,i,
            TurnManeuver.LOWER_IMPLEMENT_AT_TURN_END) or false}
    end
    return result
end

function shouldRaise(rig,x,z,t,width,depth)
    local n={x=x,z=z,t=t}
    local bx,_,bz=localToWorld(n,0,0,-depth)
    local object={left=n,back={x=bx,z=bz,t=t}}
    return rig.endHandler:shouldRaiseThisImplement(object,{x=0,z=0,t=0})
end

function shouldRaiseAt(rig,x,z,t,width,depth,ex,ez,et)
    local n={x=x,z=z,t=t}
    local bx,_,bz=localToWorld(n,0,0,-depth)
    return rig.endHandler:shouldRaiseThisImplement({left=n,back={x=bx,z=bz,t=t}},{x=ex,z=ez,t=et})
end

function shouldLowerAt(rig,x,z,t,width,depth,speed,ex,ez,et,reversing)
    rig.workStart={x=ex,z=ez,t=et}
    return shouldLower(rig,x,z,t,width,depth,speed,reversing)
end

function changeWaypoint(rig,ix)
    rig.course:setCurrentWaypointIx(ix)
    rig.turn:onWaypointChange(ix)
    return rig.course.offsetX
end

function shouldLower(rig,x,z,t,width,depth,speed,reversing)
    local n={x=x,z=z,t=t}
    local function marker(dx,dz)
        local u,_,v=localToWorld(n,dx,0,dz); return {x=u,z=v,t=t}
    end
    local object={rootNode=n,left=marker(width/2,0),right=marker(-width/2,0),back=marker(0,-depth)}
    rig.vehicle.lastSpeed=speed/1000
    return rig.handler:shouldLowerThisImplement(object,rig.workStart,reversing or false)
end

function nextTrailerHeading(heading,hitchHeading,distance,length)
    -- CP uses x/y heading, whereas the adapter uses GIANTS x/z heading.
    local state=State3D(0,0,CpMathUtil.angleFromGame(hitchHeading),0,nil,nil,nil,
        CpMathUtil.angleFromGame(heading))
    return CpMathUtil.angleToGame(state:getNextTrailerHeading(distance,length))
end

-- Direct production CP sharp-corner path, with its runtime turn controls.
function headlandCorner(p,x,z,incoming,outgoing,startX,startZ,startHeading)
    local node={x=startX,z=startZ,t=startHeading or incoming}
    local vehicle={getAIDirectionNode=function() return node end,tightDistance=p.tightDistance}
    if p.articulated then vehicle.spec_articulatedAxis={componentJoint=true} end
    local steeringLength=p.mounted and 0 or p.hitch+p.length
    local work=headlandWork(p,x,z,incoming,outgoing)
    local workStart={x=work.startX,z=work.startZ,t=outgoing}
    local endX,_,endZ=localToWorld(workStart,0,0,p.front)
    local context=setmetatable({frontMarkerDistance=-p.front,backMarkerDistance=-p.back,
        turnEndForwardOffset=p.front,workStartNode=workStart,
        vehicleAtTurnEndNode={x=endX,z=endZ,t=outgoing}},TurnContext)
    context.isLeftTurn=function() return CpMathUtil.getDeltaAngle(outgoing,incoming)<0 end
    context.createCorner=function(_,v,r)
        return Corner(v,math.deg(incoming),{x=x,z=z},math.deg(outgoing),{x=x,z=z},r,0)
    end
    local manoeuvre
    if p.loopTurnsOnHeadland then
        manoeuvre=LoopTurnManeuver(vehicle,context,node,p.radius,p.width,steeringLength)
    else
        manoeuvre=HeadlandCornerTurnManeuver(vehicle,context,node,p.radius,p.width,nil,steeringLength)
    end
    local course=manoeuvre:getCourse()
    local result={}
    local previousOffset=0
    for i,w in ipairs(course.waypoints) do
        if steeringLength>0 and (not p.loopTurnsOnHeadland or (p.tight and course:getUseTightTurnOffset(i))) then
            previousOffset=AIUtil.calculateTightTurnOffsetForTurnManeuver(vehicle,steeringLength,course,i,previousOffset)
        else previousOffset=0 end
        local change=TurnManeuver.hasTurnControl(course,i,TurnManeuver.CHANGE_TO_FWD_WHEN_REACHED)
        local target=change and course.waypoints[change]
        result[i]={x=w.x,z=w.z,t=w.yRot,reverse=w.rev or false,offset=previousOffset,
            changeForwardX=target and target.x,changeForwardZ=target and target.z,
            changeWhenAligned=TurnManeuver.hasTurnControl(course,i,TurnManeuver.CHANGE_DIRECTION_WHEN_ALIGNED) or false,
            lower=TurnManeuver.hasTurnControl(course,i,TurnManeuver.LOWER_IMPLEMENT_AT_TURN_END) or false}
    end
    return result
end

-- The analytic expansion used by CP's turn pathfinder, rather than a row
-- turn with work-marker offsets and an artificial working-row continuation.
function connectingPath(p,x,z,t,gx,gz,gt)
    -- AIDriveStrategyCourse disables reverse pathfinding with a wheeled towed
    -- implement, independently of the analytic row-turn reverse fallback.
    local solver=(p.allowReverse and p.mounted) and ReedsSheppSolver(ReedsShepp.ForwardEndingPathWords)
        or PathfinderUtil.dubinsSolver
    local path=PathfinderUtil.findAnalyticPath(solver,{x=x,z=z,t=t},0,0,
        {x=gx,z=gz,t=gt},0,0,p.radius)
    assert(path,'CP could not generate an analytic connection')
    local course=Course.createFromAnalyticPath({},path,true)
    local result={}
    local vehicle={benchTowBarLength=not p.mounted and p.hitch+p.length or false}
    local offset=0
    for i,w in ipairs(course.waypoints) do
        course:setCurrentWaypointIx(i)
        -- DRIVING_TO_WORK_START_WAYPOINT uses the ordinary fieldwork correction,
        -- not the row-turn correction limited by tightTurnOffsetDistanceInTurns.
        offset=AIUtil.calculateTightTurnOffset(vehicle,p.radius,course,offset)
        result[i]={x=w.x,z=w.z,t=w.yRot,reverse=w.rev or false,offset=offset}
    end
    return result
end

function connectionGoal(p,x,z,t)
    local context=setmetatable({frontMarkerDistance=-p.front,turnEndForwardOffset=p.front,
        workStartNode={x=x,z=z,t=t}},TurnContext)
    local node,offset=context:getTurnEndNodeAndOffsets(p.mounted and 0 or p.hitch+p.length)
    local gx,_,gz=localToWorld(node,0,0,offset)
    return gx,gz
end

function waypointOffset(x,z,t,offset)
    local waypoint=setmetatable({x=x,z=z,y=0,dx=math.sin(t),dz=math.cos(t)},Waypoint)
    return waypoint:getOffsetPosition(offset,0)
end

-- Fieldwork updates this correction at the original course waypoints, including
-- rounded working headlands. Do not apply the PW's row-turn distance limit here.
function workingCourseOffsets(p,points)
    local waypoints={}
    for i,w in ipairs(points) do waypoints[i]={x=w[1],z=w[2]} end
    local course=Course({},waypoints,true)
    local vehicle={benchTowBarLength=not p.mounted and p.hitch+p.length or false}
    local offset,result=0,{}
    for i=1,#waypoints do
        course:setCurrentWaypointIx(i)
        offset=AIUtil.calculateTightTurnOffset(vehicle,p.radius,course,offset)
        result[i]=offset
    end
    return result
end

-- CP's corner work boundaries and straight finishing course. These nodes are
-- synthetic AI markers; the overshoot and course length are production code.
function headlandWork(p,x,z,incoming,outgoing)
    local context=setmetatable({workWidth=p.width,backMarkerDistance=-p.back,
        directionChangeDeg=math.deg(CpMathUtil.getDeltaAngle(outgoing,incoming)),
        debug=function() end},TurnContext)
    local overshoot=math.min(context:getOvershootForHeadlandCorner(),p.width*2)
    local ex,_,ez=localToWorld({x=x,z=z,t=incoming},0,0,-p.width/2+overshoot)
    local sx,_,sz=localToWorld({x=x,z=z,t=outgoing},0,0,-p.width/2-overshoot)
    context.workEndNode={x=ex,z=ez,t=incoming}
    local course=context:createFinishingRowCourse({},context.workEndNode)
    local finish=course.waypoints[#course.waypoints]
    return {endX=ex,endZ=ez,startX=sx,startZ=sz,finishX=finish.x,finishZ=finish.z,
        overshoot=overshoot}
end
