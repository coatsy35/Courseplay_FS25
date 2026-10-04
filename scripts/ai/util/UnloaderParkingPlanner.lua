--- Deliberate whole-rig parking and short departures. Allocation remains in UnloaderCoordinator;
--- complex journeys still use the normal pathfinder. Geometry is never permission to ignore collisions.
UnloaderParkingPlanner = {}
local P = UnloaderParkingPlanner
P.departureDistance = 12
-- All parking jobs share one frame allowance, so four waiting trailers cannot each spend it.
P.frameBudgetMs = 3
P.frameStepBudget = 256
function P.isIncremental()
    return g_updateLoopIndex ~= nil
end

-- FS25 removes Lua's coroutine library. Each job retains explicit indices/child jobs and
-- performs one geometry step or native probe per advance, as CP's pathfinder does.
function P.createJob(work)
    assert(type(work) == 'table' and type(work.step) == 'function', 'Parking work requires an explicit step job')
    return work
end

function P.advance(job)
    if job.done then return true, job.result end
    local done, result = job:step()
    if done then job.done, job.result = true, result end
    return done, result
end

function P.run(job)
    while true do local done, result = P.advance(job); if done then return result end end
end

function P.resumeJob(job)
    if job.done then return true, job.result end
    if not P.isIncremental() then return true, P.run(job) end
    if P.frame ~= g_updateLoopIndex then P.frame, P.frameUsedMs, P.frameSteps = g_updateLoopIndex, 0, 0 end
    if P.frameUsedMs >= P.frameBudgetMs or P.frameSteps >= P.frameStepBudget then return false end
    local timer = openIntervalTimer()
    local function progress()
        while P.frameSteps < P.frameStepBudget and
                P.frameUsedMs + readIntervalTimerMs(timer) < P.frameBudgetMs do
            P.frameSteps = P.frameSteps + 1
            local done, result = P.advance(job)
            if done then return true, result end
        end
        return false
    end
    local ok, done, result = pcall(progress)
    P.frameUsedMs = P.frameUsedMs + readIntervalTimerMs(timer)
    closeIntervalTimer(timer)
    if not ok then error(done) end
    return done, result
end

local function angle(a, b) return (a - b + math.pi) % (2 * math.pi) - math.pi end
local function poseCourse(x, z)
    return {getNumberOfWaypoints = function() return 1 end,
        getWaypointPosition = function() return x, 0, z end}
end

function P.getBoundary(vehicle)
    local polygon = vehicle:cpGetFieldPolygon()
    if not polygon or #polygon < 3 then return nil end
    -- Each physical body already includes padding. Do not inset again by the whole train width.
    return {polygon = polygon, margin = 0.25,
        islands = vehicle.cpGetIslandPolygons and vehicle:cpGetIslandPolygons() or {}}
end

function P.alignedRig(vehicle, x, z, heading)
    local rig = FieldworkBoundary.captureRig(vehicle)
    local ox, oz, oh = rig[1].x, rig[1].z, rig[1].heading
    for _, part in ipairs(rig) do
        if part.parent then
            part.heading = part.parent.heading + (part.articulated and 0 or part.relativeHeading)
        else
            local dx, dz = part.x - ox, part.z - oz
            local h = heading - oh
            part.x, part.z = x + math.cos(h) * dx + math.sin(h) * dz,
                z - math.sin(h) * dx + math.cos(h) * dz
            part.heading = part.heading + h
        end
    end
    FieldworkBoundary.advanceRig(rig, x, z, heading, 0)
    return rig
end

function P.getRigLength(rig)
    local front, rear, lead = -math.huge, math.huge, rig[1]
    for _, part in ipairs(rig) do
        local dx, dz = part.x - lead.x, part.z - lead.z
        local along = math.sin(lead.heading) * dx + math.cos(lead.heading) * dz
        front = math.max(front, along + part.box.zOffset + part.box.length)
        rear = math.min(rear, along + part.box.zOffset - part.box.length)
    end
    return front - rear
end

function P.newPlanJob(previous)
    local plan = {obstacles = {}, traffic = {}, reservations = {}, detectors = {}}
    local vehicles, reservations = {}, {}
    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do vehicles[#vehicles + 1] = vehicle end
    for driver, assignment in pairs(previous or {}) do
        reservations[#reservations + 1] = {driver = driver, assignment = assignment}
    end
    local vi, ri, pending, pendingVehicle = 1, 1, nil, nil
    return {step = function()
        if pending then
            local done, sweep = P.advance(pending)
            if done then plan.traffic[#plan.traffic + 1] = {vehicle = pendingVehicle, sweep = sweep}; pending = nil end
            return false
        end
        local vehicle = vehicles[vi]
        if vehicle then
            vi = vi + 1
            if vehicle.rootNode then
                local rig = FieldworkBoundary.captureRig(vehicle)
                plan.obstacles[#plan.obstacles + 1] = {vehicle = vehicle, rig = rig}
                local driver = vehicle.getCpDriveStrategy and vehicle:getCpDriveStrategy()
                local ppc = driver and driver.ppc
                local course = ppc and ppc.getCourse and ppc:getCourse()
                local moving = driver and (driver.callUnloader or driver.getCombineToUnload and driver:getCombineToUnload() or
                    driver.isInStandbyState and driver:isInStandbyState() and driver.state == driver.states.DRIVING_TO_STANDBY or
                    driver.connectorClearance or driver.departureRecovery or driver.fullTrailerDeparture and
                        driver.state == driver.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL)
                if moving and course and course:getNumberOfWaypoints() > 1 then
                    local ix = ppc:getRelevantWaypointIx() or 1
                    local last = course:getNextWaypointIxWithinDistance(ix, 60) or course:getNumberOfWaypoints()
                    if last > ix then
                        local remaining = course:copy(vehicle, ix, last)
                        local straight = VehicleRouteConflict.createStraightSweep(rig, remaining)
                        if straight then
                            plan.traffic[#plan.traffic + 1] = {vehicle = vehicle, sweep = straight}
                        else
                            pending = VehicleRouteConflict.createSweepJob(FieldworkBoundary.captureRig(vehicle), remaining,
                                driver.turningRadius or AIUtil.getTurningRadius(vehicle))
                            pendingVehicle = vehicle
                        end
                    end
                end
            end
            return false
        end
        local reservation = reservations[ri]
        if not reservation then return true, plan end
        ri = ri + 1
        local driver, assignment = reservation.driver, reservation.assignment
        local clearing = driver.isConnectorClearancePending and driver:isConnectorClearancePending()
        local parked = assignment.parkingBay and driver.states and driver.state == driver.states.WAITING_IN_STANDBY and
            not driver.parkingBayFailed and P.rigMatchesBay(FieldworkBoundary.captureRig(driver.vehicle), assignment.parkingBay)
        if assignment.parkingBay and (clearing or parked or driver.isInStandbyState and driver:isInStandbyState() and
                (driver.state == driver.states.DRIVING_TO_STANDBY or
                 driver.state == driver.states.WAITING_FOR_STANDBY_PATHFINDER)) then
            plan.reservations[#plan.reservations + 1] = {owner = driver.vehicle, bay = assignment.parkingBay}
        end
        if clearing and driver.standbyTargetX then
            local boundary = P.getBoundary(driver.vehicle)
            local heading = driver.standbyTargetHeading or CpMathUtil.getNodeDirection(driver.vehicle:getAIDirectionNode())
            local bay = P.makeBay(driver.vehicle, {x = driver.standbyTargetX, z = driver.standbyTargetZ}, heading, boundary, 'CLEARANCE')
            plan.reservations[#plan.reservations + 1] = {owner = driver.vehicle, bay = bay}
        end
        return false
    end}
end

function P.newPlan(previous) return P.run(P.newPlanJob(previous)) end

local function ownVehicle(vehicle, other)
    return vehicle == other or other.getRootVehicle and other:getRootVehicle() == vehicle
end

function P.fruitJob(rig)
    local pi, fi = 1, 1
    return {step = function()
        local part = rig[pi]
        if not part then return true, false end
        local c, si, box = math.cos(part.heading), math.sin(part.heading), part.box
        local x = part.x + c * box.xOffset + si * box.zOffset
        local z = part.z - si * box.xOffset + c * box.zOffset
        if FSDensityMapUtil and g_fruitTypeManager then
            local fruit = g_fruitTypeManager.fruitTypes[fi]
            if not fruit then pi, fi = pi + 1, 1; return false end
            fi = fi + 1
            if fruit.index ~= FruitType.POTATO and fruit.index ~= FruitType.GRASS and fruit.index ~= FruitType.MEADOW then
                local value = FSDensityMapUtil.getFruitArea(fruit.index,
                    x-c*box.width-si*box.length, z+si*box.width-c*box.length,
                    x+c*box.width-si*box.length, z-si*box.width-c*box.length,
                    x-c*box.width+si*box.length, z+si*box.width+c*box.length, true, true)
                if value > 0 then return true, true end
            end
        else
            pi = pi + 1
            local width = 2 * (math.abs(c) * box.width + math.abs(si) * box.length)
            local length = 2 * (math.abs(si) * box.width + math.abs(c) * box.length)
            if PathfinderUtil.hasFruit(x, z, length, width) then return true, true end
        end
        return false
    end}
end

function P.rigHasFruit(rig) return P.run(P.fruitJob(rig)) end

function P.shapesJob(plan, vehicle, rig)
    local index = 1
    return {step = function()
        local part = rig[index]
        if not part then return true, true end
        local detector = plan.detectors[vehicle]
        if not detector then
            detector = PathfinderCollisionDetector(vehicle, {}, {}, false)
            plan.detectors[vehicle] = detector
        end
        if not PathfinderUtil.helperNode then PathfinderUtil.helperNode = CpUtil.createNode('pathfinderHelper', 0, 0, 0) end
        PathfinderUtil.setWorldPositionAndRotationOnTerrain(PathfinderUtil.helperNode, part.x, part.z, part.heading, 0)
        if detector:findCollidingShapes(PathfinderUtil.helperNode, vehicle, part.box) > 0 then return true, false end
        index = index + 1
        return false
    end}
end

function P.rigShapesClear(plan, vehicle, rig) return P.run(P.shapesJob(plan, vehicle, rig)) end

function P.rigClearJob(plan, vehicle, rig, boundary, checkShapes, entering)
    local phase, index, child, sweep = 'boundary', 1, nil, nil
    local function reject(reason) return true, {clear = false, reason = reason} end
    return {step = function()
        if phase == 'boundary' then
            if not entering and FieldworkBoundary.rigOutsideDistance(boundary, rig) > 0 then return reject('field boundary') end
            child, phase = P.fruitJob(rig), 'fruit'
        elseif phase == 'fruit' then
            local done, fruit = P.advance(child)
            if done then
                if fruit then return reject('standing crop') end
                sweep = VehicleRouteConflict.createSweep(rig, poseCourse(rig[1].x, rig[1].z), 1)
                phase, index = 'obstacles', 1
            end
        elseif phase == 'obstacles' then
            local obstacle = plan.obstacles[index]
            if not obstacle then phase, index = 'traffic', 1
            else
                index = index + 1
                if not ownVehicle(vehicle, obstacle.vehicle) and VehicleRouteConflict.findConflict(sweep, obstacle.rig) then
                    return reject('vehicle footprint')
                end
            end
        elseif phase == 'traffic' then
            local traffic = plan.traffic[index]
            if not traffic then phase, index = 'reservations', 1
            else
                index = index + 1
                if not ownVehicle(vehicle, traffic.vehicle) and VehicleRouteConflict.findConflict(traffic.sweep, rig) then
                    return reject('moving vehicle route')
                end
            end
        elseif phase == 'reservations' then
            local reservation = plan.reservations[index]
            if not reservation then
                if not checkShapes then return true, {clear = true} end
                child, phase = P.shapesJob(plan, vehicle, rig), 'shapes'
            else
                index = index + 1
                if reservation.owner ~= vehicle and VehicleRouteConflict.findConflict(reservation.bay.corridor, rig) then
                    return reject('reserved parking lane')
                end
            end
        else
            local done, clear = P.advance(child)
            if done then if not clear then return reject('physical shape') end; return true, {clear = true} end
        end
        return false
    end}
end

function P.rigClear(plan, vehicle, rig, boundary, checkShapes, entering)
    local result = P.run(P.rigClearJob(plan, vehicle, rig, boundary, checkShapes, entering))
    return result.clear, result.reason
end

function P.makeBay(vehicle, waypoint, heading, boundary, kind)
    local rig = P.alignedRig(vehicle, waypoint.x, waypoint.z, heading)
    local length = P.getRigLength(rig)
    local runIn = math.max(8, length)
    local startX, startZ = waypoint.x - math.sin(heading) * runIn, waypoint.z - math.cos(heading) * runIn
    -- In a straight, aligned lane each body's swept area is exactly an elongated oriented rectangle.
    -- Reserve/check that union once instead of hundreds of density/shape probes at 0.25 m intervals.
    local midpoint = (P.departureDistance - runIn) / 2
    local laneRig = P.alignedRig(vehicle, waypoint.x + math.sin(heading) * midpoint,
        waypoint.z + math.cos(heading) * midpoint, heading)
    for _, part in ipairs(laneRig) do part.box.length = part.box.length + (runIn + P.departureDistance) / 2 end
    local corridor = VehicleRouteConflict.createSweep(laneRig, poseCourse(laneRig[1].x, laneRig[1].z), 1)
    return {waypoint = Waypoint({x = waypoint.x, z = waypoint.z, angle = math.deg(heading)}),
        heading = heading, rig = rig, boundary = boundary, corridor = corridor, kind = kind,
        runIn = Waypoint({x = startX, z = startZ, angle = math.deg(heading)}), length = length, laneRig = laneRig}
end

function P.bayClear(plan, vehicle, bay)
    return P.rigClear(plan, vehicle, bay.laneRig, bay.boundary, true)
end

function P.getBayCandidates(vehicle, anchor, assignment)
        local boundary = P.getBoundary(vehicle)
        if not boundary then return end
        local heading = math.rad(anchor.angle or 0)
        local rig = P.alignedRig(vehicle, anchor.x, anchor.z, heading)
        local width = 0
        for _, part in ipairs(rig) do width = math.max(width, 2 * part.box.width) end
        local harvester = assignment.harvester:getCpDriveStrategy()
        if not harvester then return end
        local offset = (harvester:getWorkWidth() + width) / 2 + 3
        local spacing = 2 * P.getRigLength(rig) + P.departureDistance + 8
        local course = harvester:getFieldworkCourse()
        local headland = course and assignment.waypointIx and course.isOnHeadland and course:isOnHeadland(assignment.waypointIx)
        local sides = headland and {offset, -offset, 0} or {0, offset, -offset}
        local x, _, z = getWorldTranslation(vehicle:getAIDirectionNode())
        local currentHeading = CpMathUtil.getNodeDirection(vehicle:getAIDirectionNode())
        local candidates = {}
        for _, along in ipairs({0, -spacing, -2 * spacing}) do
            for _, side in ipairs(sides) do
                for _, h in ipairs({heading, heading + math.pi}) do
                    local target = {x = anchor.x + math.sin(heading) * along + math.cos(heading) * side,
                        z = anchor.z + math.cos(heading) * along - math.sin(heading) * side}
                    local cost = MathUtil.vector2Length(target.x - x, target.z - z) +
                        math.abs(along) + 10 * math.abs(angle(h, currentHeading)) + (headland and side == 0 and 20 or 0)
                    candidates[#candidates + 1] = {target = target, heading = h, cost = cost,
                        order = #candidates + 1, kind = headland and side ~= 0 and 'HEADLAND' or 'ROW'}
                end
            end
        end
        table.sort(candidates, function(a, b)
            if a.cost == b.cost then return a.order < b.order end
            return a.cost < b.cost
        end)
    return candidates, boundary
end

function P.allocateJob(plan, driver, assignment, previous)
    local vehicle, anchor = driver.vehicle, assignment.waypoint
    local phase, child, candidates, boundary, index, candidateBay = 'initial', nil, nil, nil, 1, nil
    local function finish(bay)
        assignment.parkingBay, assignment.waypoint = bay, bay and bay.waypoint or nil
        if bay then plan.reservations[#plan.reservations + 1] = {owner = vehicle, bay = bay} end
        return true
    end
    local function prepare()
        candidates, boundary = P.getBayCandidates(vehicle, anchor, assignment)
        phase = 'candidates'
    end
    local function checkPrevious()
        child = P.rigClearJob(plan, vehicle, previous.parkingBay.laneRig, previous.parkingBay.boundary, true)
        phase = 'previous'
    end
    return {step = function()
        if phase == 'initial' then
            if not anchor or assignment.waitUntilHarvesterPasses then return true end
            local inFlight = previous and previous.harvester == assignment.harvester and driver.isInStandbyState and
                driver:isInStandbyState() and (driver.state == driver.states.DRIVING_TO_STANDBY or
                driver.state == driver.states.WAITING_FOR_STANDBY_PATHFINDER)
            if inFlight then
                assignment.parkingBay, assignment.waypoint = previous.parkingBay, previous.waypoint
                return true
            end
            local canReuse = previous and previous.parkingBay and previous.harvester == assignment.harvester and
                previous.role == assignment.role and not driver.parkingBayFailed
            local sameAnchor = canReuse and (anchor == previous.waypoint or
                MathUtil.vector2Length(anchor.x-previous.waypoint.x, anchor.z-previous.waypoint.z) < 2 and
                math.abs(angle(math.rad(anchor.angle or 0), previous.parkingBay.heading)) < math.rad(12))
            if sameAnchor then checkPrevious()
            elseif canReuse and not assignment.waypointIx then
                local actual = FieldworkBoundary.captureRig(vehicle)
                if P.rigMatchesBay(actual, previous.parkingBay) then
                    child = P.rigClearJob(plan, vehicle, actual, previous.parkingBay.boundary, true)
                    phase = 'arrived'
                else prepare() end
            else prepare() end
        elseif phase == 'arrived' then
            local done, result = P.advance(child)
            if done then if result.clear then checkPrevious() else prepare() end end
        elseif phase == 'previous' then
            local done, result = P.advance(child)
            if done then if result.clear then return finish(previous.parkingBay) else prepare() end end
        elseif phase == 'checkCandidate' then
            local done, result = P.advance(child)
            if done then if result.clear then return finish(candidateBay) end; phase = 'candidates' end
        else
            local candidate = candidates and candidates[index]
            if not candidate then return finish(nil) end
            index = index + 1
            local target, h = candidate.target, candidate.heading
            local failed = driver.parkingBayFailed
            local sameFailed = failed and MathUtil.vector2Length(target.x - failed.waypoint.x,
                target.z - failed.waypoint.z) < 4 and math.abs(angle(h, failed.heading)) < math.rad(15)
            if not sameFailed then
                candidateBay = P.makeBay(vehicle, target, h, boundary, candidate.kind)
                child = P.rigClearJob(plan, vehicle, candidateBay.laneRig, boundary, true)
                phase = 'checkCandidate'
            end
        end
        return false
    end}
end

function P.allocate(plan, driver, assignment, previous) P.run(P.allocateJob(plan, driver, assignment, previous)) end

function P.planJob(order, assignments, previous)
    local child, plan, index = P.newPlanJob(previous), nil, 1
    return {step = function()
        if child then
            local done, result = P.advance(child)
            if done then if not plan then plan = result end; child = nil end
            return false
        end
        local driver = order[index]
        if not driver then return true, assignments end
        index = index + 1
        if (not driver.isAvailableForStaging or driver:isAvailableForStaging()) and
                (not assignments[driver].harvester.getIsCpActive or assignments[driver].harvester:getIsCpActive()) then
            child = P.allocateJob(plan, driver, assignments[driver], previous[driver])
        else assignments[driver] = nil end
        return false
    end}
end

function P.rigMatchesBay(actual, bay)
    if #actual ~= #bay.rig then return false end
    for i, part in ipairs(actual) do
        local target = bay.rig[i]
        if MathUtil.vector2Length(part.x - target.x, part.z - target.z) > 2 or
                math.abs(angle(part.heading, target.heading)) > math.rad(12) then return false end
    end
    return true
end

function P.hasArrived(driver, bay, plan)
    local actual = FieldworkBoundary.captureRig(driver.vehicle)
    if not P.rigMatchesBay(actual, bay) then return false end
    -- Arrival tolerances are not permission for an angled/displaced body to occupy another rig's lane.
    plan = plan or P.newPlan(UnloaderCoordinator and UnloaderCoordinator.assignments)
    return P.rigClear(plan, driver.vehicle, actual, bay.boundary, true)
end

--- Validate the full articulated route against field, crop, physical shapes, moving routes and other bays.
function P.validateCourseJob(driver, course, plan, boundary, bay)
    local function reject(reason)
        if driver.debug then driver:debug('Parking route rejected: %s', reason) end
        return true, false
    end
    local rig = FieldworkBoundary.captureRig(driver.vehicle)
    local outside = FieldworkBoundary.rigOutsideDistance(boundary, rig)
    local ix, segment, child = 2, nil, nil
    return {step = function()
        if child then
            local done, result = P.advance(child)
            if done then if not result.clear then return reject(result.reason) end; child = nil end
            return false
        end
        if ix > course:getNumberOfWaypoints() then
            if outside ~= 0 then return reject('rig remains outside field') end
            if bay and not P.rigMatchesBay(rig, bay) then return reject('rig not aligned with bay') end
            return true, true
        end
        if not segment then
            local x, z, h = rig[1].x, rig[1].z, rig[1].heading
            local gx, _, gz = course:getWaypointPosition(ix)
            local dx, dz = gx - x, gz - z
            local distance = MathUtil.vector2Length(dx, dz)
            if distance <= 0.01 then ix = ix + 1; return false end
            local count = math.ceil(distance / 0.5)
            segment = {x = x, z = z, h = h, dx = dx, dz = dz, distance = distance, progress = 0,
                step = distance / count, refinements = 0, reverse = course.isReverseAt and course:isReverseAt(ix),
                targetHeading = math.atan2(dx, dz) +
                    (course.isReverseAt and course:isReverseAt(ix) and math.pi or 0)}
        end
        local c = segment
        local step = math.min(c.trialStep or c.step, c.distance - c.progress)
        local limit = step / math.max(1, driver.turningRadius)
        local heading = c.h + math.max(-limit, math.min(limit, angle(c.targetHeading, c.h)))
        local previous = {}
        for i, part in ipairs(rig) do previous[i] = {x = part.x, z = part.z, heading = part.heading} end
        local fraction = (c.progress + step) / c.distance
        FieldworkBoundary.advanceRig(rig, c.x + c.dx * fraction, c.z + c.dz * fraction,
            heading, c.reverse and -step or step)
        local nextOutside = FieldworkBoundary.rigOutsideDistance(boundary, rig)
        local swept = {}
        for i, part in ipairs(rig) do
            local old, box = previous[i], part.box
            local radius = MathUtil.vector2Length(box.width + math.abs(box.xOffset), box.length + math.abs(box.zOffset))
            local padding = MathUtil.vector2Length(part.x-old.x, part.z-old.z) +
                radius * math.abs(angle(part.heading, old.heading))
            swept[i] = {x = part.x, z = part.z, heading = part.heading,
                box = {width = box.width + padding, length = box.length + padding,
                    xOffset = box.xOffset, zOffset = box.zOffset}}
        end
        local nextSweptOutside = FieldworkBoundary.rigOutsideDistance(boundary, swept)
        if nextOutside > outside + 0.0001 or nextSweptOutside > outside + 0.0001 then
            -- Padding over-approximates motion on every side. Near an edge, prove a smaller
            -- interval safe rather than accepting protrusion or rejecting a clear parallel route.
            -- Each trial remains one budgeted job step, with at most six refinements per segment.
            local x, z = rig[1].x, rig[1].z
            for i, part in ipairs(rig) do
                part.x, part.z, part.heading = previous[i].x, previous[i].z, previous[i].heading
            end
            if c.refinements < 6 then
                c.trialStep, c.refinements = step / 2, c.refinements + 1
                return false
            end
            local reason = nextOutside > outside + 0.0001 and 'body moving outside field' or
                'swept body moving outside field'
            return reject(string.format('%s at segment %d x %.2f z %.2f (body %.3f m, sweep %.3f m, step %.3f m)',
                reason, ix, x, z, nextOutside, nextSweptOutside, step))
        end
        outside = nextOutside
        c.h, c.progress = heading, c.progress + step
        child = P.rigClearJob(plan, driver.vehicle, swept, boundary, true, true)
        if c.progress >= c.distance - 0.0000001 then ix = ix + 1; segment = nil end
        return false
    end}
end

function P.validateCourse(driver, course, plan, boundary, bay)
    return P.run(P.validateCourseJob(driver, course, plan, boundary, bay))
end

local function prepareApproach(driver, course, bay)
    local ix = course:getNumberOfWaypoints()
    local x, _, z = course:getWaypointPosition(ix)
    -- A stopped combine/obstacle may have entered the lane while searching. Validate the added alignment too.
    local points = {}
    for i = 1, ix do local px, _, pz = course:getWaypointPosition(i); points[#points + 1] = {x = px, z = pz} end
    local length = MathUtil.vector2Length(bay.waypoint.x - x, bay.waypoint.z - z)
    for n = 1, math.max(1, math.ceil(length)) do
        local f = n / math.max(1, math.ceil(length))
        points[#points + 1] = {x = x + (bay.waypoint.x - x) * f, z = z + (bay.waypoint.z - z) * f}
    end
    local completed = Course(driver.vehicle, points, true)
    return completed
end

function P.completeApproachJob(driver, course, bay)
    local phase, child, completed, plan = 'prepare', nil, nil, nil
    return {step = function()
        if phase == 'prepare' then
            completed = prepareApproach(driver, course, bay)
            child, phase = P.newPlanJob(UnloaderCoordinator.assignments), 'plan'
        elseif phase == 'plan' then
            local done, result = P.advance(child)
            if done then
                plan = result
                child, phase = P.validateCourseJob(driver, completed, plan, bay.boundary, bay), 'validate'
            end
        elseif phase == 'validate' then
            local done, valid = P.advance(child)
            if done then
                if not valid then return true end
                child = VehicleRouteConflict.createSweepJob(FieldworkBoundary.captureRig(driver.vehicle), completed, driver.turningRadius)
                phase = 'sweep'
            end
        elseif phase == 'sweep' then
            local done, result = P.advance(child)
            if done then
                completed.parkingOccupancySweep = result
                child, phase = P.newPlanJob(UnloaderCoordinator.assignments), 'fresh'
            end
        elseif phase == 'fresh' then
            local done, result = P.advance(child)
            if done then
                plan = result
                child = P.rigClearJob(plan, driver.vehicle, FieldworkBoundary.captureRig(driver.vehicle), bay.boundary, true, true)
                phase = 'departure'
            end
        elseif phase == 'departure' then
            local done, result = P.advance(child)
            if done then
                if not result.clear then return true end
                child, phase = P.rigClearJob(plan, driver.vehicle, bay.laneRig, bay.boundary, true), 'bay'
            end
        else
            local done, result = P.advance(child)
            if done then
                if result.clear then return true, completed end
                if driver.debug then driver:debug('Parking route rejected: bay occupancy changed during validation') end
                return true
            end
        end
        return false
    end}
end

function P.completeApproach(driver, course, bay) return P.run(P.completeApproachJob(driver, course, bay)) end

function P.simpleApproachJob(driver, bay)
    local child
    return {step = function()
        if child then return P.advance(child) end
        local start = PathfinderUtil.getVehiclePositionAsState3D(driver.vehicle)
        local goal = PathfinderUtil.getWaypointAsState3D(bay.runIn, 0, 0)
        local path, length = PathfinderUtil.findAnalyticPathFromStartToGoal(PathfinderUtil.dubinsSolver, start, goal, driver.turningRadius)
        if not path or length > math.min(80, MathUtil.vector2Length(goal.x - start.x, goal.y - start.y) + 4 * driver.turningRadius) then return true end
        local points = {}
        for _, p in ipairs(path) do points[#points + 1] = {x = p.x, z = -p.y} end
        child = P.completeApproachJob(driver, Course(driver.vehicle, points, true), bay)
        return false
    end}
end

function P.simpleApproach(driver, bay) return P.run(P.simpleApproachJob(driver, bay)) end

-- A paused check is never permission to drive a stale middle section. This final indexed check uses
-- current physical bodies and current imminent routes over the complete accepted course, without native
-- crop/terrain re-probing or a second expensive all-pairs rollout. Call immediately before PPC handover.
function P.liveRouteClear(driver, course, bay)
    local sweep = course.parkingOccupancySweep
    if not sweep then return false end
    local fresh = P.newPlan(UnloaderCoordinator.assignments)
    for _, obstacle in ipairs(fresh.obstacles) do
        if not ownVehicle(driver.vehicle, obstacle.vehicle) and VehicleRouteConflict.findConflict(sweep, obstacle.rig) then return false end
    end
    for _, traffic in ipairs(fresh.traffic) do
        if not ownVehicle(driver.vehicle, traffic.vehicle) and VehicleRouteConflict.findSweepConflict(sweep, traffic.sweep) then return false end
    end
    for _, reservation in ipairs(fresh.reservations) do
        if reservation.owner ~= driver.vehicle and VehicleRouteConflict.findSweepConflict(sweep, reservation.bay.corridor) then return false end
    end
    return true
end
