--[[
Headland loop: candidate search
Prepare routes in length order and validate incrementally. Keep the first fully checked solution and configured speeds.
]]

local G = HeadlandLoopGeometry
local heading = G.math.heading

--- Planning needs positions and tangents, not the fieldwork metadata, terrain
--- queries and debug output built by Course for every rejected candidate.
function G.createCandidate(node, pull, path)
    local points = {}
    local segments = math.max(1, math.floor(pull))
    for i = 0, segments do
        local x, _, z = localToWorld(node, 0, 0, pull * i / segments)
        points[#points + 1] = {x = x, z = z}
    end
    for _, p in ipairs(path) do points[#points + 1] = {x = p.x, z = -p.y} end
    local candidate = {waypoints = points}
    function candidate:getNumberOfWaypoints() return #self.waypoints end
    function candidate:getWaypointPosition(ix)
        local p = self.waypoints[ix]
        return p.x, 0, p.z
    end
    function candidate:getWaypointYRotation(ix)
        ix = math.max(1, math.min(ix, #self.waypoints - 1))
        local a, b = self.waypoints[ix], self.waypoints[ix + 1]
        if math.abs(b.x - a.x) + math.abs(b.z - a.z) < .00001 then
            return self:getWaypointYRotation(ix > 1 and ix - 1 or ix + 1)
        end
        return math.atan2(b.x - a.x, b.z - a.z)
    end
    function candidate:getWaypointLocalPosition(reference, ix)
        local x, y, z = self:getWaypointPosition(ix)
        return worldToLocal(reference, x, y, z)
    end
    function candidate:getLength()
        local length = 0
        for ix = 2, #self.waypoints do
            local a, b = self.waypoints[ix - 1], self.waypoints[ix]
            length = length + math.sqrt((a.x - b.x)^2 + (a.z - b.z)^2)
        end
        return length
    end
    function candidate:appendWaypoints(waypoints)
        for _, p in ipairs(waypoints) do self.waypoints[#self.waypoints + 1] = p end
    end
    return candidate
end

--- Continue on the real outgoing headland instead of extending its initial
--- tangent across later bends. Every appended point is validated with the chain.
function G.appendFieldworkReturn(candidate, fieldCourse, startIx, length)
    local travelled = 0
    local px, _, pz = candidate:getWaypointPosition(candidate:getNumberOfWaypoints())
    for ix = startIx, fieldCourse:getNumberOfWaypoints() do
        if fieldCourse:isReverseAt(ix) then return nil end
        local x, _, z = fieldCourse:getWaypointPosition(ix)
        local distance = math.sqrt((x - px)^2 + (z - pz)^2)
        local count = math.max(1, math.ceil(distance))
        for j = 1, count do
            candidate:appendWaypoints({{x=px+(x-px)*j/count,z=pz+(z-pz)*j/count}})
        end
        travelled = travelled + distance
        if travelled >= length then
            candidate.followsFieldwork = true
            return ix
        end
        if fieldCourse:isTurnStartAtIx(ix) then return nil end
        px, pz = x, z
    end
    return nil
end

--- Incremental search. GIANTS does not provide Lua coroutines: retain explicit
--- state and bound both candidate preparation and sampled validation per update.
function G.createSearch(maneuver, model, loweringDistance)
    -- Freeze the search inputs after braking. All candidates use the same
    -- field snapshot and measured chain; a moved chain restarts the search.
    local search = {done = false, phase = 'preparing', candidates = {}, tested = 0, rejected = {}, model = model}
    local steadyRadius = G.minimumRadius(model, maneuver.turningRadius)
    local boundary = G.getBoundary(maneuver.vehicle)
    if not steadyRadius or ((model.internalPivots or 0) > 0 and not boundary) then
        search.done = true
        search.reason = not steadyRadius and 'radius exceeds search limit' or 'field boundary unavailable for internal-pivot loop'
    end
    if boundary and not G.bodyFits(model.bodies[1], model.root, boundary) then
        search.done = true
        search.reason = string.format('tractor starts outside %s boundary at x %.1f z %.1f',
            boundary.source, model.root.x, model.root.z)
    end
    local width = math.max(maneuver.workWidth, model.width)
    local scale, chainLength = 0, 0
    for _, link in ipairs(model.links) do
        scale = scale + link.length
        chainLength = chainLength + link.length - link.hitch
    end
    -- Preserve the radius/entry/pull combinations and their enumeration order.
    -- This refactor must not select a different loop through changed tie order.
    local radii, seenRadius = {}, {}
    local function addRadius(radius)
        local key = math.floor(radius * 100 + 0.5)
        if not seenRadius[key] then radii[#radii + 1], seenRadius[key] = radius, true end
    end
    addRadius(maneuver.turningRadius)
    if steadyRadius then
        for _, factor in ipairs({1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6}) do addRadius(steadyRadius * factor) end
        -- Refine practical radii instead of jumping directly to very large loops.
        for r = maneuver.turningRadius + 2, math.max(steadyRadius * 2, maneuver.turningRadius + 10), 2 do addRadius(r) end
    end
    table.sort(radii)
    local entries, pulls = {}, {0, width / 4, width / 2, width}
    -- The target node belongs to the work area, not the tractor. A rear drill
    -- can still be before that line when the tractor has already crossed it.
    -- Validate the predicted working markers at the actual end of the curve.
    local ahead = math.max(0, -(maneuver.turnContext.frontMarkerDistance or 0) - loweringDistance)
    local seenEntry = {}
    local function addEntry(entry)
        local key = math.floor(entry * 4 + .5)
        if not seenEntry[key] then entries[#entries + 1], seenEntry[key] = entry, true end
    end
    for fraction = 1, 8 do addEntry(-ahead * fraction / 8) end
    for _, factor in ipairs({0, .25, .5, 1, 2, 3}) do addEntry(scale * factor + loweringDistance) end
    local solvers = {}
    for pathType = DubinsSolver.PathType.LSL, DubinsSolver.PathType.LRL do
        solvers[#solvers + 1] = {solver = DubinsSolver({pathType}), name = tostring(pathType)}
    end
    local turnEndNode = maneuver.turnContext:getTurnEndNodeAndOffsets(maneuver.steeringLength)
    -- These poses depend only on pull and entry, not on radius or Dubins word.
    -- Resolve each once rather than repeating thousands of scene-node queries.
    -- DubinsSolver reads its inputs and copies them into each solution.
    local starts, goals = {}, {}
    for i, pull in ipairs(pulls) do
        local x, z, t = PathfinderUtil.getNodePositionAndDirection(maneuver.vehicleDirectionNode, 0, math.max(.5, pull) + .5)
        starts[i] = State3D(x, -z, CpMathUtil.angleFromGame(t))
    end
    for i, entry in ipairs(entries) do
        local x, z, t = PathfinderUtil.getNodePositionAndDirection(turnEndNode, 0, -entry)
        goals[i] = State3D(x, -z, CpMathUtil.angleFromGame(t))
    end
    local gx, _, gz = getWorldTranslation(turnEndNode)
    Logging.info('[CP headland loop] search pose x %.2f z %.2f heading %.2f; target x %.2f z %.2f heading %.2f; boundary %s (%d vertices)',
        model.root.x, model.root.z, math.deg(model.root.t), gx, gz, math.deg(heading(turnEndNode)),
        boundary and boundary.source or 'unavailable', boundary and #boundary.polygon or 0)
    for i, link in ipairs(model.links) do
        local body = model.bodies[i + 1]
        Logging.info('[CP headland loop] link %d: hitch %.2f length %.2f heading %.2f limit %.2f; body left %.2f right %.2f front %.2f back %.2f',
            i, link.hitch, link.length, math.deg(link.heading), math.deg(link.maxArticulation or G.maxArticulation),
            body.left, body.right, body.front, body.back)
    end
    local ri, ei, pi, si, candidateIx = 1, 1, 1, 1, 1
    -- Enumerate a bounded batch per update, then sort once by the existing score.
    -- No validation is skipped to make planning appear faster.
    local function nextDescriptor()
        local radius, entry, pull = radii[ri], entries[ei], math.max(.5, pulls[pi])
        local solver = solvers[si]
        local start, goal = starts[pi], goals[ei]
        local solution = solver.solver:solve(start, goal, radius)
        if solution then
            local length = solution:getLength(radius)
            if length < 100000 then
                search.candidates[#search.candidates + 1] = {solution = solution, start = start, radius = radius,
                    entry = entry, pull = pull, name = solver.name, score = length + pull + entry}
            end
        end
        si = si + 1
        if si > #solvers then si, pi = 1, pi + 1 end
        if pi > #pulls then pi, ei = 1, ei + 1 end
        if ei > #entries then ei, ri = 1, ri + 1 end
        return ri > #radii
    end
    local function reject(detail)
        local category = string.match(detail, '^[^(]+') or detail
        search.rejected[category] = (search.rejected[category] or 0) + 1
        search.lastRejection = detail
        -- Keep the shortest rejected route's location, not a huge loop's edge.
        search.firstRejection = search.firstRejection or detail
    end
    function search:step()
        if self.done then return true, self.course, self.reason end
        -- Preparation and validation share the caller's frame-time budget.
        if self.phase == 'preparing' then
            for _ = 1, 16 do
                if nextDescriptor() then
                    table.sort(self.candidates, function(a, b) return a.score < b.score end)
                    self.phase = 'validating'
                    break
                end
            end
            return false
        end
        if self.validator then
            -- Resume the same sampled trajectory rather than starting its
            -- physics approximation again on each game update.
            local done, ok, detail, returnData = self.validator:step(32)
            if not done then return false end
            self.validator = nil
            if ok then
                -- Only accepted points become a Course with game metadata.
                -- Keep the exact lowering controls and fieldwork return index.
                local points = {}
                for ix = 1, returnData and returnData.endIx or self.pending:getNumberOfWaypoints() do
                    points[#points + 1] = self.pending.waypoints[ix]
                end
                self.pending = Course(maneuver.vehicle, points, true)
                self.pending.temporary = true
                self.pending.followsFieldwork = maneuver.turnContext.loopFieldWorkCourse ~= nil
                for ix = self.entryIx, self.pending:getNumberOfWaypoints() do
                    TurnManeuver.addTurnControlToWaypoint(self.pending.waypoints[ix], TurnManeuver.LOWER_IMPLEMENT_AT_TURN_END, true)
                end
                local x, _, z = self.pending:getWaypointPosition(self.entryIx)
                self.pending.chainReturn = {x = x, z = z, t = heading(maneuver.turnContext.vehicleAtTurnEndNode),
                    lateralTolerance = (returnData and returnData.entryLateral or 0) + .5, model = model, boundary = boundary,
                    fieldCourse = maneuver.turnContext.loopFieldWorkCourse, fieldEndIx = self.fieldEndIx}
                -- Descriptors are ordered by route length, so stop at the first
                -- validated solution. This is a bounded search, not a global optimum.
                self.course = self.pending
                self.reason = string.format('%d pivots (%d internal), width %.1f m, radius %.1f m, entry %.1f m, Dubins %s, peak angle %.1f deg, boundary %s, %d candidates tested',
                    #model.links, model.internalPivots or 0, width, self.option.radius, self.option.entry,
                    self.option.name, math.deg(detail), boundary and boundary.source or 'unavailable', self.tested)
                self.done = true
                return true, self.course, self.reason
            end
            reject(detail)
            self.pending = nil
            return false
        end
        local option = self.candidates[candidateIx]
        if not option then
            self.done = true
            local counts = {}
            for category, count in pairs(self.rejected) do counts[#counts + 1] = string.format('%s=%d', category, count) end
            table.sort(counts)
            self.reason = string.format('no fitting candidate (%d tested; %s); shortest rejected: %s; last: %s',
                self.tested, table.concat(counts, ', '), self.firstRejection or 'none', self.lastRejection or 'none')
            return true, nil, self.reason
        end
        candidateIx = candidateIx + 1
        self.tested = self.tested + 1
        self.option = option
        local path = option.solution:getWaypoints(option.start, option.radius)
        if not path or #path < 2 then reject('empty analytic path'); return false end
        -- Reject obvious excursions before allocating/enriching several Course
        -- copies. Passing this coarse check never accepts a route: the complete
        -- chain, including the tractor, is still sampled at 0.5 m below.
        if boundary then
            local count = math.min(32, #path)
            for j = 1, count do
                local point = path[1 + math.floor((j - 1) * (#path - 1) / (count - 1))]
                local pose = {x = point.x, z = -point.y, t = CpMathUtil.angleToGame(point.t)}
                if not G.bodyFits(model.bodies[1], pose, boundary) then
                    reject(string.format('field boundary (tractor curve, x %.1f z %.1f)', pose.x, pose.z))
                    return false
                end
            end
        end
        -- Append the checked return before validating the complete combination.
        -- The real headland may bend; older callers still supply a straight tail.
        local candidate = G.createCandidate(maneuver.vehicleDirectionNode, option.pull, path)
        self.entryIx = candidate:getNumberOfWaypoints()
        local fieldCourse = maneuver.turnContext.loopFieldWorkCourse
        if fieldCourse then
            self.fieldEndIx = G.appendFieldworkReturn(candidate, fieldCourse, maneuver.turnContext.turnEndWpIx,
                2 * chainLength + math.abs(maneuver.turnContext.frontMarkerDistance or 0))
            if not self.fieldEndIx then reject('insufficient outgoing fieldwork course'); return false end
        else
            self.ending = maneuver.turnContext:appendEndingTurnCourse(candidate, 2 * chainLength)
        end
        self.pending = candidate
        self.validator = G.createValidator(model, candidate, boundary, self.entryIx,
            maneuver.turnContext.vehicleAtTurnEndNode, loweringDistance, maneuver.turnContext.workStartNode)
        return false
    end
    return search
end

--- Synchronous entry point for offline qualification. Runtime uses step().
function G.plan(maneuver, model, loweringDistance)
    local search = G.createSearch(maneuver, model, loweringDistance)
    while true do
        local done, course, reason = search:step()
        if done then return course, reason end
    end
end
