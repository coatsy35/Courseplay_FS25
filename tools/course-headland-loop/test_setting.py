"""Course-owned headland preference at mocked GIANTS persistence/UI boundaries."""
from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET
from lupa.lua52 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else SOURCE


class CourseHeadlandSettingTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().ROOT = ROOT.as_posix()
        vehicle_setup = ET.parse(ROOT / 'config/VehicleSettingsSetup.xml')
        generator_setup = ET.parse(ROOT / 'config/CourseGeneratorSettingsSetup.xml')
        self.assertIsNone(vehicle_setup.find(".//Setting[@name='loopTurnsOnHeadland']"))
        setting = generator_setup.find(".//Setting[@name='loopTurnsOnHeadland']")
        rounded = generator_setup.find(".//Setting[@name='headlandsWithRoundCorners']")
        self.assertEqual(setting.attrib['onChangeCallback'], 'onCpLoopTurnsOnHeadlandChanged')
        self.assertEqual(setting.attrib['isDisabled'], 'isLoopTurnsOnHeadlandDisabled')
        self.assertEqual(setting.attrib['tooltip'], 'CP_vehicle_setting_loopTurnsOnHeadland_courseTooltip')
        self.assertEqual(rounded.attrib['onChangeCallback'], 'onCpHeadlandsWithRoundCornersChanged')
        headland_names = [e.attrib['name'] for e in generator_setup.findall(
            ".//SettingSubTitle[@title='headland']/Setting")]
        self.assertEqual(headland_names.index('loopTurnsOnHeadland'),
                         headland_names.index('headlandsWithRoundCorners') + 1)
        master = ET.parse(ROOT / 'config/MasterTranslations.xml')
        note = master.find(".//Translation[@name='CP_vehicle_setting_loopTurnsOnHeadland_courseTooltip']/Text[@language='en']")
        self.assertEqual(note.text, 'For large trailed combinations, instead of performing a normal corner turn on a headland, '
                         'the vehicle will drive a loop. Best used with two curved headland rows; may not give full coverage with one.')
        self.lua.execute((SOURCE / 'tools/double-pivot/engine-boundary.lua').read_text(encoding='utf-8-sig'))
        self.lua.execute('''
            package.path = ROOT .. '/scripts/specializations/?.lua;' .. ROOT .. '/scripts/gui/pages/?.lua;'
                .. ROOT .. '/scripts/ai/parameters/?.lua;' .. ROOT .. '/scripts/implementProfiles/?.lua;'
                .. ROOT .. '/scripts/events/?.lua;' .. package.path
            g_currentModName = 'test'
            g_currentMission.missionDynamicInfo = {isMultiplayer=false}
            g_i18n = {getText=function(_, s) return s end}
            g_server = {broadcastEvent=function() end}
            AIParameterType = {SELECTOR=1}
            InputAction = {}
            Class = function(c, p) return {__index=c} end
            Event = {new=function(mt) return setmetatable({}, mt) end}
            InitEventClass = function() end
            TabbedMenuFrameElement = {}
            Utils = {appendedFunction=function(original) return original end}
            VariableWorkWidth = {}
            require('CpUtil')
            CpUtil.debugVehicle = function() end
            require('CpVehicleSettings')
            require('CpCourseGeneratorSettings')
            require('CpCourseManager')
            require('CpCourseGeneratorFrame')
            require('ImplementProfile')
            require('AIParameterSettingInterface')
            require('AIParameterSetting')
            require('AIParameterSettingList')
            require('AIParameterBooleanSetting')
            require('VehicleSettingsEvent')
            AIParameterSetting.debug = function() end
            SpecializationUtil = {raiseEvent=function(v, event, setting)
                if event == 'onCpLoopTurnsOnHeadlandChanged' then
                    CpCourseGeneratorSettings.onCpLoopTurnsOnHeadlandChanged(v, setting)
                elseif event == 'onCpHeadlandsWithRoundCornersChanged' then
                    CpCourseGeneratorSettings.onCpHeadlandsWithRoundCornersChanged(v, setting)
                end
            end}
            function scalar(value)
                return {value=value, values={0,1,2,3,4,5,6,8,10,12,20,25}, texts={},
                    getValue=function(self) return self.value end,
                    setValue=function(self,v) self.value=v; return false end,
                    setFloatValue=function(self,v) self.value=v; return false end,
                    getIsDisabled=function() return false end}
            end
            function vehicle(loop, rounded)
                local v = {settings={}}
                v['spec_' .. CpCourseManager.SPEC_NAME] = {courses={}}
                v.generator = {headlandsWithRoundCorners=scalar(rounded == nil and 1 or rounded)}
                v['spec_' .. CpCourseGeneratorSettings.SPEC_NAME] = v.generator
                v.getCpSettings = function(self) return self.settings end
                v.getCourseGeneratorSettings = function(self) return self.generator end
                v.getFieldWorkCourse = CpCourseManager.getFieldWorkCourse
                v.generator.loopTurnsOnHeadland = AIParameterBooleanSetting({
                    name='loopTurnsOnHeadland', values={}, texts={}, defaultBool=loop,
                    isDisabledFunc='isLoopTurnsOnHeadlandDisabled',
                    callbacks={onChangeCallbackStr='onCpLoopTurnsOnHeadlandChanged'}
                }, v, CpCourseGeneratorSettings)
                return v
            end
            function assign(v, course)
                v['spec_' .. CpCourseManager.SPEC_NAME].courses = {}
                CpCourseManager.addCourse(v, course, true)
            end
            function xml()
                return {values={}, setValue=function(self,k,v) self.values[k]=v end,
                    getValue=function(self,k,default)
                        local v=self.values[k]; if v==nil then return default end; return v
                    end, iterate=function() end}
            end
            function stream() return {values={}, read=0} end
            local function write(s,v) s.values[#s.values+1]=v end
            local function read(s) s.read=s.read+1; assert(s.values[s.read]~=nil); return s.values[s.read] end
            streamWriteString=write; streamWriteFloat32=write; streamWriteInt32=write; streamWriteBool=write
            streamReadString=read; streamReadFloat32=read; streamReadInt32=read; streamReadBool=read
        ''')

    def test_course_xml_copy_and_stream_preserve_optional_choice(self):
        for value in ('true', 'false', 'nil'):
            with self.subTest(value=value):
                self.lua.execute(f'''
                    local c = Course(nil, {{}}); c.loopTurnsOnHeadland = {value}
                    local saved = xml(); c:saveToXml(saved, 'course')
                    assert(saved.values['course#loopTurnsOnHeadland'] == {value})
                    local loaded = Course.createFromXml(nil, saved, 'course')
                    assert(loaded.loopTurnsOnHeadland == {value})
                    assert(loaded:copy().loopTurnsOnHeadland == {value})
                    local s = stream(); c:writeStream(nil, s); streamWriteInt32(s, 12345)
                    local streamed = Course.createFromStream(nil, s)
                    assert(streamed.loopTurnsOnHeadland == {value})
                    assert(streamReadInt32(s) == 12345)
                ''')

    def test_course_is_runtime_owner_and_loading_restores_working_control(self):
        self.lua.execute('''
            local v = vehicle(true)
            local normal, loop = Course(nil, {}), Course(nil, {})
            normal.loopTurnsOnHeadland=false; loop.loopTurnsOnHeadland=true
            assign(v, normal)
            assert(not v.generator.loopTurnsOnHeadland:getValue())
            assert(not normal:getLoopTurnsOnHeadland())
            assign(v, loop)
            assert(v.generator.loopTurnsOnHeadland:getValue())
            assert(loop:getLoopTurnsOnHeadland())
            local turn = {fieldWorkCourse=loop}
            assert(CourseTurn.getUseLoopTurnsOnHeadland(turn))
            v.generator.loopTurnsOnHeadland:setValue(false, true)
            assert(not loop:getLoopTurnsOnHeadland())
        ''')

    def test_legacy_course_adopts_profile_default_without_changing_library(self):
        self.lua.execute('''
            local v = vehicle(false)
            local values = {['vehicle.loopTurnsOnHeadland']=true}
            ImplementProfile.migrateSettings(values)
            assert(values['vehicle.loopTurnsOnHeadland'] == nil)
            assert(values['generator.loopTurnsOnHeadland'])
            ImplementProfile.setSettings(v, values)
            local c = Course(nil, {}); assign(v, c)
            assert(c:getLoopTurnsOnHeadland())
            v.generator.loopTurnsOnHeadland:setValue(false, true)
            assert(not c:getLoopTurnsOnHeadland())
            assert(values['generator.loopTurnsOnHeadland'])
            assert(ImplementProfile.capture(v)['generator.loopTurnsOnHeadland'] == false)
        ''')

    def test_additional_course_does_not_replace_active_choice(self):
        self.lua.execute('''
            local v = vehicle(false)
            local first, second = Course(nil, {}), Course(nil, {})
            first.loopTurnsOnHeadland=true; second.loopTurnsOnHeadland=false
            assign(v, first); CpCourseManager.addCourse(v, second, true)
            assert(v.generator.loopTurnsOnHeadland:getValue())
            assert(first:getLoopTurnsOnHeadland() and not second:getLoopTurnsOnHeadland())
        ''')

    def test_network_setting_updates_loaded_course(self):
        self.lua.execute('''
            local sender, receiver = vehicle(false), vehicle(true)
            local c = Course(nil, {}); assign(receiver, c)
            local s = stream()
            sender.generator.loopTurnsOnHeadland:writeStream(s, {getIsServer=function() return false end})
            receiver.generator.loopTurnsOnHeadland:readStream(s, {getIsServer=function() return true end})
            assert(not c:getLoopTurnsOnHeadland())
        ''')

    def test_loaded_course_keeps_headland_controls_visible(self):
        self.lua.execute('''
            local v = vehicle(false)
            v.generator.numberOfHeadlands={getValue=function() return 0 end}
            assert(not CpCourseGeneratorSettings.isHeadlandSectionVisible(v))
            local c = Course(nil, {}); c.numberOfHeadlands=2; assign(v, c)
            assert(CpCourseGeneratorSettings.isHeadlandSectionVisible(v))
            c.numberOfHeadlands=0
            assert(not CpCourseGeneratorSettings.isHeadlandSectionVisible(v))
        ''')

    def test_loop_requires_rounded_headland_and_saved_true_restores_prerequisite(self):
        self.lua.execute('''
            local v = vehicle(false, 0)
            assert(CpCourseGeneratorSettings.isLoopTurnsOnHeadlandDisabled(v))
            local c = Course(nil, {}); c.loopTurnsOnHeadland=true; assign(v, c)
            assert(v.generator.headlandsWithRoundCorners:getValue() == 1)
            assert(v.generator.loopTurnsOnHeadland:getValue() and c:getLoopTurnsOnHeadland())
            v.generator.headlandsWithRoundCorners.value=0
            CpCourseGeneratorSettings.onCpHeadlandsWithRoundCornersChanged(
                v, v.generator.headlandsWithRoundCorners)
            assert(not v.generator.loopTurnsOnHeadland:getValue())
            assert(not c:getLoopTurnsOnHeadland())
            ImplementProfile.setSettings(v, {
                ['generator.headlandsWithRoundCorners']=0,
                ['generator.loopTurnsOnHeadland']=true})
            assert(not v.generator.loopTurnsOnHeadland:getValue())
        ''')

    def test_legacy_vehicle_save_value_migrates_once(self):
        self.lua.execute('''
            local v = vehicle(false)
            local base = 'vehicles.vehicle(0)' .. CpVehicleSettings.KEY .. CpVehicleSettings.SETTINGS_KEY
            local legacy = {entries={[base]={'legacy'}}, values={
                ['legacy#name']='loopTurnsOnHeadland', ['legacy#currentValue']='true'}}
            legacy.iterate=function(self,key,callback)
                for _,entry in ipairs(self.entries[key] or {}) do callback(0,entry) end
            end
            legacy.getValue=function(self,key) return self.values[key] end
            legacy.getString=legacy.getValue
            CpCourseGeneratorSettings.loadLegacyLoopTurnsSetting(v,
                {key='vehicles.vehicle(0)', xmlFile=legacy})
            assert(v.generator.loopTurnsOnHeadland:getValue())
            v.generator.loopTurnsOnHeadland.loadedValue=false
            legacy.values['legacy#currentValue']='false'
            CpCourseGeneratorSettings.loadLegacyLoopTurnsSetting(v,
                {key='vehicles.vehicle(0)', xmlFile=legacy})
            assert(v.generator.loopTurnsOnHeadland:getValue())
        ''')


if __name__ == '__main__':
    unittest.main(verbosity=2)
