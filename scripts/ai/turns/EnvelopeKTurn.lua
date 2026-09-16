-- Keep stock CP's K-turn manoeuvre and eligibility rules. Only the final
-- lowering/handover is delegated to the common envelope entry controller.
EnvelopeKTurn = CpObject(KTurn)

function EnvelopeKTurn:init(vehicle,strategy,ppc,proximity,context,course,width)
    KTurn.init(self,vehicle,strategy,ppc,proximity,context,width)
    self.fieldWorkCourse=course
    self.envelopeAlignment=true
end

function EnvelopeKTurn:canDeployPlough()
    return false
end

function EnvelopeKTurn:endTurn(dt)
    if self.entryGuard or self.vehicle:getLastSpeed()>0.2 then return false end
    local position=EnvelopeTurnGeometry.pose(self.vehicle:getAIDirectionNode())
    local remaining={{x=position.x,z=position.z}}
    local course=self.endingTurnCourse
    for i=math.max(1,self.ppc:getCurrentWaypointIx()),course:getNumberOfWaypoints() do
        local x,_,z=course:getWaypointPosition(i)
        remaining[#remaining+1]={x=x,z=z}
    end
    self.ppc:restorePreviouslyRegisteredListeners()
    local guard=EnvelopeCourseTurn(self.vehicle,self.driveStrategy,self.ppc,self.proximityController,
        self.turnContext,self.fieldWorkCourse,self.workWidth)
    for _,controller in pairs(self.driveStrategy.controllers) do
        if controller.isRotatablePlow and controller:isRotatablePlow() then guard.needsWorkingGeometry=true end
    end
    self.entryGuard=guard
    self.driveStrategy.aiTurn=guard
    guard:log('stock K turn completed; validating final working entry')
    guard.initialRemainingPath=remaining
    guard:startTurn()
    return false
end

function EnvelopeKTurn:onWaypointPassed(ix,course)
    if self.state==self.states.ENDING_TURN then
        -- Stock AITurn resumes unconditionally at the final waypoint. The
        -- entry controller must approve lowering first, even for a short row.
        if ix==course:getNumberOfWaypoints() then self:endTurn(0) end
    else KTurn.onWaypointPassed(self,ix,course) end
end
