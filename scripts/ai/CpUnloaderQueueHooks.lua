-- Deliberately small integration surface. Protected native method bodies stay
-- byte-identical to main, including calls, crop readiness and pipe following.
local Q = CpUnloaderQueue
local U = AIDriveStrategyUnloadCombine
local C = AIDriveStrategyCombineCourse

local update = U.update
function U:update(dt)
    Q.tick(self)
    -- A no-marker/full event can synchronously stop CP and delete this driver.
    if self.vehicle:getCpDriveStrategy()~=self then return end
    return update(self,dt)
end

local drive = U.getDriveData
function U:getDriveData(...)
    Q.speed(self)
    return drive(self,...)
end

local allowed = U.isAllowedToBeCalled
function U:isAllowedToBeCalled()
    if Q.enabled(self) and ((self.queueData and self.queueData.nativeDeparture) or Q.atDepartureThreshold(self)) then return false end
    if Q.enabled(self) and Q.owns(self) then return self.queueData.operation=='prepare' and not self.queueData.bypass end
    return allowed(self)
end

local call = U.call
function U:call(combine,waypoint)
    if Q.enabled(self) and ((self.queueData and self.queueData.nativeDeparture) or Q.atDepartureThreshold(self)) then return false end
    if Q.enabled(self) and Q.owns(self) then
        if self.queueData.operation~='prepare' or self.queueData.bypass then return false end
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

local find = C.findUnloader
function C:findUnloader(combine,waypoint)
    if next(Q.members) then
        local handled,vehicle,eta=Q.findUnloader(self,combine,waypoint)
        if handled then return vehicle,eta end
    end
    return find(self,combine,waypoint)
end

-- Native turn recovery handles trees and other objects, but its vehicle-block
-- callback only asks the other driver to move. Reuse that recovery for a
-- stationary queued trailer without changing the fieldwork destination.
local combineBlocking = C.onBlockingVehicle
function C:onBlockingVehicle(vehicle,isBack)
    if Q.tryHarvesterBypass(self,vehicle,isBack) then return end
    return combineBlocking(self,vehicle,isBack)
end

local combineDrive = C.getDriveData
function C:getDriveData(...)
    local x,z,forward,speed,distance=combineDrive(self,...)
    return x,z,forward,Q.guardHarvesterTurn(self,speed),distance
end

-- A pathfinder callback runs inside update. Deleting its strategy there leaves
-- native debug/implement update code holding destroyed nodes. Stop at the next
-- update boundary instead, only after a bounded clearance wait has expired.
local combineUpdate = C.update
function C:update(dt)
    if self.queueRecoveryFailure then
        self:debug('Queue: %s; stopping after clearance timeout',self.queueRecoveryFailure)
        local bypass=self.queueBypass
        if bypass and bypass.driver then Q.clearHarvesterBypass(bypass.driver) end
        self.queueBypass=nil
        self.vehicle:stopCurrentAIJob(AIMessageCpErrorNoPathFound.new())
        return
    end
    return combineUpdate(self,dt)
end

-- Preparation ends here. CP owns marker travel, retries, clearance and the
-- full-job event consumed by AD. Do not impose a second handover gate.
local unload = U.startUnloadingTrailers
function U:startUnloadingTrailers(...)
    if Q.enabled(self) then
        if Q.owns(self) then Q.release(self) else Q.cancel(self) end
        local data=Q.data(self)
        data.operation=nil; data.nativeDeparture=true
        data.assignment=nil; data.yieldRequests=nil; data.priorityCombine=nil
    end
    return unload(self,...)
end

local last = U.onLastWaypointPassed
function U:onLastWaypointPassed(...)
    if Q.owns(self) then Q.onLast(self); return end
    return last(self,...)
end

local blocking = U.onBlockingVehicle
function U:onBlockingVehicle(vehicle,isBack)
    if Q.priority(self,vehicle) then return end
    return blocking(self,vehicle,isBack)
end

local remove = U.delete
function U:delete(...)
    local result=remove(self,...)
    Q.remove(self)
    return result
end

-- The existing reverse-clearance manoeuvre retains its native controller.
-- Invalidate a pending preparation route before native backup takes ownership.
local backup = U.requestToBackupForReversingCombine
function U:requestToBackupForReversingCombine(...)
    if Q.owns(self) then Q.release(self) end
    return backup(self,...)
end
