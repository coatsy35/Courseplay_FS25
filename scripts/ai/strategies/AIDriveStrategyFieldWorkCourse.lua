--[[
This file is part of Courseplay (https://github.com/Courseplay/Courseplay_FS25)
Copyright (C) 2021 Peter Vaiko

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

Drive strategy for driving a field work course

]]--

---@class AIDriveStrategyFieldWorkCourse : AIDriveStrategyCourse
AIDriveStrategyFieldWorkCourse = CpObject(AIDriveStrategyCourse)

AIDriveStrategyFieldWorkCourse.myStates = {
    WORKING = {},
    PREPARING = {},
    WAITING_FOR_LOWER = {},
    WAITING_FOR_LOWER_DELAYED = {},
    WAITING_FOR_STOP = {},
    WAITING_FOR_WEATHER = {},
    TURNING = { showTurnContextDebug = true },
    TEMPORARY = {},
    RETURNING_TO_START = {},
    DRIVING_TO_WORK_START_WAYPOINT = { showTurnContextDebug = true },
}

AIDriveStrategyFieldWorkCourse.normalFillLevelFullPercentage = 99.5

function AIDriveStrategyFieldWorkCourse:init(task, job)
    AIDriveStrategyCourse.init(self, task, job)
    AIDriveStrategyCourse.initStates(self, AIDriveStrategyFieldWorkCourse.myStates)
    self.state = self.states.INITIAL
    -- cache for the nodes created by TurnContext
    self.turnNodes = {}
    -- course offsets dynamically set by the AI and added to all tool and other offsets
    self.aiOffsetX, self.aiOffsetZ = 0, 0
    self.debugChannel = CpDebug.DBG_FIELDWORK
    self.waitingForPrepare = CpTemporaryObject(false)
end

function AIDriveStrategyFieldWorkCourse:delete()
    AIDriveStrategyCourse.delete(self)
    self:raiseImplements()
    TurnContext.deleteNodes(self.turnNodes)
    self:rememberWaypointToContinueFieldWork()
end

--- Start a fieldwork course. We expect that something else dropped us off close enough to startIx so
--- the most we need is an alignment course to lower the implements
function AIDriveStrategyFieldWorkCourse:start(course, startIx, jobParameters)
    self:showAllInfo('Starting field work at waypoint %d', startIx)
    self:updateFieldworkOffset(course)
    self.fieldWorkCourse = course
    self.fieldWorkCourse:setCurrentWaypointIx(startIx)
    self.remainingTime = CpRemainingTime(self.vehicle, course, startIx)
    -- remember at which waypoint we started, especially for the convoy
    self.startWaypointIx = startIx
    self.vehiclesInConvoy = {}

    local distance = course:getDistanceBetweenVehicleAndWaypoint(self.vehicle, startIx)

    ---@type CpAIJobFieldWork
    local job = self.vehicle:getJob()
    local alignmentCourse, alignmentCourseStartIx = job:getStartFieldWorkCourse()

    if alignmentCourse then
        -- there is an alignment course already created by the AIDriveStrategyDriveToFieldWorkStart,
        -- and we are supposed to continue on that one
        self:debug('Continuing the alignment course at %d to start work.', alignmentCourseStartIx)
        -- make sure the alignment course is used only once
        job:setStartFieldWorkCourse(nil, nil)
        self.course = course
        self:startAlignmentTurn(course, startIx, alignmentCourse, alignmentCourseStartIx)
    elseif distance > 2 * self.turningRadius then
        self:debug('Start waypoint is far (%.1f m), use alignment course to get there.', distance)
        self.course = course
        self:startAlignmentTurn(course, startIx)
    else
        self:debug('Close enough to start waypoint %d, no alignment course needed', startIx)
        self:startCourse(course, startIx)
        self.state = self.states.INITIAL
    end
    --- Store a reference to the original generated course
    self.originalGeneratedFieldWorkCourse = self.vehicle:getFieldWorkCourse()
end

--- Make sure all implements are in the working state
function AIDriveStrategyFieldWorkCourse:prepareForFieldWork()
    self.vehicle:raiseAIEvent('onAIFieldWorkerPrepareForWork', 'onAIImplementPrepareForWork')
end

--- Event raised when the driver has finished.
function AIDriveStrategyFieldWorkCourse:onFinished(hasFinished)
    AIDriveStrategyCourse.onFinished(self, hasFinished)
    self.remainingTime:reset()
end

function AIDriveStrategyFieldWorkCourse:update(dt)
    AIDriveStrategyCourse.update(self, dt)
    if CpDebug:isChannelActive(CpDebug.DBG_TURN, self.vehicle) then
        if self.state == self.states.TURNING then
            if self.aiTurn then
                self.aiTurn:drawDebug()
            end
        end
        if self.state.properties.showTurnContextDebug then
            if self.turnContext then
                self.turnContext:drawDebug()
            end
        end
        -- TODO_22 check user setting
        if self.course:isTemporary() then
            self.course:draw()
        elseif self.ppc:getCourse():isTemporary() then
            self.ppc:getCourse():draw()
        end
    end
    if CpDebug:isChannelActive(CpDebug.DBG_PATHFINDER, self.vehicle) then
        if self.pathfinder then
            PathfinderUtil.showNodes(self.pathfinder)
        end
    end
    if self.fieldWorkerProximityController then
        self.fieldWorkerProximityController:draw()
    end
    self:updateImplementControllers(dt)
    self.remainingTime:update(dt)
end

--- This is the interface to the Giant's AIFieldWorker specialization, telling it the direction and speed
function AIDriveStrategyFieldWorkCourse:getDriveData(dt, vX, vY, vZ)
    self:updateFieldworkOffset(self.course)
    self:updateLowFrequencyImplementControllers()
    Markers.refreshMarkerNodes(self.vehicle, self.measuredBackDistance)

    local moveForwards = not self.ppc:isReversing()
    local gx, gz

    ----------------------------------------------------------------
    if not moveForwards then
        local maxSpeed
        gx, gz, maxSpeed = self:getReverseDriveData()
        self:setMaxSpeed(maxSpeed)
    else
        gx, _, gz = self.ppc:getGoalPointPosition()
    end
    ----------------------------------------------------------------
    if self.state == self.states.INITIAL then
        -- We need a separate phase for preparing to make sure that the
        --   * onAIFieldWorkerStart,
        --   * onAIFieldWorkerPrepareForWork,
        --   * onAIImplementStartLine
        -- events are generated one by one, one in each update loop so that at the end of the loop,
        -- AIFieldWorker:updateAIFieldWorker() triggers a onAIFieldWorkerActive event.
        -- This makes sure that all implements are lowered and started correctly in multiplayer as well.
        self:setMaxSpeed(0)
        self:prepareForFieldWork()
        self.state = self.states.PREPARING
    elseif self.state == self.states.PREPARING then
        self:setMaxSpeed(0)
        self:startWaitingForLower()
        self:lowerImplements()
    elseif self.state == self.states.WAITING_FOR_LOWER then
        self:setMaxSpeed(0)
        if self:getCanContinueWork() then
            self:debug('all tools ready, start working')
            self.state = self.states.WORKING
        else
            self:debugSparse('waiting for all tools to lower')
        end
    elseif self.state == self.states.WAITING_FOR_LOWER_DELAYED then
        -- getCanAIVehicleContinueWork() seems to return false when the implement being lowered/raised (moving) but
        -- true otherwise. Due to some timing issues it may return true just after we started lowering it, so this
        -- here delays the check for another cycle.
        self.state = self.states.WAITING_FOR_LOWER
        self:setMaxSpeed(0)
    elseif self.state == self.states.WAITING_FOR_PATHFINDER then
        self:setMaxSpeed(0)
        if self.nextWaypointRetryAt and g_currentMission.time >= self.nextWaypointRetryAt then
            self.nextWaypointRetryAt = nil
            self:startPathfindingToNextWaypoint(self.waypointToContinueOnFailedPathfinding - 1)
        end
        if self.connectingPathRetryAt and g_currentMission.time >= self.connectingPathRetryAt then
            self.connectingPathRetryAt = nil
            if self.connectorRecoveryActive then
                self:startBlockedConnectorRecovery()
            else
                self:startConnectingPath(self.connectingPathStartIx)
            end
        end
    elseif self.state == self.states.WORKING then
        self:setMaxSpeed(self.settings.fieldWorkSpeed:getValue())
    elseif self.state == self.states.TURNING then
        local turnGx, turnGz, turnMoveForwards, turnMaxSpeed = self.aiTurn:getDriveData(dt)
        self:setMaxSpeed(turnMaxSpeed)
        -- if turn tells us which way to go, use that, otherwise just do whatever PPC tells us
        gx, gz = turnGx or gx, turnGz or gz
        if turnMoveForwards ~= nil then
            moveForwards = turnMoveForwards
        end
    elseif self.state == self.states.RETURNING_TO_START then
        local isReadyToDrive, blockingVehicle = self.vehicle:getIsAIReadyToDrive()
        if isReadyToDrive or not self.waitingForPrepare:get() then
            -- ready to drive or we just timed out waiting to be ready
            self:setMaxSpeed(self.settings.fieldSpeed:getValue())
        else
            self:debugSparse('Not ready to drive because of %s, preparing ...', CpUtil.getName(blockingVehicle))
        end
    elseif self.state == self.states.DRIVING_TO_WORK_START_WAYPOINT then
        self:setMaxSpeed(self.settings.fieldSpeed:getValue())
        local _, _, _, maxSpeed = self.workStarter:getDriveData()
        if maxSpeed ~= nil then
            self:setMaxSpeed(maxSpeed)
        end
    end

    self:setAITarget()
    self:limitSpeed()
    self:checkProximitySensors(moveForwards)
    self:checkDistanceToOtherFieldWorkers()

    return gx, gz, moveForwards, self.maxSpeed, 100
end

function AIDriveStrategyFieldWorkCourse:checkDistanceToOtherFieldWorkers()
    -- keep away from others working on the same course
    self:setMaxSpeed(self.fieldWorkerProximityController:getMaxSpeed(self.settings.convoyDistance:getValue(), self.maxSpeed))
end

-- Seems like the Giants AIDriveStrategyCollision needs these variables on the vehicle to be set
-- to calculate an accurate path prediction
function AIDriveStrategyFieldWorkCourse:setAITarget()
    --local dx, _, dz = localDirectionToWorld(self.vehicle:getAIDirectionNode(), 0, 0, 1)
    local wp = self.ppc:getCurrentWaypoint()
    --- TODO: For some reason wp.dx and wp.dz are nil sometimes
    local dx, dz = wp.dx or 0, wp.dz or 0
    if wp.dx ~= 0 or wp.dz ~= 0 then
        local length = MathUtil.vector2Length(dx, dz)
        dx = dx / length
        dz = dz / length
    end
    self.vehicle.aiDriveDirection = { dx, dz }
    local x, _, z = getWorldTranslation(self.vehicle:getAIDirectionNode())
    self.vehicle.aiDriveTarget = { x, z }
end

-----------------------------------------------------------------------------------------------------------------------
--- Implement handling
-----------------------------------------------------------------------------------------------------------------------
function AIDriveStrategyFieldWorkCourse:initializeImplementControllers(vehicle)

    local defaultDisabledStates = {
        self.states.TEMPORARY,
        self.states.TURNING,
        self.states.DRIVING_TO_WORK_START_WAYPOINT
    }
    self:addImplementController(vehicle, BalerController, Baler, {})
    self:addImplementController(vehicle, BaleWrapperController, BaleWrapper, defaultDisabledStates)
    self:addImplementController(vehicle, BaleLoaderController, BaleLoader, defaultDisabledStates)
    self:addImplementController(vehicle, APalletAutoLoaderController, nil, {}, "spec_aPalletAutoLoader")
    self:addImplementController(vehicle, UniversalAutoloadController, nil, {}, "spec_universalAutoload")

    self:addImplementController(vehicle, CombineController, Combine, defaultDisabledStates)
    self:addImplementController(vehicle, FertilizingSowingMachineController, FertilizingSowingMachine, defaultDisabledStates)
    self:addImplementController(vehicle, ForageWagonController, ForageWagon, defaultDisabledStates)
    self:addImplementController(vehicle, SowingMachineController, SowingMachine, defaultDisabledStates)
    self:addImplementController(vehicle, FertilizingCultivatorController, FertilizingCultivator, defaultDisabledStates)
    self:addImplementController(vehicle, MowerController, Mower, defaultDisabledStates)

    self:addImplementController(vehicle, RidgeMarkerController, RidgeMarker, defaultDisabledStates)
    self:addImplementController(vehicle, PlowController, Plow, defaultDisabledStates)

    self:addImplementController(vehicle, PickupController, Pickup, defaultDisabledStates)
    self:addImplementController(vehicle, SprayerController, Sprayer, {})
    self:addImplementController(vehicle, CutterController, Cutter, {})
    --- Makes sure the cutter timer gets reset always.
    self:addImplementController(vehicle, StonePickerController, StonePicker, defaultDisabledStates)

    self:addImplementController(vehicle, FoldableController, Foldable, {})
    self:addImplementController(vehicle, MotorController, Motorized, {})
    self:addImplementController(vehicle, WearableController, Wearable, {})
    self:addImplementController(vehicle, VineCutterController, VineCutter, defaultDisabledStates)
    self:addImplementController(vehicle, PalletFillerController, nil, defaultDisabledStates, "spec_pdlc_premiumExpansion.palletFiller")

    self:addImplementController(vehicle, SoilSamplerController, nil, defaultDisabledStates, CpUtil.getSoilSamplerSpecName())
    self:addImplementController(vehicle, StumpCutterController, StumpCutter, defaultDisabledStates)
    self:addImplementController(vehicle, TreePlanterController, TreePlanter, {})

end

--- Start waiting for the implements to lower
-- getCanAIVehicleContinueWork() seems to return false when the implement being lowered/raised (moving) but
-- true otherwise. Due to some timing issues it may return true just after we started lowering it, so we
-- set a different state for those implements
function AIDriveStrategyFieldWorkCourse:startWaitingForLower()
    -- TODO 25 looks like we always need to wait that extra cycle with FS25
    if true or AIUtil.hasAIImplementWithSpecialization(self.vehicle, SowingMachine) or self.ppc:isReversing() then
        -- sowing machines want to stop while the implement is being lowered
        -- also, when reversing, we assume that we'll switch to forward, so stop while lowering, then start forward
        self.state = self.states.WAITING_FOR_LOWER_DELAYED
        self:debug('waiting for lower delayed')
    else
        self.state = self.states.WAITING_FOR_LOWER
        self:debug('waiting for lower')
    end
end

--- Are all implements now aligned with the node? Can be used to find out if we are for instance aligned with the
--- turn end node direction in a question mark turn and can start reversing.
function AIDriveStrategyFieldWorkCourse:areAllImplementsAligned(node)
    -- see if the vehicle has AI markers -> has work areas (built-in implements like a mower or cotton harvester)
    local allAligned = self:isThisImplementAligned(self.vehicle, node)
    -- and then check all implements
    for _, implement in ipairs(AIUtil.getAllAIImplements(self.vehicle)) do
        -- _all_ implements must be aligned, hence the 'and'
        allAligned = allAligned and self:isThisImplementAligned(implement.object, node)
    end
    return allAligned
end

function AIDriveStrategyFieldWorkCourse:isThisImplementAligned(object, node)
    local aiFrontMarker, _, _ = WorkWidthUtil.getAIMarkers(object, true)
    if not aiFrontMarker then
        return true
    end
    return CpMathUtil.isSameDirection(aiFrontMarker, node, 5)
end

-----------------------------------------------------------------------------------------------------------------------
--- Event listeners
-----------------------------------------------------------------------------------------------------------------------
function AIDriveStrategyFieldWorkCourse:onWaypointChange(ix, course)
    self:calculateTightTurnOffset()
    if not self.state ~= self.states.TURNING
            and self.course:isTurnStartAtIx(ix) then
        if self.state == self.states.INITIAL or self.state == self.states.PREPARING then
            self:debug('Waypoint change (%d) to turn start right after starting work, lowering implements.', ix)
            self:startWaitingForLower()
            self:lowerImplements()
        end
        self:startTurn(ix)
    elseif self.state == self.states.WORKING then
        if (self.course:isOnConnectingPath(ix + 1) and not self.course:isOnConnectingPath(ix)) or
                self.course:shouldUsePathfinderToNextWaypoint(ix) then
            local fm, bm = self:getFrontAndBackMarkers()
            self.turnContext = RowStartOrFinishContext(self.vehicle, self.course, ix, ix, self.turnNodes, self:getWorkWidth(),
                    fm, bm, 0, 0)
            self.aiTurn = FinishRowOnly(self.vehicle, self, self.ppc, self.proximityController, self.turnContext)
            self.state = self.states.TURNING
            if self.course:isOnConnectingPath(ix + 1) then
                self:debug('finishing work before starting on the connecting path')
                self.aiTurn:registerTurnEndCallback(self, AIDriveStrategyFieldWorkCourse.startConnectingPath)
            else
                -- the generated course instructs the vehicle to use the pathfinder to the next waypoint
                self:debug('finishing work before starting pathfinding to the next waypoint')
                self.aiTurn:registerTurnEndCallback(self, AIDriveStrategyFieldWorkCourse.startPathfindingToNextWaypoint)
            end
        end
        -- towards the end of the field course make sure the implement reaches the last waypoint
        -- TODO: this needs refactoring, for now don't do this for temporary courses like a turn as it messes up reversing
        if ix > self.course:getNumberOfWaypoints() - 3 and not self.course:isTemporary() then
            local _, bm = self:getFrontAndBackMarkers()
            self:debug('adding offset (%.1f front marker) to make sure we do not miss anything when the course ends', bm)
            self.aiOffsetZ = -bm
        end
    end
end

function AIDriveStrategyFieldWorkCourse:onWaypointPassed(ix, course)
    if course:isLastWaypointIx(ix) then
        self:onLastWaypointPassed()
    end
end

--- Called when the last waypoint of a course is passed
function AIDriveStrategyFieldWorkCourse:onLastWaypointPassed()
    -- reset offset we used for the course ending to not miss anything
    self.aiOffsetZ = 0
    self:debug('Last waypoint of the course reached.')
    if self.state == self.states.RETURNING_TO_START then
        self:debug('Returned to first waypoint after fieldwork done, stopping job')
        self.vehicle:stopCurrentAIJob(AIMessageSuccessFinishedJob.new())
    elseif self.state == self.states.DRIVING_TO_WORK_START_WAYPOINT then
        self.proximityController:unregisterBlockingObjectListener()
        self.workStarter:onLastWaypoint()
        self.connectingPathStartIx = nil
        self.activeConnectingPathCourse = nil
        self.connectorRecoveryResumeIx = nil
    else
        -- by default, stop the job
        self:finishFieldWork()
    end
end

-----------------------------------------------------------------------------------------------------------------------
--- Turn
-----------------------------------------------------------------------------------------------------------------------
function AIDriveStrategyFieldWorkCourse:startTurn(ix)
    self:debug('Starting a turn at waypoint %d', ix)
    local fm, bm = self:getFrontAndBackMarkers()
    self.ppc:setShortLookaheadDistance()
    self.turnContext = TurnContext(self.vehicle, self.course, ix, ix + 1, self.turnNodes, self:getWorkWidth(), fm, bm,
            self:getTurnEndSideOffset(self.course:isHeadlandTurnAtIx(ix + 1)), self:getTurnEndForwardOffset())
    if AITurn.canMakeKTurn(self.vehicle, self.turnContext, self.workWidth, self:isTurnOnFieldActive()) then
        self.aiTurn = KTurn(self.vehicle, self, self.ppc, self.proximityController, self.turnContext, self.workWidth)
    else
        self.aiTurn = CourseTurn(self.vehicle, self, self.ppc, self.proximityController, self.turnContext, self.course, self.workWidth)
    end
    self.state = self.states.TURNING
end

function AIDriveStrategyFieldWorkCourse:isTurning()
    return self.state == self.states.TURNING
end

-- switch back to fieldwork after the turn ended.
---@param ix number waypoint to resume fieldwork after
function AIDriveStrategyFieldWorkCourse:resumeFieldworkAfterTurn(ix)
    -- Do not resume past a corner that the straight work-start approach has
    -- already carried the tractor across. Its implement can still be on the
    -- short incoming section, so let the normal turn finish that section.
    local course = self.fieldWorkCourse
    local cornerIx
    for i = ix, math.min(ix + 10, course:getNumberOfWaypoints()) do
        if course:isTurnStartAtIx(i) then
            cornerIx = i
            break
        end
    end
    local startIx, found = course:getNextFwdWaypointIxFromVehiclePosition(ix,
            self.vehicle:getAIDirectionNode(), self.workWidth / 2, cornerIx and cornerIx - ix or 10)
    if cornerIx and (not found or startIx >= cornerIx) then
        self:debug('Work-start handover reaches corner %d; start its turn instead of skipping it', cornerIx)
        -- startTurn uses self.course; this must be the fieldwork course, not
        -- the temporary joining course. Do not initialise PPC here: that can
        -- dispatch another waypoint callback before the turn owns it.
        self.course = course
        self:startTurn(cornerIx)
        return
    end
    if not found then
        self:debug('No forward continuation after waypoint %d; refusing an unaligned fieldwork handover', ix)
        self:raiseImplements()
        self.vehicle:stopCurrentAIJob(AIMessageCpErrorNoPathFound.new())
        return
    end
    self.ppc:setNormalLookaheadDistance()
    self:startWaitingForLower()
    self:lowerImplements()
    self:startCourse(course, startIx)
end

--- Attempt to recover from a turn where the vehicle got blocked. This replaces the current turn with a
--- RecoveryTurn, which just backs up a bit and then uses the pathfinder to create a turn back to the
--- start of the next row.
---@param reverseDistance number|nil distance to back up before retrying pathfinding (default 10 m)
---@param retryCount number|nil how many times have we tried to recover so far? (to limit the number of retries)
---@return boolean true if a recovery turn could be created
function AIDriveStrategyFieldWorkCourse:startRecoveryTurn(reverseDistance, retryCount)
    self:debug('Blocked in a turn, attempt to recover')
    if self.turnContext then
        self.aiTurn = RecoveryTurn(self.vehicle, self, self.ppc, self.proximityController, self.turnContext,
                self.course, self.workWidth, reverseDistance, retryCount)
        self.state = self.states.TURNING
        return true
    else
        self:debug('Lost turn context to recover, remain blocked.')
        return false
    end
end

-----------------------------------------------------------------------------------------------------------------------
--- State changes
-----------------------------------------------------------------------------------------------------------------------
function AIDriveStrategyFieldWorkCourse:finishFieldWork()
    if (self.settings.returnToStart:getValue() and self.fieldWorkCourse:startsWithHeadland()) or
            self.settings.restartCourseAtEnd:getValue() then
        self:debug('Fieldwork ended, returning to first waypoint.')
        self.vehicle:prepareForAIDriving()
        self:returnToStartAfterDone()
    else
        self:debug('Fieldwork ended, stopping job.')
        self.vehicle:stopCurrentAIJob(AIMessageSuccessFinishedJob.new())
    end
end

function AIDriveStrategyFieldWorkCourse:changeToFieldWork()
    self:debug('change to fieldwork')
    self:startWaitingForLower()
    self:lowerImplements(self.vehicle)
end

--- Start alignment turn, that is, a course to the waypoint of fieldWorkCourse where the
--- fieldwork should begin. This is performed as a turn maneuver, more specifically the end of the
--- turn maneuver where the work is started and has the logic to lower the implements exactly
--- where it needs to be.
---
--- (It is called alignment because it makes sure the vehicle is aligned with the start waypoint so
--- that it points to the right direction and the implements can start working exactly at the waypoint)
---
--- The caller can pass in an already created alignment course with an index. In that case, we'll use
--- that course, starting at alignmentStartIx for the turn, otherwise a new course is created from
--- the vehicle's current position to startIx in fieldWorkCourse.
---
---@param fieldWorkCourse Course fieldwork course
---@param startIx number index of waypoint of fieldWorkCourse where the work should start
---@param alignmentCourse Course an optional course if the caller already has one
---@param alignmentStartIx number index to start the alignment course (if supplied)
function AIDriveStrategyFieldWorkCourse:startAlignmentTurn(fieldWorkCourse, startIx, alignmentCourse, alignmentStartIx)
    if alignmentCourse then
        -- there is an alignment course, use that one, if there is a start ix, then only
        -- the part starting at startIx
        alignmentCourse = alignmentCourse:copy(self.vehicle, alignmentStartIx)
    else
        -- no alignment course given, generate one
        alignmentCourse = self:createAlignmentCourse(fieldWorkCourse, startIx)
    end
    self.ppc:setShortLookaheadDistance()
    if alignmentCourse then
        self:prepareForFieldWork()
        local fm, bm = self:getFrontAndBackMarkers()
        self.turnContext = RowStartOrFinishContext(self.vehicle, fieldWorkCourse, startIx, startIx, self.turnNodes,
                self:getWorkWidth(), fm, bm, self:getTurnEndSideOffset(false), self:getTurnEndForwardOffset())
        self.workStarter = StartRowOnly(self.vehicle, self, self.ppc, self.turnContext, alignmentCourse)
        self.state = self.states.DRIVING_TO_WORK_START_WAYPOINT
        self:startCourse(self.workStarter:getCourse(), 1)
    else
        self:debug('Could not create alignment course to first up/down row waypoint, continue without it')
        self:startCourse(fieldWorkCourse, startIx)
        self.state = self.states.INITIAL
    end
end

--- Back to the start waypoint after done
function AIDriveStrategyFieldWorkCourse:returnToStartAfterDone()
    if not self.pathfinder or not self.pathfinder:isActive() then
        self.pathfindingStartedAt = g_currentMission.time
        self:debug('Return to first waypoint')
        local context = PathfinderContext(self.vehicle)
                :allowReverse(self:getAllowReversePathfinding())
                :ignoreFruit(not self.settings.avoidFruit:getValue())
        local result
        self.pathfinder, result = PathfinderUtil.startPathfindingFromVehicleToWaypoint(
                self.fieldWorkCourse, 1, 0, 0, context)
        if result.done then
            return self:onPathfindingDoneToReturnToStart(result.path)
        else
            self.state = self.states.WAITING_FOR_PATHFINDER
            self:setPathfindingDoneCallback(self, self.onPathfindingDoneToReturnToStart)
        end
    else
        self:debug('Pathfinder already active, stopping job')
        self.vehicle:stopCurrentAIJob(AIMessageSuccessFinishedJob.new())
    end
end

function AIDriveStrategyFieldWorkCourse:onPathfindingDoneToReturnToStart(path)
    if path and #path > 2 then
        self:debug('Pathfinding to return to start finished with %d waypoints (%d ms)',
                #path, g_currentMission.time - (self.pathfindingStartedAt or 0))
        local returnCourse = Course(self.vehicle, CpMathUtil.pointsToGameInPlace(path), true)
        if self.settings.restartCourseAtEnd:getValue() then
            self:debug('Returning to the first waypoint and then restarting the fieldwork course')
            self:startAlignmentTurn(self.fieldWorkCourse, 1, returnCourse)
        else
            self:debug('Returning to the first waypoint and stopping there')
            self.state = self.states.RETURNING_TO_START
            self.waitingForPrepare:set(true, 10000)
            self:startCourse(returnCourse, 1)
        end
    else
        self:debug('No path found to return to fieldwork start after work is done (%d ms), stopping job',
                g_currentMission.time - (self.pathfindingStartedAt or 0))
        self.vehicle:stopCurrentAIJob(AIMessageSuccessFinishedJob.new())
    end
end
-----------------------------------------------------------------------------------------------------------------------
--- Use pathfinder to next waypoint
-----------------------------------------------------------------------------------------------------------------------
function AIDriveStrategyFieldWorkCourse:startPathfindingToNextWaypoint(ix)
    self.connectingPathRetryAt = nil
    self:debug('start pathfinding to waypoint %d', ix + 1)
    local fm, bm = self:getFrontAndBackMarkers()
    self.turnContext = RowStartOrFinishContext(self.vehicle, self.fieldWorkCourse, ix + 1, ix + 1,
            self.turnNodes, self:getWorkWidth(), fm, bm, self:getTurnEndSideOffset(false), self:getTurnEndForwardOffset())
    local _, steeringLength = AIUtil.getSteeringParameters(self.vehicle)
    local targetNode, zOffset = self.turnContext:getTurnEndNodeAndOffsets(steeringLength)
    local context = PathfinderContext(self.vehicle)
            :allowReverse(self:getAllowReversePathfinding())
            :ignoreFruit(not self.settings.avoidFruit:getValue())
    self.waypointToContinueOnFailedPathfinding = ix + 1
    self.pathfinderController:registerListeners(self, self.onPathfindingDoneToNextWaypoint,
            self.onPathfindingFailedToNextWaypoint)
    self:debug('Start pathfinding to target waypoint %d, zOffset %.1f', ix + 1, zOffset)
    self.state = self.states.WAITING_FOR_PATHFINDER
    -- to have a course set while waiting for the pathfinder
    self:startCourse(self.fieldWorkCourse, self.waypointToContinueOnFailedPathfinding)
    self.pathfinderController:findPathToNode(context, targetNode, 0, zOffset, 1)
end

--- Check the direct join that would be used if pathfinding fails, before disabling collisions.
function AIDriveStrategyFieldWorkCourse:isNextWaypointBlockedByWorker()
    local ix = self.waypointToContinueOnFailedPathfinding
    if not ix then return false end
    local sx, _, sz = getWorldTranslation(self.vehicle.rootNode)
    local tx, _, tz = self.fieldWorkCourse:getWaypointPosition(ix)
    local direct = {
        getNumberOfWaypoints = function() return 2 end,
        getWaypointPosition = function(_, pointIx)
            if pointIx == 1 then return sx, 0, sz end
            return tx, 0, tz
        end,
    }
    return self:isConnectingPathBlockedByWorker(direct)
end

function AIDriveStrategyFieldWorkCourse:waitForNextWaypointToClear()
    if not self:isNextWaypointBlockedByWorker() then return false end
    self:debug('Next-waypoint join is occupied; retaining collision checks and waiting')
    self.nextWaypointRetryAt = g_currentMission.time + 5000
    self.state = self.states.WAITING_FOR_PATHFINDER
    return true
end

function AIDriveStrategyFieldWorkCourse:onPathfindingFailedToNextWaypoint(controller, lastContext, wasLastRetry, currentRetryAttempt)
    if self:waitForNextWaypointToClear() then return end
    if wasLastRetry then
        self:debug('Pathfinding to next waypoint failed again, continue directly at waypoint %d', self.waypointToContinueOnFailedPathfinding)
        self:startWaitingForLower()
        self:lowerImplements()
        self:startCourse(self.fieldWorkCourse, self.waypointToContinueOnFailedPathfinding)
    else
        self:debug('Pathfinding to next waypoint failed once, retry with disabled collisions')
        lastContext:collisionMask(0)
        controller:retry(lastContext)
    end
end

function AIDriveStrategyFieldWorkCourse:onPathfindingDoneToNextWaypoint(controller, success, course, goalNodeInvalid)
    if success then
        self.nextWaypointRetryAt = nil
        self:debug('Pathfinding to next waypoint finished')
        self:startCourseToWorkStart(course)
    else
        if self:waitForNextWaypointToClear() then return end
        self:debug('Pathfinding to next waypoint failed, continue directly at waypoint %d', self.waypointToContinueOnFailedPathfinding)
        self:startWaitingForLower()
        self:lowerImplements()
        self:startCourse(self.fieldWorkCourse, self.waypointToContinueOnFailedPathfinding)
    end
end

-----------------------------------------------------------------------------------------------------------------------
--- Connecting path
-----------------------------------------------------------------------------------------------------------------------
--- The pathfinder is useful for a local joining manoeuvre. For a long route it duplicates the generated connector,
--- holds the worker stationary and can exhaust its global search before selecting that connector as its fallback.
---@param course Course
---@return boolean
function AIDriveStrategyFieldWorkCourse:canDriveConnectingPathDirectly(course)
    if not course then return false end
    local localManeuverDistance = math.max(4 * self.turningRadius, 2 * self:getWorkWidth())
    if course:getLength() <= localManeuverDistance then return false end
    -- The generated field course already accounts for the implement. This check protects the combine's own physical
    -- envelope and prevents a direct connector from crossing the field polygon or an island.
    local boundary = FieldworkBoundary.forVehicle(self.vehicle, 0)
    if not FieldworkBoundary.containsCourse(boundary, course) then return false end
    return not self:isConnectingPathBlockedByWorker(course)
end

function AIDriveStrategyFieldWorkCourse:isConnectingPathBlockedByWorker(course)
    -- A long generated connector can double back along a headland occupied by a following worker. Its field
    -- polygon is valid, but driving it directly bypasses collision-aware routing and can hit that worker.
    if not course.getNumberOfWaypoints or not course.getWaypointPosition then return false end
    local ownWidth = math.max(AIUtil.getWidth(self.vehicle), self:getWorkWidth())
    local parkedUnloader, parkedProgress
    local blockingWorker, workerIx, workerProgress
    for _, other in pairs(g_currentMission.vehicleSystem.vehicles) do
        if other ~= self.vehicle then
            local otherStrategy = other.getCpDriveStrategy and other:getCpDriveStrategy()
            local fieldWorker = other.getIsCpFieldWorkActive and other:getIsCpFieldWorkActive() and
                    self.fieldWorkerProximityController and self.fieldWorkerProximityController:hasSameCourse(other)
            -- An assigned unloader is still a physical obstacle. Only the request to move is restricted
            -- to a staging rig; an active call must not be cancelled merely to clear this connector.
            local unloader = otherStrategy and otherStrategy.requestToMoveOutOfWay and
                    otherStrategy.getCombineToUnload
            if fieldWorker or unloader then
                local parts = {other}
                if other.getChildVehicles then
                    for _, child in ipairs(other:getChildVehicles()) do
                        table.insert(parts, child)
                    end
                end
                for _, part in ipairs(parts) do
                    if part.rootNode then
                        local otherWidth = math.max(AIUtil.getWidth(part),
                                part == other and otherStrategy and otherStrategy.getWorkWidth and
                                otherStrategy:getWorkWidth() or 0)
                        local clearance = (ownWidth + otherWidth) / 2 + 5
                        local halfLength = AIUtil.getLength(part) / 2
                        for _, offset in ipairs({-halfLength, 0, halfLength}) do
                            local ox, _, oz = localToWorld(part.rootNode, 0, 0, offset)
                            local previousX, _, previousZ = course:getWaypointPosition(1)
                            for ix = 2, course:getNumberOfWaypoints() do
                                local x, _, z = course:getWaypointPosition(ix)
                                local dx, dz = x - previousX, z - previousZ
                                local lengthSquared = dx * dx + dz * dz
                                local fraction = lengthSquared > 0 and
                                        math.max(0, math.min(1, ((ox - previousX) * dx + (oz - previousZ) * dz) / lengthSquared)) or 0
                                local nearestX, nearestZ = previousX + fraction * dx, previousZ + fraction * dz
                                if MathUtil.vector2Length(ox - nearestX, oz - nearestZ) < clearance then
                                    local progress = ix - 1 + fraction
                                    if fieldWorker then
                                        if not workerProgress or progress < workerProgress then
                                            blockingWorker, workerIx, workerProgress = other, ix, progress
                                        end
                                    elseif not parkedProgress or progress < parkedProgress then
                                        parkedUnloader, parkedProgress = otherStrategy, progress
                                    end
                                    break
                                end
                                previousX, previousZ = x, z
                            end
                        end
                    end
                end
            end
        end
    end
    if parkedUnloader and (not workerProgress or parkedProgress < workerProgress) then
        -- Ask one parked rig at a time to clear the corridor. Its local escape course must not conflict with
        -- another trailer's escape course, and the combine keeps collision checks enabled while it waits.
        if not parkedUnloader:getCombineToUnload() and parkedUnloader.isAvailableForStaging and
                parkedUnloader:isAvailableForStaging() then
            parkedUnloader:requestToMoveOutOfWay(self.vehicle, nil, course)
        end
        self:debug('Connecting path occupied by a trailer; waiting for clearance')
        return true, 'unloader'
    end
    if blockingWorker then
        self:debug('Connecting path crosses %s; waiting for the worker to clear', CpUtil.getName(blockingWorker))
        return true, 'fieldWorker', blockingWorker, workerIx
    end
    return false
end

--- Rejoin beyond the obstructing machine rather than searching to the end of a whole-field connector.
function AIDriveStrategyFieldWorkCourse:getConnectingPathRejoinIx(course, blockedIx, otherWorker)
    if not blockedIx then return nil end
    local ownWidth = math.max(AIUtil.getWidth(self.vehicle), self:getWorkWidth())
    local otherStrategy = otherWorker.getCpDriveStrategy and otherWorker:getCpDriveStrategy()
    local otherWidth = math.max(AIUtil.getWidth(otherWorker),
            otherStrategy and otherStrategy.getWorkWidth and otherStrategy:getWorkWidth() or 0)
    local distanceNeeded = (ownWidth + otherWidth) / 2 + 30
    local distance = 0
    local previousX, _, previousZ = course:getWaypointPosition(blockedIx)
    for ix = blockedIx + 1, course:getNumberOfWaypoints() do
        local x, _, z = course:getWaypointPosition(ix)
        distance = distance + MathUtil.vector2Length(x - previousX, z - previousZ)
        if distance >= distanceNeeded then return ix end
        previousX, previousZ = x, z
    end
    return nil
end

function AIDriveStrategyFieldWorkCourse:setConnectingPathBoundary(context, width)
    local boundary = FieldworkBoundary.forVehicle(self.vehicle, width)
    self.connectingPathBoundary = boundary
    context._fieldworkBoundary = boundary
    if boundary then
        local x, _, z = getWorldTranslation(self.vehicle.rootNode)
        -- A combine already over the corridor line must be able to steer back in. The resulting course is
        -- checked afterwards: once it enters the corridor it may not leave again.
        context._preferFieldworkBoundary = not FieldworkBoundary.contains(boundary, x, z)
    end
end

function AIDriveStrategyFieldWorkCourse:startConnectingPath(ix)
    self.proximityController:unregisterBlockingObjectListener()
    self.nextWaypointRetryAt = nil
    self.connectingPathStartIx = ix
    -- ix was the last waypoint to work before the connecting path, ix + 1 is the first on the connecting path
    self:debug('Row finished before starting on a connecting path at waypoint %d.', ix + 1)
    -- gather the connecting path waypoints
    local connectingPath = {}
    local targetWaypointIx
    for i = ix + 1, self.fieldWorkCourse:getNumberOfWaypoints() do
        if self.fieldWorkCourse:isOnConnectingPath(i) then
            local x, _, z = self.fieldWorkCourse:getWaypointPosition(i)
            table.insert(connectingPath, { x = x, z = z })
        else
            targetWaypointIx = i
            break
        end
    end
    if targetWaypointIx == nil then
        self:debug('Can\'t find end of connecting path, continuing work')
        self.connectingPathStartIx = nil
        self:startWaitingForLower()
        self:lowerImplements()
        self:startCourse(self.fieldWorkCourse, ix + 1)
    else
        -- set up the turn context for the work starter to use when the pathfinding succeeds
        local fm, bm = self:getFrontAndBackMarkers()
        self.turnContext = RowStartOrFinishContext(self.vehicle, self.fieldWorkCourse, targetWaypointIx, targetWaypointIx,
                self.turnNodes, self:getWorkWidth(), fm, bm, self:getTurnEndSideOffset(false), self:getTurnEndForwardOffset())
        local _, steeringLength = AIUtil.getSteeringParameters(self.vehicle)
        local targetNode, zOffset = self.turnContext:getTurnEndNodeAndOffsets(steeringLength)
        local context = PathfinderContext(self.vehicle):allowReverse(self:getAllowReversePathfinding())
        context:preferredPath(connectingPath):mustBeAccurate(true):ignoreFruit(not self.settings.avoidFruit:getValue())
        -- The normal off-field cost is only a preference. A detour to a distant centre row must keep the
        -- combine clear of the field edge and islands, including when it avoids another worker.
        self:setConnectingPathBoundary(context, AIUtil.getWidth(self.vehicle) + 4)
        if #connectingPath < 2 then
            self:debug('Connecting path has only %d waypoint, use an alignment course instead', #connectingPath)
            self.workStarterCourse = self:createAlignmentCourse(self.fieldWorkCourse, targetWaypointIx)
        else
            self.workStarterCourse = Course(self.vehicle, connectingPath, true)
        end
        local blocked, blocker, otherWorker, blockedIx = self:isConnectingPathBlockedByWorker(self.workStarterCourse)
        self.connectingPathRejoinIx = nil
        if blocked and blocker == 'fieldWorker' then
            local convoyOrder = self.fieldWorkerProximityController and
                    self.fieldWorkerProximityController.otherVehicleAheadOnTrail
            local workerAhead = convoyOrder and convoyOrder[otherWorker]
            local otherStrategy = otherWorker.getCpDriveStrategy and otherWorker:getCpDriveStrategy()
            local workerStalled = otherStrategy and otherStrategy.proximityController and
                    otherStrategy.proximityController:isStopped() and AIUtil.isStopped(otherWorker)
            -- Wait for the preceding worker first. If it cannot clear, try a collision-aware
            -- detour periodically. The lead worker may detour immediately around a follower;
            -- the follower must not repeatedly search the entire connector through the lead worker.
            self.connectingPathWorkerDetourAt = self.connectingPathWorkerDetourAt or
                    g_currentMission.time + 15000
            if (workerAhead and (not workerStalled or self.connectingPathWorkerLastSearchAt and
                    g_currentMission.time < self.connectingPathWorkerLastSearchAt + 30000)) or
                    (workerAhead == nil and g_currentMission.time < self.connectingPathWorkerDetourAt) then
                self:debug('Connecting path occupied by another field worker; waiting for it to clear')
                self.connectingPathRetryAt = g_currentMission.time + 5000
                self.state = self.states.WAITING_FOR_PATHFINDER
                self:startCourse(self.workStarterCourse, 1)
                return
            end
            self.connectingPathWorkerDetourAt = g_currentMission.time + 60000
            self.connectingPathWorkerLastSearchAt = g_currentMission.time
            self.connectingPathRejoinIx = self:getConnectingPathRejoinIx(self.workStarterCourse,
                    blockedIx, otherWorker)
            if not self.connectingPathRejoinIx then
                self:debug('No connector waypoint beyond the worker has enough clearance; waiting')
                self.connectingPathRetryAt = g_currentMission.time + 5000
                self.state = self.states.WAITING_FOR_PATHFINDER
                self:startCourse(self.workStarterCourse, 1)
                return
            end
            context._preferredPath = nil
        else
            self.connectingPathWorkerDetourAt = nil
            self.connectingPathWorkerLastSearchAt = nil
        end
        if not self.connectorRecoveryActive and #connectingPath >= 2 and
                self:canDriveConnectingPathDirectly(self.workStarterCourse) then
            self:debug('Connecting path is a %.1f m generated route; drive it directly instead of pathfinding to its end',
                    self.workStarterCourse:getLength())
            self:startCourseToWorkStart(self.workStarterCourse)
            return
        end
        self.pathfinderController:registerListeners(self, self.onPathfindingDoneToConnectingPathEnd,
                self.onPathfindingFailedToConnectingPathEnd)
        self:debug('Connecting path has %d waypoints; pathfinding to %s', #connectingPath,
                self.connectingPathRejoinIx and string.format('local rejoin %d', self.connectingPathRejoinIx) or
                        string.format('work waypoint %d', targetWaypointIx))
        self.state = self.states.WAITING_FOR_PATHFINDER
        -- to have a course set while waiting for the pathfinder and make sure that the course known to the PPC
        -- is the same as the one we are using
        self:startCourse(self.workStarterCourse, 1)
        if self.connectingPathRejoinIx then
            self.pathfinderController:findPathToWaypoint(context, self.workStarterCourse,
                    self.connectingPathRejoinIx, 0, 0, 1)
        else
            self.pathfinderController:findPathToNode(context, targetNode, 0, zOffset, 1)
        end
    end
end

function AIDriveStrategyFieldWorkCourse:onPathfindingFailedToConnectingPathEnd(controller, lastContext, wasLastRetry, currentRetryAttempt)
    local blocked, blocker = self:isConnectingPathBlockedByWorker(self.workStarterCourse)
    if blocked and (blocker ~= 'fieldWorker' or not self.connectingPathRejoinIx or wasLastRetry) then
        -- Do not disable collisions or fall back to the obstructed generated route. Recheck after the other
        -- worker moves; a collision-free path found by the first search is handled by the success callback.
        self:debug('Connecting path remains occupied; waiting before retrying')
        self.connectingPathRetryAt = g_currentMission.time + 5000
        self.state = self.states.WAITING_FOR_PATHFINDER
        return
    end
    if wasLastRetry then
        self:retryOrDriveGeneratedConnectingPath()
    else
        self:debug('Pathfinding to end of connecting path failed once, retry with vehicle-width field clearance')
        self:setConnectingPathBoundary(lastContext, 0)
        controller:retry(lastContext)
    end
end

function AIDriveStrategyFieldWorkCourse:retryOrDriveGeneratedConnectingPath()
    if not self.connectorRecoveryActive and self:canDriveConnectingPathDirectly(self.workStarterCourse) then
        self:debug('Pathfinding failed; the generated connector is clear and field-contained')
        self:startCourseToWorkStart(self.workStarterCourse)
    else
        self:debug('No safe connecting path; waiting before replanning')
        self.connectingPathRetryAt = g_currentMission.time + 30000
        self.state = self.states.WAITING_FOR_PATHFINDER
    end
end

function AIDriveStrategyFieldWorkCourse:onPathfindingDoneToConnectingPathEnd(controller, success, course, goalNodeInvalid)
    if success then
        if self.connectingPathRejoinIx and self.connectingPathRejoinIx <
                self.workStarterCourse:getNumberOfWaypoints() then
            local remainder = self.workStarterCourse:copy(self.vehicle, self.connectingPathRejoinIx + 1)
            if self:isConnectingPathBlockedByWorker(remainder) then
                self:debug('Local rejoin is still occupied; waiting for a clear continuation')
                self.connectingPathRetryAt = g_currentMission.time + 5000
                self.state = self.states.WAITING_FOR_PATHFINDER
                return
            end
            course:append(remainder)
        end
        if not FieldworkBoundary.containsCourse(self.connectingPathBoundary, course, nil, nil, true) then
            self:debug('Pathfound connecting route leaves the combine field corridor; replanning')
            self.connectingPathRetryAt = g_currentMission.time + 5000
            self.state = self.states.WAITING_FOR_PATHFINDER
            return
        end
        -- The occupancy test protects the generated connector, which has no collision checks. A successful
        -- pathfinder route already avoided the parked rigs; applying the wider staging margin to that detour
        -- can reject every valid route when a trailer has nowhere else to park.
        self.connectingPathRetryAt = nil
        self:debug('Pathfinding to end of connecting path finished')
        self:startCourseToWorkStart(course)
    else
        if self:isConnectingPathBlockedByWorker(self.workStarterCourse) then
            self.connectingPathRetryAt = g_currentMission.time + 5000
            self.state = self.states.WAITING_FOR_PATHFINDER
            return
        end
        self:retryOrDriveGeneratedConnectingPath()
    end
end

function AIDriveStrategyFieldWorkCourse:startCourseToWorkStart(course)
    if self.connectingPathStartIx then
        -- Keep the unmodified approach. StartRowOnly appends its own entry section to the supplied course.
        self.activeConnectingPathCourse = course:copy(self.vehicle)
    end
    self.connectorRecoveryActive = nil
    self.connectorRecoveryResumeIx = nil
    self.workStarter = StartRowOnly(self.vehicle, self, self.ppc, self.turnContext, course)
    self.state = self.states.DRIVING_TO_WORK_START_WAYPOINT
    self:raiseImplements()
    self.ppc:setShortLookaheadDistance()
    self:startCourse(self.workStarter:getCourse(), 1)
    if self.connectingPathStartIx then
        self.proximityController:registerBlockingObjectListener(self,
                AIDriveStrategyFieldWorkCourse.onBlockedConnectingPath)
    end
end

function AIDriveStrategyFieldWorkCourse:startBlockedConnectorRecovery()
    local approach = self.activeConnectingPathCourse
    if not approach then return end
    self.proximityController:unregisterBlockingObjectListener()
    local firstIx = math.min(self.connectorRecoveryResumeIx or 1, approach:getNumberOfWaypoints())
    self.workStarterCourse = approach:copy(self.vehicle, firstIx)
    self.connectingPathRejoinIx = nil
    local distanceNeeded = math.max(30, 2 * self.turningRadius, self:getWorkWidth())
    local distance = 0
    local previousX, _, previousZ = self.workStarterCourse:getWaypointPosition(1)
    for ix = 2, self.workStarterCourse:getNumberOfWaypoints() do
        local x, _, z = self.workStarterCourse:getWaypointPosition(ix)
        distance = distance + MathUtil.vector2Length(x - previousX, z - previousZ)
        if distance >= distanceNeeded then
            self.connectingPathRejoinIx = ix
            break
        end
        previousX, previousZ = x, z
    end
    local context = PathfinderContext(self.vehicle):allowReverse(self:getAllowReversePathfinding())
            :mustBeAccurate(true):ignoreFruit(not self.settings.avoidFruit:getValue())
    self:setConnectingPathBoundary(context, AIUtil.getWidth(self.vehicle) + 4)
    self.pathfinderController:registerListeners(self, self.onPathfindingDoneToConnectingPathEnd,
            self.onPathfindingFailedToConnectingPathEnd)
    self.state = self.states.WAITING_FOR_PATHFINDER
    self:startCourse(self.workStarterCourse, 1)
    if self.connectingPathRejoinIx then
        self:debug('Blocked approach: pathfinding to local waypoint %d', self.connectingPathRejoinIx)
        self.pathfinderController:findPathToWaypoint(context, self.workStarterCourse,
                self.connectingPathRejoinIx, 0, 0, 1)
    else
        local _, steeringLength = AIUtil.getSteeringParameters(self.vehicle)
        local targetNode, zOffset = self.turnContext:getTurnEndNodeAndOffsets(steeringLength)
        self:debug('Blocked near row start: pathfinding to the work point')
        self.pathfinderController:findPathToNode(context, targetNode, 0, zOffset, 1)
    end
end

function AIDriveStrategyFieldWorkCourse:onBlockedConnectingPath(isBack)
    if isBack or self.state ~= self.states.DRIVING_TO_WORK_START_WAYPOINT or
            not self.connectingPathStartIx or
            g_currentMission.time < (self.connectingPathObstacleRetryAt or 0) then return end
    self:debug('Centre-work approach obstructed; replanning inside the field corridor')
    self.connectingPathObstacleRetryAt = g_currentMission.time + 30000
    self.connectorRecoveryActive = true
    self.connectorRecoveryResumeIx = self.course:getCurrentWaypointIx()
    self:startBlockedConnectorRecovery()
end

-----------------------------------------------------------------------------------------------------------------------
--- Static parameters (won't change while driving)
-----------------------------------------------------------------------------------------------------------------------
function AIDriveStrategyFieldWorkCourse:setAllStaticParameters()
    AIDriveStrategyCourse.setAllStaticParameters(self)
    self:setFrontAndBackMarkers()
    self.loweringDurationMs = AIUtil.findLoweringDurationMs(self.vehicle)
    self.fieldWorkerProximityController = FieldWorkerProximityController(self.vehicle, self.workWidth)
end

-----------------------------------------------------------------------------------------------------------------------
--- Dynamic parameters (may change while driving)
-----------------------------------------------------------------------------------------------------------------------
function AIDriveStrategyFieldWorkCourse:getTurnEndSideOffset(isHeadlandTurn)
    return 0
end

function AIDriveStrategyFieldWorkCourse:getTurnEndForwardOffset()
    return 0
end

function AIDriveStrategyFieldWorkCourse:getLoweringDurationMs()
    return self.loweringDurationMs
end

function AIDriveStrategyFieldWorkCourse:getImplementRaiseLate()
    return ImplementProfile.getTiming(self.settings, 'raiseImplementLate')
end

function AIDriveStrategyFieldWorkCourse:getImplementLowerEarly()
    return ImplementProfile.getTiming(self.settings, 'lowerImplementEarly')
end

function AIDriveStrategyFieldWorkCourse:rememberWaypointToContinueFieldWork()
    local ix = self:getBestWaypointToContinueFieldWork()
    self.vehicle:rememberCpLastWaypointIx(ix)
end

function AIDriveStrategyFieldWorkCourse:getBestWaypointToContinueFieldWork()
    local bestKnownCurrentWpIx = self.fieldWorkCourse:getLastPassedWaypointIx() or self.fieldWorkCourse:getCurrentWaypointIx()
    -- after we return from a refill/unload, continue a bit before the point where we left to
    -- make sure not leaving any unworked patches
    local bestWpIx = self.fieldWorkCourse:getPreviousWaypointIxWithinDistanceOrToTurnEnd(bestKnownCurrentWpIx, 10)
    self:debug('Best return to fieldwork waypoint is %s (back from %d)', bestWpIx, bestKnownCurrentWpIx)
    return bestWpIx or bestKnownCurrentWpIx
end

function AIDriveStrategyFieldWorkCourse:setOffsetX()
    -- do nothing by default
end

function AIDriveStrategyFieldWorkCourse:calculateTightTurnOffset()
    if self.state == self.states.WORKING or self.state == self.states.DRIVING_TO_WORK_START_WAYPOINT then
        -- when rounding small islands or to start on a course with curves
        self.tightTurnOffset = AIUtil.calculateTightTurnOffset(self.vehicle, self.turningRadius, self.course,
                self.tightTurnOffset)
    else
        self.tightTurnOffset = 0
    end
end

function AIDriveStrategyFieldWorkCourse:isWorking()
    return self.state == self.states.WORKING or self.state == self.states.TURNING
end

--- Gets the current ridge marker state.
function AIDriveStrategyFieldWorkCourse:getRidgeMarkerState()
    return self.course:getRidgeMarkerState(self.ppc:getCurrentWaypointIx()) or 0
end

function AIDriveStrategyFieldWorkCourse:showAllInfo(note, ...)
    self:debug('%s: work width %.1f, turning radius %.1f, front marker %.1f, back marker %.1f',
            string.format(note, ...), self.workWidth, self.turningRadius, self.frontMarkerDistance, self.backMarkerDistance)
    self:debug(' - map: %s, field %s', g_currentMission.missionInfo.mapTitle,
            CpFieldUtil.getFieldNumUnderVehicle(self.vehicle))
    for _, implement in pairs(self.vehicle:getAttachedImplements()) do
        self:debug(' - %s', CpUtil.getName(implement.object))
    end
end

--- Updates the status variables.
---@param status CpStatus
function AIDriveStrategyFieldWorkCourse:updateCpStatus(status)
    ---@type Course
    if self.fieldWorkCourse then
        local ix = self.fieldWorkCourse:getCurrentWaypointIx()
        local numWps = self.fieldWorkCourse:getNumberOfWaypoints()
        status:setWaypointData(ix, numWps, self.remainingTime:getText())
    end
end

function AIDriveStrategyFieldWorkCourse:isTurnOnFieldActive()
    return self.settings.turnOnField:getValue()
end

-----------------------------------------------------------------------------------------------------------------------
--- Convoy management
-----------------------------------------------------------------------------------------------------------------------
function AIDriveStrategyFieldWorkCourse:getProgress()
    return self.fieldWorkCourse:getProgress()
end

function AIDriveStrategyFieldWorkCourse:isDone()
    return self.fieldWorkCourse:getCurrentWaypointIx() == self.fieldWorkCourse:getNumberOfWaypoints()
end

function AIDriveStrategyFieldWorkCourse:getFieldWorkProximity(node)
    return self.fieldWorkerProximityController:getFieldWorkProximity(node)
end

-----------------------------------------------------------------------------------------------------------------------
--- Overwrite implement functions, to enable a different cp functionality compared to giants fieldworker.
--- TODO: might have to find a better solution for these kind of problems.
-----------------------------------------------------------------------------------------------------------------------
local function emptyFunction(object, superFunc, ...)
    local rootVehicle = object.rootVehicle
    if rootVehicle.getJob then
        if rootVehicle:getIsCpActive() then
            return
        end
    end
    return superFunc(object, ...)
end
--- Makes sure the automatic work width isn't being reset.
VariableWorkWidth.onAIFieldWorkerStart = Utils.overwrittenFunction(VariableWorkWidth.onAIFieldWorkerStart, emptyFunction)
VariableWorkWidth.onAIImplementStart = Utils.overwrittenFunction(VariableWorkWidth.onAIImplementStart, emptyFunction)

-- TODO 25
-- This seems to be called when the Giants AI is done generating a field course, but we don't want the stock
-- AI to do anything when the course is loaded, so we just return if the vehicle is a CP vehicle.
local function noOpWhenCpActive(self, superFunc, ...)
    -- TODO this also comes when we just stopped a CP vehicle right after it was started
    if self.vehicle:getIsCpActive() then
        return
    end
    return superFunc(self, ...)
end
AIDriveStrategyFieldCourse.onFieldCourseLoadedCallback = Utils.overwrittenFunction(AIDriveStrategyFieldCourse.onFieldCourseLoadedCallback, noOpWhenCpActive)

-- TODO 25
-- The other thing messing us up is the delete() when we remove the Giants strategies in CpAITaskFieldWork,
-- because it triggers an AI end line event, raising all implements

AIDriveStrategyFieldCourse.delete = Utils.overwrittenFunction(AIDriveStrategyFieldCourse.delete, noOpWhenCpActive)
