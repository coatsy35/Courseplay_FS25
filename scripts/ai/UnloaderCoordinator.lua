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
UnloaderCoordinator.combineSafetyMarginSeconds = 25
UnloaderCoordinator.foragerSafetyMarginSeconds = 60
UnloaderCoordinator.fallbackTrailerFillRatePercentPerSecond = 0.2
UnloaderCoordinator.minimumPoolDistance = 100
UnloaderCoordinator.poolDistanceStep = 45
UnloaderCoordinator.maximumAdditionalPoolDistance = 150
UnloaderCoordinator.stagingRetargetDistance = 25
UnloaderCoordinator.poolAdvanceDistance = 40
UnloaderCoordinator.poolAdvancePredictionSeconds = 45
UnloaderCoordinator.leadContinuityEteTolerance = 10
UnloaderCoordinator.assignments = {}
UnloaderCoordinator.trailerFillSamples = {}
UnloaderCoordinator.clearingUnloaders = {}
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
---@param referenceIx number|nil
---@return Waypoint|nil, number|nil
function UnloaderCoordinator:getStagingWaypoint(harvester, distanceOverride, referenceIx)
    local strategy = self:getHarvesterStrategy(harvester)
    if not strategy or strategy:isTurning() or strategy:isManeuvering() or strategy:isAboutToTurn() then
        return nil
    end

    local course = strategy:getFieldworkCourse()
    local currentIx = referenceIx or strategy:getClosestFieldworkWaypointIx()
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
        if fill < sample.fill then sample.rate = 0 end
        if instantaneousRate > 0.001 then
            sample.rate = sample.rate > 0 and (sample.rate + instantaneousRate) / 2 or instantaneousRate
        end
        sample.fill = fill
        sample.time = now
    end
    local rate = sample.rate > 0 and sample.rate or self.fallbackTrailerFillRatePercentPerSecond
    return math.max(0, (100 - fill) / rate)
end

--- Calculate a close-standby target on the harvested course behind the harvester. A predicted future call position
--- can still contain crop, so parking there would either be rejected or make the trailer cut through fruit.
---@param harvester table
---@param strategy AIDriveStrategyCombineCourse
---@param secondsUntilNeeded number
---@return Waypoint|nil, number|nil
function UnloaderCoordinator:getPredictedStagingWaypoint(harvester, strategy, secondsUntilNeeded)
    local currentIx = strategy:getClosestFieldworkWaypointIx()
    local course = strategy:getFieldworkCourse()
    -- getSpeedLimit also returns a boolean; keep only its numeric first result.
    local speedLimit = harvester.getSpeedLimit and harvester:getSpeedLimit(true) or 0
    local speed = math.min(30, speedLimit) / 3.6
    if course and course.getNextWaypointIxWithinDistance and secondsUntilNeeded > 0 and speed > 0 then
        local predictedIx = course:getNextWaypointIxWithinDistance(currentIx, math.min(secondsUntilNeeded, 120) * speed)
        if predictedIx then
            -- Never stage through an intervening turn. A future point is usable only if already harvested (for
            -- example, on an earlier headland); otherwise retain a safe target and refresh it as the crop is cut.
            for ix = currentIx, predictedIx do
                if course:isTurnStartAtIx(ix) or course:isReverseAt(ix) then predictedIx = ix - 1; break end
            end
            local waypoint, ix = self:getStagingWaypoint(harvester, nil, predictedIx)
            if waypoint and PathfinderUtil and not PathfinderUtil.hasFruit(waypoint.x, waypoint.z, 4, 4) then
                return waypoint, ix
            end
        end
    end
    return self:getStagingWaypoint(harvester, nil, currentIx)
end

---@param harvester table
---@return number
function UnloaderCoordinator:getSecondsUntilDowntime(harvester)
    local strategy = self:getHarvesterStrategy(harvester)
    if not strategy or strategy:alwaysNeedsUnloader() then
        return 0
    end
    if strategy.getSecondsUntilFull then
        return strategy:getSecondsUntilFull()
    end
    return math.max(0, (100 - strategy:getFillLevelPercentage()) * 6)
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
    elseif activeUnloader then
        -- The called trailer is already the combine's lead. Keep the next trailer in the rear pool until the lead's
        -- measured fill rate shows that it will need relief; the combine's own call percentage is already covered.
        secondsUntilNeeded = self:getSecondsUntilTrailerFull(activeUnloader, now)
        if activeUnloader.getFreeCapacityForHarvester and strategy.combineController then
            local free = activeUnloader:getFreeCapacityForHarvester(harvester)
            if free < strategy.combineController:getFillLevel() then
                -- Capacity is already committed to the crop in this tank. Prepare relief before discharge starts.
                secondsUntilNeeded = 0
            end
        end
    elseif strategy.getSecondsUntilUnloaderCall then
        secondsUntilNeeded = strategy:getSecondsUntilUnloaderCall()
    else
        local settings = harvester:getCpSettings()
        secondsUntilNeeded = math.max(0,
                (settings.callUnloaderPercent:getValue() - strategy:getFillLevelPercentage()) * 6)
    end

    local waypoint, waypointIx = self:getPredictedStagingWaypoint(harvester, strategy, secondsUntilNeeded)
    return {
        harvester = harvester,
        harvesterStrategy = strategy,
        activeUnloader = activeUnloader,
        isFirm = isForager,
        secondsUntilNeeded = secondsUntilNeeded,
        secondsUntilDowntime = self:getSecondsUntilDowntime(harvester),
        fillLevelPercentage = strategy:getFillLevelPercentage(),
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
    local reservation = self.assignments[unloader]
    if reservation and reservation.isFirm and reservation.harvester ~= demand.harvester and
            self:getHarvesterStrategy(reservation.harvester) and
            self:getRequestedStandbyCount(reservation.harvester) > 0 then
        return false
    end
    if unloader.canRetryCombineApproach and not unloader:canRetryCombineApproach(demand.harvester) then return false end
    if unloader.getFreeCapacityForHarvester and unloader:getFreeCapacityForHarvester(demand.harvester) <= 0 then return false end
    local x, _, z = getWorldTranslation(demand.harvester.rootNode)
    return unloader:isServingPosition(x, z, 10)
end

--- Arrival time with a bounded preference for completing a nearby partial load.
---@param fillLevelPercentage number
---@param distance number
---@return number
function UnloaderCoordinator:getCallScore(fillLevelPercentage, distance, ete)
    return math.min(10, math.max(0, fillLevelPercentage) / 10) - (ete or distance / 5)
end

---@param unloader AIDriveStrategyUnloadCombine
---@param demand table
---@param now number
---@return number
function UnloaderCoordinator:getAssignmentCost(unloader, demand, now)
    local distance
    if demand.waypoint then
        distance = unloader:getDistanceAndEteToWaypoint(demand.waypoint)
    else
        distance = unloader:getDistanceAndEteToVehicle(demand.harvester)
    end

    local cost = -self:getCallScore(unloader:getFillLevelPercentage(), distance)

    if unloader.shouldWaitAtPoolForHarvester and unloader:shouldWaitAtPoolForHarvester(demand.harvester) then
        cost = cost + 50000
    end

    local existing = self.assignments[unloader]
    if existing and existing.harvester == demand.harvester then
        cost = cost - 0.1 * self.existingAssignmentBiasSeconds
        if now - existing.assignedAt < self.minimumAssignmentTimeMs then
            cost = cost - 0.1 * self.newAssignmentBiasSeconds
        end
    end
    return cost
end

---@param unloader AIDriveStrategyUnloadCombine
---@return Waypoint
function UnloaderCoordinator:getWaypointAtUnloader(unloader)
    local x, y, z = getWorldTranslation(unloader.vehicle.rootNode)
    local yRot = 0
    if getWorldRotation then
        _, yRot, _ = getWorldRotation(unloader.vehicle.rootNode)
    end
    return {
        x = x,
        y = y,
        z = z,
        yRot = yRot,
        angle = math.deg(yRot),
        getIsReverse = function() return false end,
    }
end

---@param unloader AIDriveStrategyUnloadCombine
---@param demand table
---@return number
function UnloaderCoordinator:getEteToDemand(unloader, demand)
    local _, ete
    if demand.waypoint then
        _, ete = unloader:getDistanceAndEteToWaypoint(demand.waypoint)
    else
        _, ete = unloader:getDistanceAndEteToVehicle(demand.harvester)
    end
    if unloader.shouldWaitAtPoolForHarvester and unloader:shouldWaitAtPoolForHarvester(demand.harvester) then
        return ete + 50000
    end
    return ete
end

---@param unloader AIDriveStrategyUnloadCombine
---@param harvester table
---@return boolean
function UnloaderCoordinator:isReservedFor(unloader, harvester)
    local assignment = self.assignments[unloader]
    return assignment and assignment.reserved and assignment.harvester == harvester or false
end

---@param harvester table
---@param role string
---@param waypoint Waypoint|nil
---@param waypointIx number|nil
---@param oldAssignment table|nil
---@param unloader AIDriveStrategyUnloadCombine|nil
---@param demand table|nil
---@return Waypoint|nil, number|nil
function UnloaderCoordinator:getStableStagingWaypoint(harvester, role, waypoint, waypointIx, oldAssignment,
        unloader, demand)
    if not waypoint or not oldAssignment or oldAssignment.harvester ~= harvester or
            oldAssignment.role ~= role or not oldAssignment.waypoint or not oldAssignment.waypointIx then
        return waypoint, waypointIx
    end
    if role == 'STANDBY' and unloader and unloader.hasReachedStandbyPosition and
            unloader:hasReachedStandbyPosition() then
        local distance = unloader:getDistanceAndEteToVehicle(harvester)
        local workWidth = demand and demand.harvesterStrategy.getWorkWidth and
                demand.harvesterStrategy:getWorkWidth() or 0
        local callPercentage = harvester:getCpSettings().callUnloaderPercent:getValue()
        local atCallPercentage = demand and not demand.isFirm and
                demand.fillLevelPercentage >= callPercentage
        local movementBand = atCallPercentage and math.max(15, workWidth) or math.max(50, 2 * workWidth)
        if distance > self:getStandbyDistance(harvester) + movementBand then
            -- Advance in deliberate hops. Before the call percentage the band is broad; at the call percentage it
            -- tightens so the lead is genuinely nearby when the combine makes its pocket or requests unloading.
            return waypoint, waypointIx
        end
    elseif role == 'STANDBY' and demand and oldAssignment.secondsUntilNeeded and
            demand.secondsUntilNeeded <= self:getEteToDemand(unloader, demand) + self.combineSafetyMarginSeconds then
        local movement = MathUtil.vector2Length(waypoint.x - oldAssignment.waypoint.x,
                waypoint.z - oldAssignment.waypoint.z)
        if movement >= math.max(50, self:getStandbyDistance(harvester)) then return waypoint, waypointIx end
    elseif role == 'POOL' and unloader and unloader.hasReachedStandbyPosition and
            unloader:hasReachedStandbyPosition() and demand then
        local stagedAt = oldAssignment.stagedAtSecondsUntilNeeded
        local predictionAdvanced = stagedAt and demand.secondsUntilNeeded <=
                stagedAt - self.poolAdvancePredictionSeconds
        local targetMoved = MathUtil.vector2Length(waypoint.x - oldAssignment.waypoint.x,
                waypoint.z - oldAssignment.waypoint.z) >= self.poolAdvanceDistance
        local harvesterX, _, harvesterZ = getWorldTranslation(harvester.rootNode)
        local oldDistance = MathUtil.vector2Length(oldAssignment.waypoint.x - harvesterX,
                oldAssignment.waypoint.z - harvesterZ)
        local newDistance = MathUtil.vector2Length(waypoint.x - harvesterX, waypoint.z - harvesterZ)
        if predictionAdvanced and targetMoved and newDistance + self.stagingRetargetDistance < oldDistance then
            -- Rear trailers move in separate, prediction-driven steps. They park after each step and never close
            -- past their numbered pool layer until promoted to the lead standby role.
            return waypoint, waypointIx
        end
    end
    -- Pool targets remain fixed. An en-route standby also finishes its current move before another target is issued.
    return oldAssignment.waypoint, oldAssignment.waypointIx
end

---@param demand table
---@param poolNumber number
---@return number
function UnloaderCoordinator:getPoolDistance(demand, poolNumber)
    local workWidth = demand.harvesterStrategy.getWorkWidth and demand.harvesterStrategy:getWorkWidth() or 0
    local timeUntilNeeded = math.max(0, demand.secondsUntilNeeded or 0)
    local additionalDistance = math.min(self.maximumAdditionalPoolDistance, timeUntilNeeded * 0.35)
    return math.max(self.minimumPoolDistance, 2 * workWidth + 30) + additionalDistance +
            math.max(0, poolNumber - 1) * self.poolDistanceStep
end

---@param unloader AIDriveStrategyUnloadCombine
---@param demand table
---@param oldAssignment table|nil
---@return boolean
function UnloaderCoordinator:shouldDeploy(unloader, demand, oldAssignment)
    if unloader.shouldWaitAtPoolForHarvester and unloader:shouldWaitAtPoolForHarvester(demand.harvester) then
        return false
    end
    local _, ete
    if demand.waypoint then
        _, ete = unloader:getDistanceAndEteToWaypoint(demand.waypoint)
    else
        _, ete = unloader:getDistanceAndEteToVehicle(demand.harvester)
    end
    local safetyMargin = demand.isFirm and self.foragerSafetyMarginSeconds or self.combineSafetyMarginSeconds
    if oldAssignment and oldAssignment.harvester == demand.harvester and oldAssignment.role == 'STANDBY' then
        safetyMargin = safetyMargin + self.existingAssignmentBiasSeconds
    end
    return demand.secondsUntilNeeded <= ete + safetyMargin
end

---@param unloader AIDriveStrategyUnloadCombine
---@param demand table
---@param poolNumber number
---@param oldAssignment table|nil
---@return Waypoint|nil, number|nil, boolean
function UnloaderCoordinator:getPoolWaypoint(unloader, demand, poolNumber, oldAssignment)
    local poolDistance = self:getPoolDistance(demand, poolNumber)
    local distance = unloader:getDistanceAndEteToVehicle(demand.harvester)
    local waitUntilHarvesterPasses = unloader.shouldWaitAtPoolForHarvester and
            unloader:shouldWaitAtPoolForHarvester(demand.harvester) or false

    if oldAssignment and oldAssignment.harvester == demand.harvester and oldAssignment.role == 'POOL' and
            oldAssignment.waypoint and oldAssignment.waitUntilHarvesterPasses and waitUntilHarvesterPasses then
        return oldAssignment.waypoint, oldAssignment.waypointIx, true
    end

    -- A fruit-protected vehicle ahead of the harvester remains at its access point until the harvester passes.
    if waitUntilHarvesterPasses then
        return self:getWaypointAtUnloader(unloader), nil, waitUntilHarvesterPasses
    end

    local waypoint, waypointIx = self:getStagingWaypoint(demand.harvester, poolDistance)
    if not waypoint then
        return oldAssignment and oldAssignment.waypoint or self:getWaypointAtUnloader(unloader),
                oldAssignment and oldAssignment.waypointIx or nil, false
    end

    -- Hold within a distance band, but move progressively nearer when urgency contracts the pool distance. The
    -- common target hysteresis prevents a moving harvester from causing a new path request every rebalance.
    if distance >= poolDistance and distance <= poolDistance + self.stagingRetargetDistance and
            oldAssignment and oldAssignment.harvester == demand.harvester and
            oldAssignment.role == 'POOL' and oldAssignment.waypointIx then
        return oldAssignment.waypoint, oldAssignment.waypointIx, false
    end
    waypoint, waypointIx = self:getStableStagingWaypoint(demand.harvester, 'POOL', waypoint, waypointIx,
            oldAssignment, unloader, demand)
    return waypoint, waypointIx, false
end

---@param demandA table
---@param demandB table
---@return boolean
function UnloaderCoordinator.sortDemands(demandA, demandB)
    if demandA.secondsUntilDowntime ~= demandB.secondsUntilDowntime then
        return demandA.secondsUntilDowntime < demandB.secondsUntilDowntime
    end
    if demandA.fillLevelPercentage ~= demandB.fillLevelPercentage then
        return demandA.fillLevelPercentage > demandB.fillLevelPercentage
    end
    if demandA.secondsUntilNeeded ~= demandB.secondsUntilNeeded then
        return demandA.secondsUntilNeeded < demandB.secondsUntilNeeded
    end
    return tostring(demandA.harvester) < tostring(demandB.harvester)
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
    local previousAssignments = self.assignments

    -- Greedy earliest-need matching is intentional. Every demand gets exactly one reservation at most and every
    -- unloader gets at most one target. A combine reservation stays in the field pool until its predicted travel
    -- time says it must start moving; forage relief uses the same calculation with a larger safety margin.
    for _, demand in ipairs(demands) do
        local bestIndex
        -- Keep the established lead trailer. Re-running the global match every few seconds made trailers exchange
        -- combines and cross through the pool even though both assignments were still serviceable.
        for i, unloader in ipairs(unloaders) do
            local oldAssignment = previousAssignments[unloader]
            if oldAssignment and oldAssignment.reserved and oldAssignment.harvester == demand.harvester and
                    self:canServeDemand(unloader, demand) then
                bestIndex = i
                break
            end
        end
        if not bestIndex then
            local fastestEte = math.huge
            for _, unloader in ipairs(unloaders) do
                if self:canServeDemand(unloader, demand) then
                    fastestEte = math.min(fastestEte, self:getEteToDemand(unloader, demand))
                end
            end
            local bestScore = -math.huge
            for i, unloader in ipairs(unloaders) do
                if self:canServeDemand(unloader, demand) then
                    local ete = self:getEteToDemand(unloader, demand)
                    if ete <= fastestEte + self.leadContinuityEteTolerance then
                        local distance = demand.waypoint and unloader:getDistanceAndEteToWaypoint(demand.waypoint)
                                or unloader:getDistanceAndEteToVehicle(demand.harvester)
                        local score = self:getCallScore(unloader:getFillLevelPercentage(), distance, ete)
                        if score > bestScore then
                            bestIndex, bestScore = i, score
                        end
                    end
                end
            end
        end
        if bestIndex then
            local unloader = table.remove(unloaders, bestIndex)
            local oldAssignment = self.assignments[unloader]
            local deploy = oldAssignment and oldAssignment.harvester == demand.harvester and
                    oldAssignment.role == 'STANDBY' or self:shouldDeploy(unloader, demand, oldAssignment)
            local waypoint, waypointIx, waitUntilHarvesterPasses
            if deploy then
                waypoint, waypointIx = demand.waypoint, demand.waypointIx
                waypoint, waypointIx = self:getStableStagingWaypoint(demand.harvester, 'STANDBY', waypoint,
                        waypointIx, oldAssignment, unloader, demand)
            else
                waypoint, waypointIx, waitUntilHarvesterPasses =
                        self:getPoolWaypoint(unloader, demand, 1, oldAssignment)
            end
            newAssignments[unloader] = {
                harvester = demand.harvester,
                isFirm = demand.isFirm,
                reserved = true,
                role = deploy and 'STANDBY' or 'POOL',
                waypoint = waypoint,
                waypointIx = waypointIx,
                assignedAt = oldAssignment and oldAssignment.harvester == demand.harvester
                        and oldAssignment.assignedAt or now,
                secondsUntilNeeded = demand.secondsUntilNeeded,
                secondsUntilDowntime = demand.secondsUntilDowntime,
                waitUntilHarvesterPasses = waitUntilHarvesterPasses,
                targetMovementThreshold = self.stagingRetargetDistance,
                stagedAtSecondsUntilNeeded = oldAssignment and waypoint == oldAssignment.waypoint and
                        oldAssignment.stagedAtSecondsUntilNeeded or demand.secondsUntilNeeded,
            }
        end
    end

    -- Surplus unloaders remain well clear of the working pair. Pool positions start at a geometry- and urgency-based
    -- distance of at least roughly 100 metres and only advance in coarse prediction-driven steps.
    local poolCounts = {}
    for _, unloader in ipairs(unloaders) do
        local bestDemand, bestWaypoint, bestWaypointIx, bestCost
        local bestWaitUntilHarvesterPasses = false
        local oldAssignment = previousAssignments[unloader]
        if oldAssignment and oldAssignment.role == 'POOL' and not oldAssignment.reserved then
            for _, demand in ipairs(demands) do
                if demand.harvester == oldAssignment.harvester and self:canServeDemand(unloader, demand) then
                    local poolNumber = (poolCounts[demand.harvester] or 0) + 1
                    bestWaypoint, bestWaypointIx, bestWaitUntilHarvesterPasses =
                            self:getPoolWaypoint(unloader, demand, poolNumber + 1, oldAssignment)
                    bestDemand = demand
                    break
                end
            end
        end
        if not bestDemand then
            for _, demand in ipairs(demands) do
                if self:canServeDemand(unloader, demand) then
                    local poolNumber = (poolCounts[demand.harvester] or 0) + 1
                    local waypoint, waypointIx, waitUntilHarvesterPasses =
                            self:getPoolWaypoint(unloader, demand, poolNumber + 1, oldAssignment)
                    if waypoint then
                        local poolDemand = {
                            harvester = demand.harvester,
                            waypoint = waypoint,
                        }
                        local cost = self:getAssignmentCost(unloader, poolDemand, now) +
                                (poolCounts[demand.harvester] or 0) * 120
                        if not bestCost or cost < bestCost then
                            bestDemand, bestWaypoint, bestWaypointIx, bestCost = demand, waypoint, waypointIx, cost
                            bestWaitUntilHarvesterPasses = waitUntilHarvesterPasses
                        end
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
                reserved = false,
                role = 'POOL',
                waypoint = bestWaypoint,
                waypointIx = bestWaypointIx,
                assignedAt = oldAssignment and oldAssignment.harvester == bestDemand.harvester
                        and oldAssignment.assignedAt or now,
                secondsUntilNeeded = math.huge,
                waitUntilHarvesterPasses = bestWaitUntilHarvesterPasses,
                targetMovementThreshold = self.stagingRetargetDistance,
                stagedAtSecondsUntilNeeded = oldAssignment and bestWaypoint == oldAssignment.waypoint and
                        oldAssignment.stagedAtSecondsUntilNeeded or bestDemand.secondsUntilNeeded,
            }
        end
    end

    for unloader, oldAssignment in pairs(previousAssignments) do
        if not newAssignments[unloader] and unloader.clearStandbyAssignment then
            self:debug('Releasing %s from standby for %s', getVehicleName(unloader.vehicle),
                    getVehicleName(oldAssignment.harvester))
            unloader:clearStandbyAssignment(oldAssignment)
        end
    end
    self.assignments = newAssignments

    for unloader, assignment in pairs(newAssignments) do
        if unloader.setStandbyAssignment then
            local oldAssignment = previousAssignments[unloader]
            if not oldAssignment or oldAssignment.harvester ~= assignment.harvester or
                    oldAssignment.role ~= assignment.role then
                self:debug('Assigning %s as %s for %s (needed in %.1fs)', getVehicleName(unloader.vehicle),
                        assignment.role, getVehicleName(assignment.harvester), assignment.secondsUntilNeeded)
            end
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
    if assignment and assignment.isFirm and assignment.harvester ~= callingHarvester and
            self:getHarvesterStrategy(assignment.harvester) and self:getRequestedStandbyCount(assignment.harvester) > 0 then
        return false
    end
    if assignment and assignment.waitUntilHarvesterPasses then
        return false
    end
    if assignment and assignment.reserved and assignment.harvester ~= callingHarvester and callingHarvester then
        local assignedSeconds = self:getSecondsUntilDowntime(assignment.harvester)
        local callingSeconds = self:getSecondsUntilDowntime(callingHarvester)
        if assignedSeconds + self.combineSafetyMarginSeconds < callingSeconds then
            self:debug('Keeping %s reserved for %s: downtime in %.1fs versus %.1fs for %s',
                    getVehicleName(unloader.vehicle), getVehicleName(assignment.harvester), assignedSeconds,
                    callingSeconds, getVehicleName(callingHarvester))
            return false
        end
    end
    return true
end

--- Clearance ownership survives assignment release and AD takeover until the rig is physically clear.
---@param unloader AIDriveStrategyUnloadCombine|nil
---@param harvester table
---@return boolean
function UnloaderCoordinator:isStillClearingHarvester(unloader, harvester)
    for vehicle, record in pairs(self.clearingUnloaders) do
        if not entityExists(vehicle.rootNode) or not entityExists(record.harvester.rootNode) then
            self.clearingUnloaders[vehicle] = nil
        elseif record.harvester == harvester then
            local x, _, z = getWorldTranslation(vehicle.rootNode)
            local hx, _, hz = getWorldTranslation(harvester.rootNode)
            if MathUtil.vector2Length(x - hx, z - hz) < record.distance then return true end
            self.clearingUnloaders[vehicle] = nil
        end
    end
    return unloader and unloader.getCombineToUnload and unloader:getCombineToUnload() == harvester or false
end

function UnloaderCoordinator:registerClearingUnloader(unloader, harvester, distance)
    if not harvester then return end
    self.clearingUnloaders[unloader.vehicle] = {harvester = harvester, distance = distance}
end
