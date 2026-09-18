--- Shared profile dialogues. Keep presentation here and validation in the profile manager.
CpImplementProfileGui = {}

-- Resolve messages at display time through CP's normal language catalogue.
function CpImplementProfileGui.showError(reason)
    InfoDialog.show(g_i18n:getText('CP_implementProfiles_' .. (reason or 'saveFailed')))
end

--- A delayed naming dialogue must still belong to the same vehicle and equipment.
-- Each screen supplies its current vehicle and decides what to do after a successful save.
function CpImplementProfileGui.saveNew(getVehicle, titleKey, onSaved)
    local vehicle = getVehicle()
    if not vehicle then return end
    local equipment = ImplementProfile.signature(ImplementProfile.describe(vehicle))
    TextInputDialog.show(function(_, name, accepted)
        if not accepted then return end
        if vehicle ~= getVehicle() or equipment ~= ImplementProfile.signature(ImplementProfile.describe(vehicle)) then
            CpImplementProfileGui.showError('mismatch')
            return
        end
        local profile, reason = g_Courseplay.implementProfiles:save(vehicle, name)
        if profile then onSaved(profile) else CpImplementProfileGui.showError(reason) end
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
