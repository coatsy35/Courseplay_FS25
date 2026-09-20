"""Regression tests for the combine's outer-headland pocket turn."""
from pathlib import Path
import sys
import unittest

from lupa.lua52 import LuaRuntime


SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else SOURCE


class CombinePocketTurnTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().ROOT = ROOT.as_posix()
        self.lua.execute((ROOT / 'scripts/CpObject.lua').read_text(encoding='utf-8-sig'))
        self.lua.execute('CpDebug = {DBG_TURN=1}')
        self.lua.execute((ROOT / 'scripts/ai/turns/AITurn.lua').read_text(encoding='utf-8-sig'))

    def test_stock_pocket_geometry_is_uniformly_doubled(self):
        self.lua.execute('''
            CpFieldUtil = {isOnField=function() return true end}
            Course = function(_, waypoints)
                return {waypoints=waypoints}
            end
            local corner = {
                getPointAtDistanceFromCornerStart=function(_, distance, sideOffset)
                    return {x=distance, z=sideOffset or 0}
                end,
                getPointAtDistanceFromCornerEnd=function(_, distance, sideOffset)
                    return {x=distance, z=sideOffset or 0}
                end,
                delete=function() end
            }
            local turn = setmetatable({
                vehicle={}, turningRadius=6, workWidth=12,
                debug=function() end
            }, CombinePocketHeadlandTurn)
            local context = {
                frontMarkerDistance=3,
                turnEndWpIx=42,
                createCorner=function() return corner end
            }
            local course, endIx = turn:generatePocketHeadlandTurn(context)
            assert(endIx == 42)
            assert(#course.waypoints == 10)
            assert(course.waypoints[3].x == 18 and course.waypoints[3].rev)
            assert(course.waypoints[4].x == 36 and course.waypoints[4].rev)
            assert(course.waypoints[5].x == 27 and math.abs(course.waypoints[5].z + 10.8) < 0.0001)
            assert(course.waypoints[6].x == 18 and math.abs(course.waypoints[6].z + 12.6) < 0.0001)
            assert(math.abs(course.waypoints[7].z + 12.6) < 0.0001)
        ''')

    def test_each_reverse_waits_until_straw_discharge_finishes(self):
        self.lua.execute('''
            AITurn.turn = function() return 1, 2, true, 10 end
            local reversing, dropping = false, false
            local raised, lowered = 0, 0
            local turn = setmetatable({
                ppc={isReversing=function() return reversing end},
                driveStrategy={
                    raiseImplements=function() raised=raised+1 end,
                    lowerImplements=function() lowered=lowered+1 end,
                    combineController={isDroppingStrawSwath=function() return dropping end}
                },
                debug=function() end
            }, CombinePocketHeadlandTurn)

            local _, _, _, speed = turn:turn(0)
            assert(speed == 10 and lowered == 1 and raised == 0)

            reversing, dropping = true, true
            _, _, _, speed = turn:turn(0)
            assert(speed == 0 and raised == 1)
            _, _, _, speed = turn:turn(0)
            assert(speed == 0 and raised == 1)
            dropping = false
            _, _, _, speed = turn:turn(0)
            assert(speed == 10 and raised == 1)

            reversing = false
            turn:turn(0)
            assert(lowered == 2)
            reversing, dropping = true, true
            _, _, _, speed = turn:turn(0)
            assert(speed == 0 and raised == 2)
            dropping = false
            _, _, _, speed = turn:turn(0)
            assert(speed == 10 and raised == 2)
        ''')


if __name__ == '__main__':
    unittest.main(verbosity=2)
