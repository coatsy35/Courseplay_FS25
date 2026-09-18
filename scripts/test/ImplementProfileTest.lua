local lu = require('luaunit')
package.path = package.path .. ';../?.lua;../implementProfiles/?.lua;../events/?.lua;../gui/pages/?.lua;../gui/?.lua'
require('CpObject')
require('ImplementProfile')

-- Minimal engine boundaries. Tests exercise the real library, lifecycle, wire format and tree builder.
Class = function(class, parent)
    setmetatable(class, {__index = parent})
    return {__index = class}
end
Event = {new = function(mt) return setmetatable({}, mt) end}
InitEventClass = function() end
TabbedMenuFrameElement = {new = function(_, mt) return setmetatable({}, mt) end}
XMLValueType = {STRING = 1, INT = 2}
XMLSchema = {new = function() return {register = function() end} end}
Logging = {warning = function() end}
getDate = function() return '20260913' end
localToLocal = function(node) return 0, 0, node end
table.clone = ImplementProfile.copy
InputAction = {MENU_ACTIVATE = 1, MENU_EXTRA_1 = 2, MENU_EXTRA_2 = 3, MENU_CANCEL = 4, CP_PROFILE_RENAME = 5, CP_PROFILE_DELETE = 6}
g_i18n = {getText = function(_, text) return text end}
g_gui = {getIsGuiVisible = function() return true end}
require('CpImplementProfileGui')
require('ImplementProfileManager')
require('ImplementProfileEvent')
require('CpImplementProfilesFrame')
require('CpCourseGeneratorFrame')
require('CpVehicleSettingsFrame')

local files, failCopy, broadcasts
local function xmlFile(values, path)
    return {
        setValue = function(_, key, value) values[key] = value end,
        getValue = function(_, key) return values[key] end,
        iterate = function(_, key, callback)
            local prefix, indices = key .. '(', {}
            for entry in pairs(values) do
                if entry:sub(1, #prefix) == prefix then
                    local index = tonumber(entry:sub(#prefix + 1):match('^(%d+)%)'))
                    if index then indices[index] = true end
                end
            end
            local sorted = {}
            for index in pairs(indices) do table.insert(sorted, index) end
            table.sort(sorted)
            for _, index in ipairs(sorted) do callback(index, key .. '(' .. index .. ')') end
        end,
        save = function() if path then files[path] = ImplementProfile.copy(values) end end,
        delete = function() end
    }
end
XMLFile = {
    create = function(_, path) return xmlFile({}, path) end,
    loadIfExists = function(_, path) return files[path] and xmlFile(ImplementProfile.copy(files[path]), path) end
}
fileExists = function(path) return files[path] ~= nil end
copyFile = function(source, target)
    if target == failCopy then return false end
    files[target] = ImplementProfile.copy(files[source])
    -- GIANTS can perform the copy successfully without a return value.
end

local function setting(value, options)
    local result = {value = value, values = options or {false, true, 0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 20, 25}, texts = {}}
    result.getValue = function(self) return self.value end
    result.getIsDisabled = function(self) return self.disabled == true end
    result.setValue = function(self, v) self.value = v; return false end
    result.setFloatValue = result.setValue
    result.setDefault = function(self) self.value = false end
    result.getTitle = function() return 'setting' end
    return result
end

local function implement(name, group, config)
    local result = {configFileName = 'C:/Games/FS25/data/vehicles/test/' .. name .. '.xml',
        configurations = config or {}, attachments = {}, rootNode = 1}
    result[group or 'spec_plow'] = {}
    result.getName = function() return name end
    result.getAttachedImplements = function(self) return self.attachments end
    return result
end

local function vehicle(name, attachments)
    local result = implement(name or 'tractor', 'spec_drivable')
    result.attachments = attachments or {{object = implement('plough')}}
    result.vehicleSettings, result.generatorSettings = {}, {}
    for _, key in ipairs(ImplementProfile.SETTINGS.vehicle) do result.vehicleSettings[key] = setting(false) end
    for _, key in ipairs(ImplementProfile.SETTINGS.generator) do result.generatorSettings[key] = setting(1) end
    result.generatorSettings.workWidth.value = 6
    result.vehicleSettings.turnSpeed.value = 8
    result.vehicleSettings.toolOffsetX.value = 0
    result.generatorSettings.turningRadius = setting(5)
    result.getCpSettings = function(self) return self.vehicleSettings end
    result.getCourseGeneratorSettings = function(self) return self.generatorSettings end
    result.getIsAIActive = function(self) return self.ai == true end
    result.getIsCpActive = function(self) return self.ai == true end
    result.getIsEntered = function() return false end
    result.isServer = true
    return result
end

local function profileFor(v)
    return {id = 'library-1', name = 'Plough setup', revision = 1,
        equipment = ImplementProfile.describe(v), settings = ImplementProfile.capture(v)}
end

TestImplementProfiles = {}
function TestImplementProfiles:setUp()
    files, failCopy, broadcasts = {}, nil, 0
    g_time = 0
    g_server = {broadcastEvent = function() broadcasts = broadcasts + 1 end}
    g_currentMission = {accessHandler = {
        canPlayerAccess = function() return true end,
        canFarmAccess = function(_, farmId) return farmId == 1 end
    }, userManager = {getUserIdByConnection = function() return 7 end}}
    g_farmManager = {getFarmByUserId = function() return {farmId = 1} end}
    g_Courseplay = {implementProfiles = ImplementProfileManager('profiles/')}
    g_gui.getIsGuiVisible = function() return true end
    CpVehicleSettings = {setAutomaticWorkWidthAndOffset = function(v)
        v.generatorSettings.workWidth.value = 3
        v.vehicleSettings.toolOffsetX.value = 0
    end}
    CpCourseGeneratorSettings = {setDefaultTurningRadius = function(v) v.generatorSettings.turningRadius.value = 10 end}
end

function TestImplementProfiles:testRenamePreservesSettingsAndRejectsDuplicatesAndStaleCopies()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local first = manager:save(v, 'Original')
    local renamed = manager:rename(first, '7 headlands')
    lu.assertEquals(renamed.id, first.id)
    lu.assertEquals(renamed.settings, first.settings)
    lu.assertEquals(renamed.equipment, first.equipment)
    lu.assertEquals(renamed.revision, 2)
    lu.assertEquals(first.name, 'Original')
    lu.assertNil(manager:rename(first, 'Stale'))
    local other = manager:save(v, 'Other')
    lu.assertNil(manager:rename(other, '7 HEADLANDS'))
    lu.assertNil(manager:rename(renamed, '  '))
end

function TestImplementProfiles:testDirectEditDoesNotChangeVehicleAndValidatesBeforeSaving()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local first = manager:save(v, 'Original')
    manager:apply(v, first)
    for name, setting in pairs(v.vehicleSettings) do CpVehicleSettings[name] = setting end
    for name, setting in pairs(v.generatorSettings) do CpCourseGeneratorSettings[name] = setting end
    local draft = ImplementProfile.copy(first.settings)
    draft['generator.numberOfHeadlands'] = 12
    local saved = manager:edit(first, draft)
    lu.assertEquals(saved.revision, 2)
    lu.assertEquals(saved.settings['generator.numberOfHeadlands'], 12)
    lu.assertEquals(v.generatorSettings.numberOfHeadlands.value, 1)
    lu.assertEquals(v.cpImplementProfile.profile.revision, 1)
    lu.assertNil(manager:edit(first, draft))
    draft['generator.numberOfHeadlands'] = 999
    lu.assertNil(manager:edit(saved, draft))
    lu.assertEquals(manager.profiles[first.id], saved)
    draft = ImplementProfile.copy(saved.settings)
    draft['vehicle.raiseImplementLateOverride'] = true
    lu.assertNil(manager:edit(saved, draft))
    lu.assertEquals(manager.profiles[first.id], saved)
end

function TestImplementProfiles:testTimingDisplayFollowsOverrideWithoutChangingSavedValues()
    local v = vehicle()
    local settings = v:getCpSettings()
    local name = 'raiseImplementLate'
    settings[name].value = true
    settings[name .. 'OverrideEnabled'] = setting(false)
    local manual = setting(false)
    manual.getName = function() return name .. 'Override' end
    manual.getIsVisible = function() return true end
    manual.getTooltip = function() return 'timing' end
    settings[name .. 'Override'] = manual
    local control = {setDataSource = function(self, source) self.source = source end}
    local row = {aiParameter = manual, getDescendantByName = function() return control end}
    local layout = {elements = {row}}
    CpVehicleSettingsFrame.bindTimingSources({}, layout, v)
    lu.assertTrue(control.source:getValue())
    lu.assertTrue(control.source:getIsDisabled())
    lu.assertFalse(manual:getValue())
    settings[name .. 'OverrideEnabled'].value = true
    CpVehicleSettingsFrame.bindTimingSources({}, layout, v)
    lu.assertEquals(control.source, manual)
    lu.assertFalse(control.source:getValue())
    lu.assertFalse(control.source:getIsDisabled())
    settings[name .. 'OverrideEnabled'].value = false
    CpVehicleSettingsFrame.bindTimingSources({}, layout, v)
    lu.assertTrue(control.source:getValue())
    lu.assertFalse(manual:getValue())
end

function TestImplementProfiles:testSelfPropelledWorkingMachineIsItsOwnEquipment()
    local machine = vehicle('integratedHarvester', {})
    machine.spec_combine = {}
    local equipment = ImplementProfile.describe(machine)
    lu.assertEquals(#equipment, 1)
    lu.assertEquals(equipment[1].mount, 'self')
    lu.assertEquals(equipment[1].group, 'harvesters')
    lu.assertEquals(ImplementProfile.describe(vehicle('tractor', {})), {})
end

function TestImplementProfiles:testHarvesterAndRemovableHeaderFormCompleteCombination()
    local machine = vehicle('harvester', {{object = implement('headerA', 'spec_cutter')}})
    machine.spec_combine = {}
    local profile = profileFor(machine)
    lu.assertEquals(#profile.equipment, 2)
    lu.assertEquals(profile.equipment[1].mount, 'self')
    lu.assertEquals(profile.equipment[2].group, 'headers')
    machine.attachments[1].object = implement('headerB', 'spec_cutter')
    lu.assertNotEquals(ImplementProfile.match(profile, ImplementProfile.describe(machine)), 'exact')
    machine.attachments = {}
    lu.assertNotEquals(ImplementProfile.match(profile, ImplementProfile.describe(machine)), 'exact')
end

function TestImplementProfiles:testInlineParameterOnlyChangesDraft()
    local v = vehicle()
    CpVehicleSettings.raiseImplementLate = v.vehicleSettings.raiseImplementLate
    local frame = setmetatable({editDraft = profileFor(v), draftSettings = {}}, {__index = CpImplementProfilesFrame})
    local previous = AIParameterSettingList
    AIParameterSettingList = function(data)
        local p = setting(false, data.values)
        return p
    end
    local parameter = frame:getDraftSetting('vehicle.raiseImplementLate')
    AIParameterSettingList = previous
    parameter.value = true
    parameter:onChange()
    lu.assertTrue(frame.editDraft.settings['vehicle.raiseImplementLate'])
    lu.assertFalse(v.vehicleSettings.raiseImplementLate.value)
    lu.assertEquals(frame:getDraftSetting('vehicle.raiseImplementLate'), parameter)
    local cancelled = frame.editDraft
    frame.editDraft = nil
    parameter.value = false
    parameter:onChange()
    lu.assertTrue(cancelled.settings['vehicle.raiseImplementLate'])
end

function TestImplementProfiles:testEditAndRenameAreFooterActions()
    local v = vehicle()
    local frame = setmetatable({vehicle = v, equipment = ImplementProfile.describe(v),
        cpMenu = {defaultMenuButtonInfo = {}}, getSelectedRow = function() return {profile = profileFor(v), match = 'exact'} end,
        setMenuButtonInfoDirty = function() end}, {__index = CpImplementProfilesFrame})
    frame:updateMenuButtons()
    local found = {}
    for _, button in ipairs(frame.menuButtonInfo) do found[button.text] = true end
    lu.assertTrue(found.CP_implementProfiles_edit)
    lu.assertTrue(found.CP_implementProfiles_rename)
    lu.assertTrue(found.CP_implementProfiles_saveNew)
    lu.assertTrue(found.CP_implementProfiles_loadProfile)
    lu.assertTrue(found.CP_implementProfiles_update)
    lu.assertTrue(found.CP_implementProfiles_delete)
    lu.assertNil(found.CP_implementProfiles_moreActions)
    lu.assertEquals(#frame.menuButtonInfo, 6)
    local actions = {}
    for _, button in ipairs(frame.menuButtonInfo) do
        lu.assertNotNil(button.inputAction)
        lu.assertNil(actions[button.inputAction])
        actions[button.inputAction] = true
    end
    frame.editDraft = profileFor(v)
    frame:updateMenuButtons()
    lu.assertEquals(#frame.menuButtonInfo, 2)
    lu.assertEquals(frame.menuButtonInfo[1].text, 'CP_implementProfiles_saveChanges')
    lu.assertEquals(frame.menuButtonInfo[2].text, 'CP_implementProfiles_cancelChanges')
end

function TestImplementProfiles:testInlineRowsUseBinaryAndNumericControlsAndResetRecycledCells()
    local controls = {}
    for _, name in ipairs({'title', 'option', 'value', 'editor', 'booleanEditor'}) do
        controls[name] = {
            setVisible = function(self, v) self.visible = v end,
            setDisabled = function(self, v) self.disabled = v end,
            setText = function(self, v) self.text = v end,
            setDataSource = function(self, v) self.source = v end
        }
    end
    local cell = {getAttribute = function(_, name) return controls[name] end}
    local frame = setmetatable({profileList = {}, editDraft = {settings = {flag = false, width = 6}},
        details = {{title = 'Raise tools', value = 'Early', key = 'flag'},
                   {title = 'Width', value = '6 m', key = 'width'}, 'Header'},
        getDraftSetting = function(_, key) return key end}, {__index = CpImplementProfilesFrame})
    local previousFocus = FocusManager
    FocusManager = {loadElementFromCustomValues = function() end}
    frame:populateCellForItemInSection({}, 1, 1, cell)
    lu.assertTrue(controls.booleanEditor.visible)
    lu.assertFalse(controls.editor.visible)
    lu.assertEquals(controls.booleanEditor.source, 'flag')
    lu.assertTrue(controls.option.visible)
    frame:populateCellForItemInSection({}, 1, 2, cell)
    lu.assertFalse(controls.booleanEditor.visible)
    lu.assertTrue(controls.editor.visible)
    lu.assertEquals(controls.editor.source, 'width')
    frame:populateCellForItemInSection({}, 1, 3, cell)
    lu.assertFalse(controls.booleanEditor.visible)
    lu.assertFalse(controls.editor.visible)
    lu.assertTrue(controls.title.visible)
    frame.editDraft = nil
    frame:populateCellForItemInSection({}, 1, 1, cell)
    lu.assertTrue(controls.value.visible)
    lu.assertFalse(controls.booleanEditor.visible)
    lu.assertFalse(controls.editor.visible)
    FocusManager = previousFocus
end

function TestImplementProfiles:testAttachmentDialogInitialisesNativeSelectorAfterOpening()
    local oldDialog, oldBase, oldGui, oldFocus = CpImplementProfileDialog, DialogElement, g_gui, FocusManager
    DialogElement = {}
    dofile('../gui/CpImplementProfileDialog.lua')
    local class = CpImplementProfileDialog
    local selector = {
        setTexts = function(self, texts) self.texts = texts end,
        setState = function(self, state) self.state = state end,
        getState = function(self) return self.state end
    }
    local dialog = setmetatable({profileSelector = selector, close = function(self)
        self.profiles, self.loadCallback, self.viewCallback = nil, nil, nil
    end}, {__index = class})
    g_gui = {guis = {CpImplementProfileDialog = {target = dialog}}, showDialog = function()
        selector.texts, selector.state = {}, 0
    end}
    FocusManager = {setFocus = function() end}
    local profiles = {{id = 'one', name = '7 headlands'}, {id = 'two', name = '12 headlands'}}
    local loaded, viewed
    class.show(profiles, function(profile) loaded = profile.id end, function() viewed = true end)
    lu.assertEquals(selector.texts, {'7 headlands', '12 headlands'})
    lu.assertEquals(selector.state, 1)
    selector:setState(2)
    dialog:onClickLoad()
    lu.assertEquals(loaded, 'two')
    class.show(profiles, function(profile) loaded = profile.id end, function() viewed = true end)
    dialog:onClickView()
    lu.assertTrue(viewed)
    lu.assertEquals(loaded, 'two')
    CpImplementProfileDialog, DialogElement, g_gui, FocusManager = oldDialog, oldBase, oldGui, oldFocus
end

function TestImplementProfiles:testWorkingSettingsDistinguishCustomFromSavedProfile()
    local v = vehicle()
    local profile = profileFor(v)
    lu.assertTrue(ImplementProfile.matchesSettings(v, profile))
    v.generatorSettings.numberOfHeadlands.value = 12
    lu.assertFalse(ImplementProfile.matchesSettings(v, profile))
    v.generatorSettings.numberOfHeadlands.value = profile.settings['generator.numberOfHeadlands']
    lu.assertTrue(ImplementProfile.matchesSettings(v, profile))
    v.generatorSettings.workWidth.value = 6.00000001
    lu.assertTrue(ImplementProfile.matchesSettings(v, profile))
    v.vehicleSettings.raiseImplementLateOverrideEnabled = setting(true)
    v.vehicleSettings.raiseImplementLateOverride = setting(true)
    lu.assertTrue(ImplementProfile.matchesSettings(v, profile))
end

function TestImplementProfiles:testFieldworkSelectionLoadsOnlyOnRequestAndRejectsChangedEquipment()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    v.getFieldWorkCourse = function() return nil end
    local profile = manager:save(v, 'Field setup')
    v.generatorSettings.workWidth.value = 3
    local frame = setmetatable({fieldworkProfileVehicle = v, fieldworkProfiles = {profile},
        fieldworkProfileSelector = setting(0), cpMenu = {getCurrentVehicle = function() return v end}},
        {__index = CpCourseGeneratorFrame})
    frame:loadFieldworkProfile()
    lu.assertEquals(v.generatorSettings.workWidth.value, 3)
    frame.fieldworkProfileSelector.value = 1
    lu.assertEquals(v.generatorSettings.workWidth.value, 3)
    frame:loadFieldworkProfile()
    lu.assertEquals(v.generatorSettings.workWidth.value, 6)
    v.attachments = {}
    local message
    InfoDialog = {show = function(text) message = text end}
    frame:loadFieldworkProfile()
    lu.assertEquals(message, 'CP_implementProfiles_mismatch')
end

function TestImplementProfiles:testGenerateUsesSelectedProfileOrCustomValues()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local profile = manager:save(v, 'Setup')
    local generated = {}
    local frame = setmetatable({fieldworkProfileVehicle = v, fieldworkProfiles = {profile},
        fieldworkProfileSelector = setting(1), cpMenu = {getCurrentVehicle = function() return v end},
        getCanGenerateFieldWorkCourse = function() return true end,
        currentJob = {onClickGenerateFieldWorkCourse = function()
            generated[#generated + 1] = ImplementProfile.capture(v)
        end}}, {__index = CpCourseGeneratorFrame})
    v.generatorSettings.workWidth.value = 3
    lu.assertTrue(frame:generateFieldworkCourse())
    lu.assertEquals(generated[1], profile.settings)
    frame.generateCoursePending = false
    frame.fieldworkProfileSelector.value = 0
    v.generatorSettings.workWidth.value = 4
    lu.assertTrue(frame:generateFieldworkCourse())
    lu.assertEquals(generated[2]['generator.workWidth'], 4)
    lu.assertEquals(profile.settings['generator.workWidth'], 6)
    frame.generateCoursePending = false
    frame.fieldworkProfileSelector.value = 1
    v.attachments = {}
    InfoDialog = {show = function() end}
    lu.assertFalse(frame:generateFieldworkCourse())
    lu.assertEquals(#generated, 2)
end

function TestImplementProfiles:testClientGenerationWaitsForAcceptedProfileAndStopsOnFailure()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local profile = manager:save(v, 'Setup')
    manager:apply(v, profile)
    v.isServer = false
    g_client = {getServerConnection = function() return {sendEvent = function() end} end}
    local generated = 0
    local frame = setmetatable({fieldworkProfileVehicle = v, fieldworkProfiles = {profile},
        fieldworkProfileSelector = setting(1), cpMenu = {getCurrentVehicle = function() return v end},
        getCanGenerateFieldWorkCourse = function() return true end,
        currentJob = {onClickGenerateFieldWorkCourse = function() generated = generated + 1 end}},
        {__index = CpCourseGeneratorFrame})
    lu.assertTrue(frame:generateFieldworkCourse())
    frame:updateProfileGeneration()
    lu.assertEquals(generated, 0) -- Existing matching values are not a server acknowledgement.
    lu.assertFalse(frame:generateFieldworkCourse())
    v.cpImplementProfile = ImplementProfile.copy(v.cpImplementProfile)
    frame:updateProfileGeneration()
    lu.assertEquals(generated, 1)
    frame.generateCoursePending = false
    frame:generateFieldworkCourse()
    v.cpProfileApplyError = 'mismatch'
    frame:updateProfileGeneration()
    lu.assertNil(frame.profileGenerationPending)
    lu.assertEquals(generated, 1)
    frame:generateFieldworkCourse()
    g_time = 10001
    InfoDialog = {show = function() end}
    frame:updateProfileGeneration()
    lu.assertNil(frame.profileGenerationPending)
    lu.assertEquals(generated, 1)
end

function TestImplementProfiles:testProfileSelectionIgnoresBindingAndUnchangedControlCallbacks()
    local previous = CpSettingsUtil
    CpSettingsUtil = {updateGuiElementsBoundToSettings = function() end}
    local selector = setting(1)
    local frame = setmetatable({fieldworkProfileSelector = selector,
        fieldworkProfileControl = {setDataSource = function() end},
        cpMenu = {getCurrentVehicle = function() return nil end}}, {__index = CpCourseGeneratorFrame})
    local control = {dataSource = setting(7), cpDisplayedValue = 7, parent = {parent = {}}}
    frame:onClickCpMultiTextOption(nil, control)
    lu.assertEquals(selector.value, 1)
    frame.bindingProfileSettings = true
    control.dataSource.value = 8
    frame:onClickCpMultiTextOption(nil, control)
    lu.assertEquals(selector.value, 1)
    frame.bindingProfileSettings = false
    frame:onClickCpMultiTextOption(nil, control)
    lu.assertEquals(selector.value, 0)
    CpSettingsUtil = previous
end

function TestImplementProfiles:testInlineEditorLeavesWheelForList()
    local oldInput = Input
    Input = {MOUSE_BUTTON_WHEEL_UP = 4, MOUSE_BUTTON_WHEEL_DOWN = 5,
        isMouseButtonPressed = function() return false end}
    local clicks = 0
    local editor = {mouseEvent = function() clicks = clicks + 1; return true end}
    CpImplementProfilesFrame:disableEditorWheel(editor)
    CpImplementProfilesFrame:disableEditorWheel(editor)
    lu.assertFalse(editor:mouseEvent(0, 0, true, false, 4, false))
    lu.assertFalse(editor:mouseEvent(0, 0, true, false, 5, false))
    lu.assertEquals(clicks, 0)
    lu.assertTrue(editor:mouseEvent(0, 0, true, false, 1, false))
    lu.assertEquals(clicks, 1)
    Input = oldInput
end

function TestImplementProfiles:testBinaryBindingDoesNotReenterClickAndUserChangesAnimate()
    local oldBinary, oldGui = BinaryOptionElement, Gui
    local clicks, writes = 0, 0
    BinaryOptionElement = {STATE_LEFT = 1, STATE_RIGHT = 2}
    function BinaryOptionElement:setState(state, force, skip)
        local changed = self.state ~= state
        self.state, self.skipAnimation = state, skip
        if changed or force then self:raiseClickCallback() end
    end
    function BinaryOptionElement:raiseClickCallback()
        clicks = clicks + 1
        self:setDataSource(self.dataSource) -- A page refresh used to recurse here.
    end
    Gui = {registerGuiElement = function() end}
    dofile('../gui/elements/CpBinaryOptionElement.lua')
    CpBinaryOptionElement.superClass = function() return BinaryOptionElement end
    local value = false
    local source = {texts = {'off', 'on'}, getValue = function() return value end,
        setValue = function(_, v) writes = writes + 1; value = v end}
    local control = setmetatable({state = 2, setTexts = function() end,
        updateTitle = function() end}, {__index = CpBinaryOptionElement})
    control:setDataSource(source)
    lu.assertEquals(clicks, 0)
    lu.assertEquals(writes, 0)
    lu.assertEquals(control.state, 1)
    -- Check user input forwards animation flags without forced duplicate callbacks.
    BinaryOptionElement.raiseClickCallback = function() clicks = clicks + 1 end
    control:setState(2)
    lu.assertTrue(value)
    lu.assertEquals(control.state, 2)
    lu.assertNil(control.skipAnimation)
    lu.assertEquals(clicks, 1)
    BinaryOptionElement, Gui = oldBinary, oldGui
end

function TestImplementProfiles:testFieldworkMatchingProfilesAreExactAndSorted()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local z = manager:save(v, 'Z setup')
    local a = manager:save(v, 'A setup')
    local other = vehicle(nil, {{object = implement('drill', 'spec_sowingMachine')}})
    manager:save(other, 'Drill setup')
    lu.assertEquals(manager:getMatchingProfiles(v), {a, z})
    v.attachments[2] = {object = implement('drill', 'spec_sowingMachine')}
    lu.assertEquals(manager:getMatchingProfiles(v), {})
    lu.assertEquals(manager:getMatchingProfiles(nil), {})
end

function TestImplementProfiles:testPortableIdentityAndCosmeticConfiguration()
    local a = vehicle('tractorA')
    local b = vehicle('tractorB')
    b.attachments[1].object.configFileName = 'D:/Steam/FS25/data/vehicles/test/plough.xml'
    b.attachments[1].object.configurations.baseColor = 12
    lu.assertEquals(ImplementProfile.match(profileFor(a), ImplementProfile.describe(b)), 'exact')
    b.attachments[1].object.configurations.workingWidth = 2
    lu.assertEquals(ImplementProfile.match(profileFor(a), ImplementProfile.describe(b)), 'none')
end

function TestImplementProfiles:testModIdentityDoesNotCollideWithBasegame()
    local a, b = vehicle(), vehicle()
    b.attachments[1].object.customEnvironment = 'FS25_CustomPlough'
    b.attachments[1].object.configFileName = 'C:/Mods/FS25_CustomPlough/plough.xml'
    lu.assertEquals(ImplementProfile.model(b.attachments[1].object), 'fs25_customplough:plough.xml')
    lu.assertEquals(ImplementProfile.match(profileFor(a), ImplementProfile.describe(b)), 'none')
end

function TestImplementProfiles:testCombinationOrderAndMultiplicity()
    local a = vehicle(nil, {{object = implement('mower', 'spec_mower')}, {object = implement('drill', 'spec_sowingMachine')}})
    local b = vehicle(nil, {a.attachments[2], a.attachments[1]})
    lu.assertEquals(ImplementProfile.match(profileFor(a), ImplementProfile.describe(b)), 'exact')
    local single = vehicle(nil, {a.attachments[1]})
    lu.assertEquals(ImplementProfile.match(profileFor(single), ImplementProfile.describe(b)), 'partial')
    local double = vehicle(nil, {a.attachments[1], a.attachments[1]})
    lu.assertEquals(ImplementProfile.match(profileFor(double), ImplementProfile.describe(single)), 'none')
end

function TestImplementProfiles:testFrontRearAndNestedConnections()
    local a, b = vehicle(), vehicle()
    a.spec_attacherJoints = {attacherJoints = {{jointTransform = 2}}}
    a.attachments[1].jointDescIndex = 1
    lu.assertEquals(ImplementProfile.match(profileFor(a), ImplementProfile.describe(b)), 'partial')
    a.attachments[1].object.attachments = {{object = implement('drill', 'spec_sowingMachine')}}
    b.attachments[2] = {object = implement('drill', 'spec_sowingMachine')}
    lu.assertNotEquals(ImplementProfile.signature(ImplementProfile.describe(a)), ImplementProfile.signature(ImplementProfile.describe(b)))
end

function TestImplementProfiles:testVariableWidthAndFillTypeNames()
    local object = implement('sprayer')
    object.getVariableWorkWidth = function(_, left) return left and 3 or -3, nil, true end
    lu.assertStrContains(ImplementProfile.configuration(object), 'sections=3.000,-3.000')
    object.spec_sprayer = {}
    object.getSprayerFillUnitIndex = function() return 1 end
    object.getFillUnitFillType = function() return 20 end
    g_fillTypeManager = {getFillTypeByIndex = function() return {name = 'LIME'} end}
    lu.assertStrContains(ImplementProfile.configuration(object), 'material=LIME')
end

function TestImplementProfiles:testSaveReloadAndRevisionIsolation()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local first = manager:save(v, 'Normal')
    lu.assertEquals(first.revision, 1)
    v.vehicleSettings.turnSpeed.value = 5
    local second = manager:save(v, 'Normal', first)
    lu.assertEquals(second.revision, 2)
    lu.assertEquals(first.settings['vehicle.turnSpeed'], 8)
    local restored = ImplementProfileManager('profiles/')
    lu.assertEquals(restored.profiles[first.id].settings['vehicle.turnSpeed'], 5)
    lu.assertEquals(restored.profiles[first.id].settings['vehicle.raiseImplementLate'], false)
    lu.assertNotNil(files[manager.path .. '.bak'])
    local copy = manager:save(v, 'Alternative')
    lu.assertNotEquals(copy.id, first.id)
    lu.assertEquals(copy.revision, 1)
end

function TestImplementProfiles:testDuplicateNameAndStaleUpdateRejected()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local first = manager:save(v, 'Normal')
    local duplicate, reason = manager:save(v, ' normal ')
    lu.assertNil(duplicate)
    lu.assertEquals(reason, 'duplicateName')
    lu.assertNotNil(manager:save(v, 'Normal', first))
    lu.assertNil(manager:save(v, 'Normal', first))
end

function TestImplementProfiles:testWriteFailureKeepsMemoryAndBackup()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local first = manager:save(v, 'Normal')
    failCopy = manager.path
    local failed = manager:save(v, 'Alternative')
    lu.assertNil(failed)
    lu.assertEquals(manager.nextId, 2)
    lu.assertEquals(manager.profiles[first.id].revision, 1)
    lu.assertTrue(manager.readOnly)
    lu.assertNotNil(files[manager.path .. '.bak'])
end

function TestImplementProfiles:testFailedBackupDoesNotReplaceLibrary()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local first = manager:save(v, 'Normal')
    local original = ImplementProfile.copy(files[manager.path])
    failCopy = manager.path .. '.bak'
    lu.assertNil(manager:save(v, 'Alternative'))
    lu.assertEquals(files[manager.path], original)
    lu.assertEquals(manager.profiles[first.id], first)
end

function TestImplementProfiles:testVehicleTimingOverridesNeverLeakIntoProfiles()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local settings = v:getCpSettings()
    for _, name in ipairs({'raiseImplementLate', 'lowerImplementEarly'}) do
        settings[name].value = false
        settings[name .. 'OverrideEnabled'] = setting(true)
        settings[name .. 'Override'] = setting(true)
        lu.assertTrue(ImplementProfile.getTiming(settings, name))
    end
    local saved = manager:save(v, 'Implement defaults')
    for _, name in ipairs({'raiseImplementLate', 'lowerImplementEarly'}) do
        lu.assertFalse(saved.settings['vehicle.' .. name])
        lu.assertNil(saved.settings['vehicle.' .. name .. 'Override'])
        lu.assertNil(saved.settings['vehicle.' .. name .. 'OverrideEnabled'])
    end
    lu.assertTrue(manager:apply(v, saved))
    for _, name in ipairs({'raiseImplementLate', 'lowerImplementEarly'}) do
        settings.raiseImplementLateOverrideEnabled.value = true
        lu.assertTrue(ImplementProfile.getTiming(settings, name))
        settings.raiseImplementLateOverrideEnabled.value = false
        lu.assertFalse(ImplementProfile.getTiming(settings, name))
        settings[name].value = true
        lu.assertTrue(ImplementProfile.getTiming(settings, name))
    end
    local updated = manager:save(v, saved.name, saved)
    lu.assertTrue(updated.settings['vehicle.raiseImplementLate'])
    lu.assertTrue(updated.settings['vehicle.lowerImplementEarly'])
end

function TestImplementProfiles:testNewerLibraryIsNotOverwritten()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    manager:save(v, 'Normal')
    files[manager.path]['ImplementProfiles#version'] = 99
    local loaded = ImplementProfileManager('profiles/')
    lu.assertTrue(loaded.readOnly)
    lu.assertNil(loaded:save(v, 'New'))
    lu.assertEquals(files[manager.path]['ImplementProfiles#version'], 99)
end

function TestImplementProfiles:testDamagedLibraryUsesBackupReadOnly()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local profile = manager:save(v, 'Normal')
    manager:save(v, 'Normal', profile)
    files[manager.path]['ImplementProfiles.profile(0)#name'] = nil
    local loaded = ImplementProfileManager('profiles/')
    lu.assertTrue(loaded.readOnly)
    lu.assertEquals(loaded.profiles[profile.id].revision, 1)
end

function TestImplementProfiles:testApplyRejectsBusyWrongEquipmentAndInvalidValueWithoutMutation()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local profile = profileFor(v)
    profile.settings['vehicle.turnSpeed'] = 5
    v.ai = true
    lu.assertFalse(manager:apply(v, profile))
    v.ai = false
    v.lastSpeedReal = 0.001
    lu.assertFalse(manager:apply(v, profile))
    v.lastSpeedReal = 0
    profile.settings['generator.workWidth'] = 1234
    lu.assertFalse(manager:apply(v, profile))
    lu.assertEquals(v.vehicleSettings.turnSpeed.value, 8)
    profile.settings['generator.workWidth'] = 6
    profile.equipment[1].model = 'different'
    lu.assertFalse(manager:apply(v, profile))
    lu.assertNil(v.cpImplementProfile)
end

function TestImplementProfiles:testUnknownSettingAndNonFiniteNumbersRejected()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local profile = profileFor(v)
    profile.settings['vehicle.debugActive'] = true
    lu.assertFalse(manager:apply(v, profile))
    lu.assertNil(ImplementProfile.decode('nan'))
    lu.assertNil(ImplementProfile.decode('1e999'))
    lu.assertEquals(ImplementProfile.decode('false'), false)
end

function TestImplementProfiles:testMalformedProfileCannotBeApplied()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    lu.assertFalse(manager:apply(v, {}))
    lu.assertFalse(manager:apply(v, nil))
    local profile = profileFor(v)
    profile.settings['generator.workWidth'] = 0 / 0
    lu.assertFalse(manager:apply(v, profile))
    lu.assertNil(v.cpImplementProfile)
end

function TestImplementProfiles:testSuggestionsOfferOnceWithoutApplying()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    manager:save(v, 'Normal')
    v.getIsEntered = function() return true end
    v.cpProfileInitialised = true
    ImplementProfileManager.markChanged(v, nil, true)
    g_gui.getIsGuiVisible = function() return false end
    local offered = 0
    CpImplementProfileDialog = {show = function() offered = offered + 1 end}
    manager:updateVehicle(v)
    lu.assertEquals(offered, 0)
    g_time = 501
    manager:updateVehicle(v)
    manager:updateVehicle(v)
    lu.assertEquals(offered, 1)
    lu.assertNil(v.cpImplementProfile)
end

function TestImplementProfiles:testSuggestionsCanBeDisabledWithoutLosingManualMatches()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    manager:save(v, 'Normal')
    local enabled = setting(false)
    g_Courseplay.globalSettings = {showImplementProfileSuggestions = enabled}
    v.getIsEntered = function() return true end
    v.cpProfileInitialised = true
    ImplementProfileManager.markChanged(v, nil, true)
    g_gui.getIsGuiVisible = function() return false end
    local offered = 0
    CpImplementProfileDialog = {show = function() offered = offered + 1 end}
    manager:updateVehicle(v)
    g_time = 501
    manager:updateVehicle(v)
    lu.assertEquals(offered, 0)
    lu.assertNotEquals(v.cpProfileOfferPending, true)
    lu.assertEquals(#manager:getMatchingProfiles(v), 1)
    enabled.value = true
    manager:updateVehicle(v)
    lu.assertEquals(offered, 0)
    ImplementProfileManager.markChanged(v, nil, true)
    g_time = 1002
    manager:updateVehicle(v)
    lu.assertEquals(offered, 1)
end

function TestImplementProfiles:testSingleProfileLoadsSilentlyOnceWhenEnabled()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local profile = manager:save(v, 'Normal')
    v.vehicleSettings.turnSpeed.value = 5
    v.getIsEntered = function() return true end
    v.cpProfileInitialised = true
    ImplementProfileManager.markChanged(v, nil, true)
    g_gui.getIsGuiVisible = function() return false end
    g_Courseplay.globalSettings = {showImplementProfileSuggestions = setting(false), autoLoadSingleImplementProfile = setting(true)}
    manager:updateVehicle(v)
    lu.assertNil(v.cpImplementProfile)
    g_time = 501
    manager:updateVehicle(v)
    lu.assertEquals(v.cpImplementProfile.profile.id, profile.id)
    lu.assertEquals(v.vehicleSettings.turnSpeed.value, 8)
    local state = v.cpImplementProfile
    manager:updateVehicle(v)
    lu.assertEquals(v.cpImplementProfile, state)
end

function TestImplementProfiles:testMultipleProfilesNeverLoadSilently()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    manager:save(v, 'Normal')
    manager:save(v, 'Alternative')
    v.getIsEntered = function() return true end
    v.cpProfileInitialised = true
    ImplementProfileManager.markChanged(v, nil, true)
    g_gui.getIsGuiVisible = function() return false end
    g_Courseplay.globalSettings = {showImplementProfileSuggestions = setting(false), autoLoadSingleImplementProfile = setting(true)}
    manager:updateVehicle(v)
    g_time = 501
    manager:updateVehicle(v)
    lu.assertNil(v.cpImplementProfile)
    lu.assertNotEquals(v.cpProfileOfferPending, true)
end

function TestImplementProfiles:testSinglePromptCanDeclineBrowseOrLoad()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    manager:save(v, 'Normal')
    v.getIsEntered = function() return true end
    v.cpProfileInitialised = true
    ImplementProfileManager.markChanged(v, nil, true)
    g_gui.getIsGuiVisible = function() return false end
    g_Courseplay.globalSettings = {showImplementProfileSuggestions = setting(true), autoLoadSingleImplementProfile = setting(true)}
    local callback, opened
    CpImplementProfileDialog = {show = function(profiles, load, view)
        callback = function(choice)
            if choice == 1 then load(profiles[1]) elseif choice == 2 then view() end
        end
    end}
    MessageType = {GUI_CP_INGAME_OPEN_IMPLEMENT_PROFILES = 1}
    g_messageCenter = {publish = function() opened = true end}
    manager:updateVehicle(v)
    g_time = 501
    manager:updateVehicle(v)
    lu.assertNil(v.cpImplementProfile)
    callback(3)
    lu.assertNil(v.cpImplementProfile)
    callback(2)
    lu.assertTrue(opened)
    lu.assertNil(v.cpImplementProfile)
    callback(1)
    lu.assertNotNil(v.cpImplementProfile)
end

function TestImplementProfiles:testSinglePromptOffersLoadWhenAutoLoadIsOff()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    manager:save(v, 'Normal')
    v.getIsEntered = function() return true end
    v.cpProfileInitialised = true
    ImplementProfileManager.markChanged(v, nil, true)
    g_gui.getIsGuiVisible = function() return false end
    g_Courseplay.globalSettings = {showImplementProfileSuggestions = setting(true), autoLoadSingleImplementProfile = setting(false)}
    local callback, opened
    CpImplementProfileDialog = {show = function(profiles, load, view)
        callback = function(choice)
            if choice == 1 then load(profiles[1]) elseif choice == 2 then view() end
        end
    end}
    MessageType = {GUI_CP_INGAME_OPEN_IMPLEMENT_PROFILES = 1}
    g_messageCenter = {publish = function() opened = true end}
    manager:updateVehicle(v)
    g_time = 501
    manager:updateVehicle(v)
    lu.assertNil(v.cpImplementProfile)
    callback(3)
    lu.assertNil(v.cpImplementProfile)
    callback(2)
    lu.assertTrue(opened)
    lu.assertNil(v.cpImplementProfile)
    callback(1)
    lu.assertNotNil(v.cpImplementProfile)
end

function TestImplementProfiles:testMultipleMatchPromptSelectsOnlyConfirmedProfile()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    manager:save(v, 'A setup')
    v.vehicleSettings.turnSpeed.value = 5
    local second = manager:save(v, 'B setup')
    v.vehicleSettings.turnSpeed.value = 8
    v.getIsEntered = function() return true end
    v.cpProfileInitialised = true
    ImplementProfileManager.markChanged(v, nil, true)
    g_gui.getIsGuiVisible = function() return false end
    g_Courseplay.globalSettings = {showImplementProfileSuggestions = setting(true), autoLoadSingleImplementProfile = setting(false)}
    local callback, choices
    CpImplementProfileDialog = {show = function(profiles, load, view)
        choices = {}
        for _, profile in ipairs(profiles) do table.insert(choices, profile.name) end
        callback = function(choice) if choice > 0 then load(profiles[choice]) end end
    end}
    manager:updateVehicle(v)
    g_time = 501
    manager:updateVehicle(v)
    lu.assertEquals(choices, {'A setup', 'B setup'})
    lu.assertNil(v.cpImplementProfile)
    callback(0)
    lu.assertNil(v.cpImplementProfile)
    callback(2)
    lu.assertEquals(v.cpImplementProfile.profile.id, second.id)
    lu.assertEquals(v.vehicleSettings.turnSpeed.value, 5)
end

function TestImplementProfiles:testAutomaticLoadRejectsChangedEquipmentAndConflictingCourse()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local profile = manager:save(v, 'Normal')
    v.getIsEntered = function() return true end
    v.getFieldWorkCourse = function() return {getWorkWidth = function() return 12 end} end
    manager:loadAttachmentProfile(v, profile, true)
    lu.assertNil(v.cpImplementProfile)
    v.getFieldWorkCourse = function() return nil end
    v.attachments = {}
    manager:loadAttachmentProfile(v, profile, true)
    lu.assertNil(v.cpImplementProfile)
end

function TestImplementProfiles:testStartupDoesNotOfferOrAutoLoadAlreadyAttachedEquipment()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    manager:save(v, 'Normal')
    v.getIsEntered = function() return true end
    g_gui.getIsGuiVisible = function() return false end
    g_Courseplay.globalSettings = {showImplementProfileSuggestions = setting(true), autoLoadSingleImplementProfile = setting(true)}
    local offers = 0
    CpImplementProfileDialog = {show = function() offers = offers + 1 end}
    -- Attachment callbacks during loading precede the first vehicle update.
    ImplementProfileManager.markChanged(v, nil, true)
    manager:updateVehicle(v)
    g_time = 501
    manager:updateVehicle(v)
    lu.assertEquals(offers, 0)
    lu.assertNil(v.cpImplementProfile)
    ImplementProfileManager.markChanged(v)
    g_time = 1002
    manager:updateVehicle(v)
    lu.assertEquals(offers, 0)
    ImplementProfileManager.markChanged(v, nil, true)
    g_time = 1503
    manager:updateVehicle(v)
    lu.assertEquals(offers, 1)
end

function TestImplementProfiles:testDisabledOffsetsAreNotCaptured()
    local v = vehicle()
    v.vehicleSettings.toolOffsetX.disabled = true
    lu.assertNil(ImplementProfile.capture(v)['vehicle.toolOffsetX'])
end

function TestImplementProfiles:testWorkingCopyAndOriginalBaselineSurviveProfileSwitch()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local profile = profileFor(v)
    profile.settings['vehicle.turnSpeed'] = 5
    lu.assertTrue(manager:apply(v, profile))
    v.vehicleSettings.turnSpeed.value = 4
    lu.assertEquals(profile.settings['vehicle.turnSpeed'], 5)
    profile.settings['vehicle.turnSpeed'] = 3
    lu.assertTrue(manager:apply(v, profile))
    lu.assertEquals(v.cpImplementProfile.baseline['vehicle.turnSpeed'], 8)
    manager:clear(v)
    lu.assertEquals(v.vehicleSettings.turnSpeed.value, 8)
    lu.assertEquals(v.generatorSettings.workWidth.value, 3)
    lu.assertNil(v.cpImplementProfile)
end

function TestImplementProfiles:testSavegameRestoresWorkingCopyWithoutLibrary()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    lu.assertTrue(manager:apply(v, profileFor(v)))
    v.vehicleSettings.turnSpeed.value = 4
    local values = {}
    manager:saveVehicle(v, xmlFile(values), 'vehicle.profile')
    local restored = vehicle('differentTractor')
    manager:loadVehicle(restored, {xmlFile = xmlFile(values)}, 'vehicle.profile')
    manager.profiles = {}
    manager:updateVehicle(restored)
    g_time = 501
    manager:updateVehicle(restored)
    lu.assertEquals(restored.vehicleSettings.turnSpeed.value, 4)
    lu.assertNotNil(restored.cpImplementProfile)
    lu.assertEquals(restored.cpImplementProfile.baseline['vehicle.turnSpeed'], 8)
end

function TestImplementProfiles:testDetachRestoresBaselineAfterDebounce()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    local profile = profileFor(v)
    profile.settings['vehicle.turnSpeed'] = 5
    lu.assertTrue(manager:apply(v, profile))
    manager:updateVehicle(v)
    g_time = 501
    manager:updateVehicle(v)
    ImplementProfileManager.markChanged(v)
    v.attachments = {}
    g_time = 800
    manager:updateVehicle(v)
    lu.assertNotNil(v.cpImplementProfile)
    g_time = 1002
    manager:updateVehicle(v)
    lu.assertNil(v.cpImplementProfile)
    lu.assertEquals(v.vehicleSettings.turnSpeed.value, 8)
end

function TestImplementProfiles:testTransientAttachCallbacksDoNotLoseJobAdjustments()
    local manager, v = g_Courseplay.implementProfiles, vehicle()
    lu.assertTrue(manager:apply(v, profileFor(v)))
    manager:updateVehicle(v)
    g_time = 501
    manager:updateVehicle(v)
    v.vehicleSettings.turnSpeed.value = 4
    ImplementProfileManager.markChanged(v)
    v.vehicleSettings.turnSpeed.value = 8
    ImplementProfileManager.markChanged(v, nil, true)
    g_time = 1002
    manager:updateVehicle(v)
    lu.assertEquals(v.vehicleSettings.turnSpeed.value, 4)
end

function TestImplementProfiles:testJoiningClientRestoresAfterLoadCallbacks()
    local manager, source, target = g_Courseplay.implementProfiles, vehicle(), vehicle()
    local profile = profileFor(source)
    profile.settings['vehicle.turnSpeed'] = 4
    manager:apply(source, profile)
    local wire = {values = {}, pos = 1}
    ImplementProfileEvent.writeVehicle(wire, source)
    target.isServer = false
    ImplementProfileEvent.readVehicle(wire, target)
    target.vehicleSettings.turnSpeed.value = 8
    manager:updateVehicle(target)
    g_time = 501
    manager:updateVehicle(target)
    lu.assertEquals(target.vehicleSettings.turnSpeed.value, 4)
end

local function write(wire, value) table.insert(wire.values, value) end
local function read(wire) local value = wire.values[wire.pos]; wire.pos = wire.pos + 1; return value end
streamWriteString, streamWriteUInt8, streamWriteInt32, streamWriteBool = write, write, write, write
streamReadString, streamReadUInt8, streamReadInt32, streamReadBool = read, read, read, read
NetworkUtil = {writeNodeObject = write, readNodeObject = read}

function TestImplementProfiles:testWireRoundTripPreservesBooleanValuesAndCombination()
    local v = vehicle(nil, {{object = implement('plough')}, {object = implement('drill', 'spec_sowingMachine')}})
    local profile = profileFor(v)
    local wire = {values = {}, pos = 1}
    ImplementProfileEvent.writeProfile(wire, profile)
    lu.assertEquals(ImplementProfileEvent.readProfile(wire), profile)
end

function TestImplementProfiles:testServerRejectsUnauthorisedRequest()
    local v = vehicle()
    local response
    local connection = {getIsServer = function() return false end, sendEvent = function(_, event) response = event end}
    g_farmManager.getFarmByUserId = function() return {farmId = 2} end
    ImplementProfileEvent.new(v, profileFor(v), true):run(connection)
    lu.assertNil(v.cpImplementProfile)
    lu.assertEquals(response.errorKey, 'noAccess')
    lu.assertEquals(broadcasts, 0)
end

function TestImplementProfiles:testServerValidatesAndBroadcastsOneBatch()
    local v = vehicle()
    local connection = {getIsServer = function() return false end}
    ImplementProfileEvent.new(v, profileFor(v), true):run(connection)
    lu.assertNotNil(v.cpImplementProfile)
    lu.assertEquals(broadcasts, 1)
end

function TestImplementProfiles:testClientCannotSendAuthoritativeState()
    local source, target = vehicle(), vehicle()
    source.vehicleSettings.turnSpeed.value = 4
    local wire = {values = {}, pos = 1}
    NetworkUtil.writeNodeObject(wire, target)
    streamWriteBool(wire, false)
    streamWriteString(wire, '')
    ImplementProfileEvent.writeVehicle(wire, source)
    ImplementProfileEvent.emptyNew():readStream(wire, {getIsServer = function() return false end})
    lu.assertEquals(target.vehicleSettings.turnSpeed.value, 8)
end

local function widget()
    return {setText = function() end, setVisible = function() end, setSelected = function() end,
        reloadData = function() end, getSelectedIndexInSection = function() return 1 end}
end

function TestImplementProfiles:testExpandableTypeAndModelTree()
    local v, manager = vehicle(), g_Courseplay.implementProfiles
    manager:save(v, 'Normal')
    manager:save(v, 'Slow turns')
    local frame = CpImplementProfilesFrame.new()
    frame.vehicle, frame.cpMenu = v, {defaultMenuButtonInfo = {}}
    for _, name in ipairs({'profileList', 'detailList', 'equipmentFilter', 'emptyText', 'activeText'}) do
        frame[name] = widget()
    end
    frame.setMenuButtonInfoDirty = function() end
    frame:refresh()
    lu.assertEquals(#frame.rows, 4)
    lu.assertEquals(frame.rows[1].key, 'ploughs')
    frame:toggleRow(frame.rows[1])
    lu.assertEquals(#frame.rows, 1)
    frame:toggleRow(frame.rows[1])
    lu.assertEquals(#frame.rows, 4)
    lu.assertEquals(frame.rows[3].profile.name, 'Normal')
    lu.assertEquals(frame.rows[4].profile.name, 'Slow turns')
    frame.vehicle = vehicle(nil, {})
    frame:refresh()
    lu.assertEquals(#frame.rows, 0)
    frame.equipmentFilter.getState = function() return 2 end
    frame:onClickEquipmentFilter()
    lu.assertEquals(#frame.rows, 2)
end

function TestImplementProfiles:testCombinationAppearsUnderItsComponentTypes()
    local v = vehicle(nil, {{object = implement('plough')}, {object = implement('drill', 'spec_sowingMachine')}})
    local profile = g_Courseplay.implementProfiles:save(v, 'Combination')
    local frame = CpImplementProfilesFrame.new()
    frame.vehicle, frame.cpMenu = v, {defaultMenuButtonInfo = {}}
    for _, name in ipairs({'profileList', 'detailList', 'equipmentFilter', 'emptyText', 'activeText'}) do
        frame[name] = widget()
    end
    frame.setMenuButtonInfoDirty = function() end
    frame:refresh()
    local categories, links = {}, 0
    for _, row in ipairs(frame.rows) do
        if row.key then categories[row.key] = true end
        if row.profile then lu.assertEquals(row.profile.id, profile.id); links = links + 1 end
    end
    lu.assertTrue(categories.combinations)
    lu.assertTrue(categories.ploughs)
    lu.assertTrue(categories.seedDrills)
    lu.assertEquals(links, 3)
end

function TestImplementProfiles:testSaveFromFieldworkSettings()
    local v = vehicle()
    local frame = setmetatable({}, {__index = CpCourseGeneratorFrame})
    frame.cpMenu = {getCurrentVehicle = function() return v end}
    local callback
    local oldDialog = TextInputDialog
    TextInputDialog = {show = function(fn) callback = fn end}
    local selected
    frame.updateSubCategoryPages = function(self)
        self.fieldworkProfiles = g_Courseplay.implementProfiles:getMatchingProfiles(v)
        self.fieldworkProfileSelector = {setValue = function(_, value) selected = value end}
        self.fieldworkProfileControl = {setDataSource = function() end}
    end
    frame:saveFieldworkProfile()
    callback(nil, 'Cancelled', false)
    lu.assertNil(next(g_Courseplay.implementProfiles.profiles))
    frame:saveFieldworkProfile()
    callback(nil, 'Fieldwork setup', true)
    lu.assertEquals(#frame.fieldworkProfiles, 1)
    lu.assertEquals(frame.fieldworkProfiles[1].name, 'Fieldwork setup')
    lu.assertEquals(frame.fieldworkProfiles[1].settings, ImplementProfile.capture(v))
    lu.assertEquals(selected, 1)
    TextInputDialog = oldDialog
end

function TestImplementProfiles:testNoProfileDefaultsAndKeepCurrent()
    local v, manager = vehicle(), g_Courseplay.implementProfiles
    local signature = ImplementProfile.signature(ImplementProfile.describe(v))
    v.generatorSettings.numberOfHeadlands.value = 9
    v.vehicleSettings.raiseImplementLateOverrideEnabled = setting(true)
    local snapshot = ImplementProfile.capture(v)
    v.cpProfileLastWorkingSettings = snapshot
    v.generatorSettings.numberOfHeadlands.value = 2
    lu.assertTrue(manager:withoutProfile(v, signature, false))
    lu.assertEquals(v.generatorSettings.numberOfHeadlands.value, 9)
    lu.assertNil(v.cpImplementProfile)
    lu.assertTrue(manager:withoutProfile(v, signature, true))
    lu.assertNotEquals(v.generatorSettings.numberOfHeadlands.value, 9)
    lu.assertEquals(v.generatorSettings.workWidth.value, 3)
    lu.assertTrue(v.vehicleSettings.raiseImplementLateOverrideEnabled:getValue())
end

function TestImplementProfiles:testNoProfileRejectsChangedEquipmentOrBusyVehicle()
    local v, manager = vehicle(), g_Courseplay.implementProfiles
    local before = ImplementProfile.capture(v)
    lu.assertFalse(manager:withoutProfile(v, 'stale equipment', true))
    lu.assertEquals(ImplementProfile.capture(v), before)
    v.lastSpeedReal = 1
    lu.assertFalse(manager:withoutProfile(v, ImplementProfile.signature(ImplementProfile.describe(v)), true))
    lu.assertEquals(ImplementProfile.capture(v), before)
end

-- Shared dialogue regressions: cancellation and delayed callbacks must not change another setup.
function TestImplementProfiles:testNamingRechecksVehicleAndAttachment()
    local first, second = vehicle(), vehicle('second')
    local current, callback, errorText = first
    local oldText, oldInfo = TextInputDialog, InfoDialog
    TextInputDialog = {show = function(fn, target) lu.assertEquals(target, CpImplementProfileGui); callback = fn end}
    InfoDialog = {show = function(text) errorText = text end}
    local saved = false
    local function open()
        CpImplementProfileGui.saveNew(function() return current end, 'CP_implementProfiles_saveNew', function() saved = true end)
    end
    open()
    current = second
    callback(nil, 'Wrong tractor', true)
    lu.assertEquals(errorText, 'CP_implementProfiles_mismatch')
    lu.assertNil(next(g_Courseplay.implementProfiles.profiles))
    current = first
    open()
    first.attachments = {}
    callback(nil, 'Detached', true)
    lu.assertFalse(saved)
    lu.assertNil(next(g_Courseplay.implementProfiles.profiles))
    TextInputDialog, InfoDialog = oldText, oldInfo
end

function TestImplementProfiles:testWidthWarningCancelSilentAndConfirmation()
    local v = vehicle()
    v.getFieldWorkCourse = function() return {getWorkWidth = function() return 12 end} end
    local callback, resumed, shown = nil, 0, 0
    local oldDialog = YesNoDialog
    YesNoDialog = {show = function(fn, target) lu.assertEquals(target, CpImplementProfileGui); callback = fn; shown = shown + 1 end}
    local function resume() resumed = resumed + 1 end
    local profile = profileFor(v)
    lu.assertFalse(CpImplementProfileGui.confirmCourseWidth(v, profile, false, true, resume))
    lu.assertEquals(shown, 0)
    lu.assertFalse(CpImplementProfileGui.confirmCourseWidth(v, profile, false, false, resume))
    callback(nil, false)
    lu.assertEquals(resumed, 0)
    callback(nil, true)
    lu.assertEquals(resumed, 1)
    lu.assertTrue(CpImplementProfileGui.confirmCourseWidth(v, profile, true, false, resume))
    lu.assertEquals(shown, 1)
    v.getFieldWorkCourse = function() return {getWorkWidth = function() return 6.01 end} end
    lu.assertTrue(CpImplementProfileGui.confirmCourseWidth(v, profile, false, false, resume))
    YesNoDialog = oldDialog
end

function TestImplementProfiles:testWidthConfirmationCannotLoadAChangedSelection()
    local v = vehicle()
    local manager = g_Courseplay.implementProfiles
    local first = manager:save(v, 'First')
    v.generatorSettings.workWidth.value = 3
    local second = manager:save(v, 'Second')
    v.getFieldWorkCourse = function() return {getWorkWidth = function() return 12 end} end
    local frame = setmetatable({fieldworkProfileVehicle = v, fieldworkProfiles = {first, second},
        fieldworkProfileSelector = setting(1), cpMenu = {getCurrentVehicle = function() return v end}},
        {__index = CpCourseGeneratorFrame})
    local callback
    local oldDialog = YesNoDialog
    YesNoDialog = {show = function(fn) callback = fn end}
    frame:loadFieldworkProfile()
    frame.fieldworkProfileSelector.value = 2
    callback(nil, true)
    lu.assertNil(v.cpImplementProfile)
    lu.assertEquals(v.generatorSettings.workWidth.value, 3)
    frame:loadFieldworkProfile()
    callback(nil, true)
    lu.assertEquals(v.cpImplementProfile.profile.id, second.id)
    YesNoDialog = oldDialog
end

-- Exercise real page construction with reordered sections and an unrelated extra section.
function TestImplementProfiles:testGlobalSectionsUseKeysInsteadOfPositions()
    require('CpGlobalSettingsFrame')
    local oldSuper = CpGlobalSettingsFrame.superClass
    CpGlobalSettingsFrame.superClass = function() return {onFrameOpen = function() end} end
    local oldSettings, oldUtil, oldFocus = g_Courseplay.globalSettings, CpSettingsUtil, FocusManager
    local general, user, profiles = 'CP_global_setting_subTitle_general', 'CP_global_setting_subTitle_userSettings', 'CP_implementProfiles_title'
    g_Courseplay.globalSettings = {
        getSettings = function() return {} end,
        getSettingSetup = function() return {{title = profiles}, {title = 'unrelated'}, {title = user}, {title = general}} end
    }
    local layouts = {{}, {}}
    CpSettingsUtil = {
        generateAndBindGuiElements = function(data, layout) table.insert(layout, data.title) end,
        updateGuiElementsBoundToSettings = function() end
    }
    FocusManager = {loadElementFromCustomValues = function() end}
    local frame = setmetatable({subCategoryPages = {
        {getDescendantByName = function() return layouts[1] end},
        {getDescendantByName = function() return layouts[2] end}},
        sectionHeaderPrefab = {clone = function() return {setText = function() end} end},
        superClass = function() return {onFrameOpen = function() end} end,
        updateSubCategoryPages = function() end}, {__index = CpGlobalSettingsFrame})
    frame:onFrameOpen()
    lu.assertEquals(layouts[1], {general})
    lu.assertEquals(layouts[2], {profiles, user})
    g_Courseplay.globalSettings, CpSettingsUtil, FocusManager = oldSettings, oldUtil, oldFocus
    CpGlobalSettingsFrame.superClass = oldSuper
end

-- Verify the native-skin boundary strips only the clone, preserving graphics and the original GUI.
function TestImplementProfiles:testNativeQuestionShellLeavesSharedDialogueUntouched()
    local oldDialog, oldBase = CpImplementProfileDialog, DialogElement
    local oldText, oldButton, oldBox = TextElement, ButtonElement, BoxLayoutElement
    DialogElement, TextElement, ButtonElement, BoxLayoutElement = {}, {}, {}, {}
    dofile('../gui/CpImplementProfileDialog.lua')
    local function node(kind, children)
        local item = {kind = kind, elements = children or {}}
        item.isa = function(self, class) return self.kind == class end
        item.delete = function(self)
            for i, child in ipairs(self.parent.elements) do
                if child == self then table.remove(self.parent.elements, i); break end
            end
        end
        for _, child in ipairs(item.elements) do child.parent = item end
        item.clone = function(self, parent)
            local copies = {}
            for _, child in ipairs(self.elements) do table.insert(copies, child:clone()) end
            local copy = node(self.kind, copies)
            copy.parent = parent
            return copy
        end
        return item
    end
    local graphics = {}
    local template = node(graphics, {node(TextElement), node(graphics, {node(ButtonElement), node(graphics)}), node(BoxLayoutElement)})
    local shell = CpImplementProfileDialog.cloneQuestionShell(template, {})
    lu.assertEquals(#template.elements, 3)
    lu.assertEquals(#template.elements[2].elements, 2)
    lu.assertEquals(#shell.elements, 1)
    lu.assertEquals(#shell.elements[1].elements, 1)
    lu.assertEquals(shell.elements[1].elements[1].kind, graphics)
    lu.assertError(CpImplementProfileDialog.cloneQuestionShell, nil, {})
    CpImplementProfileDialog, DialogElement = oldDialog, oldBase
    TextElement, ButtonElement, BoxLayoutElement = oldText, oldButton, oldBox
end

os.exit(lu.LuaUnit.run())
