-- Recorded 3021 entry pose and savegame20 connector WP723 onwards. Production
-- planner/assembly/overlap run in the planar engine fixture: no crop or scenery.
local node=v:getAIDirectionNode()
node.x=-439.48; node.z=-332.51; node.t=math.rad(169)
saved=Course(v,{{x=-424.53,z=-332.70},{x=-425.02,z=-329.99},{x=-426,z=-324.58},
    {x=-426.49,z=-321.87},{x=-426.98,z=-319.17},{x=-427.47,z=-316.46},
    {x=-427.96,z=-313.76},{x=-428.45,z=-311.05},{x=-428.94,z=-308.34},
    {x=-429.92,z=-302.93},{x=-430.41,z=-300.23},{x=-430.90,z=-297.52}},true)
local function heading(x,y)
    return math.atan2(math.sin(math.rad(y)),math.cos(math.rad(x))*math.cos(math.rad(y)))
end
obstacles={
    CpUnloaderQueueGeometry.rectangle({x=-450.783,z=-330.640,heading=heading(178.72,9.78)},
        {width=2.77,length=4.95,zOffset=-.05},0),
    CpUnloaderQueueGeometry.rectangle({x=-451.896,z=-324.105,heading=heading(179.11,9.63)},
        {width=2.62,length=8.36,zOffset=.4},0)}
PathfinderUtil.VehicleData=function(vehicle)
    return {getVehicle=function() return vehicle end,
        getVehicleOverlapBoxParams=function() return {width=8.3,length=6.35,xOffset=0,zOffset=0} end,
        getTowedImplement=function() end}
end
u.connectorEntry={course=saved,context=PathfinderContext(v),node={},zOffset=0,
    nextAttempt=g_time,index=1,candidates={6,10,11},allowForwardLeadIn=true}
