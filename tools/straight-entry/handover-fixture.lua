-- Actual fieldwork handover and Course waypoint search, with vehicle/event boundaries.
package.path = ROOT .. '/scripts/ai/strategies/?.lua;' .. package.path
require('AIDriveStrategyCourse')
Utils={overwrittenFunction=function(original) return original end}
VariableWorkWidth={}
AIDriveStrategyFieldCourse={}
require('AIDriveStrategyFieldWorkCourse')
AIMessageCpErrorNoPathFound={new=function() return 'noPath' end}
function handoverFixture(points, corner, x, z, heading)
    local node={x=x,z=z,t=heading}
    local events={}
    local vehicle={getAIDirectionNode=function() return node end,
        stopCurrentAIJob=function(_,reason) events[#events+1]='stop:'..reason end}
    local course=Course(vehicle, points, false)
    -- The marker is course-generator input, not the decision being tested.
    if corner > 0 then course.waypoints[corner+1].attributes:setHeadlandTurn(true) end
    local strategy=setmetatable({fieldWorkCourse=course,course={temporary=true},vehicle=vehicle,workWidth=4,
        debug=function() end,ppc={setNormalLookaheadDistance=function() events[#events+1]='lookahead' end},
        startWaitingForLower=function() events[#events+1]='wait' end,
        lowerImplements=function() events[#events+1]='lower' end,
        raiseImplements=function() events[#events+1]='raise' end,
        startCourse=function(_,c,ix) assert(c==course); events[#events+1]='work:'..ix end,
        startTurn=function(self,ix) assert(self.course==course); events[#events+1]='turn:'..ix end},
        AIDriveStrategyFieldWorkCourse)
    strategy:resumeFieldworkAfterTurn(1)
    return table.concat(events, ',')
end