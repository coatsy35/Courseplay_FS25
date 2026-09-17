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
require('FieldworkBoundary')
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
require('BulbTurnExtension')
require('TurnManeuver')
require('AITurn')
require('AIReverseDriver')
require('WorkStartHandler')
require('WorkEndHandler')

-- Only the GIANTS boundary is mocked. Courses, Dubins, offsets and field fitting
-- execute the runtime Lua files in the source tree or extracted test ZIP.
g_vehicleConfigurations = { getRecursively = function() end }
AIUtil.canReverse = function(v) return v.allowReverse end
AIUtil.getTurningRadius = function() return 9 end
AIUtil.getReverserNode = function(v) return v.reverser, 'fixture axle' end
function entryCourse(p)
    local node={x=0,z=p.startZ or 17.8,t=0}
    local width,radius=p.width or 5.6,p.radius or 9
    local goal={x=p.side*width,z=p.pike,t=math.pi}
    local gx,_,gz=localToWorld(goal,0,0,p.workOffset or 4)
    local c=setmetatable({frontMarkerDistance=p.front or -4,backMarkerDistance=p.back or -17.7,
        turnEndForwardOffset=p.workOffset or 4,workStartNode=goal,
        vehicleAtTurnEndNode={x=gx,z=gz,t=math.pi}},TurnContext)
    c.isHeadlandCorner=function() return false end
    c.isLeftTurn=function() return p.side<0 end
    c.getHeadlandAngle=function() return p.headlandAngle or math.pi/2 end
    c.getTurnEndForwardOffset=function() return p.pike end
    local v={allowReverse=p.allowReverse~=false,getAIDirectionNode=function() return node end,
        reverser={x=0,z=node.z-p.length,t=0}}
    c.vehicle=v; c.workWidth=width; c.turnStartWpIx=1; c.turnEndWpIx=2
    if p.enabled then c:setStraightEntryDistance(p.length,p.duration,p.speed) end
    local m=DubinsTurnManeuver(v,c,node,radius,width,p.length,p.room)
    local points={}
    for i,w in ipairs(m.course.waypoints) do
        points[i]={x=w.x,z=w.z,heading=w.yRot,reverse=w.rev}
    end
    return points,c,m.course
end
