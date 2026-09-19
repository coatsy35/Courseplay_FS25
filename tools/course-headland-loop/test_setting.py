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
        setting = ET.parse(ROOT / 'config/VehicleSettingsSetup.xml').find(".//Setting[@name='loopTurnsOnHeadland']")
        self.lua.globals().SETTING_CALLBACK = setting.attrib['onChangeCallback']
        self.assertEqual(setting.attrib['tooltip'], 'CP_vehicle_setting_loopTurnsOnHeadland_courseTooltip')
        self.assertEqual(setting.attrib['isDisabled'], 'isLoopTurnsOnHeadlandDisabled')
        rounded = ET.parse(ROOT / 'config/CourseGeneratorSettingsSetup.xml').find(
            ".//Setting[@name='headlandsWithRoundCorners']")
        self.assertEqual(rounded.attrib['onChangeCallback'], 'onCpHeadlandsWithRoundCornersChanged')
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
                    CpVehicleSettings.onCpLoopTurnsOnHeadlandChanged(v, setting)
                end
            end}
            function vehicle(value)
                local v = {}
                v['spec_' .. CpCourseManager.SPEC_NAME] = {courses={}}
                v.getCpSettings = function(self) return self.settings end
                v.getCourseGeneratorSettings = function(self) return self.generator or {} end
                v.getFieldWorkCourse = CpCourseManager.getFieldWorkCourse
                v.settings = {}
                v.settings.loopTurnsOnHeadland = AIParameterBooleanSetting({
                    name='loopTurnsOnHeadland', values={}, texts={}, defaultBool=value,
                    callbacks={onChangeCallbackStr=SETTING_CALLBACK}
                }, v, CpVehicleSettings)
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

    def test_course_xml_and_copy_preserve_true_false_and_legacy_absence(self):
        for value in ('true', 'false', 'nil'):
            with self.subTest(value=value):
                self.lua.execute(f'''
                    local c = Course(nil, {{}}); c.loopTurnsOnHeadland = {value}
                    local saved = xml(); c:saveToXml(saved, 'course')
                    assert(saved.values['course#loopTurnsOnHeadland'] == {value})
                    local loaded = Course.createFromXml(nil, saved, 'course')
                    assert(loaded.loopTurnsOnHeadland == {value})
                    assert(loaded:copy().loopTurnsOnHeadland == {value})
                ''')

    def test_stream_round_trip_preserves_optional_boolean_and_alignment(self):
        for value in ('true', 'false', 'nil'):
            with self.subTest(value=value):
                self.lua.execute(f'''
                    local c = Course(nil, {{}}); c.loopTurnsOnHeadland = {value}
                    local s = stream(); c:writeStream(nil, s)
                    streamWriteInt32(s, 12345)
                    local loaded = Course.createFromStream(nil, s)
                    assert(loaded.loopTurnsOnHeadland == {value})
                    assert(streamReadInt32(s) == 12345)
                ''')

    def test_loading_opposite_courses_restores_choice_on_another_tractor(self):
        self.lua.execute('''
            local v = vehicle(true)
            local normal, loop = Course(nil, {}), Course(nil, {})
            normal.loopTurnsOnHeadland=false; loop.loopTurnsOnHeadland=true
            assign(v, normal)
            assert(not v:getCpSettings().loopTurnsOnHeadland:getValue())
            assign(v, loop)
            assert(v:getCpSettings().loopTurnsOnHeadland:getValue())
            local other = vehicle(false)
            assign(other, loop:copy())
            assert(other:getCpSettings().loopTurnsOnHeadland:getValue())
            assign(v, normal)
            assert(not v:getCpSettings().loopTurnsOnHeadland:getValue())
            assert(loop.loopTurnsOnHeadland)
        ''')

    def test_legacy_course_adopts_profile_default_and_manual_edit_preserves_library(self):
        self.lua.execute('''
            local v = vehicle(false)
            local profile = {settings={['vehicle.loopTurnsOnHeadland']=true}}
            ImplementProfile.setSettings(v, profile.settings)
            local c = Course(nil, {}); assign(v, c)
            assert(c.loopTurnsOnHeadland)
            local points = c.waypoints
            v:getCpSettings().loopTurnsOnHeadland:setValue(false, true)
            assert(c.loopTurnsOnHeadland == false and c.waypoints == points)
            assert(profile.settings['vehicle.loopTurnsOnHeadland'])
            assert(ImplementProfile.capture(v)['vehicle.loopTurnsOnHeadland'] == false)
            local saved = xml(); c:saveToXml(saved, 'course')
            local other = vehicle(true)
            assign(other, Course.createFromXml(other, saved, 'course'))
            assert(not other:getCpSettings().loopTurnsOnHeadland:getValue())
        ''')

    def test_additional_course_does_not_overwrite_the_active_course(self):
        self.lua.execute('''
            local v = vehicle(false)
            local first, second = Course(nil, {}), Course(nil, {})
            first.loopTurnsOnHeadland=true; second.loopTurnsOnHeadland=false
            assign(v, first)
            CpCourseManager.addCourse(v, second, true)
            assert(v.settings.loopTurnsOnHeadland:getValue())
            assert(first.loopTurnsOnHeadland and not second.loopTurnsOnHeadland)
        ''')

    def test_network_setting_read_updates_loaded_course_without_rebroadcast(self):
        self.lua.execute('''
            local sender, receiver = vehicle(false), vehicle(true)
            local c = Course(nil, {}); assign(receiver, c)
            local s = stream()
            sender.settings.loopTurnsOnHeadland:writeStream(s, {getIsServer=function() return false end})
            receiver.settings.loopTurnsOnHeadland:readStream(s, {getIsServer=function() return true end})
            assert(c.loopTurnsOnHeadland == false)
        ''')

    def test_course_setting_appears_only_in_headland_ui_without_mutating_shared_layout(self):
        self.lua.execute('''
            local v = vehicle(false)
            local function named(name) return {getName=function() return name end} end
            local round = named('headlandsWithRoundCorners')
            local originalVehicle = {{title='basic', elements={named('fuelSave'), v.settings.loopTurnsOnHeadland}}}
            local originalGenerator = {{title='headland', elements={round}, isVisibleFunc='hasHeadlandsSelected'}}
            CpVehicleSettings.settingsBySubTitle = originalVehicle
            CpCourseGeneratorSettings.settingsBySubTitle = originalGenerator
            for i=1,2 do
                local sections = CpVehicleSettings.getSettingSetup()
                assert(#sections[1].elements == 1)
                assert(sections[1].elements[1]:getName() == 'fuelSave')
                local settings, layout = CpCourseGeneratorFrame.getFieldworkSettings(v)
                assert(layout[1].elements[2] == v.settings.loopTurnsOnHeadland)
                assert(settings.loopTurnsOnHeadland == v.settings.loopTurnsOnHeadland)
                assert(layout[1].isVisibleFunc == 'hasHeadlandsSelected')
            end
            assert(#originalVehicle[1].elements == 2 and #originalGenerator[1].elements == 1)
        ''')

    def test_loaded_course_keeps_headland_controls_visible_with_zero_generation_headlands(self):
        self.lua.execute('''
            local v = vehicle(false)
            local selected = 0
            v['spec_' .. CpCourseGeneratorSettings.SPEC_NAME] = {
                numberOfHeadlands={getValue=function() return selected end}}
            assert(not CpCourseGeneratorSettings.isHeadlandSectionVisible(v))
            local c = Course(nil, {}); c.numberOfHeadlands=2; assign(v, c)
            assert(CpCourseGeneratorSettings.isHeadlandSectionVisible(v))
            assert(not CpCourseGeneratorSettings.hasHeadlandsSelected(v))
            c.numberOfHeadlands=0
            assert(not CpCourseGeneratorSettings.isHeadlandSectionVisible(v))
            selected=1
            assert(CpCourseGeneratorSettings.isHeadlandSectionVisible(v))
        ''')

    def test_loop_option_requires_a_rounded_headland_and_turns_off_at_zero(self):
        self.lua.execute('''
            local v = vehicle(true)
            local rounded = 1
            local roundedSetting = {getValue=function() return rounded end}
            v.generator = {headlandsWithRoundCorners=roundedSetting}
            local c = Course(nil, {}); c.loopTurnsOnHeadland=true; assign(v, c)
            assert(not CpVehicleSettings.isLoopTurnsOnHeadlandDisabled(v))
            rounded=0
            assert(CpVehicleSettings.isLoopTurnsOnHeadlandDisabled(v))
            CpCourseGeneratorSettings.onCpHeadlandsWithRoundCornersChanged(v, roundedSetting)
            assert(not v.settings.loopTurnsOnHeadland:getValue())
            assert(c.loopTurnsOnHeadland == false)
            ImplementProfile.setSettings(v, {['vehicle.loopTurnsOnHeadland']=true})
            assert(not v.settings.loopTurnsOnHeadland:getValue())
        ''')


if __name__ == '__main__':
    unittest.main(verbosity=2)
