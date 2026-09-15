-- Standalone native menu: GIANTS owns focus, mouse cursor and input routing.
-- Opening/closing this menu never operates a machine or stops a recording.
VGCCaptureScreen={}
local mt=Class(VGCCaptureScreen,DialogElement)

function VGCCaptureScreen.new(capture)
    local self=DialogElement.new(nil,mt)
    self.capture=capture
    self:exposeControlsAsFields({MACHINE='machineSelector',CATEGORY='categorySelector',
        LABEL='labelSelector',STATUS='statusText',CAPTURE='captureButton',RECORD='recordButton'})
    return self
end

function VGCCaptureScreen:onOpen()
    VGCCaptureScreen:superClass().onOpen(self)
    self.isOpen=true
    self:refresh()
    FocusManager:setFocus(self.machineSelector)
end

-- The dialog background profile supplies sizing, but its native bitmap
-- slices belong to the loaded Yes/No template. Clone only that shell; never
-- edit the shared dialog or depend on another mod's GUI/assets.
function VGCCaptureScreen:useNativeBackground()
    local native=g_gui.guis and g_gui.guis.YesNoDialog
    if not native or not native.target.dialogElement then return end
    local content=self.dialogElement
    local shell=native.target.dialogElement:clone(self,false,true)
    local function strip(element)
        for i=#element.elements,1,-1 do
            local child=element.elements[i]
            if child:isa(TextElement) or child:isa(ButtonElement) or child:isa(BoxLayoutElement) then
                child:delete()
            else strip(child) end
        end
    end
    strip(shell)
    shell:setSize(unpack(content.size))
    while #content.elements>0 do
        local child=content.elements[1]
        child:unlinkElement();shell:addElement(child)
    end
    content:delete()
    self.dialogElement=shell
end

function VGCCaptureScreen:onClose()
    self.isOpen=false
    VGCCaptureScreen:superClass().onClose(self)
end

function VGCCaptureScreen:refresh()
    local c=self.capture
    local objects=VGCGeometry.objects(c:vehicle())
    local names={}
    for i,entry in ipairs(objects) do names[i]=VGCGeometry.identity(entry.object).name end
    if #names==0 then names[1]='Enter a tractor first' end
    self.machineSelector:setTexts(names)
    local object=c:selection()
    self.machineSelector:setState(c.selected)
    self.categorySelector:setTexts(c.categories)
    self.categorySelector:setState(object and c.categoriesByObject[object] or 1)
    self.labelSelector:setTexts(c.labels)
    self.labelSelector:setState(c.labelIndex)
    self.machineSelector:setDisabled(c.recording~=nil or not object)
    self.categorySelector:setDisabled(c.recording~=nil or not object)
    self.labelSelector:setDisabled(c.recording~=nil)
    self.captureButton:setDisabled(not object)
    self.recordButton:setDisabled(not object and not c.recording)
    self.recordButton:setText(c.recording and 'Stop recording' or 'Start recording')
    self.statusText:setText(c.message or 'Ready')
end

function VGCCaptureScreen:onMachineChanged(state)
    if not self.capture.recording then self.capture.selected=state end
    self:refresh()
end

function VGCCaptureScreen:onCategoryChanged(state)
    local c=self.capture
    local object=c:selection()
    if object and not c.recording then c.categoriesByObject[object]=state end
end

function VGCCaptureScreen:onLabelChanged(state)
    if not self.capture.recording then self.capture.labelIndex=state end
end

function VGCCaptureScreen:onClickCapture()
    self.capture:capture()
    self:refresh()
end

function VGCCaptureScreen:onClickRecord()
    self.capture:toggleRecord()
    self:refresh()
end

function VGCCaptureScreen:onClickBack() self:close() end
