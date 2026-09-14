--- Attachment chooser: profile names in the selector, actions on separate buttons.
CpImplementProfileDialog = {}
local CpImplementProfileDialog_mt = Class(CpImplementProfileDialog, DialogElement)

function CpImplementProfileDialog.new()
    return DialogElement.new(nil, CpImplementProfileDialog_mt)
end

function CpImplementProfileDialog.setupGui()
    g_gui:loadGui(Utils.getFilename('config/gui/ImplementProfileDialog.xml', Courseplay.BASE_DIRECTORY),
        'CpImplementProfileDialog', CpImplementProfileDialog.new())
    local dialog = g_gui.guis.CpImplementProfileDialog.target
    dialog:useNativeQuestionBackground(g_gui.guis.YesNoDialog.target.dialogElement)
end

--- Reuse the loaded game's Yes/No shell, including its actual background slices.
-- A private clone avoids modifying the shared YesNoDialog or its callbacks.
function CpImplementProfileDialog:useNativeQuestionBackground(template)
    local content = self.dialogElement
    local shell = template:clone(self, false, true)
    local function removeContent(element)
        for i = #element.elements, 1, -1 do
            local child = element.elements[i]
            if child:isa(TextElement) or child:isa(ButtonElement) or child:isa(BoxLayoutElement) then
                child:delete()
            else
                removeContent(child)
            end
        end
    end
    removeContent(shell)
    shell:setSize(unpack(content.size))
    while #content.elements > 0 do
        local child = content.elements[1]
        child:unlinkElement()
        shell:addElement(child)
    end
    content:delete()
    self.dialogElement = shell
end

function CpImplementProfileDialog.show(profiles, onLoad, onView, onSkip)
    local dialog = g_gui.guis.CpImplementProfileDialog.target
    dialog.profiles = ImplementProfile.copy(profiles)
    dialog.loadCallback, dialog.viewCallback, dialog.skipCallback = onLoad, onView, onSkip
    local texts = {}
    for i, profile in ipairs(dialog.profiles) do texts[i] = profile.name end
    -- Native selector state is configured after opening, which may reset GUI elements.
    g_gui:showDialog('CpImplementProfileDialog')
    dialog.profileSelector:setTexts(texts)
    dialog.profileSelector:setState(1)
    FocusManager:setFocus(dialog.profileSelector)
end

function CpImplementProfileDialog:onClickLoad()
    local profile = self.profiles and self.profiles[self.profileSelector:getState()]
    local callback = self.loadCallback
    self:close()
    if profile and callback then callback(profile) end
end

function CpImplementProfileDialog:onClickView()
    local callback = self.viewCallback
    self:close()
    if callback then callback() end
end

function CpImplementProfileDialog:onClickBack()
    local callback = self.skipCallback
    self:close()
    if callback then callback() end
end

function CpImplementProfileDialog:onClose()
    self.profiles, self.loadCallback, self.viewCallback, self.skipCallback = nil, nil, nil, nil
    CpImplementProfileDialog:superClass().onClose(self)
end
