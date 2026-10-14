"""3031 ordinary-unload contracts through current hooks, with engine adapters.

The pathfinder is an asynchronous boundary, not a replay of FS25 physics.
Native admission/mode methods are also compared with the pinned milestone.
"""
from pathlib import Path
import subprocess
import sys
import unittest

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE/'tools/unloader-queue'))
import test_final_approach as final
final.ROOT = final.yielding.ROOT = final.yielding.runtime.ROOT = ROOT
MILESTONE = '03a903c11b0ae39cdf7b2bad228ed792c3df6e12'
NATIVE = subprocess.check_output(['git', 'show',
    f'{MILESTONE}:scripts/ai/strategies/AIDriveStrategyUnloadCombine.lua'], cwd=SOURCE).decode()


class MilestoneUnloadingTests(unittest.TestCase):
    def setUp(self):
        final.FinalApproachTests.setUp(self)
        self.lua.execute('currentUnloadClass=AIDriveStrategyUnloadCombine')
        self.lua.execute(NATIVE)
        self.lua.execute('''
            milestoneUnload=AIDriveStrategyUnloadCombine
            AIDriveStrategyUnloadCombine=currentUnloadClass
            final=false; harvester.lastSpeedReal=0; waitUntilEmpty=false; aligned=true
            c.states=AIDriveStrategyCombineCourse.myStates
            c.state=c.states.UNLOADING_ON_FIELD
            c.unloadState=c.states.WAITING_FOR_UNLOAD_IN_POCKET
            c.isReadyToUnload=nil -- use native crop/pocket readiness
            c.debugSparse=function() end
            c.isPipeInFruit=function() return false end
            c.course={isCloseToNextTurn=function() return false end}
            c.hasAutoAimPipe=function() return false end
            c.willWaitForUnloadToFinish=function() return waitUntilEmpty end
            c.getAreaToAvoid=function() return nil end
            c.getFillLevelPercentage=function() return fill/200 end
            c.isManeuvering=function() return false end
            u.isBehindAndAlignedToCombine=function() return aligned end
            u.isInFrontAndAlignedToMovingCombine=function() return false end
            u.getPipeOffset=function() return 12.2,0 end
            u.getCombinesMeasuredBackDistance=function() return 6.4 end
            u.getTargetNode=function(_,node) return node end
            u.pathfindingRange=25
            CpMathUtil.isSameDirection=function(a,b) return math.abs(a.t-b.t)<0.5 end
            u.getMaxFruitPercent=function() return 10 end
            u.getOffFieldPenalty=function() return 7.5 end
            u.startPathfindingToWaitingCombine=nil -- exercise the real wrapped native method
            u.startCourseFollowingCombine=function(self)
                self:setNewState(self.states.UNLOADING_MOVING_COMBINE)
            end
            u.getFollowingCourseOffset=function() return 12.2 end
            u.followCourse={setOffset=function() end, getCurrentWaypointIx=function() return 1 end,
                isTurnStartAtIx=function() return false end}
            v.cpGetFieldPolygon=function() return {} end
            CpFieldUtil={getFieldNumUnderVehicle=function() return 11 end}
            PathfinderUtil={getMaxIterationsForFieldPolygon=function() return 52619 end}
            PathfinderContext=function(vehicle)
                local context={vehicle=vehicle}
                for _,name in ipairs({'maxFruitPercent','offFieldPenalty','useFieldNum','areaToAvoid',
                        'vehiclesToIgnore','maxIterations'}) do
                    context[name]=function(self,value) self[name..'Value']=value; return self end
                end
                return context
            end
            AIUtil.getDirectionNodeToReverserNodeOffset=function() return 0 end
            function controllerFor(driver)
                return {registerListeners=function(self,owner,done,failed,obstacle)
                        self.owner=owner; self.done=done; self.failed=failed; self.obstacle=obstacle
                    end,
                    findPathToNode=function(self,context,node,x,z)
                        self.currentContext=context; self.goal={node=node,x=x,z=z}
                        self.pathfinder={}; self.searchCount=(self.searchCount or 0)+1
                    end}
            end
            u.pathfinderController=controllerFor(u)
            function noExtraRecovery(driver)
                assert(not driver.queueStoppedApproach and not driver.queueStoppedWatch
                    and not driver.queueStationaryPipe and not driver.queueFinalUnload)
            end
        ''')

    def test_ordinary_waits_match_milestone_admission_path_decision_and_mode(self):
        for state in ('WAITING_FOR_UNLOAD_IN_POCKET', 'WAITING_FOR_UNLOAD_ON_FIELD',
                      'WAITING_FOR_UNLOAD_AFTER_PULLED_BACK', 'WAITING_FOR_UNLOAD_BEFORE_STARTING_NEXT_ROW'):
            with self.subTest(state=state):
                self.setUp()
                self.lua.execute('c.unloadState=assert(c.states.'+state+')')
                self.lua.execute('''
                    assert(c:isWaitingForUnload())
                    trailer.rootNode.t=0.3 -- the added whole-rig admission would reject this
                    assert(u:isOkToStartUnloadingCombine()==milestoneUnload.isOkToStartUnloadingCombine(u))
                    assert(u:isOkToStartUnloadingCombine())
                    assert(u:isPathfindingNeeded(v,pipe,0,-8.4)==
                        milestoneUnload.isPathfindingNeeded(u,v,pipe,0,-8.4))
                    for _,wait in ipairs({false,true}) do
                        waitUntilEmpty=wait; u.state=u.states.DRIVING_TO_COMBINE
                        milestoneUnload.startUnloadingCombine(u); local expected=u.state
                        u.state=u.states.DRIVING_TO_COMBINE; u:startUnloadingCombine()
                        assert(u.state==expected); noExtraRecovery(u)
                    end
                    aligned=false
                    assert(not u:isOkToStartUnloadingCombine()) -- native rejection is preserved too
                ''')

    def test_logged_pocket_goal_survives_long_search_and_enters_native_unloading(self):
        self.lua.execute('''
            aligned=false; place(0,-60,0)
            assert(u:call(harvester,nil))
            local controller=u.pathfinderController; local search=controller.pathfinder
            assert(controller.goal.x==12.2 and math.abs(controller.goal.z+8.4)<0.0001)
            assert(controller.currentContext.maxFruitPercentValue==10)
            assert(controller.currentContext.offFieldPenaltyValue==7.5)
            for _,time in ipairs({23000,51000,78000,90190,180000}) do
                g_currentMission.time=time; Q.updateStoppedApproach(u); Q.updateFinalUnload(u)
                assert(u.state==u.states.WAITING_FOR_PATHFINDER and controller.pathfinder==search)
                assert(u.combineToUnload==harvester and not stopped); noExtraRecovery(u)
            end
            local course={adjustForReversing=function() end}
            assert(controller.done(u,controller,true,course,false))
            assert(u.state==u.states.DRIVING_TO_COMBINE and u.course==course)
            aligned=true; trailer.rootNode.t=0.3; waitUntilEmpty=true
            -- An unrelated obstacle in the queue's whole-rig goal query cannot
            -- inject a second run-in after native CP has accepted this course.
            collision=1; u:onLastWaypointPassed()
            assert(u.state==u.states.UNLOADING_STOPPED_COMBINE and not stopped)
            assert(u.combineToUnload==harvester); noExtraRecovery(u)
        ''')

    def test_four_jobs_remain_active_through_slow_pocket_search_and_transfer(self):
        self.lua.execute('''
            local fleet={u}
            for i=2,4 do
                local other={}
                for key,value in pairs(u) do other[key]=value end
                setmetatable(other,AIDriveStrategyUnloadCombine)
                other.queueData=nil; other.combineToUnload=nil; other.state=other.states.IDLE
                other.pathfinderController=controllerFor(other); fleet[i]=other
            end
            place(0,-60,0); aligned=false; assert(u:call(harvester,nil))
            for _,time in ipairs({30000,60000,90190,180000}) do
                g_currentMission.time=time
                for i,driver in ipairs(fleet) do
                    Q.updateStoppedApproach(driver); Q.updateFinalUnload(driver)
                    noExtraRecovery(driver)
                    if i>1 then assert(driver:isAllowedToBeCalled()) end
                end
                assert(not stopped and u.combineToUnload==harvester)
            end
            local controller=u.pathfinderController
            controller.done(u,controller,true,{adjustForReversing=function() end},false)
            aligned=true; waitUntilEmpty=true; u:onLastWaypointPassed()
            u:unloadStoppedCombine(); fill=fill-500; u:unloadStoppedCombine()
            assert(nativeDrives==2 and u.state==u.states.UNLOADING_STOPPED_COMBINE)
            c.isUnloadFinished=function() return true end
            u:unloadStoppedCombine()
            assert(u.state==u.states.MOVING_BACK and not stopped)
            for i=2,4 do assert(fleet[i]:isAllowedToBeCalled()) end
        ''')

    def test_ordinary_native_search_is_not_stopped_at_ninety_seconds(self):
        self.lua.execute('''
            aligned=false; place(0,-60,0); u:call(harvester,nil)
            local pending=u.pathfinderController.pathfinder
            g_currentMission.time=90190; Q.updateStoppedApproach(u)
            assert(not stopped, 'ordinary pathfinding was stopped by the final approach timer')
            assert(u.pathfinderController.pathfinder==pending)
            assert(u.state==u.states.WAITING_FOR_PATHFINDER); noExtraRecovery(u)
        ''')

    def test_ordinary_stationary_or_moving_wait_has_no_added_stall_replan(self):
        for mode in ('UNLOADING_STOPPED_COMBINE', 'UNLOADING_MOVING_COMBINE'):
            with self.subTest(mode=mode):
                self.setUp()
                self.lua.execute('u.state=u.states.'+mode)
                self.lua.execute('''
                    for _,time in ipairs({0,12001,30000,91000,180000}) do
                        g_currentMission.time=time
                        if u.state==u.states.UNLOADING_STOPPED_COMBINE then u:unloadStoppedCombine()
                        else u:unloadMovingCombine() end
                        Q.updateStoppedApproach(u); Q.updateFinalUnload(u)
                        assert(not stopped and not replan and u.combineToUnload==harvester)
                        noExtraRecovery(u)
                    end
                    assert(nativeDrives==5)
                ''')

    def test_native_failure_and_backup_callbacks_remain_in_charge(self):
        self.lua.execute('''
            aligned=false; place(0,-60,0); u:call(harvester,nil)
            u:onPathfindingDoneToWaitingCombine(u.pathfinderController,false,nil,true)
            assert(stopped=='no safe path'); noExtraRecovery(u)
        ''')
        self.setUp()
        self.lua.execute('''
            local context=nativeBackupFixture(); u.state=u.states.WAITING_FOR_PATHFINDER
            Q.stoppedApproachGoal(u,12.2,-8.4)
            u:onPathfindingObstacleAtStart(u.pathfinderController,context,1,false,0,0)
            g_currentMission.time=180000; Q.updateStoppedApproach(u)
            assert(u.state==u.states.MOVING_BACK_BEFORE_PATHFINDING and not stopped)
            u:onLastWaypointPassed()
            assert(retried==1 and u.state==u.states.DRIVING_TO_COMBINE); noExtraRecovery(u)
        ''')


if __name__ == '__main__':
    unittest.main()
