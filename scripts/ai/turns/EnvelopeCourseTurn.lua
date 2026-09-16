-- Execution adapter for the experimental envelope planner. Keep headland
-- corners, ordinary Dubins/Reeds-Shepp turns and WorkStartHandler unchanged.
-- Only vehicles opting into envelopeAlignedTurns instantiate this strategy.
EnvelopeCourseTurn = CpObject(CourseTurn)
-- Temporary test-build label; the packager uses the same value for its title.
EnvelopeCourseTurn.TEST_VERSION = '0.29'

function EnvelopeCourseTurn:init(vehicle,strategy,ppc,proximityController,context,course,width)
    CourseTurn.init(self,vehicle,strategy,ppc,proximityController,context,course,width)
    self.name='EnvelopeCourseTurn'
    self.envelopeAlignment=true
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
    self:releasePreparation()
end

function EnvelopeCourseTurn:releasePreparation()
    if self.preparationGeometry and self.preparationGeometry.activeTracker then self.preparationGeometry.activeTracker:delete() end
    self.preparationGeometry,self.preparationPlanner=nil,nil
end

-- CP still owns the actual raise point. This speculative search cannot lower,
-- raise, steer, stop the job or install a path in the live pursuit controller.
-- It only supplies a shape guess which is checked again after centring.
function EnvelopeCourseTurn:finishRow(dt)
    self:updatePreparation()
    CourseTurn.finishRow(self,dt)
end

function EnvelopeCourseTurn:updatePreparation()
    if self.preparationDone then return end
    local started=getTimeSec()
    local ok,reason=pcall(function()
        if not self.preparationPlanner then
            -- Loaded courses can lack their field polygon. Do not start field
            -- detection here or disrupt working; the ordinary stopped path owns
            -- that fallback. No speculative work is required for correctness.
            local polygon=self.vehicle.cpGetFieldPolygon and self.vehicle:cpGetFieldPolygon()
            if not polygon or #polygon<3 then self.preparationDone=true;return end
            local p=EnvelopeTurnGeometry.capture(self)
            if not p then self.preparationDone=true;return end
            local exit=EnvelopeTurnGeometry.pose(self.turnContext.workEndNode)
            local offset=0
            for _,entry in ipairs(p.objects) do
                local marker=self.driveStrategy:getImplementRaiseLate() and entry.back or entry.left
                local _,z=EnvelopeTurnGeometry.planarPoint(marker,self.vehicle:getAIDirectionNode())
                offset=math.max(offset,-z)
            end
            -- Predict the straight row-finish pose from the actual chosen raise
            -- markers. Braking/centring movement can change it, so only reuse
            -- dimensionless shape parameters, never this predicted path.
            local predicted=EnvelopeTurnPlanner.point(exit.x,exit.z,exit.t,0,offset)
            p.start={x=predicted.x,z=predicted.z,t=exit.t,phi=exit.t}
            local measured=EnvelopeTurnGeometry.applyTurnModel(p,self.driveStrategy.envelopeTurnModel)
            p.turnHint=self.driveStrategy.envelopeTurnHint
            if measured then
                for _,controller in pairs(self.driveStrategy.controllers) do
                    if controller.isRotatablePlow and controller:isRotatablePlow() then
                        p.deploymentLead=EnvelopeTurnPlanner.deploymentLead(p,false)
                        break
                    end
                end
            end
            self.preparationGeometry=p
            self.preparationPlanner=EnvelopeTurnPlanner.newSearch(p)
            self.preparationStarted=g_currentMission.time
            self:log('preparing candidate while finishing the straight row; previous raised model %s',tostring(measured))
        end
        repeat
            local result=self.preparationPlanner:update(10)
            if result then
                if result.ok then
                    self.preparedTurnHint=EnvelopeTurnPlanner.turnHint(self.preparationGeometry,result)
                    self.preparedDeploymentLead=result.deploymentLead
                    self:log('straight-row candidate ready: %d trials; actual raised geometry still requires validation',result.attempts)
                end
                self.preparationDone=true
                self:releasePreparation()
                return
            end
        until getTimeSec()-started>=0.002
    end)
    if not ok then
        self.preparationDone=true
        self:releasePreparation()
        self:log('discarding speculative preparation: %s',tostring(reason))
    end
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
                self:updatePreparation()
                if g_currentMission.time-self.prepareStarted>30000 then self:stopWithReason('plough centring did not finish') end
                return
            end
        end
    end
    self:startPlanning(self.initialRemainingPath)
    self.initialRemainingPath=nil
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
    self:releasePreparation()
    self.state=self.states.ENVELOPE_PLANNING
    self.planningStarted=g_currentMission.time
    self.planningProgressLogged=nil
    self.planner={update=function()
        self:log('measuring %s envelope',self.needsWorkingGeometry and 'centred-turn' or 'working')
        local p,reason=EnvelopeTurnGeometry.capture(self)
        if not p then return {ok=false,reason=reason} end
        self.headlandSeed=self.headlandSeed or p.headland
        self.geometry=p
        if self.needsWorkingGeometry then
            if self.initialRowGoal then p.goal=self.initialRowGoal end
            p.deploymentLead=EnvelopeTurnPlanner.deploymentLead(p,self.initialRowGoal~=nil)
            if self.preparedDeploymentLead and not self.initialRowGoal then
                -- Reuse this turn's proposed staging distance, bounded by the
                -- freshly measured geometry. The whole route is still checked.
                local _,compact=EnvelopeTurnPlanner.deploymentLead(p,false)
                p.deploymentLead=math.max(compact,math.min(p.deploymentLead,self.preparedDeploymentLead))
            end
        end
        -- Only the yaw response changes: collision/work marker positions keep
        -- their measured physical geometry. Never substitute an observed
        -- response lever for the real axle/pivot dimensions.
        p.responseLength=self.measuredResponseLength
        p.steeringResponseTime=self.measuredSteeringResponse
        p.turnHint=self.preparedTurnHint or self.driveStrategy.envelopeTurnHint
        p.approachHint=self.driveStrategy.envelopeApproachHints and self.driveStrategy.envelopeApproachHints[EnvelopeTurnPlanner.approachSide(p)]
        self:logGeometry(p)
        if remainingPath then
            -- Rotation may change hitch/axle/soil-marker positions. Validate
            -- the actual remaining approach with the freshly measured shape.
            -- The initial stock course can contain a bulb before its run-in.
            -- Only its final incoming section may deploy the plough, even if
            -- an earlier part of that bulb briefly points towards the row.
            local tailStart=EnvelopeTurnPlanner.approachTailStart(p,remainingPath)
            local approachModel={}
            for k,v in pairs(p) do approachModel[k]=v end
            -- An already driven path is revalidated against the live admission
            -- limit. New paths still require their additional planning margin.
            approachModel.validationOnly=true
            if self.needsWorkingGeometry then
                approachModel.deploymentApproach=true
                tailStart=EnvelopeTurnPlanner.straightTailStart(p,remainingPath)
            end
            local simulation=EnvelopeTurnPlanner.newSimulation(approachModel,remainingPath,tailStart,0.075,true,true)
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
                if self.needsWorkingGeometry then
                    -- A raised route that cannot reach its deployment point
                    -- needs a complete centred manoeuvre, not a working-entry
                    -- correction evaluated against folded soil markers.
                    p.initialApproachRecovery=true
                    self.planner=EnvelopeTurnPlanner.newSearch(p)
                else self.planner=EnvelopeTurnPlanner.newApproachSearch(p) end
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

-- Called only on the final approach. Hold CP's rotation event until alignment;
-- the stock PlowController still owns the animation and unfolding permission.
function EnvelopeCourseTurn:checkWorkingPosition()
    if not self.rotationStarted then
        -- Facing the row briefly on an arc is not the final straight. PPC's
        -- end-turn flag starts at the steering lead, which can still curve.
        if not self.result then return true end
        for i=math.max(1,self.ppc:getCurrentWaypointIx()),#self.result.path-1 do
            local a,b=self.result.path[i],self.result.path[i+1]
            if (b.x-a.x)^2+(b.z-a.z)^2>1e-8 and
                    math.abs(EnvelopeTurnPlanner.wrap(math.atan2(b.x-a.x,b.z-a.z)-self.geometry.goal.t))>
                        EnvelopeTurnPlanner.angleTolerance then return true end
        end
        local _,_,_,_,live=EnvelopeTurnGeometry.assessLive(self.geometry,self.vehicle)
        -- Prediction and execution require the entire raised combination to
        -- be aligned, not merely the tractor reaching its straight segment.
        if not EnvelopeTurnPlanner.canDeploy(self.geometry,live) then return true end
        if self.vehicle:getLastSpeed()>0.2 then return true end
        self.deploymentReady=true
    end
    if self.deferPreparation then
        if not self.preparationRequested then
            self.preparationRequested=true
            self.rotationStarted=g_currentMission.time
            self.state=self.states.ENVELOPE_ROTATING
            self.driveStrategy:prepareForFieldWork()
            self:log('preparing plough on confirmed final straight')
            return false -- allow GIANTS to start its physical animation
        end
        for _,controller in pairs(self.driveStrategy.controllers) do
            if controller.isRotatablePlow and controller:isRotatablePlow() and
                    (controller:isRotationActive() or not controller:getIsPlowRotationAllowed()) then
                if g_currentMission.time-self.rotationStarted>30000 then self:stopWithReason('plough preparation did not finish') end
                return false
            end
        end
        self.deferPreparation=false
    end
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

function EnvelopeCourseTurn:canDeployPlough()
    return self.deploymentReady==true
end

function EnvelopeCourseTurn:updateRotation()
    if self.needsWorkingGeometry then self:checkWorkingPosition() end
end

--[[ The numerical search retains explicit resumable state; FS25 has no Lua
coroutine library. Each call below advances a small sample batch. ]]

function EnvelopeCourseTurn:updatePlanner()
    -- The planner owns a finite candidate search. Elapsed wall time is not
    -- evidence that no path exists; keep yielding between bounded batches.
    local started=getTimeSec()
    local ok,result
    repeat
        ok,result=pcall(self.planner.update,self.planner,10)
        if not ok then self:stopWithReason('planner error: '..tostring(result)); return end
    -- Short bounded batches remain cancellable. Use the bounded stopped
    -- window rather than spreading a small calculation over many seconds.
    until result or getTimeSec()-started>=0.050
    if not result then
        -- Long first-turn searches must be distinguishable from a frozen worker.
        -- Report progress without per-candidate or per-frame log traffic.
        local now=g_currentMission.time
        if self.planner.getProgress and now-(self.planningProgressLogged or self.planningStarted or now)>=5000 then
            self:log('turn search still running: %d candidates, %.1f seconds',self.planner:getProgress(),
                (now-(self.planningStarted or now))/1000)
            self.planningProgressLogged=now
        end
        return
    end
    self.planner=nil
    if not result.ok then
        for reason,count in pairs(result.rejections or {}) do self:log('candidate rejections: %s = %d',reason,count) end
        if result.attempts then
            self:log('search exhausted: %d trials, best predicted edge error %s m',result.attempts,tostring(result.bestError))
        end
        self:stopWithReason(result.reason); return
    end
    if self.needsWorkingGeometry and result.frames then
        local straight=EnvelopeTurnPlanner.straightTailStart(self.geometry,result.path)
        for _,pose in ipairs(result.frames) do
            if pose.ix>=straight and EnvelopeTurnPlanner.canDeploy(self.geometry,pose) then
                result.deploymentStop=pose
                break
            end
        end
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
    if result.directConnection then
        result.routeLength=0
        for i=2,#result.path do
            local a,b=result.path[i-1],result.path[i]
            result.routeLength=result.routeLength+math.sqrt((b.x-a.x)^2+(b.z-a.z)^2)
        end
        self:log('SELECTED shorter connection: %d candidates, %.1f m route, outgoing %.1f m, incoming %.1f m; full envelope verified',
            result.attempts,result.routeLength,result.extension,result.bend+result.straight)
    end
    if result.repairedApproach then
        self:log('SELECTED local entry correction: %d trials, lateral lead %.3f m, predicted edge error %.3f m, worst admission error %.3f m, reused shape %s; no second loop',result.attempts,result.bias,result.entryError,result.maxEntryError or result.entryError,tostring(result.usedHint or false))
    elseif result.retainedApproach then
        if result.requiresDeployment then self:log('VALIDATED raised CP approach to final straight; working entry still requires deployment and validation')
        else self:log('VALIDATED remaining working-position approach: predicted edge error %.3f m',result.entryError) end
    else
        self.initialTurnHint=EnvelopeTurnPlanner.turnHint(self.geometry,result)
        self.initialTurnModel=EnvelopeTurnGeometry.turnModel(self.geometry)
        if result.deploymentLead then
            self:log('SELECTED centred turn: %d trials, %.2f m deployment lead, raised staging error %.3f m; working entry still requires validation',
                result.attempts,result.deploymentLead,result.entryError)
        else
            self:log('SELECTED steering-led forward turn: %d trials, radius %.2f, bend %.1f, straight %.1f, bias %.3f, outward %.1f, predicted edge error %.3f m',
                result.attempts,result.radius,result.bend,result.straight,result.bias,result.extension,result.entryError)
        end
        self:log('planned worked side %s; preferred bulb selected %s',
            self.geometry.workedSide and (self.geometry.workedSide<0 and 'left' or 'right') or 'unknown',
            tostring(result.preferWorked or false))
    end
    if result.usedTurnHint then self:log('turn shape reused and checked against actual raised geometry') end
    if result.hintMarginError then
        self:log('cached entry margin refined: cached worst %.3f m, selected worst %.3f m, %d trials',
            result.hintMarginError,result.maxEntryError,result.attempts)
    end
    if self.planningStarted then self:log('planning completed in %.2f seconds',(g_currentMission.time-self.planningStarted)/1000) end
    -- Reuse CP's per-object commands/controller events/state changes, but let
    -- this strategy own the stricter admission test. This is an INSTANCE method;
    -- the global WorkStartHandler and other turn strategies are unaffected.
    self.workStartHandler.shouldLowerThisImplement=function(handler,object,node,reversing)
        return self.lowerRequested or false,self.lastContact or -math.huge
    end
end

function EnvelopeCourseTurn:getForwardSpeed()
    -- CP's field speed is suitable for the middle of a long manoeuvre. Its
    -- turn speed applies to the final approach, including deployment staging.
    if self.result and (self.result.repairedApproach or self.result.retainedApproach or
            self.ppc:getCurrentWaypointIx()>=self.result.tailStart) then
        return AITurn.getForwardSpeed(self)
    end
    return CourseTurn.getForwardSpeed(self)
end

function EnvelopeCourseTurn:getDriveData(dt)
    if self.states.ENVELOPE_ROTATING and self.state==self.states.ENVELOPE_ROTATING then self:updateRotation(); return nil,nil,true,0 end
    if self.state==self.states.ENVELOPE_PREPARING then self:prepare(); return nil,nil,true,0 end
    if self.state==self.states.ENVELOPE_PLANNING then self:updatePlanner(); return nil,nil,true,0 end
    if self.state==self.states.ENVELOPE_STOPPED then return nil,nil,true,0 end
    local gx,gz,forward,speed=CourseTurn.getDriveData(self,dt)
    -- Brake towards the predicted deployment pose, allowing the live tractor
    -- and trailer to finish straightening before stopping. No fixed turn cap.
    local deploymentSpeedLimit=math.huge
    if self.needsWorkingGeometry and self.result and (self.result.deploymentLead or self.result.requiresDeployment) and self.result.frames then
        local stop=self.result.deploymentStop
        if stop and self.ppc:getCurrentWaypointIx()>=self.result.tailStart then
            local live=EnvelopeTurnGeometry.pose(self.vehicle:getAIDirectionNode())
            local _,remaining=EnvelopeTurnPlanner.localPoint(stop,{x=live.x,z=live.z,t=self.geometry.goal.t})
            local _,_,_,_,state=EnvelopeTurnGeometry.assessLive(self.geometry,self.vehicle)
            local yaw=math.abs(EnvelopeTurnPlanner.wrap(state.phi-self.geometry.goal.t))
            local settling=(self.geometry.length or 0)*math.log(math.max(1,
                yaw/(EnvelopeTurnPlanner.angleTolerance*0.9)))
            local heading=math.abs(EnvelopeTurnPlanner.wrap(state.t-self.geometry.goal.t))
            local turning=math.max(0,heading-EnvelopeTurnPlanner.angleTolerance*0.9)*self.geometry.radius
            deploymentSpeedLimit=3.6*math.sqrt(math.max(0,2*math.max(remaining,settling,turning)))
        end
    end
    if self.geometry and self.state~=self.states.ENVELOPE_STOPPED then
        local aligned,error,angle,contact,state=EnvelopeTurnGeometry.assessLive(self.geometry,self.vehicle)
        self:observeSteeringResponse(state,dt)
        self:observeTrailerResponse(state)
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
    return gx,gz,forward,math.min(speed or self:getForwardSpeed(),
        deploymentSpeedLimit,self.entrySpeedLimit or math.huge)
end

-- Infer steering response from commanded curvature and actual tractor yaw.
-- Only moving, resolved samples contribute; the median rejects transients.
-- This changes prediction, never CP's selected speed or steering lock.
function EnvelopeCourseTurn:observeSteeringResponse(live,dt)
    local previous=self.steeringSample
    local sample={x=live.x,z=live.z,t=live.t}
    self.steeringSample=sample
    if not previous or not self.requestedCurvature or dt<=0 or dt>250 then return end
    local distance=math.sqrt((live.x-previous.x)^2+(live.z-previous.z)^2)
    if distance<0.01 then return end
    sample.curvature=EnvelopeTurnPlanner.wrap(live.t-previous.t)/distance
    if not previous.curvature then return end
    local error=self.requestedCurvature-previous.curvature
    if math.abs(error)<0.003 then return end
    local ratio=(self.requestedCurvature-sample.curvature)/error
    if ratio<=0 or ratio>=0.99 then return end
    local response=-(dt/1000)/math.log(ratio)
    if response<0.02 or response>2 then return end
    self.steeringResponses=self.steeringResponses or {}
    local values=self.steeringResponses
    values[#values+1]=response
    if #values>40 then table.remove(values,1) end
    if #values<5 then return end
    local ordered={};for i,v in ipairs(values) do ordered[i]=v end
    table.sort(ordered)
    self.measuredSteeringResponse=ordered[math.ceil(#ordered/2)]
end

-- Estimate the passive yaw response from real forward hitch motion. A median
-- of consistent samples rejects steering transients/noise. Samples close to
-- straight, stationary, reversing or with an implausible lever are unusable.
-- This is per turn and never alters CP/XML geometry or the steering radius.
function EnvelopeCourseTurn:observeTrailerResponse(live)
    local p=self.geometry
    if not p.length or self.needsWorkingGeometry or self.lowerRequested then
        self.responseSample=nil
        return
    end
    local E=EnvelopeTurnPlanner
    local hitch=E.point(live.x,live.z,live.t,p.hitchX,p.hitchZ)
    local previous=self.responseSample
    if not previous then self.responseSample={x=hitch.x,z=hitch.z,phi=live.phi};return end
    local dx,dz=hitch.x-previous.x,hitch.z-previous.z
    local distance=math.sqrt(dx*dx+dz*dz)
    if distance<0.5 then return end
    self.responseSample={x=hitch.x,z=hitch.z,phi=live.phi}
    if distance>2 then return end
    local direction=math.atan2(dx,dz)
    local before,after=E.wrap(previous.phi-direction),E.wrap(live.phi-direction)
    if math.abs(before)<math.rad(5) or math.abs(before)>math.rad(80) then return end
    local ratio=math.tan(after/2)/math.tan(before/2)
    if ratio<=0 or ratio>=0.999 then return end
    local length=-distance/math.log(ratio)
    if length<p.length*0.5 or length>p.length*1.5 then return end
    self.responseSamples=self.responseSamples or {}
    local samples=self.responseSamples
    samples[#samples+1]=length
    if #samples>40 then table.remove(samples,1) end
    if #samples<3 then return end
    local ordered={};for i,v in ipairs(samples) do ordered[i]=v end
    table.sort(ordered)
    local median=ordered[math.ceil(#ordered/2)]
    local spread={};for i,v in ipairs(ordered) do spread[i]=math.abs(v-median) end
    table.sort(spread)
    -- A short entry may need correcting before eight half-metre samples
    -- exist. Admit an early estimate only when ALL available samples agree
    -- within 2%; the longer window retains its robust median/MAD filter.
    -- This changes prediction only, never the measured collision geometry or
    -- the 10 cm / 2 degree working-entry gate.
    local consistent=#samples>=8 and spread[math.ceil(#spread/2)]<median*0.1 or
        #samples<8 and spread[#spread]<median*0.02
    if consistent then self.measuredResponseLength=median end
end

-- The tractor can track perfectly while trailer physics differ from the
-- passive prediction (tyre scrub, steering axles, suspension). Detect that
-- discrepancy with room left to change the steering lead, not at lowering.
-- This is a replanning trigger, never a relaxed working-entry tolerance.
function EnvelopeCourseTurn:checkApproachTracking(contact,live)
    if self.lowerRequested or self.approachCorrected then return true end
    local p=self.geometry
    if not self.approachCorrectionPending then
        -- PPC can announce ENDING_TURN while the tractor is still rounding the
        -- bulb. A nearby tail sample then belongs to a different part of the
        -- manoeuvre. Do not brake and replace that unfinished arc with a local
        -- entry correction. These are phase checks, not admission tolerances.
        if math.abs(EnvelopeTurnPlanner.wrap(live.t-p.goal.t))>math.rad(30) then return true end
        if self.result and self.ppc.getCurrentWaypointIx and
                self.ppc:getCurrentWaypointIx()<self.result.tailStart then return true end
        local reach=math.max(12,2*(p.length or math.abs(p.front)))
        if contact < -reach or contact > -math.max(3,2*p.lookahead) then return true end
        local nearest,nearestIndex,distance=nil,nil,math.huge
        local frames=self.result and self.result.frames or {}
        for index,sample in ipairs(frames) do
            local d=(sample.x-live.x)^2+(sample.z-live.z)^2
            if d<distance then nearest,nearestIndex,distance=sample,index,d end
        end
        if not nearest or nearest.ix<self.result.tailStart then return true end
        -- Predictions are sampled at 20 cm intervals. Compare at the live
        -- position along the segment, not a neighbouring sample's longitudinal
        -- station, so the tighter drift trigger does not react to sampling alone.
        for i=math.max(1,nearestIndex-1),math.min(#frames-1,nearestIndex) do
            local a,b=frames[i],frames[i+1]
            if a.ix>=self.result.tailStart then
                local dx,dz=b.x-a.x,b.z-a.z
                local u=math.max(0,math.min(1,((live.x-a.x)*dx+(live.z-a.z)*dz)/math.max(1e-12,dx*dx+dz*dz)))
                local x,z=a.x+u*dx,a.z+u*dz
                local d=(x-live.x)^2+(z-live.z)^2
                if d<distance then
                    local E=EnvelopeTurnPlanner
                    nearest={x=x,z=z,t=a.t+u*E.wrap(b.t-a.t),phi=a.phi+u*E.wrap(b.phi-a.phi)}
                    distance=d
                end
            end
        end
        local deviation=0
        for _,marker in ipairs(p.work) do
            local actual=EnvelopeTurnPlanner.marker(p,live,marker)
            local predicted=EnvelopeTurnPlanner.marker(p,nearest,marker)
            local lateral=(actual.x-predicted.x)*math.cos(p.goal.t)-(actual.z-predicted.z)*math.sin(p.goal.t)
            deviation=math.max(deviation,math.abs(lateral))
        end
        -- Intervene at the width-relative planning margin while steering
        -- space remains. Smaller drift stays within the live allowance.
        if deviation<=EnvelopeTurnPlanner.entryTolerance(self.geometry)*0.6 then return true end
        self.approachCorrectionPending=true
        self:log('approach differs from prediction by %.3f m at contact %.2f; stopping for one local correction',deviation,contact)
        if self.measuredResponseLength then
            self:log('observed trailer response %.3f m from %d samples; physical lever remains %.3f m',
                self.measuredResponseLength,#self.responseSamples,p.length)
        end
    end
    if self.vehicle:getLastSpeed()>0.2 then return false end
    self.approachCorrectionPending=nil
    self.approachCorrected=true
    local position=EnvelopeTurnGeometry.pose(self.vehicle:getAIDirectionNode())
    local remaining={{x=position.x,z=position.z}}
    for i=math.max(2,self.ppc:getCurrentWaypointIx()),#self.result.path do remaining[#remaining+1]=self.result.path[i] end
    -- Reuse the working-position repair: first validate the remaining route,
    -- then a bounded forward correction. It cannot generate a second bulb.
    self:startPlanning(remaining)
    return false
end

function EnvelopeCourseTurn:endTurn(dt)
    if self.needsWorkingGeometry and not self:checkWorkingPosition() then return false end
    local aligned,error,angle,contact,live=EnvelopeTurnGeometry.assessLive(self.geometry,self.vehicle)
    self.lastContact=contact
    if not self.needsWorkingGeometry and not self:checkApproachTracking(contact,live) then return false end
    -- Check BEFORE hand-off clears geometry. Checking only after getDriveData
    -- returns would miss a loss of alignment on the very frame of entry.
    if self.entryReleased and not aligned then
        self:stopWithReason(string.format('alignment lost before entry (edge %.3f m, angle %.2f degrees)',error,math.deg(angle)))
        return false
    end
    -- Approach the first physical work corner slowly, stopping 0.5 m before
    -- contact. Waiting there decouples hydraulic delay from alignment: stopping
    -- earlier in a curve would freeze a trailer before it could straighten.
    self.entrySpeedLimit=3.6*math.sqrt(math.max(0,2*(-contact-0.5)))
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
    self.entrySpeedLimit=nil
    -- Do not hand back early: the base resume method lowers implements without
    -- an envelope check. Here every tool is ready AND live-aligned at contact.
    if contact>=0 then
        self:log('ENTRY: live edge error %.3f m, angle %.2f degrees; resuming fieldwork',error,math.deg(angle))
        -- Save only the shape of a turn which actually reached working entry.
        -- A later turn must rebuild and validate it with its own live geometry.
        local r,p=self.result,self.geometry
        if self.initialTurnHint then
            self.driveStrategy.envelopeTurnHint=self.initialTurnHint
            self.driveStrategy.envelopeTurnModel=self.initialTurnModel
        end
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
