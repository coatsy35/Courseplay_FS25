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
require('HeadlandLoopGeometry')
require('HeadlandLoopModel')
require('HeadlandLoopValidation')
require('HeadlandLoopReturn')
require('HeadlandLoopSearch')
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

g_vehicleConfigurations = {getRecursively = function() end}
Logging = {info = function() end}
ImplementUtil = {
    isWheeledImplement = function(o) return o.wheeled end,
    findJointNodeConnectingToNode = function(o)
        if o.internalPivotNode then
            return o.internalPivotNode, {o.internalPivotNode}, {{0,math.pi/3,0}}
        end
    end
}
WorkWidthUtil = {getAutomaticWorkWidthAndOffset = function(v) return v.detectedWidth or 0 end}
AIUtil.hasArticulatedAxis = function() return false end
CpFieldUtil = {
    getFieldAtWorldPosition = function() return mockMapFieldPolygon and {} or nil end,
    getFieldPolygon = function() return mockMapFieldPolygon end
}

function fixture(p)
    p = p or {}
    mockMapFieldPolygon = p.mapField
    local function body(z, width, length)
        local node = {x=0,z=z,t=0}
        local o = {rootNode=node,steeringAxleNode=node,wheeled=true,
            size={width=width,length=length},children={},componentJoints={},
            spec_wheels={wheels={{steering={steeringAxleScale=0}}}}}
        o.getAttachedImplements=function(self) return self.children end
        return o
    end
    local vehicle = body(0,3.5,8)
    vehicle.getAIDirectionNode=function(self) return self.rootNode end
    vehicle.detectedWidth=p.width or 25.6
    local drill = body(-9.8,9,11.15)
    drill.joint={node={x=0,z=-3.3,t=0}}
    drill.getActiveInputAttacherJoint=function(self) return self.joint end
    drill.getAIMarkers=function(self)
        return {x=vehicle.detectedWidth/2,z=-8.3,t=0}, {x=-vehicle.detectedWidth/2,z=-8.3,t=0}, {x=0,z=-11.2,t=0}
    end
    local cart = body(-9.8-4.47-(p.cartLength or 8.08),5.5,17)
    cart.joint={node={x=0,z=-14.27,t=0}}
    cart.getActiveInputAttacherJoint=function(self) return self.joint end
    vehicle.children={{object=drill}}; drill.children={{object=cart}}
    if p.single then drill.children={} end
    if p.internal then
        cart.internalPivotNode={x=0,z=-18.05,t=0}
        cart.joint.rootNode={x=0,z=-16.27,t=0}
        cart.components={{node=cart.rootNode},{node=cart.joint.rootNode}}
        cart.componentJoints={{jointNode=cart.internalPivotNode,componentIndices={1,2},rotLimit={0,math.pi/3,0}}}
    end
    if p.field then
        vehicle.cpGetFieldPolygon=function() return p.field end
        vehicle.cpGetIslandPolygons=function() return p.islands or {} end
    end
    local side=p.side or 1
    local goal={x=side*20,z=-10,t=side*math.pi/2}
    local x,_,z=localToWorld(goal,0,0,8.3)
    local context=setmetatable({frontMarkerDistance=-8.3,backMarkerDistance=-11.2,
        workStartNode=goal,vehicleAtTurnEndNode={x=x,z=z,t=goal.t},
        turnEndForwardOffset=8.3,vehicle=vehicle,workWidth=vehicle.detectedWidth},TurnContext)
    context.isLeftTurn=function() return side<0 end
    context.debug=function() end
    return vehicle,context,drill,cart
end
