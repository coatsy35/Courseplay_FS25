"""Offline Lua integration tests; engine integration still needs an FS25 run."""
import json
from pathlib import Path
import tempfile
import unittest
from lupa.lua52 import LuaRuntime

MOD = Path(__file__).parent / 'mod'

MOCK = r'''
function localToLocal(n,r,x,y,z)
    local dx,dz=n.x-r.x,n.z-r.z
    return dx*math.cos(r.t)-dz*math.sin(r.t)+x, (n.y or 0)-(r.y or 0)+y,
           dx*math.sin(r.t)+dz*math.cos(r.t)+z
end
function localDirectionToLocal(n,r,x,y,z)
    local t=n.t-r.t
    return x*math.cos(t)+z*math.sin(t),y,-x*math.sin(t)+z*math.cos(t)
end
function localDirectionToWorld(n,x,y,z) return localDirectionToLocal(n,{t=0},x,y,z) end
function getWorldTranslation(n) return n.x,n.y or 0,n.z end
function getDate() return '20260913_120000' end
function fileExists(p) local f=io.open(p,'r'); if f then f:close();return true end; return false end
function createFolder() end
function getUserProfileAppPath() return folder end
function addModEventListener(c) listener=c end
commands={}
function addConsoleCommand(name,desc,fn,target) commands[name]={fn=fn,target=target} end
function removeConsoleCommand(name) commands[name]=nil end
InputAction=setmetatable({},{__index=function(_,key) return key end})
g_inputBinding={count=0,removed=0}
Vehicle={INPUT_CONTEXT_NAME='VEHICLE'}
function g_inputBinding:beginActionEventsModification(context) assert(context=='VEHICLE');self.context=context end
function g_inputBinding:endActionEventsModification() self.context=nil end
function g_inputBinding:registerActionEvent(action,target,fn) self.count=self.count+1; return true,self.count end
function g_inputBinding:setActionEventText() end
function g_inputBinding:setActionEventTextVisibility() end
function g_inputBinding:removeActionEvent() self.removed=self.removed+1 end
RenderText={ALIGN_LEFT=0}
function setTextAlignment() end
function setTextColor() end
function renderText(x,y,size,text) assert(type(text)=='string') end
g_gui={getIsGuiVisible=function() return false end}
root={rootNode={x=100,z=200,t=0},configFileName='$data/tractor.xml',configurations={wheels=2},
      size={width=3,length=6},maxTurningRadius=7,isServer=true,attachments={}}
tool={rootNode={x=100,z=190,t=0},configFileName='$data/pw10012.xml',configurations={workingWidth=1},
      size={width=5.6,length=19},isServer=true}
function root:getName() return 'Test tractor' end
function tool:getName() return 'PW 100-12' end
function root:getAttachedImplements() return self.attachments end
function root:getAIDirectionNode() return self.rootNode end
function root:getAIMinTurningRadius() return 8 end
function tool:getIsLowered() return false end
function tool:getIsTurnedOn() return false end
tool.steeringAxleNode={x=100,z=188,t=0}
tool.coupling={node={x=100,z=198,t=0},lowerRotLimitScale={1,.5,1}}
function tool:getActiveInputAttacherJoint() return self.coupling end
tool.spec_attachable={inputAttacherJoints={tool.coupling}}
tool.spec_workArea={workAreas={{start={x=102.8,z=194,t=0},width={x=97.2,z=194,t=0},height={x=102.8,z=185,t=0},type=1,isDisabled=false}}}
function tool:getAIMarkers() local a=self.spec_workArea.workAreas[1];return a.start,a.width,a.height,false,5.6 end
root.attachments={{object=tool,jointDescIndex=1}}
g_localPlayer={getCurrentVehicle=function() return root end}
'''


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder=Path(self.temp.name)
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().folder=self.folder.as_posix()+'/'
        self.lua.execute(MOCK)
        for name in ('Geometry.lua','Capture.lua'):
            self.lua.execute((MOD/name).read_text(encoding='utf-8'))
        self.lua.execute('VehicleGeometryCapture:loadMap(); VehicleGeometryCapture.folder=folder')
        self.addCleanup(lambda:self.lua.execute('VehicleGeometryCapture:deleteMap()'))

    def evaluate(self, expression):
        return json.loads(self.lua.eval('VGCGeometry.json('+expression+')'))

    def test_local_geometry_and_false_values_are_preserved(self):
        data=self.evaluate("VGCGeometry.snapshot(tool,'long-narrow-trailed','plough-A-raised')")
        self.assertEqual(data['inputCouplings'][0]['pose']['position'],[0,0,8])
        self.assertEqual(data['steeringAxle']['position'],[0,0,-2])
        self.assertFalse(data['state']['lowered'])
        self.assertFalse(data['workAreas'][0]['disabled'])
        self.assertAlmostEqual(data['aiMarkers']['reportedWidth'],5.6)
        self.assertIsNone(data['clearance']['safeDrawbarAngle'])

    def test_profile_identity_does_not_depend_on_tractor(self):
        before=self.evaluate('VGCGeometry.identity(tool)')
        self.lua.execute("root.configFileName='differentTractor.xml';root.rootNode.x=1000")
        self.assertEqual(before,self.evaluate('VGCGeometry.identity(tool)'))
        self.lua.execute('tool.configurations.workingWidth=2')
        self.assertNotEqual(before['id'],self.evaluate('VGCGeometry.identity(tool)')['id'])

    def test_json_escaping_and_unknown_nodes(self):
        self.lua.execute(r'''escaped={name='quote" slash\\ newline\n',array=VGCGeometry.array(),bad=0/0}''')
        data=self.evaluate('escaped')
        self.assertIn('\n',data['name'])
        self.assertEqual(data['array'],[])
        self.assertIsNone(data['bad'])
        self.assertIsNone(self.evaluate('VGCGeometry.node(0,root.rootNode)'))

    def test_read_only_capture_creates_separate_non_overwriting_files(self):
        self.lua.execute('VehicleGeometryCapture:nextMachine();VehicleGeometryCapture:capture();VehicleGeometryCapture:capture()')
        files=list(self.folder.glob('*.json'))
        self.assertEqual(len(files),2)
        self.assertTrue(all(json.loads(p.read_text())['identity']['model'].endswith('pw10012.xml') for p in files))
        self.assertEqual(self.evaluate('tool.rootNode'),{'x':100,'z':190,'t':0})

    def test_recording_keeps_independent_profiles_and_instance_references(self):
        self.lua.execute('VehicleGeometryCapture:toggleRecord();VehicleGeometryCapture:update(100);VehicleGeometryCapture:update(100);VehicleGeometryCapture:toggleRecord()')
        self.assertEqual(len(list(self.folder.glob('*.json'))),2)
        rows=[json.loads(line) for line in next(self.folder.glob('*.jsonl')).read_text().splitlines()]
        self.assertEqual(rows[0]['members'][1]['parentInstance'],1)
        self.assertEqual(rows[-1]['samples'],2)
        self.assertEqual(rows[1]['machines'][1]['relativeToParent']['position'],[0,0,-10])
        self.assertEqual(rows[1]['machines'][1]['markers']['left']['position'],[102.8,0,194])

    def test_same_count_attachment_change_stops_recording(self):
        self.lua.execute('VehicleGeometryCapture:toggleRecord();root.attachments[1].jointDescIndex=2;VehicleGeometryCapture:update(100)')
        rows=[json.loads(line) for line in next(self.folder.glob('*.jsonl')).read_text().splitlines()]
        self.assertEqual(rows[-1]['reason'],'attachments changed')
        self.assertTrue(self.lua.eval('VehicleGeometryCapture.recording==nil'))

    def test_vehicle_exit_stops_recording(self):
        self.lua.execute('VehicleGeometryCapture:toggleRecord();g_localPlayer=nil;VehicleGeometryCapture:update(100)')
        self.assertTrue(self.lua.eval('VehicleGeometryCapture.recording==nil'))

    def test_ten_minute_limit(self):
        self.lua.execute('VehicleGeometryCapture:toggleRecord();VehicleGeometryCapture:update(600000)')
        rows=[json.loads(line) for line in next(self.folder.glob('*.jsonl')).read_text().splitlines()]
        self.assertEqual(rows[-1]['reason'],'10 minute limit')

    def test_optional_cp_radius_is_explicitly_contextual(self):
        self.lua.execute('''g_modManager={CP_MOD_NAME='testCP'};testCP={AIUtil={getTurningRadius=function(v) return 12 end},
            g_vehicleConfigurations={get=function(self,v,key) return 9 end}}''')
        context=self.evaluate('VGCGeometry.turnContext(root,tool)')
        self.assertEqual(context['cpRadius'],12)
        self.assertEqual(context['cpOverride'],9)
        self.assertIsNone(context['giantsToolRadius'])

    def test_cp_boundary_references_and_active_radius_are_recorded(self):
        self.lua.execute('''function root:getCpDriveStrategy() return {turningRadius=11,
            turnContext={workStartNode={x=20,z=30,t=0},workEndNode={x=10,z=40,t=0}},
            getStateAsString=function() return 'TURNING' end,ppc={getCurrentWaypointIx=function() return 55 end}} end''')
        trace=self.evaluate('VGCGeometry.cpTrace(root)')
        self.assertEqual(trace['radius'],11)
        self.assertEqual(trace['workStart']['position'],[20,0,30])
        self.assertEqual(trace['state'],'TURNING')
        self.assertEqual(trace['waypoint'],55)

    def test_ui_and_commands_are_registered_and_cleaned_up(self):
        self.lua.execute('VehicleGeometryCapture.visible=true;VehicleGeometryCapture:draw();VehicleGeometryCapture:nextCategory();VehicleGeometryCapture:nextLabel();VehicleGeometryCapture:draw()')
        self.assertEqual(self.lua.eval('g_inputBinding.count'),6)
        self.lua.execute('VehicleGeometryCapture:deleteMap()')
        self.assertEqual(self.lua.eval('g_inputBinding.removed'),6)
        self.assertEqual(self.evaluate('commands'),{})

    def test_write_failure_reported_without_throwing(self):
        self.lua.execute("VehicleGeometryCapture.folder=folder..'does-not-exist/';VehicleGeometryCapture:capture()")
        self.assertIn('Capture failed',self.lua.eval('VehicleGeometryCapture.message'))


if __name__=='__main__':
    unittest.main()
