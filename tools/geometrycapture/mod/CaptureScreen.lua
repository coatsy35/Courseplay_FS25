-- Non-modal HUD: no dialog, input context change or mission pause. Only
-- pointer interaction suspends camera rotation; driving keys remain active.
VGCCaptureScreen={}
VGCCaptureScreen.__index=VGCCaptureScreen

function VGCCaptureScreen.new(capture)
    return setmetatable({capture=capture,x=.025,y=.23,w=.36,h=.51,buttons={}},VGCCaptureScreen)
end

function VGCCaptureScreen:setPointer(enabled,restorePrevious)
    if enabled then
        if self.pointerOwned then
            g_inputBinding:setShowMouseCursor(true)
            for camera in pairs(self.savedCameras or {}) do camera.isRotatable=false end
            return
        end
        self.previousCursor=g_inputBinding:getShowMouseCursor()
        self.savedCameras={}
        local vehicle=self.capture:vehicle()
        for _,camera in pairs(vehicle and vehicle.spec_enterable and vehicle.spec_enterable.cameras or {}) do
            self.savedCameras[camera]=camera.isRotatable
            camera.isRotatable=false
        end
        self.pointerOwned=true
        g_inputBinding:setShowMouseCursor(true)
    elseif self.pointerOwned then
        for camera,rotatable in pairs(self.savedCameras or {}) do camera.isRotatable=rotatable end
        g_inputBinding:setShowMouseCursor(restorePrevious and self.previousCursor or false)
        self.pointerOwned=false
        self.savedCameras=nil
        self.drag=nil
        self.pressed=nil
    end
end

function VGCCaptureScreen:open()
    self.isOpen=true
    self.capture.lastVehicle=self.capture:vehicle()
    self:setPointer(true)
end

function VGCCaptureScreen:close()
    self:setPointer(false,true)
    self.isOpen=false
end

function VGCCaptureScreen:layout()
    self.h=self.detailsExpanded and .69 or .51
    self.w=math.min(.6,.36*(16/9)/(g_screenAspectRatio or 16/9))
    self.x=math.max(0,math.min(1-self.w,self.x))
    self.y=math.max(0,math.min(1-self.h,self.y))
    local c=self.capture
    local object=c:selection()
    local tags=object and c:tags(object) or {}
    self.buttons={}
    local function button(id,text,x,y,w,h,action,disabled)
        self.buttons[#self.buttons+1]={id=id,text=text,x=x,y=y,w=w,h=h,action=action,disabled=disabled}
    end
    local top=self.y+self.h
    button('close','X',self.x+self.w-.032,top-.036,.028,.031,function() self:close() end)
    local y=top-.085
    local function selector(id,text,action,disabled)
        button(id..'-previous','<',self.x+.012,y,.028,.034,function() action(-1) end,disabled)
        button(id,text..'  >',self.x+.045,y,self.w-.057,.034,function() action(1) end,disabled)
        y=y-.045
    end
    local count=#VGCGeometry.objects(c:vehicle())
    selector('machine',object and VGCGeometry.identity(object).name or 'Enter a tractor',function(step)
        c.selected=((c.selected-1+step)%math.max(1,count))+1
    end,c.recording~=nil or not object)
    local names={steering='Steering',runningGear='Wheels / tracks',implement='Implement',pivots='Pivots'}
    button('labels',self.detailsExpanded and 'Optional labels: hide' or 'Optional labels: show',
        self.x+.012,y,self.w-.024,.034,function() self.detailsExpanded=not self.detailsExpanded end)
    y=y-.04
    if self.detailsExpanded then
        for _,field in ipairs(c.tagFields) do
            selector(field,names[field]..': '..c.tagOptions[field][tags[field] or 1],
                function(step) c:cycleTag(field,step) end,c.recording~=nil or not object)
        end
    end
    selector('state','State label: '..c.labels[c.labelIndex],function(step)
        c.labelIndex=((c.labelIndex-1+step)%#c.labels)+1
    end,c.recording~=nil)
    self.noteY=y+.013
    y=y-.037
    button('capture','Save selected machine',self.x+.012,y,self.w-.024,.036,function() c:capture() end,not object)
    y=y-.046
    button('record',c.recording and 'STOP RECORDING' or 'Start recording all machines',self.x+.012,y,self.w-.024,.036,
        function() c:toggleRecord() end,not object and not c.recording)
    y=y-.046
    button('drive','Drive / camera (keep panel)',self.x+.012,y,self.w-.024,.036,function() self:setPointer(false) end)
    self.statusY=y-.028
end

local function inside(b,x,y)
    return x>=b.x and x<=b.x+b.w and y>=b.y and y<=b.y+b.h
end

function VGCCaptureScreen:mouseEvent(x,y,isDown,isUp,button)
    if not self.isOpen or g_gui:getIsGuiVisible() or not g_inputBinding:getShowMouseCursor() then return false end
    self:layout()
    self.mouseX,self.mouseY=x,y
    if self.drag then
        self.x=math.max(0,math.min(1-self.w,x-self.drag.x))
        self.y=math.max(0,math.min(1-self.h,y-self.drag.y))
        if isUp and button==Input.MOUSE_BUTTON_LEFT then self.drag=nil end
        return true
    end
    -- Do not intercept wheel/zoom or right-click bindings.
    if button~=Input.MOUSE_BUTTON_LEFT then return false end
    local hit
    for _,b in ipairs(self.buttons) do if inside(b,x,y) then hit=b;break end end
    if isDown then
        if hit then self.pressed=not hit.disabled and hit.id or nil;return true end
        if inside({x=self.x,y=self.y+self.h-.04,w=self.w-.034,h=.04},x,y) then
            self.drag={x=x-self.x,y=y-self.y};return true
        end
    elseif isUp then
        local pressed=self.pressed;self.pressed=nil
        if hit and not hit.disabled and hit.id==pressed then hit.action();return true end
    end
    return false
end

function VGCCaptureScreen:draw()
    if g_gui:getIsGuiVisible() then return end
    if not self.isOpen then
        if self.capture.recording then
            drawFilledRect(.02,.93,.28,.035,.12,.2,.15,.9)
            setTextAlignment(RenderText.ALIGN_LEFT);setTextColor(1,1,1,1)
            renderText(.03,.94,.014,'Geometry recording - open panel to stop')
        end
        return
    end
    self:layout()
    drawFilledRect(self.x,self.y,self.w,self.h,.035,.05,.045,.94)
    drawFilledRect(self.x,self.y+self.h-.04,self.w,.04,.1,.35,.23,1)
    setTextAlignment(RenderText.ALIGN_LEFT);setTextColor(1,1,1,1)
    setTextBold(true)
    renderText(self.x+.012,self.y+self.h-.028,.016,'GEOMETRY CAPTURE v0.3 - drag title')
    setTextBold(false)
    for _,b in ipairs(self.buttons) do
        local hover=self.mouseX and inside(b,self.mouseX,self.mouseY)
        local green=b.id=='record' and self.capture.recording
        drawFilledRect(b.x,b.y,b.w,b.h,green and .4 or .13,hover and .32 or .23,.19,1)
        setTextColor(1,1,1,b.disabled and .4 or 1)
        local text=b.text
        while #text>4 and getTextWidth(.014,text)>b.w-.012 do text=text:sub(1,-5)..'...' end
        renderText(b.x+.006,b.y+.009,.014,text)
    end
    setTextColor(.8,.86,.82,1)
    renderText(self.x+.012,self.noteY,.012,'Labels optional; geometry and all attachments are captured.')
    local status=self.capture.recording and string.format('Recording: %d samples / %.1f s',
        self.capture.recording.samples,(self.capture.clock-self.capture.recording.started)/1000) or 'Ready'
    renderText(self.x+.012,self.statusY,.013,status)
    local help=g_inputBinding:getShowMouseCursor() and 'Keys still drive / start CP. Drive / camera releases the mouse.'
        or 'Driving mode. Use Capture: show panel to click buttons again.'
    setTextWrapWidth(self.w-.024)
    renderText(self.x+.012,self.statusY-.023,.012,help)
    renderText(self.x+.012,self.y+.045,.012,(self.capture.message or ''):sub(1,190))
    setTextWrapWidth(0);setTextColor(1,1,1,1);setTextBold(false)
end
