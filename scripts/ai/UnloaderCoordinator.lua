--- Coordinates idle combine unloaders across every active field.
---
--- Staging assignments are deliberately separate from the combine's active unloader registration.
--- A combine assignment is soft and may be interrupted by another combine's real unload call. A forage
--- harvester assignment is firm so its relief trailer is not taken while the active trailer is filling.
---@class UnloaderCoordinator
UnloaderCoordinator = {}

UnloaderCoordinator.rebalanceIntervalMs = 3000
UnloaderCoordinator.minimumAssignmentTimeMs = 30000
UnloaderCoordinator.existingAssignmentBiasSeconds = 45
UnloaderCoordinator.newAssignmentBiasSeconds = 120
UnloaderCoordinator.foragerSafetyMarginSeconds = 60
UnloaderCoordinator.fallbackTrailerFillRatePercentPerSecond = 0.2
UnloaderCoordinator.assignments = {}
UnloaderCoordinator.trailerFillSamples = {}
UnloaderCoordinator.nextRebalanceAt = 0

local function getCurrentTime()
    if g_currentMission and g_currentMission.time then
        return g_currentMission.time
    end
    return g_time or 0
end

local function getVehicleName(vehicle)
    if CpUtil and CpUtil.getName then
        return CpUtil.getName(vehicle)
    end
    return tostring(vehicle)
end

function UnloaderCoordinator:debug(format, ...)
    if CpUtil and CpUtil.debugFormat then
        CpUtil.debugFormat(CpDebug.DBG_UNLOAD_COMBINE, 'UnloaderCoordinator: ' .. format, ...)
    end
end

---@param harvester table
---@return AIDriveStrategyCombineCourse|nil
function UnloaderCoordinator:getHarvesterStrategy(harvester)
    if not harvester or not harvester.getIsCpActive or not harvester:getIsCpActive() then
        return nil
    end
    local strategy = harvester.getCpDriveStrategy and harvester:getCpDriveStrategy()
    if strategy and strategy.callUnloader then
        return strategy
    end
    return nil
end

---@param harvester table
---@return number
function UnloaderCoordinator:getRequestedStandbyCount(harvester)
    local settings = harvester and harvester.getCpSettings and harvester:getCpSettings()
    local setting = settings and settings.nearbyStandbyUnloaders
    return setting and setting:getValue() or 0
end

---@param harvester table
---@return number
function UnloaderCoordinator:getStandbyDistance(harvester)
    local settings = harvester and harvester.getCpSettings and harvester:getCpSettings()
    local setting = settings and settings.standbyUnloaderDistance
    return setting and setting:getValue() or 50
end

---@param harvester table
---@param distanceOverride number|nil
---@return Waypoint|nil, number|nil
function UnloaderCoordinator:getStagingWaypoint(harvester, distanceOverride)
    local strategy = self:getHarvesterStrategy(harvester)
    if not strategy or strategy:isTurning() or strategy:isManeuvering() or strategy:isAboutToTurn() then
        return nil
    end

    local course = strategy:getFieldworkCourse()
    local currentIx = strategy:getClosestFieldworkWaypointIx()
    if not course or not currentIx then
        return nil
    end

    local stageIx = course:getPreviousWaypointIxWithinDistance(currentIx,
            distanceOverride or self:getStandbyDistance(harvester))
    if not stageIx then
        return nil
    end

    -- Do not intentionally park in a generated turn or on a reverse waypoint. Work backwards to a normal,
    -- already travelled waypoint. If there is no such point nearby, retain the existing standby position.
    local minimumIx = math.max(1, stageIx - 20)
    while stageIx >= minimumIx and (course:isTurnStartAtIx(stageIx) or course:isTurnEndAtIx(stageIx)
            or course:isReverseAt(stageIx)) do
        stageIx = stageIx - 1
    end
    if stageIx < minimumIx then
        return nil
    end
    return course:getWaypoint(stageIx), stageIx
end

---@param harvester table
---@return AIDriveStrategyUnloadCombine|nil
function UnloaderCoordinator:getActiveUnloader(harvester)
    for strategy, _ in pairs(AIDriveStrategyUnloadCombine.activeUnloaders or {}) do
        if strategy.getCombineToUnload and strategy:getCombineToUnload() == harvester then
            return strategy
        end
    end
    return nil
end

---@param strategy AIDriveStrategyUnloadCombine
---@param now number
---@return number
function UnloaderCoordinator:getSecondsUntilTrailerFull(strategy, now)
    local fill = strategy:getFillLevelPercentage()
    local sample = self.trailerFillSamples[strategy]
    if not sample then
        sample = { fill = fill, time = now, rate = 0 }
        self.trailerFillSamples[strategy] = sample
    elseif now > sample.time then
        local elapsed = (now - sample.time) / 1000
        local instantaneousRate = (fill - sample.fill) / elapsed
        if instantaneousRate > 0.001 then
            sample.rate = sample.rate > 0 and (sample.rate + instantaneousRate) / 2 or instantaneousRate
        end
        sample.fill = fill
        sample.time = now
    end
    local rate = sample.rate > 0 and sample.rate or self.fallbackTrailerFillRatePercentPerSecond
    return math.max(0, (100 - fill) / rate)
end

---@param harvester table
---@param now number
---@return table|nil
function UnloaderCoordinator:createDemand(harvester, now)
    local strategy = self:getHarvesterStrategy(harvester)
    if not strategy or self:getRequestedStandbyCount(harvester) < 1 then
        return nil
    end

    local isForager = strategy:alwaysNeedsUnloader()
    local activeUnloader = self:getActiveUnloader(harvester)
    local secondsUntilNeeded
    if isForager then
        secondsUntilNeeded = activeUnloader and self:getSecondsUntilTrailerFull(activeUnloader, now) or 0
        secondsUntilNeeded = secondsUntilNeeded - self.foragerSafetyMarginSeconds
    elseif strategy.getSecondsUntilUnloaderCall then
        secondsUntilNeeded = strategy:getSecondsUntilUnloaderCall()
        if activeUnloader then
            -- A combine may empty its tank while filling the first trailer. Keep the second trailer's demand
            -- urgent when that active trailer will leave sooner than the combine expects its next normal call.
            secondsUntilNeeded = math.min(secondsUntilNeeded,
                    self:getSecondsUntilTrailerFull(activeUnloader, now))
        end
    else
        local settings = harvester:getCpSettings()
        secondsUntilNeeded = math.max(0,
                (settings.callUnloaderPercent:getValue() - strategy:getFillLevelPercentage()) * 6)
    end

    local waypoint, waypointIx = self:getStagingWaypoint(harvester)
    return {
        harvester = harvester,
        harvesterStrategy = strategy,
        activeUnloader = activeUnloader,
        isFirm = isForager,
        secondsUntilNeeded = secondsUntilNeeded,
        waypoint = waypoint,
        waypointIx = waypointIx,
    }
end

---@param unloader AIDriveStrategyUnloadCombine
---@param demand table
---@return boolean
function UnloaderCoordinator:canServeDemand(unloader, demand)
    if not unloader:isAvailableForStaging() then
        return false
    end
    local x, _, z = getWorldTranslation(demand.harvester.rootNode)
    return unloader:isServingPosition(x, z, 10)
end

---@param unloader AIDriveStrategyUnloadCombine
---@param demand table
---@param now number
---@return number
function UnloaderCoordinator:getAssignmentCost(unloader, demand, now)
    local _, ete
    if demand.waypoint then
        _, ete = unloader:getDistanceAndEteToWaypoint(demand.waypoint)
    else
        _, ete = unloader:getDistanceAndEteToVehicle(demand.harvester)
    end

    local existing = self.assignments[unloader]
    if existing and existing.harvester == demand.harvester then
        ete = ete - self.existingAssignmentBiasSeconds
        if now - existing.assignedAt < self.minimumAssignmentTimeMs then
            ete = ete - self.newAssignmentBiasSeconds
        end
    end
    return ete
end

---@param demandA table
---@param demandB table
---@return boolean
function UnloaderCoordinator.sortDemands(demandA, demandB)
    if demandA.secondsUntilNeeded == demandB.secondsUntilNeeded then
        return tostring(demandA.harvester) < tostring(demandB.harvester)
    end
    return demandA.secondsUntilNeeded < demandB.secondsUntilNeeded
end

---@return table
function UnloaderCoordinator:getAvailableUnloaders()
    local unloaders = {}
    for strategy, _ in pairs(AIDriveStrategyUnloadCombine.activeUnloaders or {}) do
        if strategy:isAvailableForStaging() then
            table.insert(unloaders, strategy)
        end
    end
    return unloaders
end

---@return table
function UnloaderCoordinator:getDemands(now)
    local demands = {}
    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if AIDriveStrategyCombineCourse.isActiveCpCombine(vehicle) then
            local demand = self:createDemand(vehicle, now)
            if demand then
                table.insert(demands, demand)
            end
        end
    end
    table.sort(demands, self.sortDemands)
    return demands
end

---@param force boolean|nil
function UnloaderCoordinator:rebalance(force)
    local now = getCurrentTime()
    if not force and now < self.nextRebalanceAt then
        return
    end
    self.nextRebalanceAt = now + self.rebalanceIntervalMs

    local unloaders = self:getAvailableUnloaders()
    local demands = self:getDemands(now)
    local newAssignments = {}

    -- Greedy earliest-need matching is intentional. Every demand gets at most one standby and every unloader
    -- gets at most one target, preventing a group of independent unloaders clustering at the nearest harvester.
    for _, demand in ipairs(demands) do
        local bestIndex, bestCost
        for i, unloader in ipairs(unloaders) do
            if self:canServeDemand(unloader, demand) then
                local cost = self:getAssignmentCost(unloader, demand, now)
                if not bestCost or cost < bestCost then
                    bestIndex, bestCost = i, cost
                end
            end
        end
        if bestIndex then
            local unloader = table.remove(unloaders, bestIndex)
            local oldAssignment = self.assignments[unloader]
            newAssignments[unloader] = {
                harvester = demand.harvester,
                isFirm = demand.isFirm,
                role = 'STANDBY',
                waypoint = demand.waypoint,
                waypointIx = demand.waypointIx,
                assignedAt = oldAssignment and oldAssignment.harvester == demand.harvester
                        and oldAssignment.assignedAt or now,
                secondsUntilNeeded = demand.secondsUntilNeeded,
            }
        end
    end

    -- Keep surplus unloaders useful without forming a queue at one harvester. Pool positions are progressively
    -- further back on already worked courses, and the balancing penalty spreads the first spare across each active
    -- harvester before adding another position to the same route.
    local poolCounts = {}
    for _, unloader in ipairs(unloaders) do
        local bestDemand, bestWaypoint, bestWaypointIx, bestCost
        for _, demand in ipairs(demands) do
            if self:canServeDemand(unloader, demand) then
                local poolNumber = (poolCounts[demand.harvester] or 0) + 1
                local poolDistance = self:getStandbyDistance(demand.harvester) + 40 * poolNumber
                local waypoint, waypointIx = self:getStagingWaypoint(demand.harvester, poolDistance)
                if waypoint then
                    local poolDemand = {
                        harvester = demand.harvester,
                        waypoint = waypoint,
                    }
                    local cost = self:getAssignmentCost(unloader, poolDemand, now) +
                            (poolCounts[demand.harvester] or 0) * 120
                    if not bestCost or cost < bestCost then
                        bestDemand, bestWaypoint, bestWaypointIx, bestCost = demand, waypoint, waypointIx, cost
                    end
                end
            end
        end
        if bestDemand then
            poolCounts[bestDemand.harvester] = (poolCounts[bestDemand.harvester] or 0) + 1
            local oldAssignment = self.assignments[unloader]
            newAssignments[unloader] = {
                harvester = bestDemand.harvester,
                isFirm = false,
                role = 'POOL',
                waypoint = bestWaypoint,
                waypointIx = bestWaypointIx,
                assignedAt = oldAssignment and oldAssignment.harvester == bestDemand.harvester
                        and oldAssignment.assignedAt or now,
                secondsUntilNeeded = math.huge,
            }
        end
    end

    for unloader, oldAssignment in pairs(self.assignments) do
        if not newAssignments[unloader] and unloader.clearStandbyAssignment then
            self:debug('Releasing %s from standby for %s', getVehicleName(unloader.vehicle),
                    getVehicleName(oldAssignment.harvester))
            unloader:clearStandbyAssignment(oldAssignment)
        end
    end
    self.assignments = newAssignments

    for unloader, assignment in pairs(newAssignments) do
        if unloader.setStandbyAssignment then
            unloader:setStandbyAssignment(assignment)
        end
    end
end

---@param unloader AIDriveStrategyUnloadCombine
function UnloaderCoordinator:update(unloader)
    if unloader and unloader:isAvailableForStaging() then
        self:rebalance(false)
    end
end

---@param unloader AIDriveStrategyUnloadCombine
function UnloaderCoordinator:release(unloader)
    local assignment = self.assignments[unloader]
    self.assignments[unloader] = nil
    if assignment and unloader.clearStandbyAssignment then
        unloader:clearStandbyAssignment(assignment)
    end
    self.nextRebalanceAt = 0
end

---@param unloader AIDriveStrategyUnloadCombine
function UnloaderCoordinator:unregister(unloader)
    self.assignments[unloader] = nil
    self.trailerFillSamples[unloader] = nil
    self.nextRebalanceAt = 0
end

---@param unloader AIDriveStrategyUnloadCombine
---@param callingHarvester table|nil
---@return boolean
function UnloaderCoordinator:canBeCalledBy(unloader, callingHarvester)
    local assignment = self.assignments[unloader]
    return not assignment or not assignment.isFirm or assignment.harvester == callingHarvester
end
