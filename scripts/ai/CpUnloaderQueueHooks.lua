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
    local hold=Q.holdIncomingTurn(self)
    local gx,gz,forwards,speed,acceleration=drive(self,...)
    if Q.holdIncomingTurn(self,speed) or hold then speed=0 end
    return gx,gz,forwards,speed,acceleration
end

local allowed = U.isAllowedToBeCalled
function U:isAllowedToBeCalled()
    if self.queueData and self.queueData.bypass then return false end
    if Q.enabled(self) and ((self.queueData and self.queueData.nativeDeparture) or Q.atDepartureThreshold(self)) then return false end
    if Q.enabled(self) and Q.owns(self) then return self.queueData.operation=='prepare' end
    return allowed(self)
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
    if not isBack and Q.checkParkedTrailerTravel(self) then return end
    if Q.tryHarvesterBypass(self,vehicle,isBack) then return end
    return combineBlocking(self,vehicle,isBack)
end

local combineDrive = C.getDriveData
function C:getDriveData(...)
    local hold=Q.checkParkedTrailerTravel(self)
    local gx,gz,forwards,speed,acceleration=combineDrive(self,...)
    if Q.checkParkedTrailerTravel(self) or hold then speed=0 end
    return gx,gz,forwards,speed,acceleration
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
    if Q.deferTrailerYield(self,vehicle) then return end
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
function U:requestToBackupForReversingCombine(vehicle,...)
    if Q.deferTrailerYield(self,vehicle) then return end
    if Q.owns(self) then Q.release(self) end
    return backup(self,vehicle,...)
end
