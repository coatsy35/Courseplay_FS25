g_Courseplay={globalSettings={getSettings=function() return {
    maxDeltaAngleAtGoalDeg={getValue=function() return 30 end},
    deltaAngleRelaxFactorDeg={getValue=function() return 1 end}} end}}
-- Test-only engine boundary: real native planner, constraints and collision detector.
CourseGenerator.isRunningInGame=function() return true end
require('BinaryHeap')
require('AStar')
require('HybridAStarWithAStarInTheMiddle')
require('JumpPointSearch')
require('PathfinderCollisionDetector')
require('PathfinderConstraints')
require('PathfinderController')
require('CpUnloaderQueueGeometry')
Polyline=function(points) return points end
CourseGenerator.addDebugPolyline=function() end
function openIntervalTimer() return 0 end
function readIntervalTimerMs() return 0 end
function closeIntervalTimer() end
function printCallstack() end
Logger.error=function() end
ClassIds={TERRAIN_TRANSFORM_GROUP=1}
function getHasClassId() return false end
g_currentMission.nodeToObject={}
local G=CpUnloaderQueueGeometry
obstacles={}
probeCount=0
function overlapBox(x,y,z,rx,t,rz,halfWidth,height,halfLength,callback,detector)
    probeCount=probeCount+1
    local box=G.rectangle({x=x,z=z,heading=t},{width=halfWidth*2,length=halfLength*2},0)
    for id, obstacle in ipairs(obstacles) do
        if G.overlap(box,obstacle) then detector[callback](detector,id) end
    end
end
PathfinderUtil.setWorldPositionAndRotationOnTerrain=function(n,x,z,t) n.x=x; n.z=z; n.t=t end
PathfinderUtil.addOverlapBox=function() end
CpFieldUtil={isOnField=function() return true end}
PathfinderUtil.isWorldPositionOwned=function() return true end
PathfinderUtil.hasFruit=function() return false,0 end
AIUtil.getTowBarLength=function() return 3 end
AIUtil.getTurningRadius=function() return 4.7 end
AIUtil.getDirectionNode=function(vehicle) return vehicle:getAIDirectionNode() end
-- Logged whole-vehicle envelope, including the attached header. Engine model
-- scanning is substituted; actual rectangle overlap and native filtering run.
PathfinderUtil.VehicleData=function(vehicle)
    return {getVehicle=function() return vehicle end,
        getVehicleOverlapBoxParams=function() return {width=8.3,length=6.5,xOffset=0,zOffset=0} end,
        getTowedImplement=function() return nil end}
end
v.getRootVehicle=function(self) return self end
u.settings.penaltyFactor={getValue=function() return 1 end}
u.settings.useJps={getValue=function() return true end}
local node=v:getAIDirectionNode()
node.x=-425.57; node.z=-329.94; node.t=math.rad(169)
-- Actual first connector coordinates from the saved right-hand CR11 course.
local points={{x=-439.49,z=-335.41},{x=-439.98,z=-332.70},{x=-440.96,z=-327.30},
    {x=-441.45,z=-324.58},{x=-441.94,z=-321.88},{x=-442.43,z=-319.17},
    {x=-442.92,z=-316.48},{x=-443.41,z=-313.76},{x=-443.90,z=-311.05},
    {x=-444.88,z=-305.64},{x=-445.37,z=-302.94},{x=-445.86,z=-300.23}}
saved=Course(v,points,true)
u.connectorEntry={course=saved,context=PathfinderContext(v),node={},zOffset=0,
    nextAttempt=g_time,index=1,candidates={7,10,11}}
u.pathfinderController=PathfinderController(v,4.7)
function driveEntrySearch()
    for frame=1,2000 do
        g_time=g_time+33
        u.pathfinderController:update(33)
        u:updateHarvesterConnectorEntry()
        if not u.connectorEntry then return frame end
        assert(not u.connectorEntry.triedFullRoute,'local entry should solve this representative case')
    end
    error('local search failed to progress')
end
