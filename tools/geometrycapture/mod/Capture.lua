-- Standalone, opt-in capture. Never commands steering, hydraulics or AI.
VehicleGeometryCapture = {visible=false,selected=1,labelIndex=1,events={},clock=0,serial=0}
local C,G = VehicleGeometryCapture,VGCGeometry
C.categories={'unclassified','front-wheel-steer','four-wheel-steer','articulated','twin-track',
              'mounted','long-trailed','long-narrow-trailed','wide-short-trailed','multiple-pivots'}
C.labels={'unspecified','straight-raised','straight-lowered','plough-A-raised','plough-A-lowered',
          'plough-B-raised','plough-B-lowered','left-turn','right-turn','headland-entry','headland-exit'}
C.bindings={
    {'VGC_PANEL','Toggle capture panel','togglePanel'},
    {'VGC_NEXT','Select capture machine','nextMachine'},
    {'VGC_CLASS','Change machine category','nextCategory'},
    {'VGC_STATE','Change capture label','nextLabel'},
    {'VGC_CAPTURE','Save machine geometry','capture'},
    {'VGC_RECORD','Start / stop movement recording','toggleRecord'}}

function C:vehicle()
    return g_localPlayer and G.call(g_localPlayer,'getCurrentVehicle')
end

function C:selection()
    local objects=G.objects(self:vehicle())
    self.selected=math.min(self.selected,math.max(1,#objects))
    return objects[self.selected] and objects[self.selected].object
end

function C:notify(message)
    self.message=message
    self.visible=true
    print('[Vehicle Geometry Capture] ' .. message)
    return message
end

function C:loadMap()
    self.categoriesByObject=setmetatable({},{__mode='k'})
    self.clock,self.serial,self.selected,self.labelIndex=0,0,1,1
    self.folder=getUserProfileAppPath() .. 'modSettings/VehicleGeometryCapture/'
    createFolder(getUserProfileAppPath() .. 'modSettings/')
    createFolder(self.folder)
    addConsoleCommand('vgcCapture','Save selected machine geometry','capture',self)
    addConsoleCommand('vgcRecord','Start or stop recording','toggleRecord',self)
    addConsoleCommand('vgcPanel','Show capture controls','togglePanel',self)
    addConsoleCommand('vgcNext','Select next attached machine','nextMachine',self)
    addConsoleCommand('vgcClass','Cycle machine category','nextCategory',self)
    addConsoleCommand('vgcLabel','Cycle capture label','nextLabel',self)
    g_inputBinding:beginActionEventsModification(Vehicle.INPUT_CONTEXT_NAME)
    for _,binding in ipairs(self.bindings) do
        local _,id=g_inputBinding:registerActionEvent(InputAction[binding[1]],self,self[binding[3]],false,true,false,true)
        if id then
            self.events[#self.events+1]=id
            g_inputBinding:setActionEventText(id,binding[2])
            g_inputBinding:setActionEventTextVisibility(id,false)
        end
    end
    g_inputBinding:endActionEventsModification()
    self:notify('Ready. Ctrl+Alt+G opens capture controls. Enter a tractor to begin.')
    self.visible=false
end

function C:togglePanel() self.visible=not self.visible end
function C:nextMachine()
    if self.recording then return self:notify('Stop recording before changing the selected machine.') end
    self.selected=self.selected%math.max(1,#G.objects(self:vehicle()))+1
    local object=self:selection()
    return self:notify(object and ('Selected: '..G.identity(object).name) or 'Enter a tractor first.')
end
function C:nextCategory()
    local object=self:selection()
    if not object then return self:notify('Enter a tractor first.') end
    if self.recording then return self:notify('Stop recording before changing category.') end
    self.categoriesByObject[object]=(self.categoriesByObject[object] or 1)%#self.categories+1
    return self:notify('Category: '..self.categories[self.categoriesByObject[object]])
end
function C:nextLabel()
    if self.recording then return self:notify('Stop recording before changing label.') end
    self.labelIndex=self.labelIndex%#self.labels+1
    return self:notify('Label: '..self.labels[self.labelIndex])
end

function C:newFile(stem,extension)
    for _=1,10000 do
        self.serial=self.serial+1
        local path=self.folder .. stem .. '_' .. getDate('%Y%m%d_%H%M%S') .. '_' .. self.serial .. extension
        if not fileExists(path) then
            local file,err=io.open(path,'w')
            assert(file,err or 'Cannot create capture file')
            return file,path
        end
    end
    error('Could not allocate a new capture filename')
end

function C:saveObject(object,root)
    local snapshot=G.snapshot(object,self.categories[self.categoriesByObject[object] or 1],self.labels[self.labelIndex])
    snapshot.capturedAt=getDate('%Y-%m-%dT%H:%M:%S')
    snapshot.observedAttachmentContext=G.turnContext(root,object)
    local data=G.json(snapshot)
    local file,path=self:newFile(snapshot.identity.id .. '_' .. snapshot.label,'.json')
    local ok,err=file:write(data,'\n')
    local closed,closeError=file:close()
    assert(ok and closed,err or closeError or 'Could not finish capture file')
    return path
end

function C:capture()
    local root,object=self:vehicle(),self:selection()
    if not root or not object then return self:notify('Enter a tractor and select a machine first.') end
    local ok,path=pcall(self.saveObject,self,object,root)
    return self:notify(ok and ('Saved: '..path:match('[^/]+$')) or ('Capture failed: '..tostring(path)))
end

function C:stopRecording(reason)
    local recording=self.recording
    if not recording then return end
    self.recording=nil
    local ok,err=pcall(function()
        assert(recording.file:write(G.json({type='end',reason=reason or 'user',samples=recording.samples,
            elapsedMs=self.clock-recording.started})..'\n'))
        assert(recording.file:close())
    end)
    if not ok then pcall(recording.file.close,recording.file) end
    return self:notify(ok and ('Recording saved ('..recording.samples..' samples): '..recording.path:match('[^/]+$'))
        or ('Recording write failed: '..tostring(err)))
end

function C:toggleRecord()
    if self.recording then return self:stopRecording('user') end
    local root=self:vehicle()
    if not root then return self:notify('Enter a tractor first.') end
    local file
    local ok,err=pcall(function()
        local objects=G.objects(root)
        local members=G.array()
        for i,entry in ipairs(objects) do
            local profile=self:saveObject(entry.object,root)
            members[#members+1]={instance=i,profileFile=profile:match('[^/]+$'),identity=G.identity(entry.object),
                parentInstance=G.NULL,jointIndex=entry.jointIndex or G.NULL}
            for j,parent in ipairs(objects) do
                if parent.object==entry.parent then members[#members].parentInstance=j end
            end
        end
        local path
        file,path=self:newFile('motion','.jsonl')
        assert(file:write(G.json({schema='fs25-geometry-motion',schemaVersion=1,type='header',members=members,
            label=self.labels[self.labelIndex],sampleIntervalMs=100,
            note='Time-stamped observations, not certified drawbar clearance limits.'})..'\n'))
        self.recording={file=file,path=path,root=root,objects=objects,started=self.clock,last=self.clock-100,samples=0}
    end)
    if not ok then
        if file then pcall(file.close,file) end
        return self:notify('Could not start recording: '..tostring(err))
    end
    return self:notify('Recording at up to 10 Hz. Drive the test; Ctrl+Alt+R stops. Maximum 10 minutes.')
end

function C:sample()
    local r=self.recording
    local sample={type='sample',elapsedMs=self.clock-r.started,machines=G.array(),courseplay=G.cpTrace(r.root)}
    for i,entry in ipairs(r.objects) do
        local object=entry.object
        local left,right,back=G.call(object,'getAIMarkers')
        sample.machines[#sample.machines+1]={instance=i,pose=G.world(object.rootNode),
            direction=G.world(G.call(object,'getAIDirectionNode')),steeringAxle=G.world(object.steeringAxleNode),
            inputCoupling=G.world((G.call(object,'getActiveInputAttacherJoint') or {}).node),
            state=G.state(object),wheels=G.wheelStates(object),workAreas=G.workAreas(object,object.rootNode),
            markers={left=G.world(left),right=G.world(right),back=G.world(back)},
            relativeToParent=entry.parent and G.node(object.rootNode,entry.parent.rootNode) or G.NULL}
    end
    assert(r.file:write(G.json(sample)..'\n'))
    r.samples=r.samples+1
    if r.samples%50==0 then assert(r.file:flush()) end
    r.last=self.clock
end

function C:update(dt)
    self.clock=self.clock+dt
    local root=self:vehicle()
    if root~=self.lastVehicle then self.selected=1; self.lastVehicle=root end
    local r=self.recording
    if not r then return end
    if root~=r.root then self:stopRecording('vehicle changed'); return end
    local current=G.objects(root)
    if #current~=#r.objects then self:stopRecording('attachments changed'); return end
    for i,entry in ipairs(current) do
        local old=r.objects[i]
        if entry.object~=old.object or entry.parent~=old.parent or entry.jointIndex~=old.jointIndex then
            self:stopRecording('attachments changed'); return
        end
    end
    if self.clock-r.started>=600000 then self:stopRecording('10 minute limit'); return end
    if self.clock-r.last>=100 then
        local ok,err=pcall(self.sample,self)
        if not ok then self:stopRecording('sampling failed: '..tostring(err)) end
    end
end

function C:draw()
    if not self.visible or (g_gui and g_gui:getIsGuiVisible()) then return end
    local object=self:selection()
    local lines={'VEHICLE GEOMETRY CAPTURE',object and G.identity(object).name or 'Enter a tractor',
        'Category: '..self.categories[object and self.categoriesByObject[object] or 1],
        'Label: '..self.labels[self.labelIndex],self.recording and 'RECORDING' or 'Ready',
        'Ctrl+Alt+G: panel   N: next machine', 'Ctrl+Alt+T: category   L: label',
        'Ctrl+Alt+C: capture   R: record/stop', 'Use labelled raised/lowered captures on level ground.',
        self.message or ''}
    setTextAlignment(RenderText.ALIGN_LEFT)
    for i,line in ipairs(lines) do
        local y=.83-i*.025
        setTextColor(0,0,0,1); renderText(.551,y-.001,.016,line)
        setTextColor(1,1,1,1); renderText(.55,y,.016,line)
    end
    setTextColor(1,1,1,1)
end

function C:deleteMap()
    self:stopRecording('map closed')
    for _,name in ipairs({'vgcCapture','vgcRecord','vgcPanel','vgcNext','vgcClass','vgcLabel'}) do removeConsoleCommand(name) end
    for _,id in ipairs(self.events) do g_inputBinding:removeActionEvent(id) end
    self.events={}
end

addModEventListener(C)
