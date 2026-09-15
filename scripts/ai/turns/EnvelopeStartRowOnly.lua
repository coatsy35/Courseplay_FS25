-- Initial entry keeps CP's route (including its normal reverse manoeuvres).
-- Only the final, forward working entry is owned by the envelope controller.
-- If that approach cannot align, the envelope planner checks a complete forward
-- recovery before driving it. A tractor-only pathfinder goal behind the vehicle
-- is not proof that the trailer can follow the resulting loop into the row.
EnvelopeStartRowOnly = CpObject(StartRowOnly)

function EnvelopeStartRowOnly:init(vehicle,strategy,ppc,context,course)
    StartRowOnly.init(self,vehicle,strategy,ppc,context,course)
    self.name='EnvelopeStartRowOnly'
    self.fieldWorkCourse=strategy.fieldWorkCourse
    self.entryIx=context.turnEndWpIx
    self.envelopeAlignment=true
    self.recoveryAttempted=false
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
end

function EnvelopeStartRowOnly:getDriveData(dt)
    if self.cancelled then return nil,nil,nil,0 end
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
        if g.geometry and not g.result and not g.lowerRequested and not self.recoveryAttempted then
            -- The original/local approach is infeasible. Reuse the row-turn
            -- planner from this stopped pose, keeping the original entry and
            -- checking the complete trailer motion, footprint and lowering.
            -- Execute through EnvelopeCourseTurn too: stock StartRowOnly does
            -- not enforce the combination's steering radius while tracking.
            self.recoveryAttempted=true
            g:log('initial approach cannot align: %s; checking a complete envelope recovery to waypoint %d',reason,self.entryIx)
            g:startPlanning()
        else EnvelopeCourseTurn.stopWithReason(g,reason) end
    end
    guard.state=guard.states.ENVELOPE_PREPARING
    guard.prepareStarted=g_currentMission.time
    guard:log('checking initial entry to original course waypoint %d',self.entryIx)
    strategy.aiTurn=guard
    strategy.state=strategy.states.TURNING
end

function EnvelopeStartRowOnly:getForwardSpeed()
    -- A long trailed implement must not take the initial approach at transport
    -- speed while its final working geometry is still being checked.
    return math.min(StartRowOnly.getForwardSpeed(self),8)
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
