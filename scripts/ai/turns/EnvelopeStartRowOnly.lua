-- Initial entry keeps CP's route (including its normal reverse manoeuvres).
-- Only the final, forward working entry is owned by the envelope controller.
-- Repositioning uses CP's pathfinder with its existing reverse/collision rules;
-- no pathfinder success is treated as proof that the implement is aligned.
EnvelopeStartRowOnly = CpObject(StartRowOnly)

function EnvelopeStartRowOnly:init(vehicle,strategy,ppc,context,course)
    StartRowOnly.init(self,vehicle,strategy,ppc,context,course)
    self.name='EnvelopeStartRowOnly'
    self.fieldWorkCourse=strategy.fieldWorkCourse
    self.entryIx=context.turnEndWpIx
    self.repositions=0
    self:holdLowering()
end

function EnvelopeStartRowOnly:holdLowering()
    -- Keep CP's controller events available for rotation, but reserve the
    -- lowering command for the measured and validated envelope entry below.
    self.workStartHandler.shouldLowerThisImplement=function() return false,-math.huge end
end

function EnvelopeStartRowOnly:release()
    self.cancelled=true
    if self.guard then self.guard:release() end
    -- The private controller is no longer updated after cancellation. Avoid
    -- touching the drive strategy's normal pathfinder or its callbacks.
    self.entryPathfinder=nil
end

function EnvelopeStartRowOnly:getDriveData(dt)
    if self.cancelled then return nil,nil,nil,0 end
    if self.entryPathfinder then
        self.entryPathfinder:update(dt or 0)
        return nil,nil,nil,0
    end
    if self.guard then return nil,nil,nil,0 end
    local reversing=self.ppc:isReversing()
    self.workStartHandler:lowerImplementsAsNeeded(self:getLowerImplementNode(),reversing)
    if self.state==self.states.DRIVING_TO_ROW then
        if TurnManeuver.hasTurnControl(self.turnCourse,self.turnCourse:getCurrentWaypointIx(),
                TurnManeuver.LOWER_IMPLEMENT_AT_TURN_END) then
            self.state=self.states.APPROACHING_ROW
        end
        return nil,nil,nil,self:getForwardSpeed()
    end
    -- CP owns the approach and reverse steering. Wait for the final forward
    -- leg before measuring a deployed plough; it stays centred while reversing.
    if reversing then return nil,nil,nil,self:getForwardSpeed() end
    for i=self.ppc:getCurrentWaypointIx(),self.turnCourse:getNumberOfWaypoints() do
        if self.turnCourse:isReverseAt(i) then return nil,nil,nil,self:getForwardSpeed() end
    end
    local ready=true
    for _,controller in pairs(self.driveStrategy.controllers) do
        if controller.isRotatablePlow and controller:isRotatablePlow() then
            if controller:isRotationActive() then
                self.rotationWaitStarted=self.rotationWaitStarted or g_currentMission.time
                if g_currentMission.time-self.rotationWaitStarted>30000 then
                    self:fail('initial plough rotation did not finish')
                end
                return nil,nil,nil,0
            end
            ready=ready and controller:isRotatedToSide(self.turnContext:shouldPlowBeOnTheLeft())
        end
    end
    if not ready and not self.reachedEnd then return nil,nil,nil,self:getForwardSpeed() end
    if self.vehicle:getLastSpeed()>0.2 then return nil,nil,nil,0 end
    self:startEntryCheck(not ready)
    return nil,nil,nil,0
end

function EnvelopeStartRowOnly:refreshEntryContext()
    local strategy=self.driveStrategy
    local fm,bm=strategy:getFrontAndBackMarkers()
    -- Rotation can change CP's automatic plough offset. Rebuild from the
    -- original generated row after CP has updated that offset, never from the
    -- vehicle's current position or the temporary alignment course.
    strategy.tightTurnOffset=0
    strategy:updateFieldworkOffset(self.fieldWorkCourse)
    self.turnContext=RowStartOrFinishContext(self.vehicle,self.fieldWorkCourse,self.entryIx,self.entryIx,
        strategy.turnNodes,strategy:getWorkWidth(),fm,bm,0,strategy:getTurnEndForwardOffset())
    -- This is an entry, not a change between plough sides on opposing rows.
    -- CP's current working offset is already on the course; do not add its
    -- normal turn-side flip a second time while the guard is in TURNING state.
    strategy.turnContext=self.turnContext
end

function EnvelopeStartRowOnly:startEntryCheck(needsWorkingGeometry)
    local strategy=self.driveStrategy
    self:refreshEntryContext()
    local position=EnvelopeTurnGeometry.pose(self.vehicle:getAIDirectionNode())
    local remaining={{x=position.x,z=position.z}}
    for i=math.max(2,self.ppc:getCurrentWaypointIx()),self.turnCourse:getNumberOfWaypoints() do
        local x,_,z=self.turnCourse:getWaypointPosition(i)
        remaining[#remaining+1]={x=x,z=z}
    end
    local guard=EnvelopeCourseTurn(self.vehicle,strategy,self.ppc,strategy.proximityController,
        self.turnContext,self.fieldWorkCourse,strategy:getWorkWidth())
    self.guard=guard
    guard.needsWorkingGeometry=needsWorkingGeometry
    guard.entrySlope=EnvelopeTurnGeometry.initialEntrySlope(self.fieldWorkCourse,self.entryIx)
    guard.startPlanning=function(g,path)
        self:refreshEntryContext()
        g.turnContext=self.turnContext
        g.workStartHandler.turnContext=self.turnContext
        EnvelopeCourseTurn.startPlanning(g,path)
    end
    guard.prepare=function(g)
        if g:ensureFieldBoundary() then
            if #remaining<2 then
                g.geometry=EnvelopeTurnGeometry.capture(g)
                g:stopWithReason('no forward initial approach remains')
            else g:startPlanning(remaining) end
        end
    end
    guard.stopWithReason=function(g,reason)
        if not g.lowerRequested and self.repositions<2 then
            self:reposition(g,reason)
        else EnvelopeCourseTurn.stopWithReason(g,reason) end
    end
    guard.state=guard.states.ENVELOPE_PREPARING
    guard.prepareStarted=g_currentMission.time
    guard:log('checking initial entry to original course waypoint %d',self.entryIx)
    strategy.aiTurn=guard
    strategy.state=strategy.states.TURNING
end

function EnvelopeStartRowOnly:reposition(guard,reason)
    local p=guard.geometry
    if not p then EnvelopeCourseTurn.stopWithReason(guard,reason);return end
    self.repositions=self.repositions+1
    guard:log('initial entry needs repositioning: %s; requesting stock CP path, attempt %d',reason,self.repositions)
    guard:release()
    self.ppc:restorePreviouslyRegisteredListeners()
    self.driveStrategy.proximityController:unregisterBlockingObjectListener()
    self.driveStrategy:raiseImplements()
    self.driveStrategy.aiTurn=nil
    self.driveStrategy.state=self.driveStrategy.states.DRIVING_TO_WORK_START_WAYPOINT
    self.guard=nil
    local context=PathfinderContext(self.vehicle)
        :allowReverse(self.driveStrategy:getAllowReversePathfinding())
        :mustBeAccurate(true):ignoreFruit(not self.settings.avoidFruit:getValue())
    local controller=PathfinderController(self.vehicle,p.radius)
    self.entryPathfinder=controller
    controller:registerListeners(self,self.onRepositionFinished)
    -- Ask CP to reach behind the entry, then approach forwards. The distance
    -- scales with the measured rig and increases once on retry; it is not a
    -- fixed 20 m straight or a change to headland rows.
    local lead=math.max(p.length or 0,p.radius)*(1+self.repositions/2)
    if not controller:findPathToNode(context,self.turnContext.workStartNode,0,-p.front-lead,0) then
        self:fail('CP could not start initial-entry pathfinding')
    end
end

function EnvelopeStartRowOnly:onRepositionFinished(controller,success,course)
    if self.cancelled or controller~=self.entryPathfinder then return end
    self.entryPathfinder=nil
    if not success or not course then self:fail('CP could not reposition for the initial entry');return end
    course:adjustForTowedImplements(2)
    StartRowOnly.init(self,self.vehicle,self.driveStrategy,self.ppc,self.turnContext,course)
    self.rotationWaitStarted,self.reachedEnd=nil,nil
    self:holdLowering()
    self.driveStrategy:startCourse(self:getCourse(),1)
end

function EnvelopeStartRowOnly:fail(reason)
    Logging.info('[CP envelope] v%s %s: STOP initial entry: %s',EnvelopeCourseTurn.TEST_VERSION,CpUtil.getName(self.vehicle),reason)
    self:release()
    self.driveStrategy:raiseImplements()
    self.vehicle:stopCurrentAIJob(AIMessageCpErrorNoPathFound.new())
end

function EnvelopeStartRowOnly:onLastWaypoint()
    -- Stock StartRowOnly resumes here even if it has not lowered. Retain the
    -- selected original row and measure/reposition instead of skipping work.
    self.state=self.states.APPROACHING_ROW
    self.reachedEnd=true
end
