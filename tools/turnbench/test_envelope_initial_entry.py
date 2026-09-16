"""Initial-entry lifecycle and CP row-order regressions; GIANTS physics are mocked."""
import unittest
from pathlib import Path
import test_ingame_envelope


class InitialEntryTests(unittest.TestCase):
    def setUp(self):
        test_ingame_envelope.InGameEnvelopeTests.setUp(self)
        self.lua.execute('''
function initialFixture(parameters)
    g_currentMission.time=0
    local p=parameters or envelopeFixture(6,9,2,11,12,0,1,54)
    p.start={x=0,z=-20,t=0,phi=0};p.goal={x=0,z=0,t=0}
    local f=makeEnvelopeLiveFixture(p)
    AIUtil.getSteeringParameters=function() return p.length and f.object,p.length or 0 end
    AIUtil.hasChainedAttachments=function() return false end
    local s=f.strategy
    s.vehicle=f.vehicle;s.settings=f.vehicle:getCpSettings();s.workWidth=p.width
    s.settings.avoidFruit={getValue=function() return true end}
    s.turnNodes={};s.states={TURNING={},DRIVING_TO_WORK_START_WAYPOINT={}}
    s.state=s.states.DRIVING_TO_WORK_START_WAYPOINT
    s.getFrontAndBackMarkers=function() return p.front,p.work[3].z+p.hitchZ end
    s.getWorkWidth=function() return p.width end
    s.getTurnEndForwardOffset=function() return 0 end
    s.updateFieldworkOffset=function(_,course) course:setOffset(0,0) end
    s.proximityController={registerBlockingObjectListener=function() end,unregisterBlockingObjectListener=function() end}
    local function attr(start,finish)
        local a=CourseGenerator.WaypointAttributes();a.rowStart=start;a.rowEnd=finish;a.atBoundaryId='F';return a
    end
    s.fieldWorkCourse=Course(f.vehicle,{{x=0,z=0,attributes=attr(true,false)},
        {x=0,z=3.09,attributes=attr(false,true)},
        {x=6,z=10,attributes=attr(true,false)},
        {x=6,z=-1,attributes=attr(false,true)},
        {x=12,z=-2,attributes=attr(true,false)},{x=12,z=20,attributes=attr(false,true)}},false)
    local fm,bm=s:getFrontAndBackMarkers()
    f.context=RowStartOrFinishContext(f.vehicle,s.fieldWorkCourse,1,1,s.turnNodes,p.width,fm,bm,0,0)
    f.ppc=PurePursuitController(f.vehicle)
    s.ppc=f.ppc
    s.startCourse=function(_,course,ix) f.ppc:setCourse(course);f.ppc:initialize(ix) end
    f.starter=StartRowOnly(f.vehicle,s,f.ppc,f.context,
        Course(f.vehicle,{{x=0,z=-20},{x=0,z=-10},{x=0,z=0}},true))
    s.workStarter=f.starter
    s:startCourse(f.starter:getCourse(),1)
    return f,p
end
''')

    def load_strategy_method(self, name):
        source = (Path(__file__).resolve().parents[2] /
                  'scripts/ai/strategies/AIDriveStrategyFieldWorkCourse.lua').read_text()
        start = source.index('function AIDriveStrategyFieldWorkCourse:' + name + '(')
        end = source.index('\nend', start) + len('\nend')
        self.lua.execute('AIDriveStrategyFieldWorkCourse=AIDriveStrategyFieldWorkCourse or {}\n' + source[start:end])

    def test_all_start_modes_keep_stock_nearby_transport_start(self):
        source=(Path(__file__).resolve().parents[2]/'scripts/ai/strategies/AIDriveStrategyDriveToFieldWorkStart.lua').read_text(encoding='utf-8')
        start=source.index('function AIDriveStrategyDriveToFieldWorkStart:start(')
        end=source.index('\nend',start)+4
        self.lua.execute('AIDriveStrategyDriveToFieldWorkStart={minDistanceToDrive=20}\n'+source[start:end])
        self.lua.execute("""
CpFieldWorkJobParameters={START_AT_FIRST_POINT=1,START_AT_NEAREST_POINT=2,START_AT_LAST_POINT=3}
for _,mode in ipairs({1,2,3}) do
    local f=initialFixture();local s=f.strategy
    s.updateFieldworkOffset=function() end;s.debug=function() end
    s.states.WORK_START_REACHED={}
    s.job={setStartPosition=function() end}
    s.setCurrentTaskFinished=function() s.finished=true end
    s.startCourseWithPathfinding=function(_,course,ix) assert(ix==132);s.pathRequested=true end
    s.giantsPreFoldHeaderWithWheelsFix=function() return false end
    s.settings.foldImplementAtEnd={getValue=function() return false end}
    AIUtil.getImplementWithSpecialization=function() end
    local course={getWaypointPosition=function() return 0,0,2 end,
        getDistanceBetweenVehicleAndWaypoint=function() return 2 end,isOnHeadland=function() return false end}
    AIDriveStrategyDriveToFieldWorkStart.start(s,course,132,{startAt={getValue=function() return mode end}})
    assert(s.finished and not s.pathRequested,'nearby start requested an outward path')
end
""")

    def test_all_start_modes_keep_stock_nearby_fieldwork_start(self):
        self.load_strategy_method('start')
        self.lua.execute("""
CpFieldWorkJobParameters={START_AT_FIRST_POINT=1,START_AT_NEAREST_POINT=2,START_AT_LAST_POINT=3}
CpRemainingTime=function() return {} end
for _,mode in ipairs({1,2,3}) do
    local f=initialFixture();local s=f.strategy
    s.showAllInfo=function() end;s.debug=function() end;s.updateFieldworkOffset=function() end
    s.turningRadius=9;s.states.INITIAL={}
    local course={setCurrentWaypointIx=function(_,ix) assert(ix==132) end,
        getDistanceBetweenVehicleAndWaypoint=function() return 2 end,isOnHeadland=function() return false end}
    f.vehicle.getJob=function() return {getStartFieldWorkCourse=function() end} end
    f.vehicle.getFieldWorkCourse=function() return course end
    s.startCourse=function(_,c,ix) assert(c==course and ix==132);s.resumedDirectly=true end
    s.startAlignmentTurn=function() s.alignmentRequested=true end
    AIDriveStrategyFieldWorkCourse.start(s,course,132,{startAt={getValue=function() return mode end}})
    assert(s.resumedDirectly and not s.alignmentRequested,'start generated another alignment loop')
end
""")

    def test_stock_first_last_and_nearest_waypoint_selection(self):
        source=(Path(__file__).resolve().parents[2]/'scripts/ai/strategies/AIDriveStrategyCourse.lua').read_text(encoding='utf-8')
        start=source.index('function AIDriveStrategyCourse:getStartingPointWaypointIx(')
        end=source.index('\nend',start)+4
        self.lua.execute('AIDriveStrategyCourse=AIDriveStrategyCourse or {}\n'+source[start:end])
        self.lua.execute("""
CpFieldWorkJobParameters={START_AT_FIRST_POINT=1,START_AT_NEAREST_POINT=2,START_AT_LAST_POINT=3}
local s={debug=function() end,vehicle={getAIDirectionNode=function() return 1 end,
    getCpLastRememberedWaypointIx=function() return 87 end}}
local course={getNearestWaypoints=function() return 100,.1,132,2 end}
local select=AIDriveStrategyCourse.getStartingPointWaypointIx
assert(select(s,course,1)==1)
assert(select(s,course,2)==132,'nearest must retain CP correct-direction selection')
assert(select(s,course,3)==87)
""")

    def test_connecting_path_uses_stock_row_starter(self):
        self.load_strategy_method('startCourseToWorkStart')
        self.lua.execute("""
local f=initialFixture();local s=f.strategy
s.turnContext=f.context
AIDriveStrategyFieldWorkCourse.startCourseToWorkStart(s,f.starter:getCourse())
assert(s.workStarter.name=='StartRowOnly')
assert(s.state==s.states.DRIVING_TO_WORK_START_WAYPOINT and s.raised==1)
""")

if __name__ == '__main__':
    unittest.main()
