CpBinaryOptionElement = {}
local CpBinaryOptionElement_mt = Class(CpBinaryOptionElement, BinaryOptionElement)

function CpBinaryOptionElement.new(target, custom_mt)
	local self = BinaryOptionElement.new(target, custom_mt or CpBinaryOptionElement_mt)
	self.dataSource = nil
	self.toolTipElement = nil
	return self
end

function CpBinaryOptionElement:delete()
	self.dataSource = nil

	CpBinaryOptionElement:superClass().delete(self)
end

function CpBinaryOptionElement:setDataSource(dataSource)
	self.dataSource = dataSource
	self.useYesNoTexts = false
    self.bindingDataSource = true
	self:setTexts({self.dataSource.texts[1], self.dataSource.texts[2]})
    -- Binding is a display refresh, never a user click or setting mutation.
    local state = dataSource:getValue() and BinaryOptionElement.STATE_RIGHT or BinaryOptionElement.STATE_LEFT
    CpBinaryOptionElement:superClass().setState(self, state, false, true)
    self.bindingDataSource = false
    self:updateTitle()
end
function CpBinaryOptionElement:updateTitle()
	if self.labelElement then 
		self.labelElement:setText(self.dataSource:getTitle())
	end
	self.toolTipElement = self:getDescendantByName("tooltip")
	if self.toolTipElement then 
		self.toolTipText = self.dataSource:getTooltip()
	end
end

function CpBinaryOptionElement:raiseClickCallback(...)
    if not self.bindingDataSource then
        return CpBinaryOptionElement:superClass().raiseClickCallback(self, ...)
    end
end

function CpBinaryOptionElement:setState(state, forceEvent, skipAnimation)
    if not self.dataSource then
        return CpBinaryOptionElement:superClass().setState(self, state, forceEvent, skipAnimation)
    end
	if state == BinaryOptionElement.STATE_RIGHT then 
		self.dataSource:setValue(true)
	else 
		self.dataSource:setValue(false)
	end
	self:updateTitle()
	if self.dataSource:getValue() then 
		CpBinaryOptionElement:superClass().setState(self, BinaryOptionElement.STATE_RIGHT, forceEvent, skipAnimation)
	else
		CpBinaryOptionElement:superClass().setState(self, BinaryOptionElement.STATE_LEFT, forceEvent, skipAnimation)
	end
end

Gui.registerGuiElement("CpBinaryyOption", CpBinaryOptionElement)
