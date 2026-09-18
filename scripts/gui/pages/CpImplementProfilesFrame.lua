CpImplementProfilesFrame = {}
local CpImplementProfilesFrame_mt = Class(CpImplementProfilesFrame, TabbedMenuFrameElement)

-- Page lifecycle and focus. Reuse CP menu controls while keeping library selection local to this page.
function CpImplementProfilesFrame.new(target, customMt)
    local self = TabbedMenuFrameElement.new(target, customMt or CpImplementProfilesFrame_mt)
    self.expanded, self.rows, self.details = {}, {}, {}
    self.attachedOnly = true
    return self
end

function CpImplementProfilesFrame.setupGui()
    g_gui:loadGui(Utils.getFilename('config/gui/pages/ImplementProfilesFrame.xml', Courseplay.BASE_DIRECTORY),
        'CpImplementProfilesFrame', CpImplementProfilesFrame.new(), true)
end

function CpImplementProfilesFrame.createFromExistingGui(gui, guiName)
    g_gui.frames[gui.name].target:delete()
    g_gui.frames[gui.name]:delete()
    g_gui:loadGui(gui.xmlFilename, guiName, CpImplementProfilesFrame.new(), true)
end

function CpImplementProfilesFrame:initialize(menu)
    self.cpMenu = menu
    self.profileList:setDataSource(self)
    self.detailList:setDataSource(self)
    -- Keep list navigation, but let the native editor alone show focus in edit mode.
    self.detailList.applyElementSelection = function(list)
        if self.editDraft then
            list:clearElementSelection()
        else
            SmoothListElement.applyElementSelection(list)
        end
    end
end

function CpImplementProfilesFrame:onFrameOpen()
    self:superClass().onFrameOpen(self)
    self.vehicle = self.cpMenu:getCurrentVehicle()
    self.attachedOnly = self.vehicle ~= nil
    self.expanded = {}
    self.selectActiveOnRefresh = true
    self.equipmentFilter:setTexts({g_i18n:getText('CP_implementProfiles_attached'),
        g_i18n:getText('CP_implementProfiles_allEquipment')})
    self.equipmentFilter:setState(self.attachedOnly and 1 or 2)
    FocusManager:loadElementFromCustomValues(self.profileList)
    FocusManager:loadElementFromCustomValues(self.detailList)
    FocusManager:linkElements(self.profileList, FocusManager.RIGHT, self.detailList)
    FocusManager:linkElements(self.detailList, FocusManager.LEFT, self.profileList)
    self:refresh()
    FocusManager:setFocus(self.profileList)
end

-- Directory model. A combination can have several tree links, all referring to the same saved profile.
function CpImplementProfilesFrame:buildGroups()
    local manager = g_Courseplay.implementProfiles
    local groups = {}
    for _, profile in pairs(manager.profiles) do
        local match = ImplementProfile.match(profile, self.equipment)
        local equipmentNames = {}
        for _, item in ipairs(profile.equipment) do table.insert(equipmentNames, item.name) end
        table.sort(equipmentNames)
        local modelName = table.concat(equipmentNames, ' + ')
        if not self.attachedOnly or match ~= 'none' then
            -- Configuration variants stay together under their model/combination name.
            local models = {}
            for _, item in ipairs(profile.equipment) do table.insert(models, item.model) end
            table.sort(models)
            local modelKey = table.concat(models, '|')
            local categories = {}
            if #profile.equipment > 1 then categories.combinations = true end
            for _, item in ipairs(profile.equipment) do categories[item.group] = true end
            -- Multiple directory links refer to the same profile ID, never duplicate saved data.
            for group in pairs(categories) do
                groups[group] = groups[group] or {title = g_i18n:getText('CP_implementProfiles_group_' .. group), models = {}, count = 0}
                local category = groups[group]
                category.models[modelKey] = category.models[modelKey] or {title = modelName, profiles = {}}
                table.insert(category.models[modelKey].profiles, {profile = profile, match = match})
                category.count = category.count + 1
            end
        end
    end
    return groups
end

-- Flatten only expanded groups for the native list; saved profiles themselves remain untouched.
function CpImplementProfilesFrame:buildRows(groups)
    local keys = {}
    for key in pairs(groups) do table.insert(keys, key) end
    table.sort(keys, function(a, b) return groups[a].title < groups[b].title end)
    self.rows = {}
    for _, key in ipairs(keys) do
        local category = groups[key]
        local opened = self.expanded[key]
        if opened == nil then opened = self.attachedOnly end
        table.insert(self.rows, {key = key, title = string.format('%s %s (%d)', opened and '-' or '+', category.title, category.count)})
        if opened then
            local models = {}
            for model in pairs(category.models) do table.insert(models, model) end
            table.sort(models, function(a, b) return category.models[a].title < category.models[b].title end)
            for _, model in ipairs(models) do
                local entry = category.models[model]
                local modelKey = key .. '/' .. model
                local modelOpened = self.expanded[modelKey]
                if modelOpened == nil then modelOpened = self.attachedOnly end
                table.insert(self.rows, {key = modelKey, title = '    ' .. (modelOpened and '- ' or '+ ') .. entry.title})
                if modelOpened then
                    table.sort(entry.profiles, function(a, b)
                        if a.match ~= b.match then return a.match == 'exact' or (a.match == 'partial' and b.match == 'none') end
                        if a.profile.name == b.profile.name then return a.profile.id < b.profile.id end
                        return a.profile.name:lower() < b.profile.name:lower()
                    end)
                    for _, row in ipairs(entry.profiles) do
                        row.title = '        ' .. row.profile.name
                        table.insert(self.rows, row)
                    end
                end
            end
        end
    end
end

-- Rebuild after library changes and restore the active selection when opening the page.
function CpImplementProfilesFrame:refresh()
    self.equipment = self.vehicle and ImplementProfile.describe(self.vehicle) or {}
    self:buildRows(self:buildGroups())
    self.emptyText:setVisible(#self.rows == 0)
    self.profileList:reloadData()
    if self.selectActiveOnRefresh then
        self.selectActiveOnRefresh = false
        local active = self.vehicle and self.vehicle.cpImplementProfile and self.vehicle.cpImplementProfile.profile
        for index, row in ipairs(self.rows) do
            if row.profile and active and row.profile.id == active.id then
                self.profileList:setSelectedItem(1, index)
                break
            end
        end
    end
    self:updateDetails()
end

-- List interaction. Let the list handle scrolling and individual native controls handle value changes.
function CpImplementProfilesFrame:getSelectedRow()
    return self.rows[self.profileList:getSelectedIndexInSection()]
end

function CpImplementProfilesFrame:getNumberOfItemsInSection(list)
    return list == self.profileList and #self.rows or #self.details
end

-- Leave wheel events for the parent list; editing uses clicks or directional keys.
function CpImplementProfilesFrame:disableEditorWheel(editor)
    if editor.cpWheelDisabled then return end
    editor.cpWheelDisabled = true
    local mouseEvent = editor.mouseEvent
    editor.mouseEvent = function(control, posX, posY, isDown, isUp, button, eventUsed)
        if button == Input.MOUSE_BUTTON_WHEEL_UP or button == Input.MOUSE_BUTTON_WHEEL_DOWN or
            Input.isMouseButtonPressed(Input.MOUSE_BUTTON_WHEEL_UP) or
            Input.isMouseButtonPressed(Input.MOUSE_BUTTON_WHEEL_DOWN) then
            return eventUsed
        end
        return mouseEvent(control, posX, posY, isDown, isUp, button, eventUsed)
    end
end

function CpImplementProfilesFrame:populateCellForItemInSection(list, section, index, cell)
    if list == self.profileList then
        local row = self.rows[index]
        cell:getAttribute('title'):setText(row.title)
        cell.profileRow = row
        cell.target = self
        cell:setCallback('onClickCallback', 'onClickRow')
    else
        local detail = self.details[index]
        local isSetting = type(detail) == 'table'
        cell:getAttribute('title'):setVisible(not isSetting)
        cell:getAttribute('option'):setVisible(isSetting)
        cell:getAttribute('value'):setVisible(isSetting and not self.editDraft)
        local editing = isSetting and self.editDraft ~= nil
        local boolean = editing and type(self.editDraft.settings[detail.key]) == 'boolean'
        local selector = cell:getAttribute('editor')
        local toggle = cell:getAttribute('booleanEditor')
        self:disableEditorWheel(selector)
        self:disableEditorWheel(toggle)
        selector:setVisible(editing and not boolean)
        selector:setDisabled(not editing or boolean)
        toggle:setVisible(editing and boolean)
        toggle:setDisabled(not editing or not boolean)
        if editing then
            local editor = boolean and toggle or selector
            editor:setDataSource(self:getDraftSetting(detail.key))
            FocusManager:loadElementFromCustomValues(editor)
        end
        cell:getAttribute('title'):setText(not isSetting and detail or '')
        cell:getAttribute('option'):setText(isSetting and detail.title or '')
        cell:getAttribute('value'):setText(isSetting and detail.value or '')
    end
end

function CpImplementProfilesFrame:onListSelectionChanged(list)
    if list == self.profileList then self:updateDetails() else self:updateMenuButtons() end
end

function CpImplementProfilesFrame:onClickRow(cell)
    local row = cell.profileRow
    if row and row.key then self:toggleRow(row) end
end

function CpImplementProfilesFrame:toggleRow(row)
    local current = self.expanded[row.key]
    if current == nil then current = self.attachedOnly end
    self.expanded[row.key] = not current
    self:refresh()
end

-- Details presentation. Use CP setting titles and option texts so units and language follow the game.
function CpImplementProfilesFrame:updateDetails()
    self.detailList.showHighlights = self.editDraft == nil
    self.details = {}
    local state = self.vehicle and self.vehicle.cpImplementProfile
    self.activeText:setText(state and string.format(g_i18n:getText('CP_implementProfiles_active'),
        state.profile.name, state.profile.revision) or g_i18n:getText('CP_implementProfiles_noActive'))
    local row = self:getSelectedRow()
    if row and row.profile then
        local profile = self.editDraft or row.profile
        for _, item in ipairs(profile.equipment) do table.insert(self.details, item.name) end
        table.insert(self.details, string.format(g_i18n:getText('CP_implementProfiles_profileRevision'), profile.name, profile.revision))
        if row.match ~= 'exact' then
            table.insert(self.details, g_i18n:getText('CP_implementProfiles_match_' .. row.match))
        end
        for _, group in ipairs({'vehicle', 'generator'}) do
            for _, name in ipairs(ImplementProfile.SETTINGS[group]) do
                local key = group .. '.' .. name
                local value = profile.settings[key]
                local defaults = group == 'vehicle' and CpVehicleSettings or CpCourseGeneratorSettings
                local setting = not self.editDraft and self.vehicle and ImplementProfile.setting(self.vehicle, key) or defaults[name]
                if value ~= nil and setting then
                    local text = tostring(value)
                    for i, option in ipairs(setting.values) do
                        if option == value or (type(option) == 'number' and type(value) == 'number' and math.abs(option - value) < 0.001) then
                            text = setting.texts[i] or text
                            break
                        end
                    end
                    table.insert(self.details, {title = setting:getTitle(), value = text, key = key})
                end
            end
        end
    else
        table.insert(self.details, g_i18n:getText('CP_implementProfiles_help'))
    end
    self.detailList:reloadData()
    self:updateMenuButtons()
end

-- Footer actions. Expose only actions allowed by the selection, vehicle access and current edit state.
function CpImplementProfilesFrame:updateMenuButtons()
    self.menuButtonInfo = self.cpMenu.backButtonInfo and {self.cpMenu.backButtonInfo} or {}
    local row = self:getSelectedRow()
    local manager = g_Courseplay.implementProfiles
    if self.editDraft then
        self.menuButtonInfo = self.cpMenu.backButtonInfo and {self.cpMenu.backButtonInfo} or {}
        table.insert(self.menuButtonInfo, {inputAction = InputAction.MENU_EXTRA_1,
            text = g_i18n:getText('CP_implementProfiles_saveChanges'), callback = function() self:finishEdit(true) end})
        table.insert(self.menuButtonInfo, {inputAction = InputAction.MENU_CANCEL,
            text = g_i18n:getText('CP_implementProfiles_cancelChanges'), callback = function() self:finishEdit(false) end})
        self:setMenuButtonInfoDirty()
        return
    end
    local canChange = manager:canChange(self.vehicle) and g_currentMission.accessHandler:canPlayerAccess(self.vehicle)
    local function button(action, key, callback)
        table.insert(self.menuButtonInfo, {profile = 'buttonActivate', inputAction = action,
            text = g_i18n:getText('CP_implementProfiles_' .. key), callback = callback})
    end
    if row and row.key then
        button(InputAction.MENU_ACTIVATE, 'expand', function() self:toggleRow(row) end)
    elseif row and row.match == 'exact' and canChange then
        button(InputAction.MENU_ACTIVATE, 'loadProfile', function() self:apply(row.profile) end)
    end
    if canChange and #self.equipment > 0 and not manager.readOnly then
        button(InputAction.MENU_EXTRA_1, 'saveNew', function() self:saveNew() end)
    end
    if row and row.profile and not manager.readOnly then
        button(InputAction.MENU_EXTRA_2, 'edit', function() self:onClickEdit() end)
        button(InputAction.CP_PROFILE_RENAME, 'rename', function() self:onClickRename() end)
        if row.match == 'exact' and canChange then
            button(InputAction.MENU_CANCEL, 'update', function() self:updateProfile(row.profile) end)
        end
        button(InputAction.CP_PROFILE_DELETE, 'delete', function() self:deleteProfile(row.profile) end)
    end
    self:setMenuButtonInfoDirty()
end

-- Draft editing. Bind controls to independent parameters; only Save changes writes to the library.
function CpImplementProfilesFrame:onClickEdit()
    local row = self:getSelectedRow()
    if not row or not row.profile or g_Courseplay.implementProfiles.readOnly then return end
    self.editDraft = ImplementProfile.copy(row.profile)
    self.draftSettings = {}
    self:setEditingControls(true)
    self:updateDetails()
    FocusManager:setFocus(self.detailList)
end

function CpImplementProfilesFrame:setEditingControls(editing)
    self.profileList:setDisabled(editing)
    self.equipmentFilter:setDisabled(editing)
end

--- Independent parameters bind the value-column controls to the draft, never the vehicle.
function CpImplementProfilesFrame:getDraftSetting(key)
    if self.draftSettings[key] then return self.draftSettings[key] end
    local group, name = key:match('^(%w+)%.(%w+)$')
    local definitions = group == 'vehicle' and CpVehicleSettings or CpCourseGeneratorSettings
    local definition = definitions[name]
    local draft = self.editDraft
    local parameter = AIParameterSettingList({name = name, title = definition.title,
        tooltip = definition.tooltip, values = ImplementProfile.copy(definition.values),
        texts = ImplementProfile.copy(definition.texts), callbacks = {}}, nil, nil)
    if type(draft.settings[key]) == 'number' then
        parameter:setFloatValue(draft.settings[key], 0.002, true)
    else
        parameter:setValue(draft.settings[key], true)
    end
    parameter.onChange = function(setting)
        if self.editDraft == draft then draft.settings[key] = setting:getValue() end
    end
    parameter.onClickCenter = function() end
    self.draftSettings[key] = parameter
    return parameter
end

function CpImplementProfilesFrame:finishEdit(save)
    if not self.editDraft then return end
    if save then
        local saved, reason = g_Courseplay.implementProfiles:edit(self.editDraft, self.editDraft.settings)
        if not saved then self:showError(reason); return end
    end
    self.editDraft = nil
    self.draftSettings = nil
    self:setEditingControls(false)
    self:refresh()
    FocusManager:setFocus(self.profileList)
end

function CpImplementProfilesFrame:onFrameClose()
    self.editDraft = nil
    self.draftSettings = nil
    self:setEditingControls(false)
    self:superClass().onFrameClose(self)
end

-- Library commands. Shared dialogues handle naming and width warnings; the manager validates writes.
function CpImplementProfilesFrame:onClickAdvanced()
    InfoDialog.show(g_i18n:getText('CP_implementProfiles_advancedPlaceholder'))
end

function CpImplementProfilesFrame:onClickRename()
    local row = self:getSelectedRow()
    if not row or not row.profile then return end
    local profile = row.profile
    TextInputDialog.show(function(_, name, accepted)
        if not accepted then return end
        local renamed, reason = g_Courseplay.implementProfiles:rename(profile, name)
        if not renamed then self:showError(reason) end
        self:refresh()
    end, self, profile.name, g_i18n:getText('CP_implementProfiles_name'),
        g_i18n:getText('CP_implementProfiles_rename'), 200)
end

function CpImplementProfilesFrame:apply(profile, courseConfirmed)
    local vehicle = self.vehicle
    if not CpImplementProfileGui.confirmCourseWidth(vehicle, profile, courseConfirmed, false, function()
        if self.vehicle == vehicle then self:apply(profile, true) end
    end) then return end
    local ok, reason = g_Courseplay.implementProfiles:requestApply(vehicle, profile)
    if not ok then self:showError(reason) end
    self:updateDetails()
end

function CpImplementProfilesFrame:update(dt)
    self:superClass().update(self, dt)
    if self.editDraft then return end
    -- A server response or attachment callback may arrive while the menu is open.
    if self.vehicle and (self.lastProfileState ~= self.vehicle.cpImplementProfile or
        self.lastRefreshAt ~= self.vehicle.cpProfileRefreshAt) then
        self.lastProfileState = self.vehicle.cpImplementProfile
        self.lastRefreshAt = self.vehicle.cpProfileRefreshAt
        self:refresh()
    end
end

function CpImplementProfilesFrame:saveNew()
    CpImplementProfileGui.saveNew(function() return self.vehicle end, 'CP_implementProfiles_saveNew', function(profile)
        self:apply(profile)
        self:refresh()
    end)
end

function CpImplementProfilesFrame:updateProfile(profile)
    YesNoDialog.show(function(_, accepted)
        if not accepted then return end
        local saved, reason = g_Courseplay.implementProfiles:save(self.vehicle, profile.name, profile)
        if saved then self:apply(saved) else self:showError(reason) end
        self:refresh()
    end, self, string.format(g_i18n:getText('CP_implementProfiles_updateConfirm'), profile.name))
end

function CpImplementProfilesFrame:deleteProfile(profile)
    YesNoDialog.show(function(_, accepted)
        if not accepted then return end
        local ok, reason = g_Courseplay.implementProfiles:remove(profile)
        if not ok then self:showError(reason) end
        self:refresh()
    end, self, string.format(g_i18n:getText('CP_implementProfiles_deleteConfirm'), profile.name))
end

function CpImplementProfilesFrame:showError(reason)
    CpImplementProfileGui.showError(reason)
end

function CpImplementProfilesFrame:onClickEquipmentFilter()
    self.attachedOnly = self.equipmentFilter:getState() == 1
    self:refresh()
end
