-- Execution adapter for the experimental envelope planner. Keep headland
-- corners, ordinary Dubins/Reeds-Shepp turns and WorkStartHandler unchanged.
-- Only vehicles opting into envelopeAlignedTurns instantiate this strategy.
EnvelopeCourseTurn = CpObject(CourseTurn)

function EnvelopeCourseTurn:init(vehicle,strategy,ppc,proximityController,context,course,width)
    CourseTurn.init(self,vehicle,strategy,ppc,proximityController,context,course,width)
    self.name='EnvelopeCourseTurn'
    self:addState('ENVELOPE_PREPARING')
    self:addState('ENVELOPE_PLANNING')
    self:addState('ENVELOPE_STOPPED')
    self.enableTightTurnOffset=false
    self.forceTightTurnOffset=false
end

function EnvelopeCourseTurn:log(format,...)
    -- One record per transition, independent of the debug channel: a tester
    -- must be able to tell a selected new turn from a stock CP fallback.
    Logging.info('[CP envelope] %s: '..format,CpUtil.getName(self.vehicle),...)
end

function EnvelopeCourseTurn:startTurn()
    -- finishRow has already raised the tools. Stop before measuring so that
    -- time-sliced planning starts from the position the vehicle will execute.
    self.state=self.states.ENVELOPE_PREPARING
    self.prepareStarted=g_currentMission.time
    self:log('preparing row %d -> %d',self.turnContext.turnStartWpIx,self.turnContext.turnEndWpIx)
end

function EnvelopeCourseTurn:stopWithReason(reason)
    if self.state==self.states.ENVELOPE_STOPPED then return end
    self.state=self.states.ENVELOPE_STOPPED
    self:release()
    self:log('STOP: %s. No late-lowering or unchecked-path fallback.',tostring(reason))
    self.driveStrategy:raiseImplements()
    self.vehicle:stopCurrentAIJob(AIMessageCpErrorNoPathFound.new())
end

function EnvelopeCourseTurn:release()
    if self.geometry and self.geometry.activeTracker then self.geometry.activeTracker:delete() end
    self.planner=nil
end

function EnvelopeCourseTurn:prepare()
    if self.vehicle:getLastSpeed()>0.2 then return end
    local rotated=true
    for _,controller in pairs(self.driveStrategy.controllers) do
        if controller.isRotatablePlow and controller:isRotatablePlow() then
            local side=self.turnContext:shouldPlowBeOnTheLeft()
            if not controller:isRotatedToSide(side) then
                rotated=false
                if not controller:isRotationActive() then controller:rotate(side) end
            end
        end
    end
    -- Stock CP centres a reversible plough during a turn. This planner instead
    -- measures its NEXT working side while raised, and checks that larger body
    -- throughout the turn. Measuring the centre pose would underestimate width.
    if not rotated then
        if g_currentMission.time-self.prepareStarted>15000 then self:stopWithReason('plough rotation did not finish') end
        return
    end
    self.state=self.states.ENVELOPE_PLANNING
    self.planner=coroutine.create(function()
        local p,reason=EnvelopeTurnGeometry.capture(self)
        if not p then return {ok=false,reason=reason} end
        self.geometry=p
        self:log('geometry: radius %.2f, width %.2f, hitch %.2f/%.2f, axle %.2f, front %.2f, pike %.1f degrees, headland seed %.1f',
            p.radius,p.width,p.hitchX,p.hitchZ,p.length or 0,p.front,math.deg(math.atan(p.slope)),p.headland)
        local samples=0
        p.yield=function()
            samples=samples+1
            if samples%10==0 then coroutine.yield() end
        end
        return EnvelopeTurnPlanner.plan(p)
    end)
end

function EnvelopeCourseTurn:updatePlanner()
    local started=getTimeSec()
    local ok,result
    repeat
        ok,result=coroutine.resume(self.planner)
        if not ok then self:stopWithReason('planner error: '..tostring(result)); return end
    until coroutine.status(self.planner)=='dead' or getTimeSec()-started>=0.004
    if coroutine.status(self.planner)~='dead' then return end
    self.planner=nil
    if not result.ok then self:stopWithReason(result.reason); return end
    self.result=result
    local points={}
    for i,wp in ipairs(result.path) do
        points[i]={x=wp.x,z=wp.z}
        if i>=result.tailStart then
            TurnManeuver.addTurnControlToWaypoint(points[i],TurnManeuver.LOWER_IMPLEMENT_AT_TURN_END,true)
        end
    end
    self.turnCourse=Course(self.vehicle,points,true)
    self.ppc:setCourse(self.turnCourse)
    self.ppc:initialize(1)
    self.state=self.states.TURNING
    self:log('SELECTED steering-led forward turn: %d trials, radius %.2f, bend %.1f, straight %.1f, bias %.3f, outward %.1f, predicted edge error %.3f m',
        result.attempts,result.radius,result.bend,result.straight,result.bias,result.extension,result.entryError)
    -- Reuse CP's per-object commands/controller events/state changes, but let
    -- this strategy own the stricter admission test. This is an INSTANCE method;
    -- the global WorkStartHandler and other turn strategies are unaffected.
    self.workStartHandler.shouldLowerThisImplement=function(handler,object,node,reversing)
        return self.lowerRequested or false,self.lastContact or -math.huge
    end
end

function EnvelopeCourseTurn:getDriveData(dt)
    if self.state==self.states.ENVELOPE_PREPARING then self:prepare(); return nil,nil,true,0 end
    if self.state==self.states.ENVELOPE_PLANNING then self:updatePlanner(); return nil,nil,true,0 end
    if self.state==self.states.ENVELOPE_STOPPED then return nil,nil,true,0 end
    local gx,gz,forward,speed=CourseTurn.getDriveData(self,dt)
    if self.geometry and self.state~=self.states.ENVELOPE_STOPPED then
        local aligned,error,angle,contact,state=EnvelopeTurnGeometry.assessLive(self.geometry,self.vehicle)
        self.lastContact=contact
        if math.abs(EnvelopeTurnPlanner.wrap(state.t-state.phi))>self.geometry.maxArticulation then
            self:stopWithReason('live articulation exceeds the allowed angle'); return nil,nil,true,0
        end
        if not EnvelopeTurnPlanner.checkFootprint(self.geometry,state) then
            self:stopWithReason('live footprint reached the reserved field edge'); return nil,nil,true,0
        end
        if self.lowerRequested and not aligned then
            self:stopWithReason(string.format('alignment lost while lowering (edge %.3f m, angle %.2f degrees)',error,math.deg(angle)))
            return nil,nil,true,0
        end
    end
    return gx,gz,forward,math.min(speed or self:getForwardSpeed(),8,self.entrySpeedLimit or math.huge)
end

function EnvelopeCourseTurn:endTurn(dt)
    local aligned,error,angle,contact=EnvelopeTurnGeometry.assessLive(self.geometry,self.vehicle)
    self.lastContact=contact
    -- Check BEFORE hand-off clears geometry. Checking only after getDriveData
    -- returns would miss a loss of alignment on the very frame of entry.
    if self.lowerRequested and not aligned then
        self:stopWithReason(string.format('alignment lost before entry (edge %.3f m, angle %.2f degrees)',error,math.deg(angle)))
        return false
    end
    -- Approach the first physical work corner slowly, stopping 0.5 m before
    -- contact. Waiting there decouples hydraulic delay from alignment: stopping
    -- earlier in a curve would freeze a trailer before it could straighten.
    self.entrySpeedLimit=math.min(5,3.6*math.sqrt(math.max(0,2*(-contact-0.5))))
    if not self.lowerRequested then
        if contact>-0.65 then
            if not aligned then
                self:stopWithReason(string.format('entry not aligned (edge %.3f m, angle %.2f degrees)',error,math.deg(angle)))
                return false
            end
            if self.vehicle:getLastSpeed()>0.2 then return false end
            self.lowerRequested=true
            self.loweringStarted=g_currentMission.time
            self:log('LOWER: live edge error %.3f m, angle %.2f degrees, first work corner %.2f m before entry',error,math.deg(angle),-contact)
        else return true end
    end
    self.workStartHandler:lowerImplementsAsNeeded(self:getLowerImplementNode(),false)
    local hydraulicReady=g_currentMission.time-self.loweringStarted >= self.driveStrategy:getLoweringDurationMs()
    if not hydraulicReady or not self.driveStrategy:getCanContinueWork() then
        if g_currentMission.time-self.loweringStarted>30000 then self:stopWithReason('implement did not become ready after lowering') end
        return false
    end
    self.entrySpeedLimit=3
    -- Do not hand back early: the base resume method lowers implements without
    -- an envelope check. Here every tool is ready AND live-aligned at contact.
    if contact>=0 then
        self:log('ENTRY: live edge error %.3f m, angle %.2f degrees; resuming fieldwork',error,math.deg(angle))
        self.geometry=nil
        self:resumeFieldworkAfterTurn(self.turnContext.turnEndWpIx)
    end
    return true
end

function EnvelopeCourseTurn:onWaypointPassed(ix,course)
    -- AITurn normally resumes unconditionally at the last waypoint. That would
    -- bypass the entry gate when a predicted turn failed to track in the game.
    if self.result and ix==course:getNumberOfWaypoints() then
        self:stopWithReason('end of approach reached before an aligned working entry')
    end
end

function EnvelopeCourseTurn:onBlocked()
    -- Stock recovery builds a different route. It has not passed this planner's
    -- checks, so do not silently swap to it while claiming an aligned turn.
    self:stopWithReason('turn blocked by an obstacle')
end
