-- v0.19, 15 September 23:24:26: centred snapshot. Deployment applies the
-- measured working markers and 1.505 m CP goal-offset change from 23:25:18.
function deploymentFixture(side)
    g_currentMission.time=0
    local p=envelopeFixture(5.6,11.27,1.641,3.33,16.931,14.3,1,50.1)
    p.start={x=-168.816*side,z=-142.077,t=math.rad(61.245)*side,phi=math.rad(60.915)*side}
    p.goal={x=-158.266*side,z=-118.820,t=0}
    p.hitchX=.001*side;p.axleOffsetX=-.01*side;p.slope=p.slope*side
    p.lookahead=2.695;p.vehicleRadius=5.389
    p.work={{x=.016*side,z=-2.751,towed=true},{x=-.002*side,z=-1.694,towed=true},
        {x=.016*side,z=-15.290,towed=true,rear=true},{x=-.002*side,z=-15.290,towed=true,rear=true}}
    local f=makeEnvelopeLiveFixture(p);local t=f.turn
    addStockPloughFixture(f)
    f.object.setRotationMax=function(self,whichSide)
        local _,_,_,_,state=EnvelopeTurnGeometry.assessLive(t.geometry,f.vehicle)
        assert(math.abs(EnvelopeTurnPlanner.wrap(state.t-t.geometry.goal.t))<=EnvelopeTurnPlanner.angleTolerance,
            'rotation before tractor alignment')
        for i=math.max(1,t.ppc:getCurrentWaypointIx()),#t.result.path-1 do
            local a,b=t.result.path[i],t.result.path[i+1]
            assert(math.abs(EnvelopeTurnPlanner.wrap(math.atan2(b.x-a.x,b.z-a.z)-t.geometry.goal.t))<=
                EnvelopeTurnPlanner.angleTolerance,'rotation before final straight')
        end
        self.sideCommands=self.sideCommands+1;self.targetAnimation=whichSide and 1 or 0
        self.playing=true;self.animationEnd=g_currentMission.time+7000
    end
    t.needsWorkingGeometry=true;t.entrySlope=p.slope;t.headlandSeed=50.1
    t.ppc=PurePursuitController(f.vehicle);t.ppc.shortLookaheadDistance=2.695
    local log={};f.logs=log
    t.log=function(_,format,...) log[#log+1]=string.format(format,...) end
    p.stateFixture=function(current,s)
        if current.object.playing and g_currentMission.time>=current.object.animationEnd then
            current.object.animation=current.object.targetAnimation;current.object.playing=false
            p.work={{x=-3.264*side,z=-2.155,towed=true},{x=2.287*side,z=-2.469,towed=true},
                {x=-3.264*side,z=-16.136,towed=true,rear=true},{x=2.287*side,z=-16.136,towed=true,rear=true}}
            p.length=11.11;p.hitchX=.018*side;p.hitchZ=-1.645;p.axleOffsetX=.02*side
            current.context.workStartNode.x=-156.761*side
            s.phi=EnvelopeTurnPlanner.wrap(s.phi-math.rad(12.3)*side)
        end
    end
    p.planFixture=function()
        t:startPlanning()
        for i=1,10000 do
            g_currentMission.time=g_currentMission.time+50
            t:updatePlanner()
            if not t.planner then
                f.initialAttempts=t.result and t.result.attempts
                return assert(t.result,table.concat(log,'\n'))
            end
        end
        error('deployment planning did not finish')
    end
    return p,f
end

-- Saved T7 first-pike course: use its outer headland CENTRELINE as a
-- conservative inset boundary. Arrival yaw and hydraulic transform remain
-- synthetic; a separate unit check covers the stock approach's handover
-- policy, not GIANTS' execution of the complete drive-to-work path.
function configureSavedStraightEntry(p,f,field,arrivalAngle)
    f.vehicle.cpGetFieldPolygon=function() return field end
    f.strategy.vehicle=f.vehicle;f.strategy.workWidth=p.width
    f.strategy.frontMarkerDistance=-3.7;f.strategy.backMarkerDistance=-17.4
    local course={getWaypointPosition=function() return p.goal.x,0,p.goal.z end,
        getWaypointYRotation=function() return p.goal.t end,getNumberOfHeadlands=function() return 9 end}
    local offset,fits=EnvelopeTurnGeometry.outerEntryOffset(f.strategy,course,1,-p.length)
    assert(fits and offset < -24)
    p.start={x=p.goal.x,z=p.goal.z+offset,t=0,phi=math.rad(arrivalAngle)}
    f:setPose(p.start)
    p.planFixture=function()
        local path={}
        for z=p.start.z,p.goal.z+12,0.5 do path[#path+1]={x=p.start.x,z=z} end
        f.turn:startPlanning(path)
        for i=1,1000 do
            g_currentMission.time=g_currentMission.time+50
            f.turn:updatePlanner()
            if not f.turn.planner then return assert(f.turn.result,table.concat(f.logs,'\n')) end
        end
        error('straight entry validation did not finish')
    end
end

function attachFieldworkHandover(p,f)
    local s,t=f.strategy,f.turn
    s.vehicle=f.vehicle;s.settings=f.vehicle:getCpSettings();s.workWidth=p.width;s.ppc=t.ppc
    s.settings.fieldWorkSpeed={getValue=function() return 12 end}
    s.states={TURNING={},WAITING_FOR_LOWER={},WAITING_FOR_LOWER_DELAYED={},WORKING={}}
    s.state=s.states.TURNING;s.aiTurn=t
    s.debug=function() end;s.debugSparse=function() end
    s.plowOffsetUnknown={reset=function() f.offsetResets=(f.offsetResets or 0)+1 end}
    s.haveRotatablePlow=function() return f.controller~=nil end
    s.rotatePlows=function() error('central-row handover must not rotate again') end
    s.startWaitingForLower=AIDriveStrategyFieldWorkCourse.startWaitingForLower
    s.lowerImplements=function()
        assert(t.entryReleased,'fieldwork lowered before envelope release')
        f.fieldworkLowerCalls=(f.fieldworkLowerCalls or 0)+1
    end
    s.startCourse=function(self,course,ix)
        self.course=course;self.ppc:setCourse(course);self.ppc:initialize(ix)
    end
    s.resumeFieldworkAfterTurn=function(self,ix)
        -- Reconstruct the original generated row with its current CP offset.
        local row={};local goal=f.context.workStartNode
        for distance=0,100,2 do
            local q=EnvelopeTurnPlanner.point(goal.x,goal.z,goal.t,0,distance)
            local attr=CourseGenerator.WaypointAttributes();attr.rowStart=distance==0;attr.rowEnd=distance==100
            attr.atBoundaryId='F';q.attributes=attr;row[#row+1]=q
        end
        self.fieldWorkCourse=Course(f.vehicle,row,false)
        self.resumed=self.resumed+1
        AIDriveStrategyPlowCourse.resumeFieldworkAfterTurn(self,1)
        f.entryGeometry=assert(EnvelopeTurnGeometry.capture(t))
        f.handoverSteps=0;f.workedDistance=0
    end
    s.setMaxSpeed=function(self,speed) self.maxSpeed=math.min(self.maxSpeed or math.huge,speed) end
    for _,method in ipairs({'updateFieldworkOffset','updateLowFrequencyImplementControllers',
            'setAITarget','limitSpeed','checkProximitySensors','checkDistanceToOtherFieldWorkers'}) do
        s[method]=function() end
    end
    AIUtil.getSteeringParameters=function() return p.length and f.object,p.length or 0 end
    AIUtil.hasChainedAttachments=function() return false end
    Markers=Markers or {};Markers.refreshMarkerNodes=function() end
    t.resumeFieldworkAfterTurn=AITurn.resumeFieldworkAfterTurn
    p.driveDataFixture=function(_,dt)
        s.maxSpeed=math.huge
        return AIDriveStrategyFieldWorkCourse.getDriveData(s,dt,0,0,0)
    end
    p.afterHandoverFixture=function(_,state)
        f.handoverSteps=f.handoverSteps+(s.state~=s.states.WORKING and 1 or 0)
        local aligned,error,_,contact=EnvelopeTurnGeometry.assessLive(f.entryGeometry,f.vehicle)
        assert(aligned,'fieldwork lost entry alignment after handover: '..tostring(error))
        assert(s.resumed==1 and not f.vehicle.stopped)
        if s.state==s.states.WORKING then f.workedDistance=contact end
        return f.workedDistance>=8
    end
end
