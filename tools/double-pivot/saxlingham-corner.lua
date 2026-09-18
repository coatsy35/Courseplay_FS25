-- Regression geometry: Saxlingham field07 outline, savegame18 waypoints
-- 475/476, and the 16 September Quadtrac / Seed Hawk / PD 1000 captures.
-- Planar replay, not a claim to reproduce GIANTS dynamics or collision meshes.
function saxlinghamCorner(displacement, mirror)
    displacement, mirror = displacement or 0, mirror or 1
    local polygon = {
        {x=-817.566000,z=-505.082000},
        {x=-814.966630,z=-510.341490},
        {x=-806.582500,z=-522.177800},
        {x=-798.456800,z=-531.474700},
        {x=-777.530300,z=-547.381800},
        {x=-490.205000,z=-547.798800},
        {x=-476.354000,z=-546.457500},
        {x=-461.326000,z=-543.389700},
        {x=-451.154000,z=-538.107700},
        {x=-444.635000,z=-527.717400},
        {x=-442.297000,z=-521.554700},
        {x=-441.577000,z=-514.962160},
        {x=-442.206000,z=-504.177490},
        {x=-481.158000,z=-284.640000},
        {x=-485.970000,z=-277.024000},
        {x=-494.151000,z=-270.735000},
        {x=-500.579000,z=-269.633000},
        {x=-596.022000,z=-281.953000},
        {x=-671.356000,z=-287.601000},
        {x=-770.093200,z=-292.884000},
        {x=-778.047800,z=-293.590000},
        {x=-788.207500,z=-296.911000},
        {x=-792.269500,z=-301.182000},
        {x=-794.783600,z=-307.924000},
        {x=-796.066700,z=-325.003000},
        {x=-799.510200,z=-334.027000},
        {x=-813.773150,z=-353.042000},
        {x=-820.649190,z=-369.436000},
        {x=-820.967060,z=-374.873000},
    }
    for _,p in ipairs(polygon) do p.x=p.x*mirror end
    local v,c,d,cart=fixture({internal=true,field=polygon})
    v.size.width=3.25; v.size.lengthOffset=.600000024
    d.size.lengthOffset=1.019999981
    d.rootNode.z=-3.255859375-6.498657227
    d.joint.node.z=-3.255859375
    d.joint.rootNode={x=0,z=d.rootNode.z+4.365600586,t=0}
    d.joint.lowerRotLimitScale={0,1.2,1}
    cart.rootNode.z=d.rootNode.z-4.471679688-8.083496094
    cart.joint.node.z=cart.rootNode.z+8.083496094
    cart.joint.rootNode.z=cart.rootNode.z+6.081604004
    cart.internalPivotNode.z=cart.rootNode.z+4.306945801
    cart.joint.lowerRotLimitScale={1,1,1}
    v.getAttacherJointDescFromObject=function() return {lowerRotLimit={0,math.rad(65),0},upperRotLimit={0,math.rad(65),0}} end
    d.getAttacherJointDescFromObject=function() return {lowerRotLimit={0,math.rad(40),0},upperRotLimit={0,math.rad(40),0}} end
    d.getAIMarkers=function()
        local function marker(x,z)
            local wx,_,wz=localToWorld(d.rootNode,x,0,z)
            return {x=wx,z=wz,t=d.rootNode.t}
        end
        return marker(12.80001831,1.49041748),marker(-12.79995728,1.490356445),marker(.000030518,-1.412902832)
    end
    local a=math.atan2(3.73,.41)
    local X,Z=-481.85+displacement*math.sin(a),-510.87+displacement*math.cos(a)
    local seen={}
    local function transform(n)
        if not n or seen[n] then return end
        seen[n]=true
        local x,z=n.x,n.z
        n.x=mirror*(X+x*math.cos(a)+z*math.sin(a))
        n.z=Z-x*math.sin(a)+z*math.cos(a)
        n.t=mirror*(a+n.t)
    end
    for _,o in ipairs({v,d,cart}) do
        transform(o.rootNode);transform(o.steeringAxleNode);transform(o.internalPivotNode)
        if o.joint then transform(o.joint.node);transform(o.joint.rootNode) end
        for _,component in ipairs(o.components or {}) do transform(component.node) end
    end
    local t=math.atan2(-.81,5.4)
    c.frontMarkerDistance=-8.3;c.backMarkerDistance=-11.2
    c.workStartNode={x=mirror*(-477.87-13.3*math.sin(t)),z=-510.43-13.3*math.cos(t),t=mirror*t}
    c.vehicleAtTurnEndNode={x=mirror*(-477.87+8.3*math.sin(t)),z=-510.43+8.3*math.cos(t),t=mirror*t}
    c.isLeftTurn=function() return mirror==1 end
    local m=assert(HeadlandLoopGeometry.detect(v))
    return v,c,m
end

-- Actual outgoing headland points from the same saved corner.
function saxlinghamReturn(vehicle)
    return Course(vehicle, {
        {x=-477.87,z=-510.43},
        {x=-478.68,z=-505.03},
        {x=-479.09,z=-502.31},
        {x=-479.50,z=-499.59},
        {x=-479.91,z=-496.87},
        {x=-480.42,z=-493.44},
        {x=-480.74,z=-491.47},
        {x=-481.20,z=-489.10},
        {x=-481.75,z=-486.12},
        {x=-482.24,z=-483.28},
        {x=-482.71,z=-480.65},
        {x=-483.19,z=-477.94},
        {x=-483.68,z=-475.24},
        {x=-484.16,z=-472.53},
        {x=-484.64,z=-469.82},
        {x=-485.13,z=-467.12},
        {x=-486.09,z=-461.70},
        {x=-486.58,z=-458.99},
        {x=-487.06,z=-456.29},
        {x=-487.54,z=-453.58},
        {x=-488.02,z=-450.87},
        {x=-488.51,z=-448.16},
        {x=-488.99,z=-445.46},
        {x=-489.96,z=-440.04},
        {x=-490.44,z=-437.34},
        {x=-490.92,z=-434.63},
        {x=-491.41,z=-431.92},
        {x=-491.89,z=-429.21},
        {x=-492.86,z=-423.80},
        {x=-493.34,z=-421.09},
        {x=-493.82,z=-418.39},
        {x=-494.31,z=-415.68},
    }, false)
end
