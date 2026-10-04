-- Queue decisions only. Native CP owns calls, approaches and unloading.
-- Inputs are a fresh, read-only snapshot; no engine objects are retained.
CpUnloaderQueuePolicy = {}

local function finite(value)
    return type(value) == 'number' and value == value and value < math.huge and value >= 0
end

function CpUnloaderQueuePolicy.deadline(combine)
    if combine.waiting or combine.fill >= combine.capacity * combine.callPercent / 100 then
        return 0
    end
    if finite(combine.rate) and combine.rate > 0 then
        return (combine.capacity * combine.callPercent / 100 - combine.fill) / combine.rate
    end
    -- Unknown fill rate is a reason to prepare now, never to wait indefinitely.
    return 0
end

-- Forecast the current transfer to completion. A trailer's departure threshold
-- applies after unloading; physical capacity can end the transfer earlier.
function CpUnloaderQueuePolicy.remainingAfterTransfer(trailer, combines)
    local current = combines[trailer.owner]
    if not current or not trailer.transferring or not finite(trailer.transferRate)
            or trailer.transferRate <= (current.rate or 0) then
        return nil
    end
    local finish = current.fill / (trailer.transferRate - (current.rate or 0))
    local expectedFill = trailer.fill + finish * trailer.transferRate
    if expectedFill >= trailer.capacity * trailer.departPercent / 100 then
        return nil
    end
    return trailer.capacity - expectedFill, finish, expectedFill
end

local function candidate(trailer, combine, combines, eta)
    if not trailer.enabled or trailer.failed or not trailer.compatible[combine.id]
            or trailer.capacity <= 0 or trailer.fill >= trailer.capacity * trailer.departPercent / 100 then
        return nil
    end
    local free, finish, expectedFill = trailer.capacity - trailer.fill, 0, trailer.fill
    if trailer.owner then
        free, finish, expectedFill = CpUnloaderQueuePolicy.remainingAfterTransfer(trailer, combines)
        if not free or trailer.owner == combine.id then
            return nil
        end
    elseif not trailer.available then
        -- Native reverse clearance still owns it. Only an existing reservation
        -- with a measured, bounded release estimate may survive this interval.
        if trailer.reservedFor ~= combine.id or not finite(trailer.releaseIn) then return nil end
        finish = trailer.releaseIn
    end
    local travel = eta(trailer, combine)
    if not finite(travel) then
        return nil
    end
    local arrival = finish + travel
    local deadline = CpUnloaderQueuePolicy.deadline(combine)
    -- A busy trailer must actually be able to meet the next combine's deadline.
    -- At or past the deadline, call an available trailer rather than suppressing it.
    local future = trailer.owner ~= nil or not trailer.available
    if future and (arrival > deadline or free < combine.fill + (combine.rate or 0) * arrival) then
        return nil
    end
    return {trailer = trailer.id, combine = combine.id, arrival = arrival,
        future = future, free = free, expectedFill = expectedFill,
        timely = arrival <= deadline, partial = expectedFill > 0}
end

local function better(a, b)
    if not b then return true end
    if a.timely ~= b.timely then return a.timely end
    -- When both are late, arrival takes precedence over topping up.
    if not a.timely and a.arrival ~= b.arrival then return a.arrival < b.arrival end
    if a.partial ~= b.partial then return a.partial end
    if a.arrival ~= b.arrival then return a.arrival < b.arrival end
    return tostring(a.trailer) < tostring(b.trailer)
end

function CpUnloaderQueuePolicy.plan(combines, trailers, eta)
    local byId, ordered, used = {}, {}, {}
    local plan = {leads = {}, successors = {}, trailers = {}}
    for _, combine in ipairs(combines) do
        byId[combine.id] = combine
        ordered[#ordered + 1] = combine
    end
    table.sort(ordered, function(a, b)
        local da, db = CpUnloaderQueuePolicy.deadline(a), CpUnloaderQueuePolicy.deadline(b)
        if da ~= db then return da < db end
        return tostring(a.id) < tostring(b.id)
    end)
    -- Current native owners are never reassigned. Each can reserve at most one
    -- next combine. Fresh snapshots automatically expire incompatible reservations.
    for _, combine in ipairs(ordered) do
        if not combine.owner then
            local best
            for _, trailer in ipairs(trailers) do
                if not used[trailer.id] then
                    local option = candidate(trailer, combine, byId, eta)
                    if option and better(option, best) then best = option end
                end
            end
            if best then
                plan.leads[combine.id], plan.trailers[best.trailer] = best, best
                used[best.trailer] = true
            end
        end
    end
    -- Prepare a successor if the current trailer cannot finish the tank, or is
    -- approaching departure. A successor is preparation, not a second native call.
    for _, combine in ipairs(ordered) do
        if combine.owner then
            local current
            for _, trailer in ipairs(trailers) do
                if trailer.id == combine.owner then current = trailer; break end
            end
            if current and (current.capacity - current.fill < combine.fill or
                    current.fill + combine.fill >= current.capacity * current.departPercent / 100) then
                local best
                for _, trailer in ipairs(trailers) do
                    if not used[trailer.id] and not trailer.owner then
                        local option = candidate(trailer, combine, byId, eta)
                        if option and better(option, best) then best = option end
                    end
                end
                if best then
                    best.successor = true
                    plan.successors[combine.id], plan.trailers[best.trailer] = best, best
                    used[best.trailer] = true
                end
            end
        end
    end
    for _, trailer in ipairs(trailers) do
        if trailer.enabled and trailer.available and not trailer.owner and not used[trailer.id] then
            plan.trailers[trailer.id] = {trailer = trailer.id, pool = true}
        end
    end
    return plan
end

-- Preparation closes progressively, but preserves space for native CP's 25 m
-- moving-rendezvous admission check and the full tractor/trailer train.
function CpUnloaderQueuePolicy.lag(combine, rigLength, approachSeconds, speed)
    local minimum = math.max(35, rigLength + 12)
    local spare = math.max(0, CpUnloaderQueuePolicy.deadline(combine) - approachSeconds)
    return minimum + math.min(100, spare * math.max(0, speed) * 0.35)
end
