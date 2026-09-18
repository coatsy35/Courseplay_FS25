--- User-local library; only validated working copies are sent to the server.
ImplementProfileManager = CpObject()

-- XML schema and codecs. Library files and savegames use the same portable profile representation.
function ImplementProfileManager.registerProfileSchema(schema, key)
    schema:register(XMLValueType.STRING, key .. '#id')
    schema:register(XMLValueType.STRING, key .. '#name')
    schema:register(XMLValueType.INT, key .. '#revision')
    for _, field in ipairs({'model', 'configuration', 'mount', 'parent', 'name', 'group'}) do
        schema:register(XMLValueType.STRING, key .. '.equipment.item(?)#' .. field)
    end
    ImplementProfileManager.registerValuesSchema(schema, key .. '.settings')
end

function ImplementProfileManager.registerValuesSchema(schema, key)
    schema:register(XMLValueType.STRING, key .. '.setting(?)#name')
    schema:register(XMLValueType.STRING, key .. '.setting(?)#value')
end

function ImplementProfileManager.registerVehicleSchema(schema, key)
    schema:register(XMLValueType.INT, key .. '#version')
    ImplementProfileManager.registerProfileSchema(schema, key .. '.profile')
    ImplementProfileManager.registerValuesSchema(schema, key .. '.baseline')
end

function ImplementProfileManager.writeValues(xml, key, values)
    local names = {}
    for name in pairs(values) do table.insert(names, name) end
    table.sort(names)
    for i, name in ipairs(names) do
        local entry = string.format('%s.setting(%d)', key, i - 1)
        xml:setValue(entry .. '#name', name)
        xml:setValue(entry .. '#value', tostring(values[name]))
    end
end

function ImplementProfileManager.readValues(xml, key)
    local result, valid, count = {}, true, 0
    xml:iterate(key .. '.setting', function(_, entry)
        count = count + 1
        local name = xml:getValue(entry .. '#name')
        local value = ImplementProfile.decode(xml:getValue(entry .. '#value'))
        if not name or value == nil or result[name] ~= nil then valid = false
        else result[name] = value end
    end)
    return valid and count <= ImplementProfile.MAX_SETTINGS and result or nil
end

function ImplementProfileManager.writeProfile(xml, key, profile)
    xml:setValue(key .. '#id', profile.id)
    xml:setValue(key .. '#name', profile.name)
    xml:setValue(key .. '#revision', profile.revision)
    for i, item in ipairs(profile.equipment) do
        local entry = string.format('%s.equipment.item(%d)', key, i - 1)
        for _, field in ipairs({'model', 'configuration', 'mount', 'parent', 'name', 'group'}) do
            xml:setValue(entry .. '#' .. field, item[field])
        end
    end
    ImplementProfileManager.writeValues(xml, key .. '.settings', profile.settings)
end

function ImplementProfileManager.readProfile(xml, key)
    local profile = {id = xml:getValue(key .. '#id'), name = xml:getValue(key .. '#name'),
        revision = xml:getValue(key .. '#revision'), equipment = {}}
    xml:iterate(key .. '.equipment.item', function(_, entry)
        local item = {}
        for _, field in ipairs({'model', 'configuration', 'mount', 'parent', 'name', 'group'}) do
            item[field] = xml:getValue(entry .. '#' .. field)
        end
        table.insert(profile.equipment, item)
    end)
    profile.settings = ImplementProfileManager.readValues(xml, key .. '.settings')
    return ImplementProfile.valid(profile) and profile.settings and profile or nil
end

-- Library storage and recovery. Validate replacements and keep a backup before changing saved data.
function ImplementProfileManager:init(directory)
    self.path = directory .. 'implementProfiles.xml'
    self.profiles, self.nextId = {}, 1
    self.libraryId = getDate('%Y%m%d%H%M%S') .. '-' .. tostring(math.random(100000, 999999))
    self.schema = XMLSchema.new('ImplementProfiles')
    self.schema:register(XMLValueType.INT, 'ImplementProfiles#version')
    self.schema:register(XMLValueType.STRING, 'ImplementProfiles#libraryId')
    self.schema:register(XMLValueType.INT, 'ImplementProfiles#nextId')
    ImplementProfileManager.registerProfileSchema(self.schema, 'ImplementProfiles.profile(?)')
    self:load()
end

function ImplementProfileManager:readLibrary(path)
    local xml = XMLFile.loadIfExists('implementProfiles', path, self.schema)
    if not xml then return nil end
    if xml:getValue('ImplementProfiles#version') ~= ImplementProfile.VERSION then
        xml:delete()
        return nil, 'version'
    end
    local profiles, valid = {}, true
    local libraryId = xml:getValue('ImplementProfiles#libraryId')
    local nextId = xml:getValue('ImplementProfiles#nextId')
    xml:iterate('ImplementProfiles.profile', function(_, key)
        local profile = ImplementProfileManager.readProfile(xml, key)
        if not profile or profiles[profile.id] then valid = false
        else profiles[profile.id] = profile end
    end)
    xml:delete()
    if not valid or not libraryId or #libraryId == 0 or not nextId or nextId < 1 or nextId >= 2147483647 or nextId % 1 ~= 0 then
        return nil, 'invalid'
    end
    if profiles[libraryId .. '-' .. nextId] then return nil, 'invalid' end
    return {profiles = profiles, libraryId = libraryId, nextId = nextId}
end

function ImplementProfileManager:load()
    if not fileExists(self.path) then return end
    local library, reason = self:readLibrary(self.path)
    if not library then
        -- Never overwrite a newer schema or replace damaged data silently.
        self.readOnly = true
        if reason ~= 'version' then library = self:readLibrary(self.path .. '.bak') end
        Logging.warning('Courseplay: implement profile library is read-only; inspect %s and its backup.', self.path)
    end
    if library then
        self.profiles, self.libraryId, self.nextId = library.profiles, library.libraryId, library.nextId
    end
end

-- Compare parsed data: GIANTS copyFile may succeed without returning a value.
local function equalData(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then
        if type(a) == 'number' then return math.abs(a - b) < 0.000000001 end
        return a == b
    end
    for key, value in pairs(a) do if not equalData(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end

function ImplementProfileManager:persist(profiles, nextId)
    if self.readOnly then return false, 'libraryReadOnly' end
    local temp = self.path .. '.tmp'
    local xml = XMLFile.create('implementProfiles', temp, 'ImplementProfiles', self.schema)
    if not xml then return false, 'saveFailed' end
    xml:setValue('ImplementProfiles#version', ImplementProfile.VERSION)
    xml:setValue('ImplementProfiles#libraryId', self.libraryId)
    xml:setValue('ImplementProfiles#nextId', nextId)
    local ids = {}
    for id in pairs(profiles) do table.insert(ids, id) end
    table.sort(ids)
    for i, id in ipairs(ids) do
        ImplementProfileManager.writeProfile(xml, string.format('ImplementProfiles.profile(%d)', i - 1), profiles[id])
    end
    local saved = xml:save()
    xml:delete()
    if saved == false then return false, 'saveFailed' end
    local expected = {profiles = profiles, libraryId = self.libraryId, nextId = nextId}
    if not equalData(expected, self:readLibrary(temp)) then return false, 'saveFailed' end
    if fileExists(self.path) then
        local previous = self:readLibrary(self.path)
        if not previous then return false, 'saveFailed' end
        copyFile(self.path, self.path .. '.bak', true)
        if not equalData(previous, self:readLibrary(self.path .. '.bak')) then
            Logging.warning('Courseplay: could not verify implement profile backup: %s', self.path)
            return false, 'saveFailed'
        end
    end
    copyFile(temp, self.path, true)
    if not equalData(expected, self:readLibrary(self.path)) then
        Logging.warning('Courseplay: could not verify saved implement profiles: %s', self.path)
        self.readOnly = true
        return false, 'saveFailed'
    end
    self.profiles, self.nextId = profiles, nextId
    return true
end

-- Library editing. Work on copies so failed writes and edits never mutate an applied vehicle setup.
function ImplementProfileManager:save(vehicle, name, existing)
    if not self:canChange(vehicle) then return nil, 'stopFirst' end
    if not g_currentMission.accessHandler:canPlayerAccess(vehicle) then return nil, 'noAccess' end
    name = (name or ''):match('^%s*(.-)%s*$')
    if #name == 0 or #name > 200 or name:find('%c') then return nil, 'invalidName' end
    local equipment = ImplementProfile.describe(vehicle)
    if #equipment == 0 or #equipment > ImplementProfile.MAX_EQUIPMENT then return nil, 'noEquipment' end
    if existing and (not self.profiles[existing.id] or self.profiles[existing.id].revision ~= existing.revision or
        ImplementProfile.match(existing, equipment) ~= 'exact') then return nil, 'mismatch' end
    for _, profile in pairs(self.profiles) do
        if profile.name:lower() == name:lower() and (not existing or profile.id ~= existing.id) and
            ImplementProfile.match(profile, equipment) == 'exact' then return nil, 'duplicateName' end
    end
    local profile = {id = existing and existing.id or (self.libraryId .. '-' .. self.nextId), name = name,
        revision = existing and existing.revision + 1 or 1, equipment = equipment,
        settings = ImplementProfile.capture(vehicle)}
    if not ImplementProfile.valid(profile) then return nil, 'invalidSettings' end
    local profiles = ImplementProfile.copy(self.profiles)
    profiles[profile.id] = profile
    local ok, reason = self:persist(profiles, self.nextId + (existing and 0 or 1))
    return ok and profile or nil, reason
end

--- Edit a library copy independently of any tractor or running job.
function ImplementProfileManager:edit(profile, values)
    local current = self.profiles[profile.id]
    if not current or current.revision ~= profile.revision then return nil, 'mismatch' end
    local definitions = {vehicle = CpVehicleSettings, generator = CpCourseGeneratorSettings}
    for key, value in pairs(values) do
        if current.settings[key] == nil then return nil, 'invalidSettings' end
        local group, name = key:match('^(%w+)%.(%w+)$')
        local setting = definitions[group] and definitions[group][name]
        local allowed = false
        for _, entry in ipairs(ImplementProfile.SETTINGS[group] or {}) do
            if entry == name then allowed = true end
        end
        if not allowed or not setting then return nil, 'invalidSettings' end
        local valid = false
        for _, option in ipairs(setting.values) do
            if option == value or (type(option) == 'number' and type(value) == 'number' and math.abs(option - value) < 0.001) then valid = true end
        end
        if not valid then return nil, 'invalidSettings' end
    end
    for key in pairs(current.settings) do if values[key] == nil then return nil, 'invalidSettings' end end
    local profiles = ImplementProfile.copy(self.profiles)
    local edited = profiles[profile.id]
    edited.settings, edited.revision = ImplementProfile.copy(values), current.revision + 1
    if not ImplementProfile.valid(edited) then return nil, 'invalidSettings' end
    local ok, reason = self:persist(profiles, self.nextId)
    return ok and edited or nil, reason
end

--- Rename library metadata without capturing the current vehicle's settings.
function ImplementProfileManager:rename(profile, name)
    local current = self.profiles[profile.id]
    if not current or current.revision ~= profile.revision then return nil, 'mismatch' end
    name = (name or ''):match('^%s*(.-)%s*$')
    if #name == 0 or #name > 200 or name:find('%c') then return nil, 'invalidName' end
    for id, other in pairs(self.profiles) do
        if id ~= profile.id and other.name:lower() == name:lower() and
            ImplementProfile.match(other, current.equipment) == 'exact' then return nil, 'duplicateName' end
    end
    if name == current.name then return current end
    local profiles = ImplementProfile.copy(self.profiles)
    local renamed = profiles[profile.id]
    renamed.name, renamed.revision = name, current.revision + 1
    if not ImplementProfile.valid(renamed) then return nil, 'invalidSettings' end
    local ok, reason = self:persist(profiles, self.nextId)
    return ok and renamed or nil, reason
end

function ImplementProfileManager:remove(profile)
    if not self.profiles[profile.id] or self.profiles[profile.id].revision ~= profile.revision then return false, 'mismatch' end
    local profiles = ImplementProfile.copy(self.profiles)
    profiles[profile.id] = nil
    return self:persist(profiles, self.nextId)
end

-- Applying profiles. All entry points share stationary, equipment and access checks before changing values.
function ImplementProfileManager:canChange(vehicle)
    return vehicle and vehicle.getCpSettings and not vehicle:getIsAIActive() and
        not vehicle:getIsCpActive() and math.abs(vehicle.lastSpeedReal or 0) < 0.0001 and
        not vehicle.cpProfileRefreshAt
end

function ImplementProfileManager:getMatchingProfiles(vehicle)
    local matches = {}
    local equipment = vehicle and ImplementProfile.describe(vehicle) or {}
    for _, profile in pairs(self.profiles) do
        if ImplementProfile.match(profile, equipment) == 'exact' then table.insert(matches, profile) end
    end
    table.sort(matches, function(a, b)
        if a.name:lower() == b.name:lower() then return a.id < b.id end
        return a.name:lower() < b.name:lower()
    end)
    return matches
end

function ImplementProfileManager:apply(vehicle, profile)
    if not self:canChange(vehicle) then return false, 'stopFirst' end
    if not ImplementProfile.valid(profile) or not profile.settings or ImplementProfile.match(profile, ImplementProfile.describe(vehicle)) ~= 'exact' then
        return false, 'mismatch'
    end
    local valid, key = ImplementProfile.validateSettings(vehicle, profile.settings)
    if not valid then return false, 'invalidSettings', key end
    local previous = vehicle.cpImplementProfile
    local baseline = previous and previous.baseline or ImplementProfile.capture(vehicle)
    ImplementProfile.setSettings(vehicle, profile.settings)
    vehicle.cpImplementProfile = {profile = ImplementProfile.copy(profile), baseline = ImplementProfile.copy(baseline)}
    return true
end

function ImplementProfileManager:requestApply(vehicle, profile)
    if not g_currentMission.accessHandler:canPlayerAccess(vehicle) then return false, 'noAccess' end
    if not self:canChange(vehicle) then return false, 'stopFirst' end
    if ImplementProfile.match(profile, ImplementProfile.describe(vehicle)) ~= 'exact' then return false, 'mismatch' end
    local valid = ImplementProfile.validateSettings(vehicle, profile.settings)
    if not valid then return false, 'invalidSettings' end
    if vehicle.isServer then
        local ok, reason = self:apply(vehicle, profile)
        if ok then ImplementProfileEvent.sendState(vehicle) end
        return ok, reason
    end
    g_client:getServerConnection():sendEvent(ImplementProfileEvent.new(vehicle, profile, true))
    return true
end

--- Apply the user's no-profile policy on the server for the current attachment only.
-- No-profile policy. Reset only portable settings, or restore the last working values as a custom setup.
function ImplementProfileManager:withoutProfile(vehicle, equipment, useDefaults)
    if not self:canChange(vehicle) then return false, 'stopFirst' end
    if equipment ~= ImplementProfile.signature(ImplementProfile.describe(vehicle)) then return false, 'mismatch' end
    if useDefaults then
        for group, names in pairs(ImplementProfile.SETTINGS) do
            local container = ImplementProfile.containers(vehicle)[group]
            for _, name in ipairs(names) do
                if container[name] then container[name]:setDefault(true) end
            end
        end
        CpVehicleSettings.setAutomaticWorkWidthAndOffset(vehicle)
        CpCourseGeneratorSettings.setDefaultTurningRadius(vehicle)
    elseif vehicle.cpProfileLastWorkingSettings then
        ImplementProfile.setSettings(vehicle, vehicle.cpProfileLastWorkingSettings)
    end
    vehicle.cpProfileLastWorkingSettings = nil
    vehicle.cpImplementProfile = nil
    return true
end

function ImplementProfileManager:requestWithoutProfile(vehicle, equipment)
    if not g_currentMission.accessHandler:canPlayerAccess(vehicle) then return false, 'noAccess' end
    local preference = g_Courseplay.globalSettings and g_Courseplay.globalSettings.noImplementProfileSettings
    local defaults = not preference or preference:getValue() == 1
    if vehicle.isServer then
        local ok, reason = self:withoutProfile(vehicle, equipment, defaults)
        if ok then ImplementProfileEvent.sendState(vehicle) end
        return ok, reason
    end
    g_client:getServerConnection():sendEvent(ImplementProfileEvent.new(vehicle, nil, true, nil, equipment, defaults))
    return true
end

-- Attachment invalidation. Restore the baseline, then recalculate geometry for the new combination.
function ImplementProfileManager:clear(vehicle)
    local state = vehicle.cpImplementProfile
    if not state then return end
    ImplementProfile.setSettings(vehicle, state.baseline)
    vehicle.cpImplementProfile = nil
    -- Geometry always comes from the newly attached combination.
    CpVehicleSettings.setAutomaticWorkWidthAndOffset(vehicle)
    CpCourseGeneratorSettings.setDefaultTurningRadius(vehicle)
    for _, name in ipairs({'raiseImplementLate', 'lowerImplementEarly', 'baleCollectorOffset'}) do
        vehicle:getCpSettings()[name]:setDefault(true)
    end
    ImplementProfileEvent.sendState(vehicle)
end

function ImplementProfileManager.markChanged(vehicle, invalidate, attached)
    if vehicle and vehicle.getCpSettings then
        if vehicle.cpImplementProfile and not vehicle.cpProfileRestorePending and not vehicle.cpProfileRefreshAt then
            vehicle.cpImplementProfile.profile.settings = ImplementProfile.capture(vehicle)
            vehicle.cpProfileRestorePending = true
        end
        if invalidate and vehicle.cpProfileInitialised and not vehicle.cpProfileLastWorkingSettings then
            vehicle.cpProfileLastWorkingSettings = ImplementProfile.capture(vehicle)
        end
        vehicle.cpProfileRefreshAt = g_time + 500
        if attached and vehicle.cpProfileInitialised then vehicle.cpProfileOfferPending = true end
        vehicle.cpProfileInvalidated = vehicle.cpProfileInvalidated or (invalidate and vehicle.cpProfileInitialised)
    end
end

-- Savegame persistence. Keep working copies independent of the personal library and its later revisions.
function ImplementProfileManager:loadVehicle(vehicle, savegame, key)
    if not savegame or savegame.resetVehicles then return end
    local xml = savegame.xmlFile
    if xml:getValue(key .. '#version') ~= ImplementProfile.VERSION then return end
    local profile = ImplementProfileManager.readProfile(xml, key .. '.profile')
    local baseline = ImplementProfileManager.readValues(xml, key .. '.baseline')
    if profile and baseline then
        vehicle.cpImplementProfile = {profile = profile, baseline = baseline}
        vehicle.cpProfileRestorePending = true
    end
end

function ImplementProfileManager:saveVehicle(vehicle, xml, key)
    if vehicle.cpImplementProfile then
        local state = vehicle.cpImplementProfile
        xml:setValue(key .. '#version', ImplementProfile.VERSION)
        local profile = ImplementProfile.copy(state.profile)
        -- Preserve local job adjustments even if the library later changes or disappears.
        profile.settings = ImplementProfile.capture(vehicle)
        ImplementProfileManager.writeProfile(xml, key .. '.profile', profile)
        ImplementProfileManager.writeValues(xml, key .. '.baseline', state.baseline)
    end
end

-- Equipment refresh runs after the attachment debounce, separately from user-facing offers.
-- Restore saved working values only when the complete equipment identity still matches.
function ImplementProfileManager:refreshVehicle(vehicle)
    vehicle.cpProfileRefreshAt = nil
    local state = vehicle.cpImplementProfile
    if state then
        if vehicle.cpProfileInvalidated or ImplementProfile.match(state.profile, ImplementProfile.describe(vehicle)) ~= 'exact' then
            if vehicle.isServer then self:clear(vehicle) end
        elseif vehicle.cpProfileRestorePending then
            if ImplementProfile.validateSettings(vehicle, state.profile.settings) then
                ImplementProfile.setSettings(vehicle, state.profile.settings)
                if vehicle.isServer then ImplementProfileEvent.sendState(vehicle) end
            elseif vehicle.isServer then
                self:clear(vehicle)
            end
        end
    end
    vehicle.cpProfileRestorePending = nil
    vehicle.cpProfileInvalidated = nil
end

-- Only new attachments queue offers. Opening a savegame must restore its setup without a prompt.
-- Apply the no-profile policy first so declining a profile uses the chosen defaults/current values.
function ImplementProfileManager:offerAttachedProfiles(vehicle)
    if not vehicle.cpProfileOfferPending or vehicle.cpProfileRefreshAt or vehicle.cpImplementProfile or
        not vehicle.getIsEntered or not vehicle:getIsEntered() or not self:canChange(vehicle) or g_gui:getIsGuiVisible() then return end
    vehicle.cpProfileOfferPending = false
    local equipment = ImplementProfile.signature(ImplementProfile.describe(vehicle))
    if not self:requestWithoutProfile(vehicle, equipment) then return end
    local matches = self:getMatchingProfiles(vehicle)
    local preferences = g_Courseplay.globalSettings
    local suggestions = preferences and preferences.showImplementProfileSuggestions
    local automatic = preferences and preferences.autoLoadSingleImplementProfile
    if #matches > 0 and (not suggestions or suggestions:getValue()) then
        CpImplementProfileDialog.show(matches, function(profile)
            self:loadAttachmentProfile(vehicle, profile, false)
        end, function()
            g_messageCenter:publish(MessageType.GUI_CP_INGAME_OPEN_IMPLEMENT_PROFILES)
        end, function()
            local accepted, reason = self:requestWithoutProfile(vehicle, equipment)
            if not accepted then CpImplementProfileGui.showError(reason) end
        end)
    elseif #matches == 1 and automatic and automatic:getValue() then
        self:loadAttachmentProfile(vehicle, ImplementProfile.copy(matches[1]), true)
    end
end

-- Tick orchestration only: let normal CP attachment callbacks settle before restoring or offering.
function ImplementProfileManager:updateVehicle(vehicle)
    if not vehicle.cpProfileInitialised then
        vehicle.cpProfileInitialised = true
        ImplementProfileManager.markChanged(vehicle)
    end
    if vehicle.cpProfileRefreshAt and g_time >= vehicle.cpProfileRefreshAt then
        if vehicle:getIsAIActive() then return end
        self:refreshVehicle(vehicle)
    end
    self:offerAttachedProfiles(vehicle)
end

--- Recheck a delayed dialogue choice; never apply to a different attachment or occupied job.
function ImplementProfileManager:loadAttachmentProfile(vehicle, profile, silent, courseConfirmed)
    local current = self.profiles[profile.id]
    if not current or current.revision ~= profile.revision or vehicle.cpImplementProfile or
        not vehicle:getIsEntered() or not self:canChange(vehicle) then return end
    if ImplementProfile.match(profile, ImplementProfile.describe(vehicle)) ~= 'exact' then return end
    if not CpImplementProfileGui.confirmCourseWidth(vehicle, profile, courseConfirmed, silent, function()
        self:loadAttachmentProfile(vehicle, profile, false, true)
    end) then return end
    local ok, reason = self:requestApply(vehicle, profile)
    if not ok and not silent then CpImplementProfileGui.showError(reason) end
end
