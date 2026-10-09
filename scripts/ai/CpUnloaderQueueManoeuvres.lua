-- Queue clearance only. Native CP owns full-trailer departure and AD handover.
local Q = CpUnloaderQueue
local W = CpUnloaderQueueWorld
local G = CpUnloaderQueueGeometry
local H = HeadlandLoopGeometry
local function distance(a,b) return math.sqrt((a.x-b.x)^2+(a.z-b.z)^2) end

-- A fieldworker waiting for its turn is not a parked obstacle. Native CP owns
-- the convoy/proximity relationship between active harvesters, including when
-- one is temporarily stationary or joining centre work.
local function isActiveFieldworker(vehicle)
    return vehicle and vehicle.spec_combine and vehicle.getIsCpFieldWorkActive
        and vehicle:getIsCpFieldWorkActive()
end

-- Use CP's collision-aware hybrid planner for the entire short bypass. Its
-- fast A* middle section smooths using penalties only, so it can straighten a
-- route back through a parked vehicle. Do not change that planner globally.
function Q.generateHarvesterBypass(turn)
    local target,offset=turn.turnContext:getTurnEndNodeAndOffsets(turn.steeringLength)
    local x,z,t=PathfinderUtil.getNodePositionAndDirection(turn.vehicle:getAIDirectionNode(),0,0)
    local start=State3D(x,-z,CpMathUtil.angleFromGame(t))
    x,z,t=PathfinderUtil.getNodePositionAndDirection(target,0,offset)
    if turn.queueConnectorCourse then
        local course=turn.queueConnectorCourse
        local ix=course:getNextWaypointIxWithinDistance(turn.queueConnectorIx,math.max(60,6*turn.turningRadius))
        if ix and ix<course:getNumberOfWaypoints() then
            turn.queueConnectorJoin=ix
            x,_,z=course:getWaypointPosition(ix); t=course:getWaypointYRotation(ix)
        end
    end
    local goal=State3D(x,-z,CpMathUtil.angleFromGame(t))
    local context=PathfinderContext(turn.vehicle):useFieldNum(CpFieldUtil.getFieldNumUnderVehicle(turn.vehicle))
    if turn.queueConnectorCourse and turn.settings.avoidFruit then
        context:ignoreFruit(not turn.settings.avoidFruit:getValue())
    end
    context:offFieldPenalty(turn.driveStrategy:isTurnOnFieldActive() and 10 or context._offFieldPenalty)
    if not turn.vehicle.spec_combine then context._fieldworkBoundary=FieldworkBoundary.forVehicle(turn.vehicle,turn.workWidth) end
    local constraints=PathfinderConstraints(context)
    -- Leave tracking room outside the final guard envelope. Native course
    -- conversion and reverse clearance can shift the path between solver poses.
    constraints.vehicleData=PathfinderUtil.VehicleData(turn.vehicle,true,2)
    turn.queueBypassConstraints=PathfinderConstraints(context)
    turn.queueBypassConstraints.vehicleData=PathfinderUtil.VehicleData(turn.vehicle,true,1)
    local pathfinder=HybridAStar(turn.vehicle,200,10000,true)
    local allowReverse=not turn.queueForwardOnly and turn.driveStrategy:getAllowReversePathfinding()
    pathfinder.analyticSolver=allowReverse and ReedsSheppSolver(ReedsShepp.ForwardEndingPathWords) or DubinsSolver()
    pathfinder.ignoreValidityAtStart=false
    turn.driveStrategy.pathfinder=pathfinder
    turn.pathfindingStartedAt=g_currentMission.time
    local result=pathfinder:start(start,goal,turn.turningRadius,
        allowReverse,constraints,constraints.trailerHitchLength)
    if result.done then return turn:onPathfindingDone(result.path) end
    turn.state=turn.states.WAITING_FOR_PATHFINDER
    turn.driveStrategy:setPathfindingDoneCallback(turn,turn.onPathfindingDone)
end

function Q.validateHarvesterBypass(turn)
    local course,constraints=turn.turnCourse,turn.queueBypassConstraints
    if not course or not constraints then return false end
    local previous,count=nil,0
    for i=1,turn.queueBypassValidationEnd or course:getNumberOfWaypoints() do
        local x,_,z=course:getWaypointPosition(i)
        local reverse=(course:isReverseAt(i) and not course:switchingToForwardAt(i)) or course:switchingToReverseAt(i)
        local t=course:getWaypointYRotation(i)+(reverse and math.pi or 0)
        local point={x=x,z=z,t=t}
        previous=previous or point
        local delta=H.math.delta(t,previous.t)
        local samples=math.max(1,math.ceil(distance(previous,point)/0.5),math.ceil(math.abs(delta)/math.rad(3)))
        for j=0,samples do
            count=count+1
            if count>3000 then return false end
            local f=j/samples
            local node=State3D(previous.x+(x-previous.x)*f,-(previous.z+(z-previous.z)*f),
                CpMathUtil.angleFromGame(previous.t+delta*f))
            if not constraints:isValidNode(node,false,true) then
                turn.driveStrategy:debug('Queue: bypass clearance rejected at waypoint %d, %.1f/%.1f heading %.1f',
                    i,node.x,-node.y,math.deg(previous.t+delta*f))
                return false
            end
        end
        previous=point
    end
    return true
end

-- Construct the same native turn ending and reverse clearance, but do not
-- install its course until the final geometry has passed validation.
function Q.finishHarvesterBypass(turn,path)
    turn.turnCourse=Course(turn.vehicle,CpMathUtil.pointsToGameInPlace(path),true)
    if turn.queueConnectorJoin then
        -- Only search the local detour, then rejoin the existing work starter.
        -- Resolve native solver tolerance with an exact checked seam. Its tail
        -- already contains the original straight entry and implement markers.
        local course,ix=turn.queueConnectorCourse,turn.queueConnectorJoin
        local cut=math.max(1,turn.turnCourse:getPreviousWaypointIxWithinDistance(
            turn.turnCourse:getNumberOfWaypoints(),2*turn.turningRadius) or 1)
        local start=PathfinderUtil.getWaypointAsState3D(turn.turnCourse:getWaypoint(cut),0,0)
        local goal=PathfinderUtil.getWaypointAsState3D(course:getWaypoint(ix),0,0)
        local tail,length=PathfinderUtil.findAnalyticPathFromStartToGoal(DubinsSolver(),start,goal,turn.turningRadius)
        if not tail or length>6*turn.turningRadius+5 then return false end
        local joined=Course.createFromAnalyticPath(turn.vehicle,tail,true)
        if cut>1 then
            local prefix=turn.turnCourse:copy(turn.vehicle,1,cut-1)
            prefix:append(joined); joined=prefix
        end
        -- Validate the changed detour and its seam; the unchanged, potentially
        -- kilometre-long connector remains under the live braking guard.
        turn.queueBypassValidationEnd=joined:getNumberOfWaypoints()+1
        joined:append(course:copy(turn.vehicle,ix+1))
        turn.turnCourse=joined
    else
        turn.turnCourse:setUseTightTurnOffsetForLastWaypoints(15)
        local ending=turn.turnContext:appendPathfinderEndingTurnCourse(turn.turnCourse,nil)
        turn.turnCourse:setUseTightTurnOffsetForLastWaypoints(ending)
        turn.turnCourse:adjustForReversing(math.max(1,-AIUtil.getDirectionNodeToReverserNodeOffset(turn.vehicle)))
        TurnManeuver.setLowerImplements(turn.turnCourse,ending,true)
    end
    if not Q.validateHarvesterBypass(turn) then return false end
    turn.ppc:setCourse(turn.turnCourse)
    turn.ppc:initialize(1)
    turn.state=turn.states.TURNING
    return true
end

function Q.waitForHarvesterClearance(bypass,reason)
    local combine,turn,driver=bypass.combine,bypass.turn,bypass.driver
    turn.state=turn.states.WAITING_FOR_PATHFINDER
    -- A native reverse-cusp extension may invalidate an otherwise valid path.
    -- Try a forward-only route once, on the next drive update, before yielding.
    if not turn.queueForwardOnly then
        turn.queueForwardOnly=true; bypass.retry=true
        combine:debug('Queue: bypass %s; trying a forward-only route',reason)
        return
    end
    bypass.waiting=true; bypass.retry=nil
    bypass.waitUntil=g_currentMission.time+120000
    bypass.failedPose=W.pose(bypass.vehicle:getAIDirectionNode())
    bypass.checkedAt=g_currentMission.time
    if driver and driver.queueData and driver.queueData.bypass==bypass then driver.queueData.bypass=nil end
    combine:debug('Queue: bypass %s; waiting for vehicle clearance',reason)
    if driver then Q.priority(driver,combine.vehicle) end
end

-- Called only after native proximity has reported a persistent vehicle block.
-- Retain CP's target, implement preparation, pathfinder and collision geometry.
function Q.tryHarvesterBypass(combine,vehicle,isBack)
    if isActiveFieldworker(vehicle) then return false end
    if not combine.states then return false end
    local connector=combine.states.DRIVING_TO_WORK_START_WAYPOINT and
        combine.state==combine.states.DRIVING_TO_WORK_START_WAYPOINT
    local turn=connector and combine.workStarter or combine.aiTurn
    if isBack or (not connector and combine.state~=combine.states.TURNING) or not turn
            or not combine.turnContext or turn.turnContext~=combine.turnContext
            or turn.callbackFunction or not combine.startRecoveryTurn
            or (not connector and not turn.startRecoveryTurn) then return false end
    local active=combine.queueBypass
    if active and active.turn==turn then
        if active.vehicle~=vehicle then return false end
        if turn.state==turn.states.TURNING then Q.waitForHarvesterClearance(active,'live route obstructed') end
        return true
    end
    local driving=connector and turn.states.DRIVING_TO_ROW or turn.states.TURNING
    if turn.state~=driving or (combine.pathfinder and combine.pathfinder:isActive())
            or (combine.pathfinderController and combine.pathfinderController.pathfinder) then return false end
    local driver=vehicle and vehicle.getCpDriveStrategy and vehicle:getCpDriveStrategy()
    local data=driver and driver.queueData
    local queued=data and Q.owns(driver) and not data.nativeDeparture and not Q.atDepartureThreshold(driver)
        and not driver:isDriveUnloadNowRequested() and not driver.combineToUnload
    local parkedVehicle=vehicle and (vehicle.spec_combine or vehicle.spec_motorized)
    if not queued and not parkedVehicle then return false end
    if not AIUtil.isStopped(vehicle) or not AIUtil.isStopped(combine.vehicle) then return false end
    if not queued then driver=nil; data=nil end
    -- A second harvester may need this trailer to yield instead of holding still.
    for other in pairs(data and data.yieldRequests or {}) do
        if other~=combine.vehicle then return false end
    end
    local time=g_currentMission.time
    if combine.queueBypassAttempt and time-combine.queueBypassAttempt<15000 then return false end
    combine.queueBypassAttempt=time
    if connector then
        -- StartRowOnly owns the same row-start context but does not register a
        -- turn proximity listener. Recover to that exact destination through
        -- the strategy, retaining the saved fieldwork course and straight entry.
        if not combine:startRecoveryTurn(combine.turningRadius) then return false end
        combine.workStarter=nil
    else
        turn:startRecoveryTurn(combine.turningRadius)
    end
    local recovery=combine.aiTurn
    if recovery==turn then return false end
    local bypass={turn=recovery,vehicle=vehicle,driver=driver,combine=combine,untilTime=time+120000,
        blockedCourse=combine.ppc:getCourse(),blockedIx=combine.ppc:getRelevantWaypointIx()}
    if connector then
        recovery.queueConnectorCourse=bypass.blockedCourse
        recovery.queueConnectorIx=bypass.blockedIx
        recovery.queueForwardOnly=true
    end
    if driver then
        Q.take(driver,'prepare')
        data.yieldRequests=nil; data.priorityCombine=nil; data.bypass=bypass
    end
    combine.queueBypass=bypass
    recovery.generatePathfinderTurn=Q.generateHarvesterBypass
    recovery.startPreparedRecovery=function(self) self:generatePathfinderTurn(false) end
    local getDriveData=recovery.getDriveData
    recovery.getDriveData=function(self,dt)
        if bypass.retry then
            bypass.retry=nil; self:generatePathfinderTurn(false)
            return nil,nil,nil,0
        end
        if bypass.waiting then
            if g_currentMission.time>=bypass.waitUntil then
                combine.queueRecoveryFailure='vehicle did not clear the checked turn route'
                return nil,nil,nil,0
            end
            -- Never repeat an unsuccessful search against unchanged obstacles.
            -- A trailer yield or a previously parked combine moving is new evidence.
            local pose=W.pose(vehicle:getAIDirectionNode())
            if g_currentMission.time-bypass.checkedAt>=5000 and
                    (distance(pose,bypass.failedPose)>3 or math.abs(H.math.delta(pose.t,bypass.failedPose.t))>math.rad(15))
                    and AIUtil.isStopped(vehicle) then
                bypass.waiting=nil; bypass.checkedAt=g_currentMission.time
                self:generatePathfinderTurn(false)
            end
            return nil,nil,nil,0
        end
        return getDriveData(self,dt)
    end
    recovery.onPathfindingDone=function(self,path)
        if not path or #path<=2 then Q.waitForHarvesterClearance(bypass,'no collision-checked route'); return end
        if not Q.finishHarvesterBypass(self,path) then Q.waitForHarvesterClearance(bypass,'final route clearance') end
    end
    recovery.onBlocked=function(self)
        if self.state==self.states.PREPARING_RECOVERY or self.state==self.states.WAITING_FOR_PATHFINDER then return end
        Q.waitForHarvesterClearance(bypass,'recovery route blocked')
    end
    -- RecoveryTurn registered its original method during construction.
    recovery.proximityController:registerBlockingObjectListener(recovery,recovery.onBlocked)
    combine:debug('Queue: routing around parked %s to original turn end %d',
        CpUtil.getName(vehicle),combine.turnContext.turnEndWpIx)
    return true
end

function Q.clearHarvesterBypass(driver)
    local data=driver.queueData
    local bypass=data and data.bypass
    if not bypass then return end
    if bypass.combine.queueBypass==bypass then bypass.combine.queueBypass=nil end
    data.bypass=nil; data.nextAttempt=0
end

function Q.holdForHarvesterBypass(driver)
    local data=driver.queueData
    local bypass=data and data.bypass
    if not bypass then return false end
    local combine=bypass.combine
    if Q.atDepartureThreshold(driver) or driver:isDriveUnloadNowRequested()
            or not combine.vehicle:getIsCpActive() or combine.aiTurn~=bypass.turn
            or combine.state~=combine.states.TURNING then
        Q.clearHarvesterBypass(driver)
        return false
    end
    if g_currentMission.time>=bypass.untilTime then
        bypass.turn.queueForwardOnly=true
        Q.waitForHarvesterClearance(bypass,'recovery timeout')
        return false
    end
    driver:setMaxSpeed(0)
    return true
end

-- Proximity rays can miss a header as steering changes. During turns, keep a
-- short swept envelope against nearby harvesters and queue rigs, even when a
-- stopped harvester's CP job has ended. This is geometry work only: no search
-- in the per-frame guard and no changes to the saved fieldwork course.
function Q.guardHarvesterTurn(combine,speed)
    local bypass=combine.queueBypass
    if bypass and (combine.aiTurn~=bypass.turn or combine.state~=combine.states.TURNING) then
        if bypass.driver then Q.clearHarvesterBypass(bypass.driver) end
        combine.queueBypass=nil
    end
    local connector=combine.states.DRIVING_TO_WORK_START_WAYPOINT and
        combine.state==combine.states.DRIVING_TO_WORK_START_WAYPOINT
    local turn=combine.aiTurn
    local finishing=combine.state==combine.states.TURNING and turn and turn.states.FINISHING_ROW
        and turn.state==turn.states.FINISHING_ROW
    -- Row finishing follows a deliberately overlong straight guiding course.
    -- Native implement raising ends it early. Reserving that unused tail can
    -- stop the combine and send a trailer backwards before the real turn exists.
    if finishing or (combine.state~=combine.states.TURNING and not connector) then
        combine.queueTurnGuard=nil; combine.queueTurnPreflight=nil; combine.queueTurnBlocker=nil
        return speed
    end
    local longConnector=connector or (combine.aiTurn and combine.aiTurn.queueConnectorCourse)
    if longConnector then combine.queueTurnPreflight=nil end
    local time=g_currentMission.time
    local guard=combine.queueTurnGuard
    local course=combine.ppc:getCourse()
    if not guard or guard.course~=course or time-guard.checked>=100 then
        guard={course=course,checked=time}; combine.queueTurnGuard=guard
        local origin=W.pose(combine.vehicle:getAIDirectionNode())
        local preflight=combine.queueTurnPreflight
        -- Long work-start routes use the live braking horizon. Full-turn
        -- preflight belongs only to a newly installed, bounded row manoeuvre.
        local newCourse=not longConnector and combine.aiTurn and combine.aiTurn.turnCourse==course and
            (not preflight or preflight.course~=course)
        if newCourse then
            preflight={course=course,attempts=1,checked=time}; combine.queueTurnPreflight=preflight
            -- Check the complete newly planned turn before granting any speed.
            -- The larger sample budget is used only once per installed course.
            preflight.area=Q.yieldArea(combine.vehicle,math.huge,2048)
            if not preflight.area then preflight.unknown=true end
        elseif preflight and preflight.unknown and time-preflight.checked>=1000 then
            preflight.checked=time; preflight.attempts=preflight.attempts+1
            preflight.area=Q.yieldArea(combine.vehicle,math.huge,2048)
            preflight.unknown=not preflight.area
            newCourse=not preflight.unknown
            if preflight.unknown and preflight.attempts>=3 then
                combine.queueRecoveryFailure='turn footprint could not be checked after three attempts'
            end
        end
        local candidates={}
        for _,other in pairs(g_currentMission.vehicleSystem.vehicles) do
            if other~=combine.vehicle and other.rootNode and other.getAIDirectionNode and not isActiveFieldworker(other) then
                local driver=other.getCpDriveStrategy and other:getCpDriveStrategy()
                if other.spec_combine or other.spec_motorized or (driver and driver.queueData) then
                    local pose=W.pose(other:getAIDirectionNode())
                    local d=distance(origin,pose)
                    local range=newCourse and course:getLength()+30 or 60
                    if d<range or (preflight and preflight.vehicle==other) then
                        candidates[#candidates+1]={vehicle=other,d=d}
                    end
                end
            end
        end
        table.sort(candidates,function(a,b) return a.d<b.d end)
        if preflight and preflight.unknown then guard.unknown=true end
        if #candidates>0 then
            -- Include reaction distance and a conservative braking allowance.
            local metresPerSecond=math.max(speed or 0,(combine.vehicle.lastSpeedReal or 0)*3600)/3.6
            local horizon=math.min(30,math.max(8,metresPerSecond*0.4+metresPerSecond^2/3+3))
            local area=Q.yieldArea(combine.vehicle,horizon)
            if not area then guard.unknown=true end
            for _,candidate in ipairs(candidates) do
                local bodies=W.currentBodies(candidate.vehicle)
                if not bodies then guard.unknown=true end
                for _,item in ipairs(bodies or {}) do
                    local rectangle=W.rectangle(item.body,item.pose)
                    if preflight and preflight.area and (newCourse or preflight.vehicle==candidate.vehicle)
                            and AIUtil.isStopped(candidate.vehicle) and preflight.area(rectangle) then
                        preflight.vehicle=candidate.vehicle; guard.vehicle=candidate.vehicle; break
                    end
                    if area and area(rectangle) then
                        guard.vehicle=candidate.vehicle; break
                    end
                end
                if guard.vehicle then break end
            end
        end
        if preflight and (not preflight.vehicle or not guard.vehicle) then preflight.area=nil; preflight.vehicle=nil end
    end
    if guard.vehicle then
        if combine.queueTurnBlocker~=guard.vehicle then
            combine:debug('Queue: turn envelope blocked by %s; holding before contact',CpUtil.getName(guard.vehicle))
            combine.queueTurnBlocker=guard.vehicle
        end
        -- Stopped vehicles may no longer intersect any proximity ray, so the
        -- checked envelope also supplies the recovery callback.
        if combine.ppc:getCourse()~=course then combine.queueTurnGuard=nil; return 0 end
        if AIUtil.isStopped(combine.vehicle) and AIUtil.isStopped(guard.vehicle) then
            combine:onBlockingVehicle(guard.vehicle,false)
        end
        return 0
    end
    combine.queueTurnBlocker=nil
    if guard.unknown then
        combine.queueGeometryUnknownSince=combine.queueGeometryUnknownSince or time
        if time-combine.queueGeometryUnknownSince>=5000 then
            combine.queueRecoveryFailure='nearby vehicle footprint could not be checked'
        end
    else combine.queueGeometryUnknownSince=nil end
    return guard.unknown and 0 or speed
end

-- Read CP's current route; never create or replace a harvester course here.
-- The envelope includes the attached header, relative to the AI direction node.
function Q.yieldArea(combine,horizon,sampleLimit)
    local strategy=combine:getCpDriveStrategy()
    local origin=W.pose(combine:getAIDirectionNode())
    local bodies=W.currentBodies(combine)
    if not bodies then return nil,'harvester body geometry unavailable' end
    local left,right,front,back=-math.huge,math.huge,-math.huge,math.huge
    for _,item in ipairs(bodies) do
        for _,p in ipairs(W.rectangle(item.body,item.pose,0)) do
            local dx,dz=p.x-origin.x,p.z-origin.z
            local x,z=dx*math.cos(origin.t)-dz*math.sin(origin.t),dx*math.sin(origin.t)+dz*math.cos(origin.t)
            left=math.max(left,x); right=math.min(right,x)
            front=math.max(front,z); back=math.min(back,z)
        end
    end
    local box={width=left-right,length=front-back,xOffset=(left+right)/2,zOffset=(front+back)/2}
    local rectangles={}
    local function add(p)
        local r=G.rectangle({x=p.x,z=p.z,heading=p.t},box,1)
        r.minX=math.huge; r.maxX=-math.huge; r.minZ=math.huge; r.maxZ=-math.huge
        for _,q in ipairs(r) do
            r.minX=math.min(r.minX,q.x); r.maxX=math.max(r.maxX,q.x)
            r.minZ=math.min(r.minZ,q.z); r.maxZ=math.max(r.maxZ,q.z)
        end
        rectangles[#rectangles+1]=r
    end
    add(origin)
    local course=strategy.getCurrentCourse and strategy:getCurrentCourse()
    local ix=strategy.ppc and strategy.ppc:getRelevantWaypointIx()
    local bypass=strategy.queueBypass
    if bypass and bypass.waiting then course=bypass.blockedCourse; ix=bypass.blockedIx end
    horizon=horizon or 30
    sampleLimit=sampleLimit or 160
    if course and ix and course:getNumberOfWaypoints()>1 then
        local previous,travelled,sinceSample=origin,0,0
        -- A local horizon covers the immediate turn without reserving an
        -- entire fieldwork row. Bound both travel and sample count.
        local cornerRadius=math.sqrt(math.max(left*left,right*right)+math.max(front*front,back*back))
        for i=math.max(1,ix),course:getNumberOfWaypoints() do
            local x,_,z=course:getWaypointPosition(i)
            -- Waypoint yaw describes the outgoing segment. At a gear change,
            -- use the same physical heading convention as Course's offsets.
            local reverse=(course:isReverseAt(i) and not course:switchingToForwardAt(i))
                or course:switchingToReverseAt(i)
            local t=course:getWaypointYRotation(i)+(reverse and math.pi or 0)
            local d=distance(previous,{x=x,z=z})
            local fraction=d>0 and math.min(1,(horizon-travelled)/d) or 1
            local target={x=previous.x+(x-previous.x)*fraction,z=previous.z+(z-previous.z)*fraction,
                t=previous.t+H.math.delta(t,previous.t)*fraction}
            local motion=d*fraction+cornerRadius*math.abs(H.math.delta(target.t,previous.t))
            -- Carry the corner-travel allowance across waypoint boundaries.
            -- One sample per tiny waypoint would exhaust the limit even on a
            -- straight route. One metre of padding covers the unsampled sweep.
            local sampleAt=1-sinceSample
            while sampleAt<=motion and motion>0 do
                if #rectangles>=sampleLimit then return nil,'harvester route envelope sample limit' end
                local f=sampleAt/motion
                add({x=previous.x+(target.x-previous.x)*f,z=previous.z+(target.z-previous.z)*f,
                    t=previous.t+H.math.delta(target.t,previous.t)*f})
                sampleAt=sampleAt+1
            end
            sinceSample=motion-(sampleAt-1)
            previous=target; travelled=travelled+d*fraction
            if travelled>=horizon then break end
        end
        if sinceSample>0.000001 then
            if #rectangles>=sampleLimit then return nil,'harvester route envelope sample limit' end
            add(previous)
        end
    end
    return function(rectangle)
        local minX,maxX,minZ,maxZ=math.huge,-math.huge,math.huge,-math.huge
        for _,p in ipairs(rectangle) do
            minX=math.min(minX,p.x); maxX=math.max(maxX,p.x)
            minZ=math.min(minZ,p.z); maxZ=math.max(maxZ,p.z)
        end
        for _,r in ipairs(rectangles) do
            if minX<=r.maxX and maxX>=r.minX and minZ<=r.maxZ and maxZ>=r.minZ
                    and G.overlap(rectangle,r) then return true end
        end
        return false
    end
end

function Q.resumeAfterYield(driver)
    local data=Q.data(driver)
    data.priorityCombine=nil; data.yieldRequests=nil
    Q.take(driver,'prepare')
    data.nextAttempt=0
    Q.reason(data,'clear of harvester manoeuvre; resuming prepare')
end

function Q.priority(driver,combine)
    if (driver.queueData and driver.queueData.nativeDeparture)
            or driver.state==driver.states.MOVING_BACK_WITH_TRAILER_FULL then return false end
    if not Q.enabled(driver) or not combine or not driver.vehicle:getIsCpActive()
            or not AIDriveStrategyCombineCourse.isActiveCpCombine(combine) then return false end
    if Q.atDepartureThreshold(driver) or driver:isDriveUnloadNowRequested() then return false end
    -- Native continuous-harvester following already handles its own harvester's proximity
    -- and turns. Other queued/approaching trailers still yield to it normally.
    if driver.combineToUnload==combine and combine:getCpDriveStrategy():alwaysNeedsUnloader() and not Q.owns(driver) then
        return false
    end
    local data=Q.data(driver)
    Q.clearHarvesterBypass(driver)
    if data.operation=='yield' and Q.owns(driver) then
        data.yieldRequests[combine]=data.yieldRequests[combine] or {}
        data.yieldRequests[combine].clearSince=nil
        return true
    end
    -- Native searches are advanced synchronously by this controller; removing
    -- its runner prevents a superseded callback after clearance. The next native
    -- call installs its own context/listeners in the ordinary way.
    if driver.pathfinderController then driver.pathfinderController.pathfinder=nil end
    driver:releaseCombine()
    Q.take(driver,'yield')
    data.priorityCombine=combine
    data.yieldRequests={[combine]={}}
    data.nextAttempt=0
    Q.reason(data,'yield requested by '..CpUtil.getName(combine))
    return true
end

function Q.yieldTarget(driver,checkOnly)
    local data=Q.data(driver)
    local bodies=W.currentBodies(driver.vehicle)
    local areas,combine,anyBlocked={},nil,false
    local time=g_currentMission.time
    for vehicle,request in pairs(data.yieldRequests or {}) do
        if not AIDriveStrategyCombineCourse.isActiveCpCombine(vehicle) then
            data.yieldRequests[vehicle]=nil
        else
            local strategy=vehicle:getCpDriveStrategy()
            if not request.checked or time-request.checked>=200 then
                request.area,request.reason=Q.yieldArea(vehicle); request.checked=time
            end
            local blocked=not bodies or not request.area or strategy:isVehicleInProximity(driver.vehicle)
            for _,item in ipairs(bodies or {}) do
                if request.area and request.area(W.rectangle(item.body,item.pose)) then blocked=true end
            end
            anyBlocked=anyBlocked or blocked
            if blocked then request.clearSince=nil else request.clearSince=request.clearSince or time end
            if request.clearSince and time-request.clearSince>=2000 then
                data.yieldRequests[vehicle]=nil
            else
                combine=combine or vehicle
                if not request.area then
                    Q.reason(data,'harvester clearance unavailable: '..(request.reason or 'unknown geometry'))
                    return
                end
                areas[#areas+1]=request.area
            end
        end
    end
    if not combine then Q.resumeAfterYield(driver); return end
    if checkOnly then return true end
    if not anyBlocked then return end -- let the existing safe pass finish without starting another move
    local pose=W.pose(combine:getAIDirectionNode())
    local width=combine:getCpDriveStrategy():getWorkWidth()+4
    local function corridor(rectangle)
        for _,area in ipairs(areas) do if area(rectangle) then return true end end
        return false
    end
    local here=W.pose(driver.vehicle:getAIDirectionNode())
    local lateral=(here.x-pose.x)*math.cos(pose.t)-(here.z-pose.z)*math.sin(pose.t)
    local side=lateral>=0 and 1 or -1
    local function accepts(poses,model)
        for i,p in ipairs(poses) do if corridor(W.rectangle(model.bodies[i],p)) then return false end end
        return true
    end
    local choices={}
    -- A rig parallel to a narrow headland may only need to pull forward.
    -- Sideways targets can all be outside the field and reversing can keep
    -- its trailer in the header's swept area. Validate these like every other
    -- candidate, including the trailer, crop and live obstacle checks.
    for _,length in ipairs({10,20,40,60}) do
        local forward=G.point({x=here.x,z=here.z,heading=here.t},0,length)
        forward.t=here.t; forward.accept=accepts; forward.clearance=corridor
        choices[#choices+1]=forward
    end
    for _,lateralSide in ipairs({side,-side}) do
        local p=G.point({x=here.x,z=here.z,heading=here.t},lateralSide*(width/2+8),
            math.max(40,3*driver.turningRadius))
        p.t=here.t; p.accept=accepts; p.clearance=corridor
        choices[#choices+1]=p
        -- A quarter turn followed by a straight clearance leg can fit where
        -- returning immediately to the original heading would swing the
        -- trailer across the header. The search still validates the full rig.
        local lateral=G.point({x=here.x,z=here.z,heading=here.t},
            lateralSide*(2*driver.turningRadius+2*AIUtil.getLength(driver.vehicle)),driver.turningRadius)
        lateral.t=here.t+lateralSide*math.pi/2
        lateral.accept=accepts; lateral.clearance=corridor
        choices[#choices+1]=lateral
    end
    for _,length in ipairs({10,20,40,60}) do
        local reverse=G.point({x=here.x,z=here.z,heading=here.t},0,-length)
        reverse.t=here.t; reverse.reverse=true; reverse.accept=accepts; reverse.clearance=corridor
        choices[#choices+1]=reverse
    end
    local target={x=choices[1].x,z=choices[1].z,t=here.t,choices=choices}
    return target
end
