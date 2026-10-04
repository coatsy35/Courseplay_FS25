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

local function preparationDeadline(combine, current)
    if current and current.transferring and finite(current.transferRate) and
            finite(combine.rate) and combine.rate > 0 and current.transferRate > combine.rate then
        local finish = combine.fill / (current.transferRate-combine.rate)
        if current.fill+current.transferRate*finish < current.capacity then
            -- This tank is covered. Its successor is due for the following tank,
            -- not ahead of a different combine which is currently filling.
            return finish+combine.capacity*combine.callPercent/100/combine.rate
        end
    end
    return CpUnloaderQueuePolicy.deadline(combine)
end

local function candidate(trailer, combine, combines, eta, targetDeadline)
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
    local deadline = targetDeadline or CpUnloaderQueuePolicy.deadline(combine)
    -- A busy trailer must actually be able to meet the next combine's deadline.
    -- At or past the deadline, call an available trailer rather than suppressing it.
    local future = trailer.owner ~= nil or not trailer.available
    if future and (arrival > deadline or free < combine.fill + (combine.rate or 0) * arrival) then
        return nil
    end
    return {trailer = trailer.id, combine = combine.id, arrival = arrival,
        future = future, free = free, expectedFill = expectedFill,
        timely = arrival <= deadline, partial = expectedFill > 0,
        reserved = trailer.reservedFor == combine.id}
end

local function better(a, b)
    if not b then return true end
    if a.timely ~= b.timely then return a.timely end
    -- When both are late, arrival takes precedence over topping up.
    if not a.timely and a.arrival ~= b.arrival then return a.arrival < b.arrival end
    if a.partial ~= b.partial then return a.partial end
    if a.reserved ~= b.reserved and math.abs(a.arrival-b.arrival) <= 5 then return a.reserved end
    if a.arrival ~= b.arrival then return a.arrival < b.arrival end
    return tostring(a.trailer) < tostring(b.trailer)
end

function CpUnloaderQueuePolicy.plan(combines, trailers, eta)
    local byId, byTrailerId, ordered, used = {}, {}, {}, {}
    local plan = {leads = {}, successors = {}, trailers = {}}
    for _, combine in ipairs(combines) do
        byId[combine.id] = combine
        ordered[#ordered + 1] = combine
    end
    for _, trailer in ipairs(trailers) do byTrailerId[trailer.id] = trailer end
    table.sort(ordered, function(a, b)
        local da, db = preparationDeadline(a,byTrailerId[a.owner]), preparationDeadline(b,byTrailerId[b.owner])
        if da ~= db then return da < db end
        if not not a.waiting ~= not not b.waiting then return not not a.waiting end
        if a.fill/a.capacity ~= b.fill/b.capacity then return a.fill/a.capacity > b.fill/b.capacity end
        return tostring(a.id) < tostring(b.id)
    end)
    -- Current native owners are never reassigned. Each can reserve at most one
    -- next combine. Fresh snapshots automatically expire incompatible reservations.
    for _, combine in ipairs(ordered) do
        local current = byTrailerId[combine.owner]
        local projectedFill=current and current.fill+combine.fill
        if current and current.transferring and finite(current.transferRate)
                and current.transferRate>(combine.rate or 0) then
            projectedFill=current.fill+current.transferRate*combine.fill/(current.transferRate-(combine.rate or 0))
        end
        local successor = current and (current.capacity-current.fill < combine.fill or
            (combine.hasMoreWork ~= false and
                projectedFill >= current.capacity*current.departPercent/100))
        if not combine.owner or successor then
            local best
            for _, trailer in ipairs(trailers) do
                if not used[trailer.id] and (not successor or not trailer.owner) then
                    local option = candidate(trailer, combine, byId, eta,
                        successor and preparationDeadline(combine,current) or nil)
                    if option and better(option, best) then best = option end
                end
            end
            if best then
                best.successor = not not successor
                local targets = successor and plan.successors or plan.leads
                targets[combine.id], plan.trailers[best.trailer] = best, best
                used[best.trailer] = true
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
