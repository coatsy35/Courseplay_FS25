-- GIANTS animation and marker boundary; event ordering, readiness, lowering and
-- turn speed handling below execute the shipped controller/handler/turn methods.
package.path = ROOT .. '/scripts/ai/controllers/?.lua;' .. package.path
require('ImplementController')
require('PlowController')
CpUtil.debugImplement=function() end
g_updateLoopIndex=0
AIUtil.hasAIImplementWithSpecialization=function() return false end
SowingMachine={}
VehicleStateChange={AI_START_LINE=1}
AIDriveStrategyCourse={onTurnEndProgressEvent='onTurnEndProgress',onLoweringEvent='onLowering'}
WorkWidthUtil={getAIMarkers=function(o) return o.left,o.right,o.back end}

function preparationFixture(speed, side, enabled)
    local function setting(v) return {getValue=function() return v end} end
    local settings={turnSpeed=setting(speed),fieldSpeed=setting(speed+5),reverseSpeed=setting(8)}
    local target={x=0,z=0,t=0}
    local tool={rootNode={x=0,z=-28,t=math.rad(20)},
        left={x=2.8,z=-28,t=0},right={x=-2.8,z=-28,t=0},back={x=0,z=-41.7,t=0},
        animation=.5,playing=false,lowerCount=0,rotateCount=0}
    function tool:getAnimationTime() return self.animation end
    function tool:getIsAnimationPlaying() return self.playing end
    function tool:setRotationMax(wanted)
        self.rotateCount=self.rotateCount+1; self.playing=true; self.wanted=wanted
    end
    function tool:aiImplementStartLine() self.lowerCount=self.lowerCount+1 end
    local directionNode={x=0,z=-14,t=0}
    -- Separate the drawbar pivot frames from the angled working frame.
    tool.drawbarNode={x=0,z=-15,t=0}
    tool.hitchNode=directionNode
    tool.components={{node=tool.rootNode},{node=tool.drawbarNode},{node=tool.hitchNode}}
    tool.componentJoints={{jointNode=tool.drawbarNode,componentIndices={2,3},rotLimit={0,math.pi/2,0}}}
    function tool:getActiveInputAttacherJoint() return {rootNode=self.hitchNode} end
    ImplementUtil.findJointNodeConnectingToNode=function(object)
        return object.drawbarNode,{object.drawbarNode},{{0,math.pi/2,0}}
    end
    local vehicle={lastSpeed=speed/3600,getLastSpeed=function() return speed end,
        getAIDirectionNode=function() return directionNode end,
        getCpSettings=function() return settings end,getChildVehicles=function() return {tool} end,
        raiseStateChange=function() end}
    local controller=setmetatable({vehicle=vehicle,implement=tool,towed=true,
        plowSpec={rotationPart={turnAnimation='rotate'}},lastPlowSide=CpTemporaryObject()},PlowController)
    local strategy={controllers={controller},getLoweringDurationMs=function() return 1000 end,
        getImplementLowerEarly=function() return true end,getCanContinueWork=function() return true end}
    function strategy:raiseControllerEvent(name,...)
        for _,c in ipairs(self.controllers) do if c[name] then c[name](c,...) end end
    end
    local context={straightEntryDistance=enabled and 45 or nil,shouldPlowBeOnTheLeft=function() return side end,
        turnEndWpIx=821}
    local handler=WorkStartHandler(vehicle,strategy,context)
    local ending={name='ENDING_TURN'}
    local turn=setmetatable({vehicle=vehicle,driveStrategy=strategy,settings=settings,workStartHandler=handler,
        turnContext=context,states={ENDING_TURN=ending},state=ending,ppc={isReversing=function() return false end},
        getLowerImplementNode=function() return target end,debug=function() end,resumed=0},CourseTurn)
    function turn:resumeFieldworkAfterTurn() self.resumed=self.resumed+1 end
    local f={tool=tool,controller=controller,turn=turn,handler=handler,vehicle=vehicle,strategy=strategy}
    function f:position(z)
        tool.left.z=z; tool.right.z=z; tool.back.z=z-13.7; tool.rootNode.z=z
    end
    function f:drive()
        local _,_,_,v=AITurn.getDriveData(turn,33)
        return v
    end
    return f
end
