-- Execution adapter for the experimental envelope planner. Keep headland
-- corners, ordinary Dubins/Reeds-Shepp turns and WorkStartHandler unchanged.
-- Only vehicles opting into envelopeAlignedTurns instantiate this strategy.
EnvelopeCourseTurn = CpObject(CourseTurn)
-- Temporary test-build label; the packager uses the same value for its title.
EnvelopeCourseTurn.TEST_VERSION = '0.11'

function EnvelopeCourseTurn:init(vehicle,strategy,ppc,proximityController,context,course,width)
    CourseTurn.init(self,vehicle,strategy,ppc,proximityController,context,course,width)
    self.name='EnvelopeCourseTurn'
    self:addState('ENVELOPE_PREPARING')
    self:addState('ENVELOPE_PLANNING')
    self:addState('ENVELOPE_STOPPED')
    self:addState('ENVELOPE_ROTATING')
    self.enableTightTurnOffset=false
    self.forceTightTurnOffset=false
end

function EnvelopeCourseTurn:log(format,...)
    -- One record per transition, independent of the debug channel: a tester
    -- must be able to tell a selected new turn from a stock CP fallback.
    Logging.info('[CP envelope] v%s %s: '..format,EnvelopeCourseTurn.TEST_VERSION,CpUtil.getName(self.vehicle),...)
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
    if not self:ensureFieldBoundary() then return end
    -- AITurn.finishRow already emitted the stock onFinishRow event, which
    -- centres reversible ploughs. Wait for that animation; NEVER rotate to the
    -- next working side here, where the side arm can obstruct tractor steering.
    for _,controller in pairs(self.driveStrategy.controllers) do
        if controller.isRotatablePlow and controller:isRotatablePlow() then
            self.needsWorkingGeometry=true
            if controller:isRotationActive() then
                if g_currentMission.time-self.prepareStarted>30000 then self:stopWithReason('plough centring did not finish') end
                return
            end
        end
    end
    self:startPlanning()
end

-- Loaded courses can lack the generator's transient field polygon. Use CP's
-- normal asynchronous GIANTS/custom-field detector, including its islands.
-- Do not replace the hedge with a rectangle or disable containment to proceed.
function EnvelopeCourseTurn:ensureFieldBoundary()
    local v=self.vehicle
    if v.cpIsFieldBoundaryDetectionRunning and v:cpIsFieldBoundaryDetectionRunning() then
        self.boundaryWaitStarted=self.boundaryWaitStarted or g_currentMission.time
        if g_currentMission.time-self.boundaryWaitStarted>60000 then
            self:stopWithReason('field boundary detection timed out')
        end
        return false
    end
    local polygon=v.cpGetFieldPolygon and v:cpGetFieldPolygon()
    local position=EnvelopeTurnGeometry.pose(v:getAIDirectionNode())
    local goal=EnvelopeTurnGeometry.pose(self.turnContext.workStartNode)
    if polygon and #polygon>=3 and EnvelopeTurnPlanner.inside(position,polygon) and EnvelopeTurnPlanner.inside(goal,polygon) then
        return true
    end
    if self.boundaryStarted or not v.cpDetectFieldBoundary then
        self:stopWithReason('field boundary detection failed; no valid polygon for this turn')
        return false
    end
    self.boundaryStarted=g_currentMission.time
    self:log('detecting field boundary for loaded course at %.2f/%.2f',position.x,position.z)
    v:cpDetectFieldBoundary(position.x,position.z)
    return false
end

function EnvelopeCourseTurn:startPlanning(remainingPath)
    self.state=self.states.ENVELOPE_PLANNING
    self.planningStarted=g_currentMission.time
    self.planner={update=function()
        self:log('measuring %s envelope',self.needsWorkingGeometry and 'centred-turn' or 'working')
        local p,reason=EnvelopeTurnGeometry.capture(self)
        if not p then return {ok=false,reason=reason} end
        self.headlandSeed=self.headlandSeed or p.headland
        self.geometry=p
        p.approachHint=self.driveStrategy.envelopeApproachHints and self.driveStrategy.envelopeApproachHints[EnvelopeTurnPlanner.approachSide(p)]
        self:logGeometry(p)
        if remainingPath then
            -- Rotation may change hitch/axle/soil-marker positions. Validate
            -- the actual remaining approach with the freshly measured shape.
            local simulation=EnvelopeTurnPlanner.newSimulation(p,remainingPath,2,0.075,true,true)
            self.planner={update=function(_,budget)
                local result=simulation:update(budget)
                if not result then return nil end
                if result.ok then
                    result.attempts,result.straight,result.bend=0,0,0
                    result.radius,result.extension,result.bias=p.radius,0,0
                    result.retainedApproach=true
                    return result
                end
                self:log('working-position approach needs local correction: %s, predicted edge error %s m',
                    tostring(result.reason),tostring(result.error))
                self.planner=EnvelopeTurnPlanner.newApproachSearch(p)
                return nil
            end}
        else self.planner=EnvelopeTurnPlanner.newSearch(p) end
        return nil
    end}
end

function EnvelopeCourseTurn:logGeometry(p)
    if p.directionSource then
        self:log('trailer reference: %s, heading difference from steering axle %.3f degrees',p.directionSource,math.deg(p.directionOffset))
    end
    if p.declaredPivotX then
        self:log('selected pivot: %s, %.3f/%.3f; declared %.3f/%.3f; input coupling %.3f/%.3f',
            p.pivotSource,p.hitchX,p.hitchZ,p.declaredPivotX,p.declaredPivotZ,p.inputHitchX,p.inputHitchZ)
    end
    self:log('geometry: radius %.2f, width %.2f, hitch %.2f/%.2f, axle %.2f (lateral %.2f), front %.2f, pike %.1f degrees, headland seed %.1f',
        p.radius,p.width,p.hitchX,p.hitchZ,p.length or 0,p.axleOffsetX or 0,p.front,math.deg(math.atan(p.slope)),p.headland)
    self:log('snapshot: start %.3f/%.3f heading %.3f tool %.3f, goal %.3f/%.3f heading %.3f, lookahead %.3f, tractor radius %.3f',
        p.start.x,p.start.z,math.deg(p.start.t),math.deg(p.start.phi),p.goal.x,p.goal.z,math.deg(p.goal.t),p.lookahead,p.trackingRadius or p.radius)
    for i,m in ipairs(p.work) do
        self:log('work marker %d: %.3f/%.3f, towed %s, rear %s',i,m.x,m.z,tostring(m.towed),tostring(m.rear))
    end
end

-- Called only on the final approach. Stock PlowController owns the decision
-- to rotate (near the incoming direction), and receives shouldLower=false.
function EnvelopeCourseTurn:checkWorkingPosition()
    self.driveStrategy:raiseControllerEvent(AIDriveStrategyCourse.onTurnEndProgressEvent,
        self:getLowerImplementNode(),false,false,self.turnContext:shouldPlowBeOnTheLeft())
    local ready,active=true,false
    for _,controller in pairs(self.driveStrategy.controllers) do
        if controller.isRotatablePlow and controller:isRotatablePlow() then
            ready=ready and controller:isRotatedToSide(self.turnContext:shouldPlowBeOnTheLeft())
            active=active or controller:isRotationActive()
        end
    end
    if not ready or self.vehicle:getLastSpeed()>0.2 then
        if active or ready or self.rotationStarted then
            if not self.rotationStarted then self.rotationStarted=g_currentMission.time; self:log('waiting for stock plough rotation on approach') end
            self.state=self.states.ENVELOPE_ROTATING
            if g_currentMission.time-self.rotationStarted>30000 then self:stopWithReason('working-side rotation did not finish') end
            return false
        end
        -- Stock CP has not reached its rotation direction yet. Continue with
        -- the centred plough, but the ordinary contact guard still applies.
        return true
    end
    self.needsWorkingGeometry=false
    local position=EnvelopeTurnGeometry.pose(self.vehicle:getAIDirectionNode())
    local remaining={{x=position.x,z=position.z}}
    for i=math.max(2,self.ppc:getCurrentWaypointIx()),#self.result.path do
        remaining[#remaining+1]=self.result.path[i]
    end
    if #remaining<2 then
        self:stopWithReason('no approach remains after plough rotation')
        return false
    end
    self:log('plough in working position; checking entry with measured working envelope')
    self:startPlanning(remaining)
    return false
end

function EnvelopeCourseTurn:updateRotation()
    if self.needsWorkingGeometry then self:checkWorkingPosition() end
end

--[[ The numerical search retains explicit resumable state; FS25 has no Lua
coroutine library. Each call below advances a small sample batch. ]]

function EnvelopeCourseTurn:updatePlanner()
    local started=getTimeSec()
    local ok,result
    repeat
        ok,result=pcall(self.planner.update,self.planner,10)
        if not ok then self:stopWithReason('planner error: '..tostring(result)); return end
    -- Planning is stationary. Give it up to 8 ms per update rather than 4 ms;
    -- retain small sample batches so the UI and cancellation stay responsive.
    until result or getTimeSec()-started>=0.008
    if not result then return end
    self.planner=nil
    if not result.ok then
        if result.attempts then
            self:log('search exhausted: %d trials, best predicted edge error %s m',result.attempts,tostring(result.bestError))
        end
        self:stopWithReason(result.reason); return
    end
    self.result=result
    self.entrySpeedLimit=nil
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
    if result.repairedApproach then
        self:log('SELECTED local entry correction: %d trials, lateral lead %.3f m, predicted edge error %.3f m, worst admission error %.3f m, reused shape %s; no second loop',result.attempts,result.bias,result.entryError,result.maxEntryError or result.entryError,tostring(result.usedHint or false))
    elseif result.retainedApproach then
        self:log('VALIDATED remaining working-position approach: predicted edge error %.3f m',result.entryError)
    else
        self:log('SELECTED steering-led forward turn: %d trials, radius %.2f, bend %.1f, straight %.1f, bias %.3f, outward %.1f, predicted edge error %.3f m',
            result.attempts,result.radius,result.bend,result.straight,result.bias,result.extension,result.entryError)
    end
    if self.planningStarted then self:log('planning completed in %.2f seconds',(g_currentMission.time-self.planningStarted)/1000) end
    -- Reuse CP's per-object commands/controller events/state changes, but let
    -- this strategy own the stricter admission test. This is an INSTANCE method;
    -- the global WorkStartHandler and other turn strategies are unaffected.
    self.workStartHandler.shouldLowerThisImplement=function(handler,object,node,reversing)
        return self.lowerRequested or false,self.lastContact or -math.huge
    end
end

function EnvelopeCourseTurn:getDriveData(dt)
    if self.states.ENVELOPE_ROTATING and self.state==self.states.ENVELOPE_ROTATING then self:updateRotation(); return nil,nil,true,0 end
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
        if self.entryReleased and not aligned then
            self:stopWithReason(string.format('alignment lost after lowering (edge %.3f m, angle %.2f degrees)',error,math.deg(angle)))
            return nil,nil,true,0
        end
        local px,_,pz=self.ppc:getGoalPointPosition()
        gx,gz,self.requestedCurvature=EnvelopeTurnGeometry.driveGoal(self.geometry,self.vehicle,px,pz)
        forward=true
        -- Sparse live traces make prediction/physics disagreement measurable on
        -- any implement. Never dump one log line per simulation sample/frame.
        if not self.nextTrace or g_currentMission.time>=self.nextTrace then
            self.nextTrace=g_currentMission.time+2000
            self:log('TRACK: wp %d, pose %.2f/%.2f, tractor %.2f, tool %.2f, contact %.2f, edge %.3f, heading %.2f, curvature %.4f',
                self.ppc:getCurrentWaypointIx(),state.x,state.z,math.deg(state.t),math.deg(state.phi),contact,error,math.deg(angle),self.requestedCurvature)
        end
    end
    return gx,gz,forward,math.min(speed or self:getForwardSpeed(),8,self.entrySpeedLimit or math.huge)
end

function EnvelopeCourseTurn:endTurn(dt)
    if self.needsWorkingGeometry and not self:checkWorkingPosition() then return false end
    local aligned,error,angle,contact=EnvelopeTurnGeometry.assessLive(self.geometry,self.vehicle)
    self.lastContact=contact
    -- Check BEFORE hand-off clears geometry. Checking only after getDriveData
    -- returns would miss a loss of alignment on the very frame of entry.
    if self.entryReleased and not aligned then
        self:stopWithReason(string.format('alignment lost before entry (edge %.3f m, angle %.2f degrees)',error,math.deg(angle)))
        return false
    end
    -- Approach the first physical work corner slowly, stopping 0.5 m before
    -- contact. Waiting there decouples hydraulic delay from alignment: stopping
    -- earlier in a curve would freeze a trailer before it could straighten.
    self.entrySpeedLimit=math.min(5,3.6*math.sqrt(math.max(0,2*(-contact-0.5))))
    if not self.lowerRequested then
        -- Alignment acquired AFTER entering unworked ground is too late. A
        -- delayed callback or braking overshoot must not silently create a gap
        -- by lowering at that new position. Allow only the sampling tolerance.
        if contact>0.1 then
            self:stopWithReason('working edge passed entry before lowering was requested')
            return false
        end
        if contact>EnvelopeTurnPlanner.loweringGateContact then
            if self.needsWorkingGeometry then
                self:stopWithReason('entry reached before plough working position was validated')
                return false
            end
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
        if contact>0.1 then
            self:stopWithReason('working edge passed entry before the implement was ready')
            return false
        end
        if g_currentMission.time-self.loweringStarted>30000 then self:stopWithReason('implement did not become ready after lowering') end
        return false
    end
    -- Lowering changes pitch and the physical marker positions even while the
    -- tractor is braked. Those intermediate poses are not working entries.
    -- Keep the original row target and strict tolerance, but assess admission
    -- only once the hydraulic wait and CP's readiness checks have completed.
    -- Never recalibrate the target to make a displaced implement appear aligned.
    if not aligned then
        self:stopWithReason(string.format('settled implement not aligned after lowering (edge %.3f m, angle %.2f degrees)',error,math.deg(angle)))
        return false
    end
    if not self.entryReleased then
        self.entryReleased=true
        self:log('READY: settled edge error %.3f m, angle %.2f degrees, first work corner %.2f m before entry',error,math.deg(angle),-contact)
    end
    self.entrySpeedLimit=3
    -- Do not hand back early: the base resume method lowers implements without
    -- an envelope check. Here every tool is ready AND live-aligned at contact.
    if contact>=0 then
        self:log('ENTRY: live edge error %.3f m, angle %.2f degrees; resuming fieldwork',error,math.deg(angle))
        -- Save only the shape of a turn which actually reached working entry.
        -- A later turn must rebuild and validate it with its own live geometry.
        local r,p=self.result,self.geometry
        if r and r.repairedApproach and r.factorA and r.factorB then
            self.driveStrategy.envelopeApproachHints=self.driveStrategy.envelopeApproachHints or {}
            self.driveStrategy.envelopeApproachHints[EnvelopeTurnPlanner.approachSide(p)]={
                factorA=r.factorA,factorB=r.factorB,straightRatio=r.straight/p.width,
                biasRatio=r.bias/(p.width*EnvelopeTurnPlanner.approachSide(p))}
        end
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
