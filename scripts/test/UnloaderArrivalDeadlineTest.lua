-- Exercise the production dispatcher against CP's configured arrival deadline and native waypoint restrictions.
function CpObject() return {} end
CpDebug = {DBG_UNLOAD_COMBINE = 1}
CpUtil = {getName = function(v) return v.name or 'vehicle' end, debugFormat = function() end}
MathUtil = {vector2Length = function(x, z) return math.sqrt(x*x + z*z) end}
function getWorldTranslation(n) return n.x, 0, n.z end
dofile('scripts/ai/UnloaderCoordinator.lua')
dofile('scripts/ai/strategies/AIDriveStrategyCombineCourse.lua')
dofile('scripts/ai/strategies/AIDriveStrategyUnloadCombine.lua')
local function setting(v) return {getValue = function() return v end} end
local function fixture(ete, remaining, enabled)
    local f = {fill = 60, level = 80, ete = ete, speed = 3.6, safe = true, waiting = false,
        headland = false, firstHeadland = false, fruit = false, fullIn = 200, calls = {}, pocketCalls = 0}
    local course = {
        getCurrentWaypointIx = function() return 1 end,
        getDistanceBetweenWaypoints = function(_, a, b) return math.abs(a-b) end,
        getWaypoint = function(_, ix) return {x = ix, z = 0, ix = ix} end,
        getNextWaypointIxWithinDistance = function(_, ix, distance) return ix+distance end,
        isOnHeadland = function(_, _, number) return number == 1 and f.firstHeadland or f.headland end,
        isTurnStartAtIx = function(_, ix) return f.turnStart == ix end,
        getDistanceToNextTurn = function() return f.distanceToTurn or 500 end,
        getRowLength = function() return 500, 1 end,
        getMultiTools = function() return 1 end,
        getPreviousWaypointIxWithinDistance = function(_, ix, distance) return math.max(1, ix-distance) end,
    }
    local driver = {
        getDistanceAndEteToWaypoint = function(_, waypoint)
            local eta=f.eteByWaypoint and f.eteByWaypoint(waypoint) or f.ete
            return eta*5,eta
        end,
        getDistanceAndEteToVehicle = function() local eta=f.vehicleEte or f.ete; return eta*5,eta end,
        call = function(_, combine, waypoint)
            f.calls[#f.calls+1] = {combine=combine, waypoint=waypoint}; return true
        end,
        callForPocket = function() f.pocketCalls=f.pocketCalls+1; return true end,
    }
    local trailer = {name='trailer', getCpDriveStrategy=function() return driver end}
    local v = {rootNode={x=0,z=0}, getSpeedLimit=function() return f.speed end}
    local c = setmetatable({vehicle=v, course=course, waypointIxWhenCallUnloader=1+remaining,
        settings={callUnloaderPercent=setting(f.level), nearbyStandbyUnloaders=setting(enabled == false and 0 or 1),
            unloadOnFirstHeadland=setting(false)},
        combineController={getFillLevelPercentage=function() return f.fill end},
        timeToCallUnloader={get=function() return true end, set=function(_, value, interval)
            assert(value == false and interval == 3000)
        end},
        unloader={get=function() return f.assigned end}, unloaderToRendezvous={set=function() end},
        debug=function() end, alwaysNeedsUnloader=function() return false end,
        isWaitingForUnload=function() return f.waiting end,
        isPipeInFruitAt=function(_, ix) return f.fruit or f.fruitAfter and ix > f.fruitAfter end,
        getFieldworkCourse=function() return course end, getClosestFieldworkWaypointIx=function() return 1 end,
        getSecondsUntilFull=function() return f.fullIn end,
        findUnloader=function(_, combine, waypoint)
            if not f.unavailable then
                local _,eta
                if combine then _,eta=driver:getDistanceAndEteToVehicle(combine)
                else _,eta=driver:getDistanceAndEteToWaypoint(waypoint) end
                return trailer,eta
            end
        end,
    }, {__index=AIDriveStrategyCombineCourse})
    v.getIsCpActive=function() return true end
    v.getCpDriveStrategy=function() return c end
    v.getCpSettings=function() return c.settings end
    c.getFillLevelPercentage=function() return f.fill end
    f.combine, f.driver, f.trailer, f.course = c, driver, trailer, course
    return f
end
local function dispatch(f) f.combine:callUnloaderWhenNeeded(); return #f.calls end

-- Depart at travel + alignment reserve, rather than first dispatching at 80% or following minutes too soon.
for _, ete in ipairs({10, 50, 150}) do
    local f=fixture(ete, ete+26)
    assert(dispatch(f)==0, 'An early parked trailer must wait until departure is due')
    f.combine.waypointIxWhenCallUnloader=1+ete+25
    assert(dispatch(f)==1 and f.calls[1].waypoint.ix==1+ete+25,
        'Departure must precede the configured unloading level by travel and approach time')
end
local near=fixture(10,300)
assert(dispatch(near)==0, 'A nearby staged trailer must not follow a low-fill combine unnecessarily')
local stock=fixture(10,35,false)
assert(dispatch(stock)==0, 'Disabling the coordinator must preserve stock CP timing')
stock.combine.waypointIxWhenCallUnloader=16
assert(dispatch(stock)==1, 'Stock predictive calls retain the five-second reserve')

-- Different unloading settings drive the same prediction; do not hard-code 80% or 100%.
for _, level in ipairs({50,80,95}) do
    local f=fixture(20,45)
    f.level, f.fill=level,level-10
    f.combine.settings.callUnloaderPercent=setting(level)
    assert(dispatch(f)==1, 'Each configured level is an arrival deadline')
end

-- No guessed active calls without CP's harvest-rate prediction. Real due or stopped calls still work on loading.
local unknown=fixture(200,100)
unknown.combine.waypointIxWhenCallUnloader=nil
assert(dispatch(unknown)==0 and unknown.pocketCalls==0, 'Unknown harvest rate must not start speculative following')
unknown.fill=80
assert(dispatch(unknown)==1, 'An already-due saved worker must call without a rate prediction')
local stopped=fixture(20,200)
stopped.waiting=true; stopped.fill=20; stopped.combine.waypointIxWhenCallUnloader=nil
assert(dispatch(stopped)==1 and stopped.calls[1].waypoint==nil, 'A stopped combine must request immediate pipe approach')
for _, speed in ipairs({0, math.huge, 150}) do
    local f=fixture(100,100); f.speed=speed
    assert(dispatch(f)==0 and f.pocketCalls==0, 'Invalid work speed must not create a predictive rendezvous')
end

-- CP's first-headland and pipe-in-crop restrictions prepare behind, never authorise unsafe parallel unloading.
for _, reason in ipairs({'firstHeadland','fruit'}) do
    local f=fixture(20,46)
    if reason=='fruit' then f.fruit=true else f.headland,f.firstHeadland=true,true end
    assert(dispatch(f)==0 and f.pocketCalls==0, 'Restricted entry must not summon a near trailer too soon')
    f.combine.waypointIxWhenCallUnloader=46
    assert(dispatch(f)==0 and f.pocketCalls==1, 'Restricted entry needs its lead prepared before the configured level')
end
local pocketSaved=fixture(50,100)
pocketSaved.headland,pocketSaved.firstHeadland,pocketSaved.fill=true,true,90
pocketSaved.combine.waypointIxWhenCallUnloader=nil
assert(dispatch(pocketSaved)==0 and pocketSaved.pocketCalls==1, 'A due restricted saved worker needs its pocket lead immediately')
local futurePocket=fixture(90,100)
futurePocket.fruit=true; futurePocket.vehicleEte=5
assert(dispatch(futurePocket)==0 and futurePocket.pocketCalls==1,
    'A nearby current combine must not conceal the longer journey to its predicted pocket area')
local futureNear=fixture(10,100)
futureNear.fruit=true; futureNear.vehicleEte=200
assert(dispatch(futureNear)==0 and futureNear.pocketCalls==0,
    'A long distance to the current pose must not summon a trailer already near the future rendezvous minutes early')

-- A late arrival remains bounded by full tank time, and every shifted point is checked using native restrictions.
local late=fixture(100,10)
late.fullIn=30
assert(dispatch(late)==1 and late.calls[1].waypoint.ix==31, 'Late fallback must not aim beyond tank-full time')
local unsafe=fixture(100,10)
unsafe.fruitAfter=20
assert(dispatch(unsafe)==0 and unsafe.pocketCalls==1, 'A late shifted point in crop must use pocket preparation')
local rerouted=fixture(100,10)
rerouted.eteByWaypoint=function(wp) return wp.ix==101 and 130 or 100 end
assert(dispatch(rerouted)==1 and rerouted.calls[1].waypoint.ix==101,
    'A shifted native rendezvous must be selected and timed against its own target')
local rowEnd=fixture(10,35)
rowEnd.distanceToTurn=5
assert(dispatch(rowEnd)==1 and rowEnd.calls[1].waypoint.ix<36,
    'Native row-end adjustment must keep the rendezvous before the turn')

-- Keep an accepted predictive call rather than repeatedly cancelling progress before its rendezvous is due.
local assigned=fixture(50,75)
assigned.assigned=assigned.driver
local switched=0
assigned.combine.trySwitchToCloserUnloader=function(_, driver)
    assert(driver==assigned.driver); switched=switched+1
end
assert(dispatch(assigned)==0 and switched==0, 'Do not churn an accepted predictive lead before its call level')
assigned.combine.waypointIxWhenCallUnloader=201
dispatch(assigned)
assert(switched==0, 'Do not repeatedly reconsider a lead when ample predicted time remains')
assigned.fill=80
dispatch(assigned)
assert(switched==1, 'An overdue call must retain the existing closer-trailer recovery')

-- Crop-protected parking ahead of the combine rejects staging, but accepts a due checked predictive rear approach.
local ahead=fixture(20,46)
ahead.driver.shouldWaitAtPoolForHarvester=function() return true end
UnloaderCoordinator.assignments[ahead.driver]={harvester=ahead.combine.vehicle,waitUntilHarvesterPasses=true}
assert(not UnloaderCoordinator:canBeCalledBy(ahead.driver,ahead.combine.vehicle),
    'An ahead-of-combine wait must not turn into speculative following')
ahead.combine.waypointIxWhenCallUnloader=46
assert(UnloaderCoordinator:canBeCalledBy(ahead.driver,ahead.combine.vehicle),
    'An ahead-of-combine wait must not delay a predictive actual call until after the unloading level')
ahead.combine.waypointIxWhenCallUnloader=nil
assert(not UnloaderCoordinator:canBeCalledBy(ahead.driver,ahead.combine.vehicle))
ahead.fill=80
assert(UnloaderCoordinator:canBeCalledBy(ahead.driver,ahead.combine.vehicle), 'A due saved call must remain eligible')
UnloaderCoordinator.assignments={}

-- A faster replacement is accepted before releasing the old call; failed approaches retain its search intact.
do
    local f=fixture(20,45)
    f.fill=85
    local current, yielded, cancelled, accepted = nil,0,0,0
    local original={vehicle={name='original'}, getDistanceAndEteToVehicle=function() return 500,100 end,
        getFillLevelPercentage=function() return 0 end}
    current=original
    f.combine.unloader={get=function() return current end, set=function(_, value) current=value end,
        reset=function() current=nil end}
    f.combine.unloaderSwitchEteAdvantage=10
    f.combine.cancelRendezvous=function() cancelled=cancelled+1 end
    original.yieldCallToCloserUnloader=function()
        assert(accepted==1 and current==f.driver, 'Replacement ownership must precede old deregistration')
        yielded=yielded+1
        f.combine:deregisterUnloader(original)
        return true
    end
    f.driver.getFillLevelPercentage=function() return 0 end
    f.fruit=true
    f.driver.callForPocket=function() return false end
    assert(not f.combine:trySwitchToCloserUnloader(original) and current==original and yielded==0 and cancelled==0,
        'A rejected pocket target must not abandon the existing route or registration')
    f.fruit=false
    f.driver.call=function(_, combine, waypoint)
        assert(combine==f.combine.vehicle and waypoint)
        accepted=accepted+1; return true
    end
    assert(f.combine:trySwitchToCloserUnloader(original) and current==f.driver and yielded==1 and cancelled==0,
        'Old deregistration must not cancel the accepted new rendezvous')
    current=original; accepted=0; f.waiting=true
    f.driver.call=function() return false end
    assert(not f.combine:trySwitchToCloserUnloader(original) and current==original and yielded==1,
        'A rejected stopped call must retain the previous owner too')
    f.driver.call=function() return true end
    f.driver.getCombineToUnload=function() return nil end
    assert(not f.combine:trySwitchToCloserUnloader(original) and current==original and yielded==1,
        'A synchronous failed route may release before call returns; it must not evict the old owner')
end

-- No compatible/free trailer is a capacity shortage, not permission to enter with an unsuitable rig.
local shortage=fixture(50,60)
shortage.unavailable=true
assert(dispatch(shortage)==0 and shortage.pocketCalls==0)
shortage.fruit=true
assert(dispatch(shortage)==0 and shortage.pocketCalls==0)
print('Configured unloading arrival deadline, native restrictions and predictive eligibility: OK')
