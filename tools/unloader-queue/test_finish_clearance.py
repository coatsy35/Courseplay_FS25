"""Final unload, checked forward parking, native completion and obstruction guards."""
from pathlib import Path
import sys
import unittest

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE/'tools/unloader-queue'))
import test_yield as yielding
yielding.ROOT = yielding.runtime.ROOT = ROOT


class FinishClearanceTests(unittest.TestCase):
    def setUp(self):
        yielding.YieldTests.setUp(self)
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,0,0)
            harvester.spec_combine={}
            harvester.cpGetFieldPolygon=v.cpGetFieldPolygon
            harvester.cpGetFieldBoundary=v.cpGetFieldBoundary
            neighbour,other=makeHarvester(15,-20,0)
            neighbour.getIsCpActive=function() return true end
            other.callUnloader=function() end
            c.states={WORKING={},UNLOADING_ON_FIELD={},WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED={}}
            c.state=c.states.UNLOADING_ON_FIELD; c.unloadState=c.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED
            c.safeFieldworkUnloadOrRefillStates={c.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED}
            CpUtil.isStateOneOf=function(state,states)
                for _,s in pairs(states) do if s==state then return true end end
                return false
            end
            c.isTurning=function() return false end
            c.combine=harvester
            c.isChopper=function() return false end
            c.settings={selfUnload={getValue=function() return false end},
                restartCourseAtEnd={getValue=function() return false end}}
            c.turningRadius=10
            c.fieldWorkerProximityController={hasSameCourse=function() return true end}
            fill=0; c.combineController={getFillLevel=function() return fill end}
            c.setMaxSpeed=function(self,speed) self.speed=math.min(self.speed or math.huge,speed) end
            c.raiseImplements=function() raised=true end
            c.startCourse=function(self,course) self.course=course; starts=(starts or 0)+1 end
            c.ppc.setShortLookaheadDistance=function() end
            c.fieldWorkCourse=Course(harvester,{{x=0,z=-100},{x=0,z=0}},false); c.course=c.fieldWorkCourse
            c.course:setCurrentWaypointIx(c.course:getNumberOfWaypoints())
            AIUtil.getSteeringParameters=function() return 0,0 end
            AIDriveStrategyFieldWorkCourse.finishFieldWork=function(self)
                assert(self:isWaitingForUnloadAfterCourseEnded())
                finishes=(finishes or 0)+1; harvester.active=false
            end
            g_currentMission.vehicleSystem.vehicles={harvester,neighbour}
            function advance()
                g_currentMission.time=g_currentMission.time+100
                c.speed=math.huge; c:driveUnloadOnField()
            end
            function plan()
                for i=1,100 do
                    advance()
                    if not c.queueFinishClearance or c.queueFinishClearance.driving then return end
                end
                error('clearance validation did not finish')
            end
            function move(z)
                harvester.rootNode.z=z; header.rootNode.z=z+5
            end
        ''')

    def test_final_unload_moves_then_preserves_native_finished_identity(self):
        self.lua.execute('''
            fill=100; advance(); assert(not c.queueFinishClearance and c.speed==0 and not finishes)
            fill=0; advance(); assert(c.queueFinishClearance and raised and not finishes)
            assert(not c:isWaitingForUnload() and c:isWaitingForUnloadAfterCourseEnded())
            assert(not c:isReadyToUnload(false) and c:isManeuvering())
            local original=c.fieldWorkCourse
            plan(); assert(starts==1 and c.course~=original and c.fieldWorkCourse==original)
            assert(original:getNumberOfWaypoints()==2)
            assert(c.queueFinishClearance.length>=20 and c.queueFinishClearance.length<=25)
            c:updateFieldworkOffset(c.course)
            for z=0,20 do move(z); advance(); if finishes then break end; assert(c.speed==5) end
            assert(finishes==1 and not c.queueFinishClearance and c:isWaitingForUnloadAfterCourseEnded())
            assert(not Q.beginFinishClearance(c),'completed job attempted a second parking move')
        ''')

    def test_empty_at_original_end_uses_same_clearance_without_editing_work_course(self):
        self.lua.execute('''
            c.state=c.states.WORKING; c.unloadState=nil
            c:onLastWaypointPassed(); assert(c.queueFinishClearance)
            plan(); local last=c.course:getNumberOfWaypoints()
            assert(last>2 and c.fieldWorkCourse:getNumberOfWaypoints()==2)
            move(c.queueFinishClearance.length); c:onLastWaypointPassed()
            assert(finishes==1)
        ''')

    def test_no_early_move_or_native_reverse_hold_while_unloader_is_assigned(self):
        self.lua.execute('''
            advance()
            local unloader={combineToUnload=harvester}
            local tractor={getCpDriveStrategy=function() return unloader end}
            g_currentMission.vehicleSystem.vehicles={harvester,neighbour,tractor}
            for i=1,20 do advance(); assert(not starts and not finishes and c.speed==0) end
            -- Native stopped-unload completion must recognise end-of-course,
            -- release its assignment and back away without holding the combine.
            setmetatable(unloader,AIDriveStrategyUnloadCombine)
            unloader.changeToUnloadWhenTrailerFull=function() return false end
            unloader.areThereAnyCombinesOrLoaderLeftoverOnTheField=function() return true end
            unloader.debug=function() end
            unloader.states={MOVING_BACK={}}
            unloader.ppc={setNormalLookaheadDistance=function() end}
            unloader.releaseCombine=function(self) self.combineJustUnloaded=self.combineToUnload; self.combineToUnload=nil end
            unloader.startMovingBackFromCombine=function(_,state,combine,hold)
                assert(combine==harvester and not hold); reversed=true
            end
            c.getFillLevelPercentage=function() return 0 end
            c.isFull=function() return false end
            c.pipeController={justStoppedDischarging=function() return false end}
            unloader:unloadStoppedCombine(); assert(reversed and not unloader.combineToUnload)
            plan(); assert(starts==1 and not finishes)
        ''')

    def test_standing_crop_boundary_and_header_only_obstacle_prevent_departure(self):
        for obstruction in ('densityCount=10', '''
            harvester.cpGetFieldPolygon=function() return {{x=-100,z=-100},{x=100,z=-100},{x=100,z=12},{x=-100,z=12}} end
            ''', '''
            overlapBox=function(x,y,z,rx,ry,rz,w,h,l,callback,detector)
                -- Only the header side intersects this stationary object.
                detector.collidingShapes=(x+w>=7 and z+l>=10) and 1 or 0
            end
            '''):
            with self.subTest(obstruction=obstruction):
                self.setUp()
                self.lua.execute(obstruction+'''
                    advance(); assert(c.queueFinishClearance)
                    for i=1,300 do advance(); if finishes then break end end
                    assert(finishes==1 and not starts and not c.queueFinishClearance)
                ''')

    def test_moving_unload_completion_releases_without_holding_finished_combine(self):
        self.lua.execute('''
            advance(); assert(c.queueFinishClearance)
            c.getFillLevelPercentage=function() return 0 end
            c.isTurningOnHeadland=function() return false end
            u.combineToUnload=harvester
            u.getFollowingCourseOffset=function() return 0 end
            u.followCourse={setOffset=function() end}
            u.changeToUnloadWhenTrailerFull=function() return false end
            u.driveBesideCombine=function() return 0,0 end
            u.startWaitingForSomethingToDo=function() idle=true end
            u.startMovingBackFromCombine=function() error('moving unload incorrectly held the finished combine') end
            u:unloadMovingCombine()
            assert(idle and not u.combineToUnload)
            plan(); assert(starts==1 and not finishes)
        ''')

    def test_late_obstacle_and_native_stop_do_not_reset_progress_timeout(self):
        self.lua.execute('''
            advance(); plan(); advance(); assert(c.speed==5)
            collision=1; g_currentMission.time=g_currentMission.time+201
            advance(); assert(c.speed==0 and not finishes)
            collision=0; move(1); advance(); advance(); assert(c.speed==5)
            -- Native proximity/traffic may still stop us despite a clear
            -- geometric route. No movement must eventually end the attempt.
            g_currentMission.time=g_currentMission.time+10001; advance()
            assert(finishes==1 and not c.queueFinishClearance)
        ''')

    def test_no_other_worker_or_unsupported_mode_keeps_native_completion(self):
        for setup in ('g_currentMission.vehicleSystem.vehicles={harvester}',
                      'c.settings.selfUnload.getValue=function() return true end',
                      'c.settings.restartCourseAtEnd.getValue=function() return true end',
                      'AIUtil.getSteeringParameters=function() return 0,8 end',
                      'c.isChopper=function() return true end'):
            with self.subTest(setup=setup):
                self.setUp()
                self.lua.execute(setup+'; advance(); assert(finishes==1 and not starts and not c.queueFinishClearance)')

    def test_manual_stop_cleanup_does_not_finish_or_keep_collision_probe(self):
        self.lua.execute('''
            advance(); local world=c.queueFinishClearance.world; assert(world.node)
            Q.clearFinishClearance(c)
            assert(not world.node and not c.queueFinishClearance and not finishes and not starts)
        ''')

    def test_empty_parking_combine_is_not_another_load_for_final_trailer(self):
        self.lua.execute('''
            advance(); assert(c.queueFinishClearance)
            c.callUnloader=function() end
            u.isServingPosition=function(_,x,z) return x<500 end
            assert(u:areThereAnyCombinesOrLoaderLeftoverOnTheField(harvester,c))
            other.queueFinishClearance={}
            assert(not u:areThereAnyCombinesOrLoaderLeftoverOnTheField(harvester,c))
            other.queueFinishClearance=nil; neighbour.rootNode.x=800
            assert(not u:areThereAnyCombinesOrLoaderLeftoverOnTheField(harvester,c))
            -- The caller can now use its native reverse/full-trailer handover,
            -- even when the other empty combine is still finishing its move.
        ''')


    def test_crop_in_empty_gap_beside_chassis_does_not_block_header_move(self):
        self.lua.execute('''
            -- A small patch behind the header and outside the chassis. The old
            -- union box covers it at the starting pose; neither real part does.
            harvester.getAIMarkers=function()
                return {x=7.6,z=5,t=0},{x=-7.6,z=5,t=0},{x=0,z=-4,t=0}
            end
            DensityMapModifier.new=function()
                return {setParallelogramWorldCoords=function(self,ax,az,bx,bz,dx,dz)
                    self.rectangle={{x=ax,z=az},{x=bx,z=bz},{x=bx+dx-ax,z=bz+dz-az},{x=dx,z=dz}}
                end,executeGet=function(self,filter)
                    local hit=G.inside(self.rectangle,{x=6,z=-2})
                    return 0,(filter.mode==1 and hit) and 1 or 0,100
                end}
            end
            advance(); plan()
            assert(c.queueFinishClearance and c.queueFinishClearance.driving and not finishes)
        ''')

    def test_cut_canola_is_clear_and_invalid_density_has_distinct_diagnosis(self):
        self.lua.execute('''
            g_fruitTypeManager.getFruitTypes=function()
                return {{name='CANOLA',terrainDataPlaneId=1,startStateChannel=0,numStateChannels=4,cutStates={[11]=true}}}
            end
            densityStates={[11]=100}
            advance(); plan(); assert(c.queueFinishClearance.driving)
            Q.clearFinishClearance(c); c.queueFinishAttempted=nil; densityTotal=0
            c.unloadState=c.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED
            local message
            c.debug=function(_,format,...) message=string.format(format,...) end
            advance(); plan()
            assert(finishes==1 and message:find('invalid crop density',1,true))
            assert(message:find('crop=CANOLA',1,true) and not message:find('standing crop',1,true))
        ''')

    def test_header_geometry_change_restarts_initial_sweep(self):
        self.lua.execute('''
            advance(); advance()
            assert(c.queueFinishClearance.sample==8)
            header.rootNode.x=header.rootNode.x+0.5
            advance()
            assert(c.queueFinishClearance.sample==8 and not starts)
            plan(); assert(c.queueFinishClearance.driving)
        ''')

    def test_separate_rotated_offset_components_preserve_world_footprints(self):
        self.lua.execute('''
            harvester.rootNode={x=31,z=-14,t=1.2}
            header.rootNode={x=37,z=-9,t=1.45}
            header.size.widthOffset=1.4
            local originals=W.currentBodies(harvester)
            local model=W.rigidModel(harvester)
            assert(#model.bodies==2)
            local world={model=model}
            local checked=0
            local native=W.bodyClear
            W.bodyClear=function(_,body,pose)
                checked=checked+1
                local actual=W.rectangle(body,pose,0)
                local expected=W.rectangle(originals[checked].body,originals[checked].pose,0)
                for i=1,4 do
                    assert(math.abs(actual[i].x-expected[i].x)<0.0001)
                    assert(math.abs(actual[i].z-expected[i].z)<0.0001)
                end
                return true
            end
            assert(W.rigidClear(world,model.root) and checked==2)
            W.bodyClear=native
        ''')

if __name__=='__main__': unittest.main()
