-- Deliberately small integration surface. Protected native method bodies stay
-- byte-identical to main, including calls, crop readiness and pipe following.
local Q = CpUnloaderQueue
local U = AIDriveStrategyUnloadCombine
local C = AIDriveStrategyCombineCourse

local setVehicle = U.setAIVehicle
function U:setAIVehicle(vehicle,...)
    local result=setVehicle(self,vehicle,...)
    if Q.enabled(self) then Q.captureArrival(self) end
    return result
end

-- Job completion can delete the combine strategy before its unloader updates.
-- Retain only a successful, empty end-of-course unload, never a manual/error stop.
if CpAIJob then
    local J = CpAIJob
    local start = J.start
    function J:start(...)
        local vehicle=self.vehicleParameter:getVehicle()
        if self.isServer and vehicle then vehicle.queueFinishedEmptyCombine=nil end
        return start(self,...)
    end
    local stop = J.stop
    function J:stop(message,...)
        local vehicle=self.vehicleParameter:getVehicle()
        if self.isServer and vehicle then
            local driver=vehicle:getCpDriveStrategy()
            local event
            if message then
                local _,_,completionEvent=g_infoTextManager:getInfoTextDataByAIMessage(message)
                event=completionEvent
            end
            vehicle.queueFinishedEmptyCombine=event=='onCpFinished' and driver
                and driver.isWaitingForUnloadAfterCourseEnded and driver:isWaitingForUnloadAfterCourseEnded()
                and driver:getFillLevelPercentage()<0.1 or nil
        end
        return stop(self,message,...)
    end
end

local update = U.update
function U:update(dt)
    Q.releaseFinishedCombine(self)
    Q.updateStoppedApproach(self)
    Q.updateFinalUnload(self)
    if self.vehicle:getCpDriveStrategy()~=self then return end
    Q.resumeWaitingApproach(self)
    Q.tick(self)
    -- A no-marker/full event can synchronously stop CP and delete this driver.
    if self.vehicle:getCpDriveStrategy()~=self then return end
    return update(self,dt)
end

local drive = U.getDriveData
function U:getDriveData(...)
    Q.releaseFinishedCombine(self)
    Q.speed(self)
    local hold=Q.holdIncomingTurn(self)
    local gx,gz,forwards,speed,acceleration=drive(self,...)
    if Q.holdPocketDeparture(self,forwards,speed) then speed=0 end
    if Q.holdIncomingTurn(self,speed) or hold then speed=0 end
    speed=Q.finalUnloadSpeed(self,speed)
    speed=Q.stoppedApproachSpeed(self,speed)
    return gx,gz,forwards,speed,acceleration
end

local stoppedUnload = U.unloadStoppedCombine
function U:unloadStoppedCombine()
    if self.queueStationaryPipe==self.combineToUnload and not Q.stationaryGrainTarget(self) then
        self.queueStationaryPipe=nil
        local c=self.combineToUnload and self.combineToUnload:getCpDriveStrategy()
        if c and not c:willWaitForUnloadToFinish() and not c:isUnloadFinished() then
            self:startCourseFollowingCombine(); self:setMaxSpeed(0); return
        end
    end
    if Q.watchFinalUnload(self) then return end
    return stoppedUnload(self)
end

local stoppedApproach = U.startUnloadingStoppedCombine
function U:startUnloadingStoppedCombine()
    if Q.deferFinalPipeApproach(self) then return end
    return stoppedApproach(self)
end

local admission = U.isOkToStartUnloadingCombine
function U:isOkToStartUnloadingCombine()
    if Q.stoppedAdmission(self)==false then return false end
    return admission(self)
end

local needsPath = U.isPathfindingNeeded
function U:isPathfindingNeeded(vehicle,target,...)
    if vehicle==self.vehicle and Q.stationaryGrainTarget(self)
            and target==self:getPipeOffsetReferenceNode() and Q.pipeEntryAligned(self)==false then
        return true -- nearby but misaligned still needs the checked rear entry
    end
    return needsPath(self,vehicle,target,...)
end

local startUnload = U.startUnloadingCombine
function U:startUnloadingCombine()
    if Q.stationaryGrainTarget(self) then
        self.queueStationaryPipe=self.combineToUnload
        self:startUnloadingStoppedCombine(); return
    end
    return startUnload(self)
end

local movingUnload = U.unloadMovingCombine
function U:unloadMovingCombine()
    if Q.watchStoppedMovingUnload(self) then return end
    return movingUnload(self)
end

local allowed = U.isAllowedToBeCalled
function U:isAllowedToBeCalled()
    if self.queueData and (self.queueData.approachRetryAt or 0)>g_currentMission.time then return false end
    if self.queueData and self.queueData.bypass then return false end
    if Q.enabled(self) and ((self.queueData and self.queueData.nativeDeparture) or Q.atDepartureThreshold(self)) then return false end
    if Q.enabled(self) and Q.owns(self) then return self.queueData.operation=='prepare' end
    return allowed(self)
end

-- Keep a replacement's native assignment while an outgoing train occupies
-- its exact final goal. Other failures retain native retry/error handling.
local waitingPath = U.startPathfindingToWaitingCombine
function U:startPathfindingToWaitingCombine(x,z)
    x,z=Q.stoppedApproachGoal(self,x,z)
    if Q.deferWaitingApproach(self,x,z) then return end
    if self.queueData then self.queueData.waitingApproach={combine=self.combineToUnload,x=x,z=z} end
    return waitingPath(self,x,z)
end

local stationaryFailed = U.onPathfindingFailedToStationaryTarget
function U:onPathfindingFailedToStationaryTarget(...)
    local attempt=self.queueData and self.queueData.waitingApproach
    if attempt and attempt.combine==self.combineToUnload and Q.deferWaitingApproach(self,attempt.x,attempt.z) then return end
    return stationaryFailed(self,...)
end

local waitingDone = U.onPathfindingDoneToWaitingCombine
function U:onPathfindingDoneToWaitingCombine(controller,success,course,invalid)
    local attempt=self.queueData and self.queueData.waitingApproach
    if not success and attempt and attempt.combine==self.combineToUnload
            and Q.deferWaitingApproach(self,attempt.x,attempt.z) then return false end
    if self.queueData then self.queueData.waitingApproach=nil end
    Q.stoppedApproachPath(self,success,course)
    return waitingDone(self,controller,success,course,invalid)
end

local call = U.call
function U:call(combine,waypoint)
    if self.queueData and self.queueData.bypass then return false end
    if Q.enabled(self) and ((self.queueData and self.queueData.nativeDeparture) or Q.atDepartureThreshold(self)) then return false end
    if Q.enabled(self) and Q.owns(self) then
        if self.queueData.operation~='prepare' then return false end
        Q.release(self)
    end
    return call(self,combine,waypoint)
end

-- The configured emptying percentage is a departure threshold, including
-- during transfer. Native fullness handling still releases the harvester and
-- performs its reverse-clearance manoeuvre before native departure.
local fullTrailers = U.getAllTrailersFull
function U:getAllTrailersFull(threshold)
    if threshold==nil and Q.enabled(self) and self.settings and self.settings.fullThreshold then
        threshold=self.settings.fullThreshold:getValue()
    end
    return fullTrailers(self,threshold)
end

local remaining = U.areThereAnyCombinesOrLoaderLeftoverOnTheField
function U:areThereAnyCombinesOrLoaderLeftoverOnTheField(combine,...)
    if Q.enabled(self) then return Q.hasRemainingCombine(self,combine) end
    return remaining(self,combine,...)
end

local find = C.findUnloader
function C:findUnloader(combine,waypoint)
    if next(Q.members) then
        local handled,vehicle,eta=Q.findUnloader(self,combine,waypoint)
        if handled then return vehicle,eta end
    end
    return find(self,combine,waypoint)
end

local combineUnload = C.driveUnloadOnField
function C:driveUnloadOnField()
    if self.queueFinishClearance then Q.driveFinishClearance(self); return end
    if self.unloadState==self.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED
            and self.combineController:getFillLevel()<0.01 and Q.beginFinishClearance(self) then return end
    return combineUnload(self)
end

local combineLast = C.onLastWaypointPassed
function C:onLastWaypointPassed(...)
    if self.queueFinishClearance then Q.driveFinishClearance(self); return end
    if self.state==self.states.WORKING and self.course==self.fieldWorkCourse
            and self.combineController:getFillLevel()<0.01 and Q.beginFinishClearance(self) then return end
    return combineLast(self,...)
end

local combineEnded = C.isWaitingForUnloadAfterCourseEnded
function C:isWaitingForUnloadAfterCourseEnded()
    return self.queueFinishClearance~=nil or combineEnded(self)
end

local combineReady = C.isReadyToUnload
function C:isReadyToUnload(...)
    if self.queueFinishClearance then return false end
    return combineReady(self,...)
end

local cutterOff = C.getCanCutterBeTurnedOff
function C:getCanCutterBeTurnedOff()
    return self.queueFinishClearance~=nil or cutterOff(self)
end

local combineOffset = C.updateFieldworkOffset
function C:updateFieldworkOffset(course)
    if self.queueFinishClearance and self.queueFinishClearance.driving then course:setOffset(0,0); return end
    return combineOffset(self,course)
end

local combineDelete = C.delete
function C:delete(...)
    Q.clearFinishClearance(self)
    return combineDelete(self,...)
end

-- Native turn recovery handles trees and other objects, but its vehicle-block
-- callback only asks the other driver to move. Reuse that recovery for a
-- stationary queued trailer without changing the fieldwork destination.
local combineBlocking = C.onBlockingVehicle
function C:onBlockingVehicle(vehicle,isBack)
    if Q.checkCombineTurns(self) then return end
    if not isBack and Q.checkParkedTrailerTravel(self) then return end
    if Q.tryHarvesterBypass(self,vehicle,isBack) then return end
    return combineBlocking(self,vehicle,isBack)
end

local combineDrive = C.getDriveData
function C:getDriveData(...)
    local cornerHold=Q.holdHeadlandCorner(self)
    local hold=Q.checkCombineTurns(self) or Q.checkParkedTrailerTravel(self) or cornerHold
    local gx,gz,forwards,speed,acceleration=combineDrive(self,...)
    cornerHold=Q.holdHeadlandCorner(self) or cornerHold
    if cornerHold~=self.queueCornerHold then
        if cornerHold then
            self:debug('Queue: waiting before headland corner for centre-entry combine %s', CpUtil.getName(cornerHold))
        elseif self.queueCornerHold then
            self:debug('Queue: centre-entry hold released')
        end
        self.queueCornerHold=cornerHold
    end
    if Q.checkCombineTurns(self,speed) or Q.checkParkedTrailerTravel(self) or cornerHold or hold then speed=0 end
    return gx,gz,forwards,speed,acceleration
end

-- Preparation ends here. CP owns marker travel, retries, clearance and the
-- full-job event consumed by AD. Do not impose a second handover gate.
local unload = U.startUnloadingTrailers
function U:startUnloadingTrailers(...)
    Q.clearStoppedApproach(self)
    self.queueStationaryPipe=nil; self.queueStoppedWatch=nil
    Q.clearFinalUnload(self)
    if Q.enabled(self) then
        -- Remember a pocket departure only after native reverse clearance.
        -- Pathfinding can take longer than the pause, so start its clock when
        -- the resulting forward route is actually ready to move.
        if self.state==self.states.MOVING_BACK_WITH_TRAILER_FULL then
            local vehicle=self.state.properties.vehicle
            local combine=vehicle and vehicle:getCpDriveStrategy()
            Q.data(self).pocketDeparturePause=combine and combine.isAboutToReturnFromPocket
                and combine:isAboutToReturnFromPocket() and {} or nil
        end
        if Q.owns(self) then Q.release(self) else Q.cancel(self) end
        local data=Q.data(self)
        data.operation=nil; data.nativeDeparture=true
        data.assignment=nil; data.yieldRequests=nil; data.priorityCombine=nil
    end
    return unload(self,...)
end

local last = U.onLastWaypointPassed
function U:onLastWaypointPassed(...)
    if Q.stoppedApproachLast(self) then return end
    if Q.finishFinalReverse(self) then return end
    if Q.owns(self) then Q.onLast(self); return end
    return last(self,...)
end

local blocking = U.onBlockingVehicle
function U:onBlockingVehicle(vehicle,isBack)
    if Q.deferTrailerYield(self,vehicle) then return end
    if Q.priority(self,vehicle) then return end
    return blocking(self,vehicle,isBack)
end

local remove = U.delete
function U:delete(...)
    Q.clearStoppedApproach(self)
    self.queueStationaryPipe=nil; self.queueStoppedWatch=nil
    Q.clearFinalUnload(self)
    local result=remove(self,...)
    Q.remove(self)
    return result
end

-- The existing reverse-clearance manoeuvre retains its native controller.
-- Invalidate a pending preparation route before native backup takes ownership.
local backup = U.requestToBackupForReversingCombine
function U:requestToBackupForReversingCombine(vehicle,...)
    if Q.deferTrailerYield(self,vehicle) then return end
    if Q.owns(self) then Q.release(self) end
    return backup(self,vehicle,...)
end
