dofile('scripts/CpUtil.lua')

local definitions = {
    MOVING_AWAY_FROM_OTHER_VEHICLE = {denyBackupRequest = true},
}
local first = CpUtil.initStates(nil, definitions)
local second = CpUtil.initStates(nil, definitions)
local combine = {name = 'combine'}
local tractor = {name = 'tractor'}

first.MOVING_AWAY_FROM_OTHER_VEHICLE.properties.vehicle = combine
second.MOVING_AWAY_FROM_OTHER_VEHICLE.properties.vehicle = tractor

assert(first.MOVING_AWAY_FROM_OTHER_VEHICLE.properties.vehicle == combine,
        'A second trailer must not replace the first trailer\'s blocking vehicle')
assert(second.MOVING_AWAY_FROM_OTHER_VEHICLE.properties.vehicle == tractor,
        'Each trailer must retain its own avoidance target')
assert(definitions.MOVING_AWAY_FROM_OTHER_VEHICLE.vehicle == nil,
        'Runtime manoeuvre properties must not mutate the shared state definition')
assert(first.MOVING_AWAY_FROM_OTHER_VEHICLE.properties.denyBackupRequest and
        second.MOVING_AWAY_FROM_OTHER_VEHICLE.properties.denyBackupRequest,
        'Each driver must retain the state configuration')

print('CpUtilStateIsolationTest: OK')
