--- Apply requests carry a portable profile. Only the server broadcasts accepted working state.
ImplementProfileEvent = {}
local ImplementProfileEvent_mt = Class(ImplementProfileEvent, Event)
InitEventClass(ImplementProfileEvent, 'ImplementProfileEvent')

function ImplementProfileEvent.emptyNew()
    return Event.new(ImplementProfileEvent_mt)
end

function ImplementProfileEvent.new(vehicle, profile, request, errorKey, equipment, useDefaults)
    local self = ImplementProfileEvent.emptyNew()
    self.vehicle, self.profile, self.request, self.errorKey = vehicle, profile, request == true, errorKey or ''
    self.equipment, self.useDefaults = equipment, useDefaults
    return self
end

function ImplementProfileEvent.writeValues(streamId, values)
    local names = {}
    for name in pairs(values) do table.insert(names, name) end
    table.sort(names)
    streamWriteUInt8(streamId, #names)
    for _, name in ipairs(names) do
        streamWriteString(streamId, name)
        streamWriteString(streamId, tostring(values[name]))
    end
end

function ImplementProfileEvent.readValues(streamId)
    local values, valid = {}, true
    local count = streamReadUInt8(streamId)
    for _ = 1, count do
        local name = streamReadString(streamId)
        local value = ImplementProfile.decode(streamReadString(streamId))
        if value == nil or values[name] ~= nil then valid = false else values[name] = value end
    end
    return valid and count <= ImplementProfile.MAX_SETTINGS and values or nil
end

function ImplementProfileEvent.writeProfile(streamId, profile)
    streamWriteString(streamId, profile.id)
    streamWriteString(streamId, profile.name)
    streamWriteInt32(streamId, profile.revision)
    streamWriteUInt8(streamId, #profile.equipment)
    for _, item in ipairs(profile.equipment) do
        for _, field in ipairs({'model', 'configuration', 'mount', 'parent', 'name', 'group'}) do
            streamWriteString(streamId, item[field])
        end
    end
    ImplementProfileEvent.writeValues(streamId, profile.settings)
end

function ImplementProfileEvent.readProfile(streamId)
    local profile = {id = streamReadString(streamId), name = streamReadString(streamId),
        revision = streamReadInt32(streamId), equipment = {}}
    for _ = 1, streamReadUInt8(streamId) do
        local item = {}
        for _, field in ipairs({'model', 'configuration', 'mount', 'parent', 'name', 'group'}) do
            item[field] = streamReadString(streamId)
        end
        table.insert(profile.equipment, item)
    end
    profile.settings = ImplementProfileEvent.readValues(streamId)
    return ImplementProfile.valid(profile) and profile.settings and profile or nil
end

function ImplementProfileEvent.writeVehicle(streamId, vehicle)
    ImplementProfileEvent.writeValues(streamId, ImplementProfile.capture(vehicle))
    local state = vehicle.cpImplementProfile
    streamWriteBool(streamId, state ~= nil)
    if state then
        ImplementProfileEvent.writeProfile(streamId, state.profile)
        ImplementProfileEvent.writeValues(streamId, state.baseline)
    end
end

function ImplementProfileEvent.readVehicle(streamId, vehicle)
    local settings = ImplementProfileEvent.readValues(streamId)
    local state
    if streamReadBool(streamId) then
        local profile = ImplementProfileEvent.readProfile(streamId)
        local baseline = ImplementProfileEvent.readValues(streamId)
        if profile and baseline then state = {profile = profile, baseline = baseline} end
    end
    if vehicle and vehicle.getCpSettings and settings then
        ImplementProfile.setSettings(vehicle, settings)
        vehicle.cpImplementProfile = state
        if state then
            state.profile.settings = settings
            -- Defer restoring on a joining client until attachment/load callbacks have finished.
            vehicle.cpProfileRestorePending = not vehicle.cpProfileInitialised
        end
    end
end

function ImplementProfileEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteBool(streamId, self.request)
    if self.request then
        streamWriteBool(streamId, self.equipment ~= nil)
        if self.equipment then
            streamWriteString(streamId, self.equipment)
            streamWriteBool(streamId, self.useDefaults)
        else
            ImplementProfileEvent.writeProfile(streamId, self.profile)
        end
    else
        streamWriteString(streamId, self.errorKey)
        if self.errorKey == '' then ImplementProfileEvent.writeVehicle(streamId, self.vehicle) end
    end
end

function ImplementProfileEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.request = streamReadBool(streamId)
    if self.request then
        if streamReadBool(streamId) then
            self.equipment = streamReadString(streamId)
            self.useDefaults = streamReadBool(streamId)
        else
            self.profile = ImplementProfileEvent.readProfile(streamId)
        end
    else
        self.errorKey = streamReadString(streamId)
        if self.errorKey == '' then
            -- Consume untrusted client state without applying it.
            ImplementProfileEvent.readVehicle(streamId, connection:getIsServer() and self.vehicle or nil)
        end
    end
    self:run(connection)
end

function ImplementProfileEvent:run(connection)
    if connection:getIsServer() then
        if not self.request and self.errorKey ~= '' then
            if self.vehicle then self.vehicle.cpProfileApplyError = self.errorKey end
            InfoDialog.show(g_i18n:getText('CP_implementProfiles_' .. self.errorKey))
        end
        return
    end
    if not self.request or not self.vehicle or not self.vehicle.getCpSettings then return end
    local userId = g_currentMission.userManager:getUserIdByConnection(connection)
    local farm = userId and g_farmManager:getFarmByUserId(userId)
    local reason, ok = 'noAccess', false
    if farm and g_currentMission.accessHandler:canFarmAccess(farm.farmId, self.vehicle) then
        if self.equipment then
            ok, reason = g_Courseplay.implementProfiles:withoutProfile(self.vehicle, self.equipment, self.useDefaults)
        elseif self.profile then ok, reason = g_Courseplay.implementProfiles:apply(self.vehicle, self.profile)
        else reason = 'invalidSettings' end
    end
    if ok then ImplementProfileEvent.sendState(self.vehicle)
    else connection:sendEvent(ImplementProfileEvent.new(self.vehicle, nil, false, reason)) end
end

function ImplementProfileEvent.sendState(vehicle)
    if g_server then g_server:broadcastEvent(ImplementProfileEvent.new(vehicle), nil, nil, vehicle) end
end
