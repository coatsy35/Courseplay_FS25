-- Load CP's offline field generator, including polygon offsets and block splitting.
package.path = package.path .. ';' .. ROOT .. '/scripts/courseGenerator/genetic/?.lua;'
    .. ROOT .. '/scripts/courseGenerator/geometry/?.lua'
local loadedClasses=CourseGenerator
require('CourseGenerator')
for key,value in pairs(loadedClasses) do if CourseGenerator[key]==nil then CourseGenerator[key]=value end end
for _, name in ipairs({'Util','CacheMap','WrapAroundIndex','Vertex','LineSegment','Polyline',
    'Polygon','Intersection','Slider','Field','FieldworkContext','FieldworkCourse',
    'FieldworkCourseHelper','HeadlandConnector','Offset','Row','Block','Headland',
    'CurvedPathHelper','Center','Island','SplineHelper','AnalyticHelper','Genetic','BlockSequencer',
    'FieldworkCourseMultiVehicle','CenterTwoSided','FieldworkCourseTwoSided'}) do
    require(name)
end

function fieldLayout(points,p,islands)
    local boundary={}
    for _, v in ipairs(points) do table.insert(boundary,Vector(v[1],v[2])) end
    local field=CourseGenerator.Field('bench',1,boundary)
    for i,island in ipairs(islands or {}) do
        local polygon=Polygon()
        for _,v in ipairs(island) do polygon:append(Vector(v[1],v[2])) end
        polygon:calculateProperties()
        field:addIsland(CourseGenerator.Island.createFromBoundary(i,polygon))
    end
    local context=CourseGenerator.FieldworkContext(field,p.width,p.generatorRadius,p.headlandRows)
    context:setBypassIslands(p.bypassIslands)
    context.autoRowAngle=p.autoRowAngle
    context.rowAngle=math.rad(p.rowAngle)
    context.overlap=p.headlandOverlap/100
    context.nHeadlandsWithRoundCorners=p.roundHeadlands
    context.headlandFirst=p.headlandFirst
    context.headlandClockwise=p.clockwise
    context.startLocation=Vector(p.fieldWidth*p.startX/100,p.fieldLength*p.startZ/100)
    context:setBaselineEdge(context.startLocation.x,context.startLocation.y)
    context:setUseBaselineEdge(p.useBaseline)
    context:setFieldMargin(p.fieldMargin)
    context:setFieldCornerRadius(7) -- Same preprocessing as CourseGeneratorInterface.
    context:setSharpenCorners(p.sharpenCorners)
    context:setEvenRowDistribution(p.evenRowWidth)
    context:setIslandHeadlands(p.islandHeadlands*p.vehicles)
    context:setIslandHeadlandClockwise(p.islandClockwise)
    context:setNumberOfVehicles(p.vehicles)
    context:setUseSameTurnWidth(p.sameTurnWidth)
    context:setHeadlands(p.headlandRows*p.vehicles)
    if p.rowPattern=='lands' then context.rowPattern=CourseGenerator.RowPatternLands(p.centreClockwise,p.rowsPerLand)
    elseif p.rowPattern=='spiral' then context.rowPattern=CourseGenerator.RowPatternSpiral(p.centreClockwise,p.spiralFromInside)
    elseif p.rowPattern=='racetrack' then context.rowPattern=CourseGenerator.RowPatternRacetrack(p.circles)
    elseif p.rowsToSkip>0 then context.rowPattern=CourseGenerator.RowPatternSkip(p.rowsToSkip,false) end
    local class=p.vehicles>1 and CourseGenerator.FieldworkCourseMultiVehicle or
        (p.narrowField and CourseGenerator.FieldworkCourseTwoSided or CourseGenerator.FieldworkCourse)
    local course=class(context)
    local function vertices(path)
        local result={}
        for _,v in ipairs(path) do table.insert(result,{v.x,v.y}) end
        return result
    end
    local headlands={}
    for _,h in ipairs(course:getHeadlands() or {}) do table.insert(headlands,vertices(h:getPolygon())) end
    local rows={}
    if p.vehicles==1 and course:getCenter() then
        for _,block in ipairs(course:getCenter():getBlocks()) do
            for _,row in ipairs(block:getUnsequencedRows()) do
                table.insert(rows,vertices(row))
            end
        end
    end
    -- Apply the same reversal as FieldworkCourse:reverse(), separately for each
    -- fleet path. Reversing waypoints alone would leave row and pathfinder markers wrong.
    if p.reverseCourse then
        for _,_,path in course:pathIterator() do
            path:reverse()
            for _,v in ipairs(path) do v:getAttributes():_reverse() end
        end
    end
    local routes={}
    for _,position,path in course:pathIterator() do
        local route={}
        for _,v in ipairs(path) do
            local a=v:getAttributes()
            table.insert(route,{x=v.x,z=v.y,headland=a:getHeadlandPassNumber() or 0,
                block=a:_getBlockNumber() or 0,row=a:getRowNumber() or 0,rowStart=a:isRowStart() or false,rowEnd=a:isRowEnd() or false,
                connecting=a:isOnConnectingPath() or a:shouldUsePathfinderToNextWaypoint() or false,
                headlandTurn=a:isHeadlandTurn() or false,island=a:isIslandHeadland() or false,
                islandBypass=a:isIslandBypass() or false})
        end
        table.insert(routes,{position=position,waypoints=route})
    end
    return {path=vertices(course:getPath(p.vehicles>1 and routes[1].position or nil)),
        routes=routes,headlands=headlands,rows=rows,errors=context:getErrors()}
end
