--- Shared profile dialogues. Keep presentation here and validation in the profile manager.
CpImplementProfileGui = {}

-- Resolve messages at display time through CP's normal language catalogue.
function CpImplementProfileGui.showError(reason)
    InfoDialog.show(g_i18n:getText('CP_implementProfiles_' .. (reason or 'saveFailed')))
end

--- Save one category for the whole setup, including chains whose shop categories are identical.
-- Offer the actual equipment categories and reusable custom names; never infer a dominant implement.
function CpImplementProfileGui.chooseCategory(equipment, onSelected, preferred)
    local groups, found = {}, {}
    local function add(key)
        if key and not found[key] then table.insert(groups, key); found[key] = true end
    end
    -- Keep the saved choice first so accepting an edit does not accidentally move the profile.
    if preferred and (preferred:match('^shop:.+$') or preferred:match('^custom:.+$')) then add(preferred) end
    for _, key in ipairs(ImplementProfile.directoryGroups(equipment)) do add(key) end
    local custom = {}
    for _, profile in pairs(g_Courseplay.implementProfiles.profiles) do
        if profile.category and profile.category:match('^custom:.+$') then custom[profile.category] = true end
    end
    local names = {}
    for key in pairs(custom) do table.insert(names, key) end
    table.sort(names)
    for _, key in ipairs(names) do add(key) end
    local texts = {}
    for i, key in ipairs(groups) do texts[i] = ImplementProfile.categoryTitle(key) end
    table.insert(texts, g_i18n:getText('CP_implementProfiles_newCategory'))
    OptionDialog.show(function(index)
        if index and groups[index] then
            onSelected(groups[index])
        elseif index == #texts then
            TextInputDialog.show(function(_, name, accepted)
                if not accepted then return end
                local key = ImplementProfile.customCategory(name)
                if not key then CpImplementProfileGui.showError('invalidCategory'); return end
                -- Reuse an existing spelling when the user enters the same category again.
                for _, existing in ipairs(names) do
                    if existing:lower() == key:lower() then key = existing; break end
                end
                onSelected(key)
            end, CpImplementProfileGui, '', g_i18n:getText('CP_implementProfiles_categoryName'),
                g_i18n:getText('CP_implementProfiles_newCategory'), 50)
        end
    end, g_i18n:getText('CP_implementProfiles_categoryTitle'),
        g_i18n:getText('CP_implementProfiles_categoryPrompt'), texts)
end

--- All delayed dialogues must still belong to the same vehicle and complete equipment setup.
-- Each screen supplies its current vehicle and decides what to do after a successful save.
function CpImplementProfileGui.saveNew(getVehicle, titleKey, onSaved)
    local vehicle = getVehicle()
    if not vehicle then return end
    local equipment = ImplementProfile.describe(vehicle)
    local signature = ImplementProfile.signature(equipment)
    local function isCurrent()
        if vehicle == getVehicle() and signature == ImplementProfile.signature(ImplementProfile.describe(vehicle)) then return true end
        CpImplementProfileGui.showError('mismatch')
        return false
    end
    TextInputDialog.show(function(_, name, accepted)
        if not accepted or not isCurrent() then return end
        CpImplementProfileGui.chooseCategory(equipment, function(category)
            if not isCurrent() then return end
            local profile, reason = g_Courseplay.implementProfiles:save(vehicle, name, nil, category)
            if profile then onSaved(profile) else CpImplementProfileGui.showError(reason) end
        end)
    end, CpImplementProfileGui, '', g_i18n:getText('CP_implementProfiles_name'), g_i18n:getText(titleKey), 50)
end

--- Return whether loading may proceed now; confirmation resumes the caller's validation.
-- Silent attachment loading must never replace a course's width without the player's choice.
function CpImplementProfileGui.confirmCourseWidth(vehicle, profile, confirmed, silent, onConfirmed)
    local course = vehicle and vehicle.getFieldWorkCourse and vehicle:getFieldWorkCourse()
    local width = profile.settings['generator.workWidth']
    if confirmed or not course or type(width) ~= 'number' or math.abs((course:getWorkWidth() or 0) - width) <= 0.05 then
        return true
    end
    if not silent then
        YesNoDialog.show(function(_, accepted)
            if accepted then onConfirmed() end
        end, CpImplementProfileGui, g_i18n:getText('CP_implementProfiles_courseWarning'))
    end
    return false
end
