CpFieldUtil = {}
-- force reload
CpFieldUtil.groundTypeModifier = nil

function CpFieldUtil.isNodeOnField(node, fieldId)
    local x, y, z = getWorldTranslation(node)
    local isOnField, _ = FSDensityMapUtil.getFieldDataAtWorldPosition(x, y, z)
    if isOnField and fieldId then
        return fieldId == CpFieldUtil.getFieldIdAtWorldPosition(x, z)
    end
    return isOnField
end

function CpFieldUtil.isNodeOnFieldArea(node)
    local x, _, z = getWorldTranslation(node)
    return CpFieldUtil.isOnFieldArea(x, z)
end

--- Is the relative position dx/dz on the same field as node?
function CpFieldUtil.isOnSameField(node, dx, dy)

end

function CpFieldUtil.isOnField(x, z, fieldId)
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 1, z);
    local isOnField, _ = FSDensityMapUtil.getFieldDataAtWorldPosition(x, y, z)
    if isOnField and fieldId then
        return fieldId == CpFieldUtil.getFieldIdAtWorldPosition(x, z)
    end
    return isOnField
end

--- Find a field position close to a point which may be just outside the field boundary.
---@param x number world X coordinate
---@param z number world Z coordinate
---@param maxDistance number maximum search distance in metres
---@param probeSpacing number|nil approximate distance between probes, defaults to 2 metres
---@return number|nil, number|nil, number|nil field X, field Z and distance from the original point
function CpFieldUtil.findNearbyFieldPosition(x, z, maxDistance, probeSpacing)
    probeSpacing = probeSpacing or 2
    if maxDistance < 0 or probeSpacing <= 0 then
        return nil, nil, nil
    end

    local function isFieldPosition(px, pz)
        if CpFieldUtil.isOnField(px, pz) then
            return true
        end
        -- Custom fields have no Giants density-map field data.
        return g_customFieldManager and g_customFieldManager:getCustomField(px, pz) ~= nil
    end

    if isFieldPosition(x, z) then
        return x, z, 0
    end

    -- Search outwards so the first match is the closest field. Scale the probe
    -- count with each ring to keep approximately probeSpacing metres between probes.
    for radius = probeSpacing, maxDistance, probeSpacing do
        local probeCount = math.max(8, math.ceil(2 * math.pi * radius / probeSpacing))
        for probe = 0, probeCount - 1 do
            local angle = 2 * math.pi * probe / probeCount
            local dx, dz = math.cos(angle), math.sin(angle)
            local px, pz = x + dx * radius, z + dz * radius
            if isFieldPosition(px, pz) then
                -- Prefer a point one probe step farther into the field so boundary
                -- detection does not start on a marginal density-map pixel.
                local insetRadius = math.min(radius + probeSpacing, maxDistance)
                local insetX, insetZ = x + dx * insetRadius, z + dz * insetRadius
                if insetRadius > radius and isFieldPosition(insetX, insetZ) then
                    return insetX, insetZ, insetRadius
                end
                return px, pz, radius
            end
        end
    end
    return nil, nil, nil
end

function CpFieldUtil.initFieldMod()
    local groundTypeMapId, groundTypeFirstChannel, groundTypeNumChannels = g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    CpFieldUtil.groundTypeModifier = DensityMapModifier.new(groundTypeMapId, groundTypeFirstChannel, groundTypeNumChannels,
            g_currentMission.terrainRootNode)
    CpFieldUtil.groundTypeFilter = DensityMapFilter.new(CpFieldUtil.groundTypeModifier)
end

function CpFieldUtil.isOnFieldArea(x, z)
    if CpFieldUtil.groundTypeModifier == nil then
        CpFieldUtil.initFieldMod()
    end
    local w, h = 1, 1
    CpFieldUtil.groundTypeModifier:setParallelogramWorldCoords(x - w / 2, z - h / 2, w, 0, 0, h, DensityCoordType.POINT_VECTOR_VECTOR)
    CpFieldUtil.groundTypeFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
    local density, area, totalArea = CpFieldUtil.groundTypeModifier:executeGet(CpFieldUtil.groundTypeFilter)
    return area > 0, area, totalArea
end

--- Which field this node is on.
---@param node table Giants engine node
---@return number 0 if not on any field, otherwise the number of field, see note on getFieldIdAtWorldPosition()
function CpFieldUtil.getFieldNumUnderNode(node)
    local x, _, z = getWorldTranslation(node)
    return CpFieldUtil.getFieldIdAtWorldPosition(x, z)
end

--- Which field this node is on. See above for more info
function CpFieldUtil.getFieldNumUnderVehicle(vehicle)
    return CpFieldUtil.getFieldNumUnderNode(vehicle.rootNode)
end

--- Returns a field for a position. Looks like in FS25, there is a one-to-one mapping between field and farmland.
function CpFieldUtil.getFieldAtWorldPosition(posX, posZ)
    local farmland = g_farmlandManager:getFarmlandAtWorldPosition(posX, posZ)
    if farmland and farmland:getField() then
        return farmland:getField()
    else
        return nil
    end
end

--- Returns a field ID for a position, 0 if no field ID found
function CpFieldUtil.getFieldIdAtWorldPosition(posX, posZ)
    local field = CpFieldUtil.getFieldAtWorldPosition(posX, posZ)
    return field and field:getId() or 0
end

local xmlFile, fileName, fields, currentField, currentFieldKey

function CpFieldUtil.saveNextField(vehicle)
    currentFieldKey, currentField = next(fields, currentFieldKey)
    if currentField then
        vehicle:cpDetectFieldBoundary(currentField.posX, currentField.posZ, nil, CpFieldUtil.onFieldBoundaryDetectionFinished)
    else
        saveXMLFile(xmlFile);
        delete(xmlFile);
        CpUtil.info('Saved all fields to %s', fileName)
    end
end

function CpFieldUtil.onFieldBoundaryDetectionFinished(vehicle, fieldPolygon, islandPolygons)
    if fieldPolygon then
        local key = ('CPFields.field(%s)'):format(currentFieldKey - 1);
        setXMLInt(xmlFile, key .. '#fieldNum', currentField:getId());
        setXMLInt(xmlFile, key .. '#numPoints', #fieldPolygon);
        for i, point in ipairs(fieldPolygon) do
            setXMLString(xmlFile, key .. ('.point(%s)#pos'):format(i - 1), ('%.2f %.2f'):format(point.x, point.z))
        end
        CpUtil.info('Field %s saved', currentField:getId())
        if islandPolygons then
            for i, islandPolygon in ipairs(islandPolygons) do
                local islandKey = key .. ('.island(%s)'):format(i - 1)
                for j, islandPolygonVertex in ipairs(islandPolygon) do
                    setXMLString(xmlFile, islandKey .. ('.point(%s)#pos'):format(j - 1),
                            ('%.2f %2.f'):format(islandPolygonVertex.x, islandPolygonVertex.z))
                end
            end
        end
    else
        CpUtil.error('Field %s: Could not detect field boundary, not saved', currentField:getId())
    end
    CpFieldUtil.saveNextField(vehicle)
end

function CpFieldUtil.saveAllFields()
    local vehicle = CpUtil.getCurrentVehicle()
    if not vehicle then
        CpUtil.error('Must be in a vehicle to save fields')
        return
    end
    fileName = string.format('%s/%s.xml', g_Courseplay.debugPrintDir, g_currentMission.missionInfo.mapTitle)
    xmlFile = createXMLFile('cpFields', fileName, 'CPFields');
    setXMLString(xmlFile, 'CPFields#version', '2')
    currentFieldKey = nil
    fields = g_fieldManager:getFields()
    if xmlFile and xmlFile ~= 0 then
        CpFieldUtil.saveNextField(vehicle)
    end
end

function CpFieldUtil.initializeFieldMod()
    CpFieldUtil.fieldMod = {}
    CpFieldUtil.fieldMod.modifier = DensityMapModifier:new(g_currentMission.terrainDetailId, g_currentMission.terrainDetailTypeFirstChannel, g_currentMission.terrainDetailTypeNumChannels)
    CpFieldUtil.fieldMod.filter = DensityMapFilter:new(CpFieldUtil.fieldMod.modifier)
end

function CpFieldUtil.isField(x, z, widthX, widthZ)
    if not CpFieldUtil.fieldMod then
        CpFieldUtil.initializeFieldMod()
    end
    widthX = widthX or 0.5
    widthZ = widthZ or 0.5
    local startWorldX, startWorldZ = x, z
    local widthWorldX, widthWorldZ = x - widthX, z - widthZ
    local heightWorldX, heightWorldZ = x + widthX, z + widthZ

    CpFieldUtil.fieldMod.modifier:setParallelogramWorldCoords(startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, 'ppp')
    CpFieldUtil.fieldMod.filter:setValueCompareParams('greater', 0)

    local _, area, totalArea = CpFieldUtil.fieldMod.modifier:executeGet(CpFieldUtil.fieldMod.filter)
    local isField = area > 0
    return isField, area, totalArea
end

--- Get the field polygon vertices from the map. These determine the field boundary in the game's
--- initial state. These do not reflect changes made by terrain modification or plowing, to get a
--- field polygon with those changes, use the FieldScanner
---@return table [{x, y, z}] field polygon vertices
function CpFieldUtil.getFieldPolygon(field)
    local unpackedVertices = field:getDensityMapPolygon():getVerticesList()
    local vertices = {}
    for i = 1, #unpackedVertices, 2 do
        local x, z = unpackedVertices[i], unpackedVertices[i + 1]
        table.insert(vertices, { x = x, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 1, z), z = z })
    end
    return vertices
end

--- Rice fields work differently, just defined by their polygon, no density map, so the scanner
--- wouldn't work
function CpFieldUtil.getRiceFieldPolygon(riceField)
    local boundary = Polygon()
    for i = 1, riceField.polygon:getNumVertices() do
        local x, z = riceField.polygon:getVertex(i)
        boundary:append({ x = x, y = -z })
    end
    boundary:calculateProperties()
    -- for some reason, the rice field boundary is wider than the actual field, so shrink it a bit
    local offsetBoundary = CourseGenerator.Headland(boundary, boundary:isClockwise(), 0, 0.8, false):getPolygon()
    return CpMathUtil.pointsToGameInPlace(offsetBoundary)
end

--- Get the field polygon (field edge vertices) at the world position.
--- If there is also a custom field at the position it may return that, depending on the user's preference set.
---@return {x, y, z}[], boolean the field polygon, nil if not on field. True if a custom field was selected
function CpFieldUtil.getFieldPolygonAtWorldPosition(x, z)
    local fieldPolygon, isCustomField
    local customField = g_customFieldManager:getCustomField(x, z)
    local fieldNum = CpFieldUtil.getFieldIdAtWorldPosition(x, z)
    CpUtil.info('Scanning field %d on %s, prefer custom fields %s',
            fieldNum, g_currentMission.missionInfo.mapTitle, g_Courseplay.globalSettings.preferCustomFields:getValue())
    local mapFieldPolygon = CpFieldUtil.detectFieldBoundary(x, z, true)

    if customField and (not mapFieldPolygon or g_Courseplay.globalSettings.preferCustomFields:getValue()) then
        -- use a custom field if there is one under us and either there's no regular map field or, there is,
        -- but the user prefers custom fields
        CpUtil.info('Custom field found: %s', customField:getName())
        fieldPolygon = customField:getVertices()
        isCustomField = true
    elseif mapFieldPolygon then
        fieldPolygon = mapFieldPolygon
    end
    return fieldPolygon, isCustomField
end

--- Find the boundary of field at position, using either the statically configured map field boundaries or our
--- field scanner.
---@param x number
---@param z number
---@param detect boolean use one of the field boundary detectors. If false, only the static map field boundaries are used.
---@param useGiantsDetector boolean use the Giants field boundary detector. If false, the CP field scanner is used.
---@param vehicle table the vehicle to use for the Giants detector
---@return [{x, z]|nil the field boundary, nil if not on field
function CpFieldUtil.detectFieldBoundary(x, z, detect, useGiantsDetector, vehicle)
    if detect then
        if useGiantsDetector then
            -- implemented in FieldBoundaryDetector
        else
            local valid, points = g_fieldScanner:findContour(x, z)
            return valid and points or nil
        end
    else
        local field = CpFieldUtil.getFieldAtWorldPosition(x, z)
        return field and CpFieldUtil.getFieldPolygon(field) or nil
    end
end

