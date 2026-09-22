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

--- Compare actual outstanding calls before letting update order decide which combine gets a free trailer.
function UnloaderCoordinator:hasHigherCallPriority(harvester, current)
    local strategy, currentStrategy = self:getHarvesterStrategy(harvester), self:getHarvesterStrategy(current)
    if not strategy or not currentStrategy then return false end
    local waiting = strategy.isWaitingForUnload and strategy:isWaitingForUnload() or false
    local currentWaiting = currentStrategy.isWaitingForUnload and currentStrategy:isWaitingForUnload() or false
    local settings = harvester:getCpSettings()
    if not waiting and (not strategy.getFillLevelPercentage or not settings.callUnloaderPercent or
            strategy:getFillLevelPercentage() < settings.callUnloaderPercent:getValue()) then return false end
    local currentSettings = current:getCpSettings()
    if not currentWaiting and currentStrategy.getFillLevelPercentage and currentSettings.callUnloaderPercent and
            currentStrategy:getFillLevelPercentage() < currentSettings.callUnloaderPercent:getValue() then return true end
    -- A known convoy leader requesting unload has priority over its follower, including during a pocket.
    local proximity = currentStrategy.fieldWorkerProximityController
    local otherProximity = strategy.fieldWorkerProximityController
    local sameCourse = proximity and proximity.fieldWorkCourse and proximity:hasSameCourse(harvester) or
            otherProximity and otherProximity.fieldWorkCourse and otherProximity:hasSameCourse(current)
    if sameCourse then
        local ahead = proximity and proximity.otherVehicleAheadOnTrail and proximity.otherVehicleAheadOnTrail[harvester]
        local behind = otherProximity and otherProximity.otherVehicleAheadOnTrail and otherProximity.otherVehicleAheadOnTrail[current]
        -- Consult both ends so only one recorded trail is sufficient. Contradictory stale records fall through
        -- to the common urgency ordering, rather than making each combine wait for the other.
        if ahead ~= nil and behind == nil then return ahead end
        if behind ~= nil and ahead == nil then return not behind end
        if ahead ~= nil and ahead ~= behind then return ahead end
        if strategy.getFieldWorkProximity and currentStrategy.getFieldWorkProximity then
            local aheadDistance = strategy:getFieldWorkProximity(current:getAIDirectionNode())
            local behindDistance = currentStrategy:getFieldWorkProximity(harvester:getAIDirectionNode())
            if aheadDistance < math.huge and behindDistance == math.huge then return true end
            if behindDistance < math.huge and aheadDistance == math.huge then return false end
        end
    end
    if waiting ~= currentWaiting then return waiting end
    local seconds, currentSeconds = self:getSecondsUntilDowntime(harvester), self:getSecondsUntilDowntime(current)
    if seconds ~= currentSeconds then return seconds < currentSeconds end
    return tostring(harvester.rootNode) < tostring(current.rootNode)
end

function UnloaderCoordinator:shouldServeHarvesterFirst(unloader, harvester)
    if self:getSharedUnloader(harvester) then return false end
    for _, other in pairs(g_currentMission.vehicleSystem.vehicles) do
        if other ~= harvester and self:getHarvesterStrategy(other) and not self:getActiveUnloader(other) and
                self:hasHigherCallPriority(other, harvester) then
            local x, _, z = getWorldTranslation(other.rootNode)
            if unloader:isServingPosition(x, z, 10) and unloader:isAllowedToBeCalled(other) then
                -- Preserve locality: a waiting combine across the field must not monopolise this trailer.
                local _, otherEte = unloader:getDistanceAndEteToVehicle(other)
                local _, currentEte = unloader:getDistanceAndEteToVehicle(harvester)
                if otherEte <= currentEte + self.combineSafetyMarginSeconds then return false end
            end
        end
    end
    return true
end

--- Nearby combines share the active rig while it can still take crop after its current tank.
--- Do not use an unloading trailer's transfer rate as the field's crop production rate.
function UnloaderCoordinator:getSharedUnloader(harvester)
    local strategy = self:getHarvesterStrategy(harvester)
    if not strategy or not strategy.alwaysNeedsUnloader or strategy:alwaysNeedsUnloader() then return nil end
    if self:getActiveUnloader(harvester) then return nil end
    local hx, _, hz = getWorldTranslation(harvester.rootNode)
    for unloader in pairs(AIDriveStrategyUnloadCombine.activeUnloaders or {}) do
        local other = unloader:getCombineToUnload()
        local clearing = not other and unloader.states and unloader.state == unloader.states.MOVING_BACK and
                self.clearingUnloaders[unloader.vehicle]
        other = other or clearing and clearing.harvester
        local otherStrategy = other and (other ~= harvester or clearing) and self:getHarvesterStrategy(other)
        if otherStrategy and not otherStrategy:alwaysNeedsUnloader() and
                unloader.getFreeCapacityForHarvester and otherStrategy.combineController then
            local x, _, z = getWorldTranslation(other.rootNode)
            local width = math.max(strategy:getWorkWidth(), otherStrategy:getWorkWidth())
            local distance = MathUtil.vector2Length(x - hx, z - hz)
            local free = unloader:getFreeCapacityForHarvester(harvester)
            local tank = clearing and 0 or otherStrategy.combineController:getFillLevel()
            local harvestAllowance = math.max(0, otherStrategy.litersPerSecond or 0) * self.combineSafetyMarginSeconds
            local departing = unloader.getAllTrailersFull and unloader.settings and
                    unloader:getAllTrailersFull(unloader.settings.fullThreshold:getValue())
            if distance <= math.max(self.minimumPoolDistance, width * 4) and
                    not departing and free > tank + harvestAllowance and
                    (not unloader.isInDeadlock or not unloader:isInDeadlock()) and
                    (not unloader.canRetryCombineApproach or unloader:canRetryCombineApproach(harvester)) then
                return unloader
            end
        end
    end
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
    -- A temporary pocket course has no last-passed waypoint until its first reverse segment completes.
    if not course or not currentIx then return nil end
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

--- Once a lead is assigned, further demand is for relief, not another lead for the same tank.
function UnloaderCoordinator:getSecondsUntilRelief(harvester, strategy, activeUnloader, now)
    local seconds = self:getSecondsUntilTrailerFull(activeUnloader, now)
    if not strategy:alwaysNeedsUnloader() and activeUnloader.getFreeCapacityForHarvester and strategy.combineController then
        local remaining = activeUnloader:getFreeCapacityForHarvester(harvester) - strategy.combineController:getFillLevel()
        if remaining <= 0 then return 0 end
        if strategy.litersPerSecond and strategy.litersPerSecond > 0.1 then
            -- Include the crop still being harvested while the lead travels and unloads.
            seconds = remaining / strategy.litersPerSecond
        else
            seconds = math.huge
        end
    end
    return seconds
end

function UnloaderCoordinator:getSecondsUntilUncovered(harvester)
    local strategy = self:getHarvesterStrategy(harvester)
    local active = strategy and self:getActiveUnloader(harvester)
    if active then return self:getSecondsUntilRelief(harvester, strategy, active, getCurrentTime()) end
    return self:getSecondsUntilDowntime(harvester)
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
    local sharedUnloader = self:getSharedUnloader(harvester)
    local activeUnloader = self:getActiveUnloader(harvester)
    local secondsUntilNeeded
    if sharedUnloader then
        secondsUntilNeeded = math.huge
    elseif activeUnloader then
        secondsUntilNeeded = self:getSecondsUntilRelief(harvester, strategy, activeUnloader, now)
    elseif isForager then
        secondsUntilNeeded = 0
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
        sharedUnloader = sharedUnloader,
        activeUnloader = activeUnloader,
        isFirm = isForager,
        secondsUntilNeeded = secondsUntilNeeded,
        secondsUntilDowntime = activeUnloader and secondsUntilNeeded or self:getSecondsUntilDowntime(harvester),
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
    return (fillLevelPercentage > 0 and self.combineSafetyMarginSeconds or 0) - (ete or distance / 5)
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
        local atCallPercentage = demand and not demand.isFirm and not demand.activeUnloader and
                (demand.fillLevelPercentage or 0) >= callPercentage
        if demand and not atCallPercentage and not self:shouldDeploy(unloader, demand, oldAssignment) then
            return oldAssignment.waypoint, oldAssignment.waypointIx
        end
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
    local distance, ete
    if demand.waypoint then
        distance, ete = unloader:getDistanceAndEteToWaypoint(demand.waypoint)
    else
        distance, ete = unloader:getDistanceAndEteToVehicle(demand.harvester)
    end
    -- The harvested staging point trails a moving combine. Allow time to close that moving gap, rather than
    -- planning as if the combine will stay where it is throughout the journey.
    if not demand.activeUnloader and demand.harvester.getSpeedLimit and distance > 0 then
        local speedLimit = demand.harvester:getSpeedLimit(true)
        local settings = demand.harvesterStrategy.settings
        local workSpeed = settings and settings.fieldWorkSpeed and settings.fieldWorkSpeed:getValue() or speedLimit
        local harvestSpeed = math.min(30, speedLimit, workSpeed) / 3.6
        local trailerSpeed = unloader.settings and unloader.settings.fieldSpeed and
                unloader.settings.fieldSpeed:getValue() / 3.6 or distance / math.max(1, ete)
        ete = math.max(ete, distance / math.max(1, trailerSpeed - harvestSpeed))
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

    -- A spare already on harvested ground and clear of the working pair need not turn around to reach a pool
    -- waypoint behind it. Keep its present position until predicted demand brings its layer further forwards.
    local clearance = unloader.getHarvesterTurnClearanceDistance and
            unloader:getHarvesterTurnClearanceDistance(demand.harvester) or self.minimumPoolDistance
    -- The reverse manoeuvre already measures turn clearance. Adding another header width here makes a cleared
    -- trailer drive a long loop to a pool waypoint even though it can safely stay where it stopped.
    local clearOfHarvesters = distance + 2 >= clearance
    if clearOfHarvesters then
        for _, other in pairs(g_currentMission.vehicleSystem.vehicles) do
            if other ~= demand.harvester and self:getHarvesterStrategy(other) then
                local ox, _, oz = getWorldTranslation(other.rootNode)
                local ux, _, uz = getWorldTranslation(unloader.vehicle.rootNode)
                local otherStrategy = self:getHarvesterStrategy(other)
                local otherClearance = unloader.getHarvesterTurnClearanceDistance and
                        unloader:getHarvesterTurnClearanceDistance(other) or self.minimumPoolDistance
                if MathUtil.vector2Length(ox - ux, oz - uz) + 2 < otherClearance then
                    clearOfHarvesters = false
                    break
                end
            end
        end
    end
    if clearOfHarvesters and distance <= poolDistance and
            unloader.vehicle.cpGetFieldPolygon and FieldworkBoundary then
        local x, _, z = getWorldTranslation(unloader.vehicle.rootNode)
        local boundary = FieldworkBoundary.forVehicle(unloader.vehicle, AIUtil.getWidth(unloader.vehicle) + 2)
        if boundary and FieldworkBoundary.contains(boundary, x, z) and
                (unloader.postUnloadClearanceHarvester or
                        unloader.hasReachedStandbyPosition and unloader:hasReachedStandbyPosition() or
                        not PathfinderUtil.hasFruit(x, z, 4, 4)) then
            return self:getWaypointAtUnloader(unloader), nil, false
        end
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
                if unloader:getFillLevelPercentage() == 0 then
                    local currentEte = self:getEteToDemand(unloader, demand)
                    for _, candidate in ipairs(unloaders) do
                        if candidate:getFillLevelPercentage() > 0 and self:canServeDemand(candidate, demand) and
                                self:getEteToDemand(candidate, demand) <= currentEte + self.combineSafetyMarginSeconds then
                            bestIndex = nil
                            break
                        end
                    end
                end
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
                    if ete <= fastestEte + self.combineSafetyMarginSeconds then
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
        if bestIndex and not demand.sharedUnloader then
            local unloader = table.remove(unloaders, bestIndex)
            local oldAssignment = self.assignments[unloader]
            local deploy = oldAssignment and oldAssignment.harvester == demand.harvester and
                    oldAssignment.role == 'STANDBY' or self:shouldDeploy(unloader, demand, oldAssignment)
            -- Combine relief stays in the rear pool until the active rig has left.
            -- Foragers retain their continuous-feed relief arrangement.
            if demand.activeUnloader and not demand.isFirm then deploy = false end
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
    if assignment and assignment.waitUntilHarvesterPasses and
            (not callingHarvester or not unloader.shouldWaitAtPoolForHarvester or
                    unloader:shouldWaitAtPoolForHarvester(callingHarvester)) then
        return false
    end
    if assignment and assignment.reserved and assignment.harvester ~= callingHarvester and callingHarvester then
        local assignedSeconds = self:getSecondsUntilUncovered(assignment.harvester)
        -- An actual call may be replacing a delayed lead. Its urgency is the harvester's remaining tank time.
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
