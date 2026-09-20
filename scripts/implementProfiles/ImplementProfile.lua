--- Portable data and matching rules. No vehicle references or map coordinates are persisted.
ImplementProfile = {}
ImplementProfile.VERSION = 1
ImplementProfile.MAX_EQUIPMENT = 32
ImplementProfile.MAX_SETTINGS = 80

-- An explicit allow-list keeps HUD, debug, job positions and tractor geometry out of profiles.
ImplementProfile.SETTINGS = {
    vehicle = {
        'turnOnField', 'allowReversePathfinding', 'allowPathfinderTurns',
        'foldImplementAtEnd', 'raiseImplementLate', 'lowerImplementEarly', 'toolOffsetX',
        'baleCollectorOffset', 'useAdditiveFillUnit', 'refillOnTheField',
        'ridgeMarkersAutomatic', 'sowingMachineFertilizerEnabled', 'optionalSowingMachineEnabled',
        'fieldWorkSpeed', 'turnSpeed', 'reverseSpeed'
    },
    generator = {
        'workWidth', 'numberOfHeadlands', 'startOnHeadland', 'sharpenCorners', 'loopTurnsOnHeadland',
        'headlandsWithRoundCorners', 'headlandClockwise', 'headlandOverlapPercent',
        'centerMode', 'centerClockwise', 'evenRowWidth', 'rowsToSkip', 'numberOfCircles',
        'rowsPerLand', 'spiralFromInside', 'bypassIslands', 'nIslandHeadlands', 'islandHeadlandClockwise'
    }
}
-- Capabilities only decide whether the root vehicle belongs in the equipment identity.
-- They never assign directory categories: tractors must remain interchangeable.
ImplementProfile.WORKING_SPECIALISATIONS = {
    'spec_plow', 'spec_sowingMachine', 'spec_cultivator', 'spec_mower', 'spec_sprayer',
    'spec_baler', 'spec_baleWrapper', 'spec_windrower', 'spec_tedder', 'spec_forageWagon',
    'spec_combine', 'spec_cutter'
}

-- Data helpers and equipment identity. Stable keys allow profiles to move between maps and machines.
function ImplementProfile.copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = ImplementProfile.copy(item) end
    return result
end

--- Move the former vehicle-owned key into the generator group. Migration at
-- persistence and network boundaries leaves one canonical owner internally.
function ImplementProfile.migrateSettings(values)
    if type(values) ~= 'table' then return values end
    local legacy = values['vehicle.loopTurnsOnHeadland']
    if values['generator.loopTurnsOnHeadland'] == nil and legacy ~= nil then
        values['generator.loopTurnsOnHeadland'] = legacy
    end
    values['vehicle.loopTurnsOnHeadland'] = nil
    return values
end

--- Resolve portable saved models against the current shop, including mod and DLC categories.
-- Build once per directory refresh/chooser; do not cache across store reloads or language changes.
function ImplementProfile.shopCategories()
    local catalogue = {}
    for _, item in ipairs(g_storeManager and g_storeManager:getItems() or {}) do
        -- Match Vehicle's clean filename too: DLC paths may not contain their customEnvironment name.
        local model = ImplementProfile.model({configFileName = item.xmlFilename,
            configFileNameClean = Utils.getFilenameInfo(item.xmlFilename, true), customEnvironment = item.customEnvironment})
        local categories = {}
        for _, name in ipairs(item.categoryNames or {item.categoryName}) do
            local category = g_storeManager:getCategoryByName(name)
            if category then categories['shop:' .. category.name] = true end
        end
        catalogue[model] = categories
    end
    return catalogue
end

--- Shop IDs are stable across languages; custom names are user data, never translation keys.
function ImplementProfile.categoryTitle(key)
    local name = key:match('^shop:(.+)$')
    if name then
        local category = g_storeManager and g_storeManager:getCategoryByName(name)
        return category and category.title or name
    end
    return key:match('^custom:(.+)$') or g_i18n:getText('CP_implementProfiles_uncategorised')
end

function ImplementProfile.directoryGroups(equipment, catalogue)
    catalogue = catalogue or ImplementProfile.shopCategories()
    local found, choices = {}, {}
    for _, item in ipairs(equipment) do
        for key in pairs(catalogue[item.model] or {}) do found[key] = true end
    end
    for key in pairs(found) do table.insert(choices, key) end
    table.sort(choices, function(a, b)
        local left, right = ImplementProfile.categoryTitle(a), ImplementProfile.categoryTitle(b)
        return left == right and a < b or left < right
    end)
    return choices
end

--- Legacy chains remain accessible without guessing their owner's preferred category.
-- Choosing a category later changes only library metadata, never equipment matching.
function ImplementProfile.directoryGroup(equipment, preferred, catalogue)
    if preferred and (preferred:match('^shop:.+$') or preferred:match('^custom:.+$')) then return preferred end
    local choices = ImplementProfile.directoryGroups(equipment, catalogue)
    if #equipment == 1 and #choices == 1 then return choices[1] end
    return 'uncategorised'
end

function ImplementProfile.customCategory(name)
    if type(name) ~= 'string' then return nil end
    name = name:match('^%s*(.-)%s*$')
    if name == '' or #name > 200 or name:find('%c') then return nil end
    return 'custom:' .. name
end

local function normalise(path)
    return (path or ''):gsub('\\', '/'):lower()
end

function ImplementProfile.model(object)
    local mod = normalise(object.customEnvironment or 'basegame')
    local path = normalise(object.configFileName or object.configFileNameClean)
    local marker = object.customEnvironment and ('/' .. mod .. '/') or '/data/'
    local start = path:find(marker, 1, true)
    if start then path = path:sub(start + #marker) end
    -- Never retain a machine-specific installation path as an identity.
    if path:match('^%a:') or path:sub(1, 1) == '/' then
        path = normalise(object.configFileNameClean or path:match('[^/]+$'))
    end
    return mod .. ':' .. path
end

function ImplementProfile.configuration(object)
    local values = {}
    for name, value in pairs(object.configurations or {}) do
        -- Appearance has no effect on the working setup. Unknown functional options are retained.
        if name ~= 'color' and name ~= 'baseColor' and name ~= 'designColor' and name ~= 'rimColor' then
            table.insert(values, tostring(name) .. '=' .. tostring(value))
        end
    end
    if object.getVariableWorkWidth then
        local left, _, leftValid = object:getVariableWorkWidth(true)
        local right, _, rightValid = object:getVariableWorkWidth()
        if leftValid and rightValid then
            table.insert(values, string.format('sections=%.3f,%.3f', left, right))
        end
    end
    if object.spec_sprayer and object.getSprayerFillUnitIndex then
        local fillType = object:getFillUnitFillType(object:getSprayerFillUnitIndex())
        local descriptor = g_fillTypeManager:getFillTypeByIndex(fillType)
        -- Fill type names are portable; numeric IDs can change with the installed mods.
        if descriptor then table.insert(values, 'material=' .. descriptor.name) end
    end
    table.sort(values)
    return table.concat(values, ';')
end

local function token(value)
    value = tostring(value or '')
    return #value .. ':' .. value
end

function ImplementProfile.equipmentKey(item)
    return token(item.model) .. token(item.configuration) .. token(item.mount) .. token(item.parent)
end

function ImplementProfile.signature(equipment)
    local keys = {}
    for _, item in ipairs(equipment) do table.insert(keys, ImplementProfile.equipmentKey(item)) end
    table.sort(keys)
    return table.concat(keys, '|')
end

function ImplementProfile.describe(vehicle)
    -- Retain the legacy group field for XML/network compatibility; display categories come from the shop.
    local equipment = {}
    local function visit(parent, parentKey)
        for _, attachment in ipairs(parent:getAttachedImplements()) do
            local object = attachment.object
            local mount = 'rear'
            local joints = parent.spec_attacherJoints and parent.spec_attacherJoints.attacherJoints
            local joint = joints and joints[attachment.jointDescIndex]
            if joint and joint.jointTransform then
                local reference = parent.getAIDirectionNode and parent:getAIDirectionNode() or parent.rootNode
                local _, _, z = localToLocal(joint.jointTransform, reference, 0, 0, 0)
                mount = z > 0 and 'front' or 'rear'
            end
            local item = {
                model = ImplementProfile.model(object), configuration = ImplementProfile.configuration(object),
                mount = mount, parent = parentKey, name = object:getName(), group = ''
            }
            table.insert(equipment, item)
            visit(object, ImplementProfile.equipmentKey(item))
        end
    end
    -- Self-propelled working machines also have an implement identity; ordinary tractors do not.
    local isWorkingMachine = false
    for _, name in ipairs(ImplementProfile.WORKING_SPECIALISATIONS) do
        if vehicle[name] then isWorkingMachine = true; break end
    end
    local rootKey = ''
    if isWorkingMachine then
        local item = {model = ImplementProfile.model(vehicle), configuration = ImplementProfile.configuration(vehicle),
            mount = 'self', parent = '', name = vehicle:getName(), group = ''}
        table.insert(equipment, item)
        rootKey = ImplementProfile.equipmentKey(item)
    end
    visit(vehicle, rootKey)
    return equipment
end

--- Partial matches are discoverable, but cannot be applied as a complete combination.
function ImplementProfile.match(profile, equipment)
    if ImplementProfile.signature(profile.equipment) == ImplementProfile.signature(equipment) then return 'exact' end
    local available = {}
    for _, item in ipairs(equipment) do
        local key = token(item.model) .. token(item.configuration)
        available[key] = (available[key] or 0) + 1
    end
    for _, item in ipairs(profile.equipment) do
        local key = token(item.model) .. token(item.configuration)
        if (available[key] or 0) == 0 then return 'none' end
        available[key] = available[key] - 1
    end
    return #profile.equipment > 0 and 'partial' or 'none'
end

-- Settings ownership. Only allow-listed implement values are captured; tractor preferences stay local.
function ImplementProfile.containers(vehicle)
    return {vehicle = vehicle:getCpSettings(), generator = vehicle:getCourseGeneratorSettings()}
end

--- Vehicle overrides never change the implement defaults captured by the library.
function ImplementProfile.getTiming(settings, name)
    local enabled = settings.raiseImplementLateOverrideEnabled
    local override = settings[name .. 'Override']
    if enabled and override and enabled:getValue() then return override:getValue() end
    return settings[name]:getValue()
end

function ImplementProfile.capture(vehicle)
    local result = {}
    for group, names in pairs(ImplementProfile.SETTINGS) do
        local container = ImplementProfile.containers(vehicle)[group]
        for _, name in ipairs(names) do
            local setting = container[name]
            if setting and not setting:getIsDisabled() then result[group .. '.' .. name] = setting:getValue() end
        end
    end
    return result
end

function ImplementProfile.setting(vehicle, key)
    local group, name = key:match('^(%w+)%.(%w+)$')
    for _, allowed in ipairs(ImplementProfile.SETTINGS[group] or {}) do
        if name == allowed then return ImplementProfile.containers(vehicle)[group][name] end
    end
end

--- Compare saved values, not option indices; vehicle overrides are deliberately separate.
function ImplementProfile.matchesSettings(vehicle, profile)
    for key, saved in pairs(profile.settings) do
        local setting = ImplementProfile.setting(vehicle, key)
        if not setting then return false end
        local current = setting:getValue()
        if current ~= saved and not (type(current) == 'number' and type(saved) == 'number' and
            math.abs(current - saved) < 0.001) then return false end
    end
    return true
end

-- Persistence validation. Reject invalid values before they can reach a setting or cross the network.
function ImplementProfile.decode(value)
    if value == 'true' then return true end
    if value == 'false' then return false end
    local number = tonumber(value)
    if number and number == number and math.abs(number) < math.huge then return number end
end

--- Validate every value before changing anything. Numerical values are persisted, never option indices.
function ImplementProfile.validateSettings(vehicle, values)
    local count = 0
    for key, value in pairs(values) do
        count = count + 1
        local setting = ImplementProfile.setting(vehicle, key)
        if not setting then return false, key end
        if setting:getIsDisabled() and setting:getValue() ~= value then
            -- A profile may enable the prerequisite in the same transaction. Validation
            -- must use the complete target state rather than table iteration order.
            local enablesRoundedHeadland = key == 'generator.loopTurnsOnHeadland' and value == true and
                (values['generator.headlandsWithRoundCorners'] or 0) >= 1
            if not enablesRoundedHeadland then return false, key end
        end
        local valid = false
        for _, option in ipairs(setting.values) do
            if option == value or (type(option) == 'number' and type(value) == 'number' and
                math.abs(option - value) < 0.001) then valid = true; break end
        end
        if not valid then return false, key end
    end
    return count > 0 and count <= ImplementProfile.MAX_SETTINGS
end

function ImplementProfile.setSettings(vehicle, values)
    for key, value in pairs(values) do
        local setting = ImplementProfile.setting(vehicle, key)
        if setting then
            if type(value) == 'boolean' then setting:setValue(value, true)
            else setting:setFloatValue(value, 0.002, true) end
        end
    end
    local generator = vehicle:getCourseGeneratorSettings()
    if generator.headlandsWithRoundCorners and generator.headlandsWithRoundCorners:getValue() < 1 then
        generator.loopTurnsOnHeadland:setValue(false, true)
    end
end

function ImplementProfile.valid(profile)
    if type(profile) ~= 'table' or type(profile.equipment) ~= 'table' or type(profile.settings) ~= 'table' then return false end
    if type(profile.id) ~= 'string' or #profile.id == 0 or #profile.id > 100 or
        type(profile.name) ~= 'string' or #profile.name == 0 or #profile.name > 200 or
        type(profile.revision) ~= 'number' or profile.revision < 1 or profile.revision >= 2147483647 or profile.revision % 1 ~= 0 or
        #profile.equipment == 0 or #profile.equipment > ImplementProfile.MAX_EQUIPMENT then return false end
    for _, item in ipairs(profile.equipment) do
        if type(item) ~= 'table' then return false end
        for _, field in ipairs({'model', 'configuration', 'mount', 'parent', 'name', 'group'}) do
            if type(item[field]) ~= 'string' or #item[field] > 8192 then return false end
        end
    end
    -- Permit old category keys and temporarily unavailable shop entries so existing libraries still load.
    local category = profile.category
    if category ~= nil then
        if type(category) ~= 'string' or #category == 0 or #category > 207 or category:find('%c') then return false end
        if category:sub(1, 7) == 'custom:' and ImplementProfile.customCategory(category:sub(8)) ~= category then return false end
        if category == 'shop:' then return false end
    end
    local count = 0
    for key, value in pairs(profile.settings) do
        count = count + 1
        if type(key) ~= 'string' or #key > 100 or (type(value) ~= 'boolean' and type(value) ~= 'number') then return false end
        if type(value) == 'number' and (value ~= value or math.abs(value) == math.huge) then return false end
    end
    if count == 0 or count > ImplementProfile.MAX_SETTINGS then return false end
    return true
end
