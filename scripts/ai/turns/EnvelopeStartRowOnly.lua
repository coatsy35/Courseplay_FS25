-- Initial entry checks CP's forward route before driving, retaining it when
-- the combination can align. CP still owns its normal reversing manoeuvres.
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
    self.initialPrepareStarted=g_currentMission.time
    self:holdLowering()
end

-- Initial entry has no finishRow event. Prepare the combination before it
-- follows an alignment path, not after that path has brought it to the crop.
-- Leave unfolding to GIANTS and use CP's synchronised centring event only when
-- rotation is permitted. In particular, never deploy a folded plough to measure it.
function EnvelopeStartRowOnly:prepareInitialPosition()
    if self.vehicle:getLastSpeed()>0.2 then return false end
    if self.deferPreparation then
        self.initialNeedsWorkingGeometry=true
        self.initialPrepared=true
        return true
    end
    for _,controller in pairs(self.driveStrategy.controllers) do
        if controller.isRotatablePlow and controller:isRotatablePlow() then
            self.initialNeedsWorkingGeometry=true
            if controller:isRotationActive() or
                    (controller.getIsPlowRotationAllowed and not controller:getIsPlowRotationAllowed()) then
                if g_currentMission.time-self.initialPrepareStarted>30000 then
                    self:fail('initial plough unfolding/centring did not finish')
                end
                return false
            end
        end
    end
    if self:canDeployPlough() then
        -- Already on the straight: do not centre a plough which preparation
        -- has put on its working side, only to turn it over again immediately.
        self.initialNeedsWorkingGeometry=false
        for _,controller in pairs(self.driveStrategy.controllers) do
            if controller.isRotatablePlow and controller:isRotatablePlow() and
                    not controller:isRotatedToSide(self.turnContext:shouldPlowBeOnTheLeft()) then
                self.initialNeedsWorkingGeometry=true
            end
        end
        self.initialPrepared=true
        return true
    end
    if self.initialNeedsWorkingGeometry and not self.initialCentreRequested then
        self.initialCentreRequested=true
        self.driveStrategy:raiseImplements()
        self.driveStrategy:raiseControllerEvent(AIDriveStrategyCourse.onFinishRowEvent,false)
        return false -- allow GIANTS to begin the animation before checking it
    end
    self.initialPrepared=true
    return true
end

function EnvelopeStartRowOnly:canDeployPlough()
    local heading=EnvelopeTurnGeometry.pose(self.turnContext.workStartNode).t
    local pose=EnvelopeTurnGeometry.pose(self.vehicle:getAIDirectionNode())
    if math.abs(EnvelopeTurnPlanner.wrap(pose.t-heading))>EnvelopeTurnPlanner.angleTolerance then return false end
    for i=math.max(1,self.ppc:getCurrentWaypointIx()),self.turnCourse:getNumberOfWaypoints()-1 do
        if self.turnCourse:isReverseAt(i) or
                math.abs(EnvelopeTurnPlanner.wrap(self.turnCourse:getWaypointYRotation(i)-heading))>
                    EnvelopeTurnPlanner.angleTolerance then return false end
    end
    return true
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
    if not self.initialPrepared and not self:prepareInitialPosition() then return nil,nil,nil,0 end
    local reversing=self.ppc:isReversing()
    -- CP retains any reversing section. All-forward approaches are checked
    -- from the starting pose, while the headland is still available to align.
    if reversing then return nil,nil,nil,self:getForwardSpeed() end
    for i=self.ppc:getCurrentWaypointIx(),self.turnCourse:getNumberOfWaypoints() do
        if self.turnCourse:isReverseAt(i) then return nil,nil,nil,self:getForwardSpeed() end
    end
    if self.vehicle:getLastSpeed()>0.2 then return nil,nil,nil,0 end
    self:startEntryCheck(self.initialNeedsWorkingGeometry or false)
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
    guard.deferPreparation=self.deferPreparation
    guard.needsWorkingGeometry=needsWorkingGeometry
    guard.entrySlope=EnvelopeTurnGeometry.initialEntrySlope(self.fieldWorkCourse,self.entryIx)
    guard.startPlanning=function(g,path)
        self:refreshEntryContext()
        g.turnContext=self.turnContext
        g.workStartHandler.turnContext=self.turnContext
        EnvelopeCourseTurn.startPlanning(g,path)
    end
    guard.prepare=function(g)
        if g.initialRecoveryPreparing then
            return EnvelopeCourseTurn.prepare(g)
        end
        if g:ensureFieldBoundary() then
            if #remaining<2 then
                g.geometry=EnvelopeTurnGeometry.capture(g)
                g:stopWithReason('no forward initial approach remains')
            else g:startPlanning(remaining) end
        end
    end
    guard.stopWithReason=function(g,reason)
        if g.geometry and not g.result and not g.lowerRequested and not self.recoveryAttempted and not g.planningTimedOut then
            -- The original/local approach is infeasible. Reuse the row-turn
            -- planner from this stopped pose, keeping the original entry and
            -- checking the complete trailer motion, footprint and lowering.
            -- Execute through EnvelopeCourseTurn too: stock StartRowOnly does
            -- not enforce the combination's steering radius while tracking.
            self.recoveryAttempted=true
            -- Account for calculation across attempts, but not the physical
            -- centring animation between them.
            g.planningWaitUsed=g.planningWaitStarted and g_currentMission.time-g.planningWaitStarted or 0
            g.planningWaitStarted=nil
            g:log('initial approach cannot align: %s; checking a complete envelope recovery to waypoint %d',reason,self.entryIx)
            -- Initial entry has no finishRow transition. Emit the same stock
            -- event explicitly before attempting a bulb: the working-side
            -- plough arm otherwise obstructs the tractor's steering wheels.
            if not g.needsWorkingGeometry then
                strategy:raiseImplements()
                strategy:raiseControllerEvent(AIDriveStrategyCourse.onFinishRowEvent,false)
            end
            g.initialRecoveryPreparing=true
            g.prepareStarted=g_currentMission.time
            g.state=g.states.ENVELOPE_PREPARING
            g:log('centring implements before initial recovery loop')
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
