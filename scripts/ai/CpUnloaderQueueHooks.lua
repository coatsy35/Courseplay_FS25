-- Deliberately small integration surface. Protected native method bodies stay
-- byte-identical to main, including calls, crop readiness and pipe following.
local Q = CpUnloaderQueue
local U = AIDriveStrategyUnloadCombine
local C = AIDriveStrategyCombineCourse

local update = U.update
function U:update(dt)
    Q.tick(self)
    return update(self,dt)
end

local drive = U.getDriveData
function U:getDriveData(...)
    Q.speed(self)
    return drive(self,...)
end

local allowed = U.isAllowedToBeCalled
function U:isAllowedToBeCalled()
    if Q.enabled(self) and Q.atDepartureThreshold(self) then return false end
    if Q.enabled(self) and Q.owns(self) then return self.queueData.operation=='prepare' end
    return allowed(self)
end

local call = U.call
function U:call(combine,waypoint)
    if Q.enabled(self) and Q.atDepartureThreshold(self) then return false end
    if Q.enabled(self) and Q.owns(self) then
        if self.queueData.operation~='prepare' then return false end
        Q.release(self)
    end
    if Q.enabled(self) and self.queueData then self.queueData.departure=nil end
    return call(self,combine,waypoint)
end

-- The configured emptying percentage is a departure threshold, including
-- during transfer. Native fullness handling still releases the harvester and
-- performs its reverse-clearance manoeuvre before our row/headland departure.
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

local release = U.releaseCombine
function U:releaseCombine(...)
    if Q.enabled(self) then Q.capture(self) end
    return release(self,...)
end

local unload = U.startUnloadingTrailers
function U:startUnloadingTrailers(...)
    if Q.enabled(self) then return Q.beginExit(self) end
    return unload(self,...)
end

local full = U.onTrailerFull
function U:onTrailerFull(...)
    if Q.enabled(self) then
        local clear,reason=Q.canFinishExit(self)
        if not clear then
            if not Q.owns(self) or self.queueData.operation~='exit' then Q.beginExit(self) end
            Q.reason(Q.data(self),reason)
            self:setMaxSpeed(0)
            return
        end
    end
    return full(self,...)
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
