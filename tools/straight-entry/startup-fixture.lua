-- Load production startup strategies; GIANTS registration and terrain queries
-- remain boundary stubs. Route generation uses the real AlignmentCourse/Dubins.
package.path = ROOT .. '/scripts/ai/strategies/?.lua;' .. package.path
require('AIDriveStrategyCourse')
TurnOnVehicle={setIsTurnedOn=function() end}
Utils={overwrittenFunction=function(original, replacement) return original end}
require('AIDriveStrategyDriveToFieldWorkStart')
CpFieldUtil={getFieldIdAtWorldPosition=function() return 1 end}
PathfinderUtil.hasFruit=function() return false end
PathfinderContext=function()
    local c={}
    for _,name in ipairs({'maxFruitPercent','areaToIgnoreFruit','useFieldNum','allowReverse'}) do
        c[name]=function(self) return self end
    end
    return c
end

function startupFixture(length, speed, front)
    local node={x=35,z=-70,t=math.rad(70)}
    local vehicle={getAIDirectionNode=function() return node end}
    AIUtil.getSteeringParameters=function() return 9,length end
    AIUtil.findLoweringDurationMs=function() return 1000 end
    local settings={turnSpeed={getValue=function() return speed end},avoidFruit={getValue=function() return false end}}
    local strategy=setmetatable({vehicle=vehicle,settings=settings,frontMarkerDistance=front,
        turningRadius=9,workWidth=5.6,debug=function() end,ppc={setCourse=function() end,initialize=function() end},
        setFrontAndBackMarkers=function() end,getAllowReversePathfinding=function() return false end},
        AIDriveStrategyDriveToFieldWorkStart)
    strategy.pathfinderController={findPathToWaypoint=function(_,context,course,ix,x,z)
        strategy.request={course=course,ix=ix,x=x,z=z}
    end}
    local points={}
    for i=0,20 do points[#points+1]={x=0,z=i*5} end
    local course=Course(vehicle,points,false)
    return strategy,course
end
