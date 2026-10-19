"""Final-only crop crossing, checked parking routes and native completion."""
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
            other.combineController={getFillLevel=function() return 0 end}
            other.getPipeOffset=function(_,x,z) return 11+(x or 0),-2+(z or 0) end
            other.getPipeOffsetReferenceNode=function() return neighbour.rootNode end
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
            local worked={}
            for z=60,-90,-2 do worked[#worked+1]={x=-45,z=z} end
            worked[#worked+1]={x=0,z=-90}
            for z=-88,0,2 do worked[#worked+1]={x=0,z=z} end
            c.fieldWorkCourse=Course(harvester,worked,false); c.course=c.fieldWorkCourse
            originalCount=#worked
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
                for i=1,3000 do
                    advance()
                    if not c.queueFinishClearance or c.queueFinishClearance.driving then return end
                end
                error('clearance validation did not finish')
            end
            function move(z)
                harvester.rootNode.z=z; header.rootNode.z=z+5
            end
            function movePose(p)
                harvester.rootNode.x=p.x; harvester.rootNode.z=p.z; harvester.rootNode.t=p.t
                header.rootNode.x,header.rootNode.z=H.math.position(p,0,5); header.rootNode.t=p.t
            end
            function followParking()
                local points=c.queueFinishClearance.route.points
                for _,p in ipairs(points) do
                    movePose(p); advance()
                    if finishes then return end
                    assert(c.speed==5)
                end
                assert(finishes==1)
            end
        ''')

    def test_completed_combine_cannot_recall_trailer_in_its_stopping_update(self):
        self.lua.execute('''
            Q.data(u)
            c.timeToCallUnloader={get=function() return true end,set=function() end}
            c.unloader={get=function() return nil end}
            u.call=function() error('empty terminal combine recalled trailer') end
            -- Exercise the actual native call through the existing dispatch hook,
            -- both before deletion and after the successful stop in this frame.
            c:callUnloaderWhenNeeded()
            advance(); plan(); followParking()
            assert(finishes==1 and not harvester:getIsCpActive())
            c:callUnloaderWhenNeeded()
        ''')

    def close_combine_fixture(self, lateral=-17, longitudinal=3):
        self.lua.globals().lateral = lateral
        self.lua.globals().longitudinal = longitudinal
        self.lua.execute('''
            neighbour.rootNode.x=lateral; neighbour.rootNode.z=longitudinal
            otherHeader=neighbour:getAttachedImplements()[1].object
            otherHeader.rootNode.x=lateral; otherHeader.rootNode.z=longitudinal+5
            neighbour.spec_combine={}
            neighbour.cpGetFieldPolygon=v.cpGetFieldPolygon
            neighbour.cpGetFieldBoundary=v.cpGetFieldBoundary
            for _,key in ipairs({'states','settings','turningRadius','safeFieldworkUnloadOrRefillStates',
                    'fieldWorkerProximityController','setMaxSpeed','raiseImplements','startCourse','isTurning','isChopper'}) do
                other[key]=c[key]
            end
            other.combine=neighbour
            other.state=other.states.UNLOADING_ON_FIELD
            other.unloadState=other.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED
            other.ppc.setShortLookaheadDistance=function() end
            otherFill=100
            other.combineController.getFillLevel=function() return otherFill end
            local worked={}
            for z=60,-90,-2 do worked[#worked+1]={x=lateral-45,z=z} end
            worked[#worked+1]={x=lateral,z=-90}
            for z=-88,longitudinal,2 do worked[#worked+1]={x=lateral,z=z} end
            worked[#worked+1]={x=lateral,z=longitudinal}
            other.fieldWorkCourse=Course(neighbour,worked,false); other.course=other.fieldWorkCourse
            other.course:setCurrentWaypointIx(other.course:getNumberOfWaypoints())
            u.isServingPosition=function() return true end
            u.settings.combineOffsetX={getValue=function() return 0 end}
            u.settings.combineOffsetZ={getValue=function() return 0 end}
            place(65,-60,0)
            g_currentMission.vehicleSystem.vehicles={harvester,neighbour,v}
            local constructor=PathfinderCollisionDetector
            PathfinderCollisionDetector=function(vehicle,...)
                local detector=constructor(vehicle,...); detector.vehicle=vehicle; return detector
            end
            -- Engine adapter checks both actual chassis/header footprints and
            -- tractor/trailer bodies, excluding only the queried rig itself.
            overlapBox=function(x,y,z,rx,ry,rz,w,h,l,callback,detector)
                local probe=G.rectangle({x=x,z=z,heading=ry},{width=2*w,length=2*l},0)
                detector.collidingShapes=0
                for _,vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
                    if vehicle~=detector.vehicle then
                        for _,item in ipairs(W.currentBodies(vehicle)) do
                            if G.overlap(probe,W.rectangle(item.body,item.pose,0)) then
                                detector.collidingShapes=detector.collidingShapes+1
                                detector.collidingShapesText='adjacent rig'
                            end
                        end
                    end
                end
            end
            AIDriveStrategyFieldWorkCourse.finishFieldWork=function(self)
                assert(self:isWaitingForUnloadAfterCourseEnded())
                self.finished=true; self.vehicle.active=false
            end
            function stepFinal(driver)
                g_currentMission.time=g_currentMission.time+100
                driver.speed=math.huge; driver:driveUnloadOnField()
            end
            function planFinal(driver)
                for i=1,5000 do
                    stepFinal(driver)
                    if driver.queueFinishClearance.driving then return end
                end
                error('no checked final route')
            end
            function followFinal(driver,mounted)
                local points=driver.queueFinishClearance.route.points
                for _,p in ipairs(points) do
                    local node=driver.vehicle.rootNode
                    node.x=p.x; node.z=p.z; node.t=p.t
                    mounted.rootNode.x,mounted.rootNode.z=H.math.position(p,0,5)
                    mounted.rootNode.t=p.t
                    stepFinal(driver)
                    if driver.finished then return end
                    assert(driver.speed==5)
                end
                assert(driver.finished)
            end
        ''')

    def test_follower_leaves_room_through_final_unload_reverse_and_parking(self):
        self.close_combine_fixture(lateral=-15.2, longitudinal=3)
        self.lua.execute('''
            fill=100
            other.state=other.states.WORKING; other.unloadState=nil
            other.course:setCurrentWaypointIx(other.course:getNumberOfWaypoints()-10)
            neighbour.rootNode.z=-20; otherHeader.rootNode.z=-15
            assert(Q.holdFinalApproach(other)==harvester)
            assert(not Q.holdFinalApproach(c))
            -- Emptying alone does not release the following header.
            fill=0; advance()
            assert(c.queueFinishClearance and Q.holdFinalApproach(other)==harvester)
            -- Retain priority while the lead turns back towards a cleared row.
            move(-40)
            assert(Q.holdFinalApproach(other)==harvester)
            Q.clearFinishClearance(c); harvester.active=false
            assert(not Q.holdFinalApproach(other))
        ''')

    def test_final_order_uses_physical_forward_position_not_distance_to_end(self):
        self.close_combine_fixture(lateral=-15.2, longitudinal=3)
        self.lua.execute('''
            c.state=c.states.WORKING; c.unloadState=nil
            other.state=other.states.WORKING; other.unloadState=nil
            c.course:setCurrentWaypointIx(c.course:getNumberOfWaypoints()-10)
            other.course:setCurrentWaypointIx(other.course:getNumberOfWaypoints()-10)
            move(-20); neighbour.rootNode.z=-24; otherHeader.rootNode.z=-19
            -- Give the physically trailing worker an earlier endpoint, so it is
            -- closer to its own finish despite being behind the lead harvester.
            local points={{x=lateral,z=-50},{x=lateral,z=-30},{x=lateral,z=-9}}
            other.fieldWorkCourse=Course(neighbour,points,false); other.course=other.fieldWorkCourse
            other.course:setCurrentWaypointIx(2)
            assert(not Q.holdFinalApproach(c))
            assert(Q.holdFinalApproach(other)==harvester)
            -- Ordinary rows, turns and distant finishes never use this gate.
            local original=c.course
            c.course=Course(harvester,{{x=0,z=-20},{x=0,z=20}},true)
            assert(not Q.holdFinalApproach(other))
            c.course=original; c.settings.restartCourseAtEnd.getValue=function() return true end
            assert(not Q.holdFinalApproach(other))
        ''')

    def test_three_finishers_release_in_physical_order_without_reciprocal_holds(self):
        self.close_combine_fixture(lateral=-15.2, longitudinal=3)
        self.lua.execute('''
            neighbour.getIsCpActive=function() return neighbour.active end
            c.state=c.states.WORKING; c.unloadState=nil
            other.state=other.states.WORKING; other.unloadState=nil
            c.course:setCurrentWaypointIx(c.course:getNumberOfWaypoints()-5)
            other.course:setCurrentWaypointIx(other.course:getNumberOfWaypoints()-5)
            move(-20); neighbour.rootNode.z=-20.9; otherHeader.rootNode.z=-15.9
            local third,thirdDriver=makeHarvester(-30.4,-21.8,0)
            third.spec_combine={}; thirdDriver.combine=third
            for _,key in ipairs({'states','settings','turningRadius','fieldWorkerProximityController','isTurning','isChopper'}) do
                thirdDriver[key]=c[key]
            end
            thirdDriver.state=thirdDriver.states.WORKING
            thirdDriver.fieldWorkCourse=Course(third,{{x=-30.4,z=-50},{x=-30.4,z=-25},{x=-30.4,z=0}},false)
            thirdDriver.course=thirdDriver.fieldWorkCourse; thirdDriver.course:setCurrentWaypointIx(2)
            g_currentMission.vehicleSystem.vehicles={third,neighbour,harvester}
            assert(not Q.holdFinalApproach(c))
            assert(Q.holdFinalApproach(other)==harvester)
            assert(Q.holdFinalApproach(thirdDriver))
            harvester.active=false
            assert(not Q.holdFinalApproach(other))
            assert(Q.holdFinalApproach(thirdDriver)==neighbour)
            neighbour.active=false
            assert(not Q.holdFinalApproach(thirdDriver))
        ''')

    def test_five_finishers_clear_in_physical_order_including_ties(self):
        for tied in (False, True):
            with self.subTest(tied=tied):
                self.setUp()
                self.lua.globals().tied = tied
                self.lua.execute('''
                    local fleet={}
                    for i=1,5 do
                        local x,z=(i-1)*15.2,tied and -20 or -18-i*2
                        local vehicle,driver=makeHarvester(x,z,0)
                        vehicle.spec_combine={}; driver.combine=vehicle
                        for _,key in ipairs({'states','settings','turningRadius','fieldWorkerProximityController','isTurning','isChopper'}) do
                            driver[key]=c[key]
                        end
                        driver.state=driver.states.WORKING
                        driver.fieldWorkCourse=Course(vehicle,{{x=x,z=-60},{x=x,z=-30},{x=x,z=0}},false)
                        driver.course=driver.fieldWorkCourse; driver.course:setCurrentWaypointIx(2)
                        fleet[#fleet+1]=vehicle
                    end
                    -- Mission enumeration must not decide departure priority.
                    g_currentMission.vehicleSystem.vehicles={fleet[5],fleet[3],fleet[1],fleet[4],fleet[2]}
                    table.sort(fleet,function(a,b)
                        if a.rootNode.z~=b.rootNode.z then return a.rootNode.z>b.rootNode.z end
                        return tostring(a.rootNode)<tostring(b.rootNode)
                    end)
                    for index,leader in ipairs(fleet) do
                        for i=index,5 do
                            local blocker=Q.holdFinalApproach(fleet[i]:getCpDriveStrategy())
                            if i==index then assert(not blocker) else assert(blocker) end
                        end
                        -- Keep ownership when the leader has emptied and turns
                        -- back; only completing its parking releases the next.
                        local driver=leader:getCpDriveStrategy()
                        driver.queueFinishClearance={}
                        leader.rootNode.z=-50
                        for i=index+1,5 do assert(Q.holdFinalApproach(fleet[i]:getCpDriveStrategy())) end
                        driver.queueFinishClearance=nil; leader.active=false
                    end
                ''')

    def test_adjacent_finished_combines_unload_clear_and_park_in_sequence(self):
        self.close_combine_fixture()
        self.lua.execute('''
            place(11,0,0)
            g_currentMission.vehicleSystem.vehicles={harvester,neighbour,v}
            u.states.MOVING_BACK={properties={vehicle=harvester}}
            u.states.MOVING_BACK_WITH_TRAILER_FULL={properties={}}
            u.combineToUnload=harvester
            fill=0; advance()
            for i=1,10 do advance(); assert(not starts and not c.finished) end
            u.combineToUnload=nil; u.state=u.states.MOVING_BACK
            place(11,-15,0)
            for i=1,10 do advance(); assert(not starts and not c.finished) end
            u.state=u.states.IDLE
            planFinal(c)
            local route=c.queueFinishClearance.route
            assert(route.option>1 and route.options[route.option].lead>3)
            assert(otherFill==100 and not other.queueFinishClearance and not other.finished)
            for _,p in ipairs(route.points) do assert(W.rigidClear(c.queueFinishClearance.world,p)) end
            followFinal(c,header)
            assert(c.finished and not c.queueFinishClearance and not other.finished)
            -- Only now simulate completion of the second native final unload.
            u.combineToUnload=neighbour; otherFill=0
            stepFinal(other)
            assert(other.queueFinishClearance and not other.queueFinishClearance.driving)
            u.combineToUnload=nil; u.state=u.states.MOVING_BACK
            u.state.properties.vehicle=neighbour
            place(lateral+11,longitudinal-15,0)
            stepFinal(other); assert(not other.queueFinishClearance.driving)
            u.state=u.states.IDLE
            planFinal(other)
            assert(other.queueFinishClearance.goal.x==lateral-45)
            followFinal(other,otherHeader)
            assert(other.finished and not other.queueFinishClearance)
        ''')

    def test_opposite_turn_word_can_clear_a_close_header(self):
        self.close_combine_fixture(lateral=-15.2, longitudinal=3)
        self.lua.execute('''
            otherFill=0
            advance(); planFinal(c)
            local data=c.queueFinishClearance
            local selected=data.route.options[data.route.option]
            assert(data.route.option>1)
            assert(selected.word~=data.route.options[1].word)
            for _,p in ipairs(data.route.points) do assert(W.rigidClear(data.world,p)) end
            followFinal(c,header); assert(c.finished)
        ''')

    def test_blocked_start_waits_once_and_recovers_without_ignoring_header(self):
        self.close_combine_fixture(lateral=-15.2, longitudinal=0)
        self.lua.execute('''
            otherFill=0; advance(); advance()
            local data=c.queueFinishClearance
            assert(not starts and not c.finished and data.reason:find('start blocked:'))
            assert(data.reason:find('adjacent rig'))
            local calls=0; local clear=W.rigidClear
            W.rigidClear=function(...) calls=calls+1; return clear(...) end
            for i=1,10 do advance() end
            assert(calls==0 and not starts)
            W.rigidClear=clear
            neighbour.rootNode.z=3; otherHeader.rootNode.z=8
            planFinal(c); followFinal(c,header); assert(c.finished)
        ''')

    def test_final_unload_moves_then_preserves_native_finished_identity(self):
        self.lua.execute('''
            fill=100; advance(); assert(not c.queueFinishClearance and c.speed==0 and not finishes)
            fill=0; advance(); assert(c.queueFinishClearance and raised and not finishes)
            assert(not c:isWaitingForUnload() and c:isWaitingForUnloadAfterCourseEnded())
            assert(not c:isReadyToUnload(false) and c:isManeuvering())
            local original=c.fieldWorkCourse
            plan(); assert(starts==1 and c.course~=original and c.fieldWorkCourse==original)
            assert(original:getNumberOfWaypoints()==originalCount)
            local goal=c.queueFinishClearance.goal
            assert(goal.x==-45 and math.abs(math.sin(goal.t))<0.001)
            c:updateFieldworkOffset(c.course)
            followParking()
            assert(finishes==1 and not c.queueFinishClearance and c:isWaitingForUnloadAfterCourseEnded())
            assert(not Q.beginFinishClearance(c),'completed job attempted a second parking move')
        ''')

    def test_empty_at_original_end_uses_same_clearance_without_editing_work_course(self):
        self.lua.execute('''
            c.state=c.states.WORKING; c.unloadState=nil
            c:onLastWaypointPassed(); assert(c.queueFinishClearance)
            plan(); local last=c.course:getNumberOfWaypoints()
            assert(last>2 and c.fieldWorkCourse:getNumberOfWaypoints()==originalCount)
            movePose(c.queueFinishClearance.goal); c:onLastWaypointPassed()
            assert(finishes==1)
        ''')

    def test_no_early_move_or_native_reverse_hold_while_unloader_is_assigned(self):
        self.lua.execute('''
            advance()
            local unloader={combineToUnload=harvester,augerWagon=true}
            local tractor={getCpDriveStrategy=function() return unloader end,
                getAIDirectionNode=function() return {x=10,z=0,t=0} end}
            g_currentMission.vehicleSystem.vehicles={harvester,neighbour,tractor}
            for i=1,20 do advance(); assert(not starts and not finishes and c.speed==0) end
            -- Native stopped-unload completion must recognise end-of-course,
            -- release its assignment and back away without holding the combine.
            setmetatable(unloader,AIDriveStrategyUnloadCombine)
            unloader.changeToUnloadWhenTrailerFull=function() return false end
            unloader.areThereAnyCombinesOrLoaderLeftoverOnTheField=function() return true end
            unloader.debug=function() end
            unloader.states={MOVING_BACK={properties={}},IDLE={properties={}}}
            unloader.ppc={setNormalLookaheadDistance=function() end}
            unloader.releaseCombine=function(self) self.combineJustUnloaded=self.combineToUnload; self.combineToUnload=nil end
            unloader.startMovingBackFromCombine=function(self,state,combine,hold)
                assert(combine==harvester and not hold); reversed=true
                self.state=state; state.properties.vehicle=combine
            end
            c.getFillLevelPercentage=function() return 0 end
            c.isFull=function() return false end
            c.pipeController={justStoppedDischarging=function() return false end}
            unloader:unloadStoppedCombine(); assert(reversed and not unloader.combineToUnload)
            g_currentMission.time=g_currentMission.time+61000; advance()
            assert(not starts and not finishes and c.speed==0)
            unloader.state=unloader.states.IDLE
            plan(); assert(starts==1 and not finishes)
        ''')

    def test_stalled_trailer_clearance_waits_unfolded_and_recovers(self):
        self.lua.execute('''
            advance()
            u.states={MOVING_BACK={properties={vehicle=harvester}},MOVING_BACK_WITH_TRAILER_FULL={}}
            u.state=u.states.MOVING_BACK; u.combineToUnload=nil
            g_currentMission.vehicleSystem.vehicles={harvester,neighbour,v}
            advance(); assert(not starts and not finishes)
            g_currentMission.time=g_currentMission.time+110000; place(0,2,0); advance()
            assert(not starts and not finishes,'physical reverse progress must renew the wait')
            g_currentMission.time=g_currentMission.time+120001; advance()
            assert(not finishes and not starts and c.queueFinishClearance)
            u.state={}; plan(); assert(starts==1 and not finishes)
        ''')

    def test_boundary_and_header_only_obstacle_still_prevent_departure(self):
        for obstruction in ('''
            harvester.cpGetFieldPolygon=function() return {{x=-100,z=-100},{x=100,z=-100},{x=100,z=7},{x=-100,z=12}} end
            ''', '''
            overlapBox=function(x,y,z,rx,ry,rz,w,h,l,callback,detector)
                -- Only the header side intersects this stationary object.
                detector.collidingShapes=(x+w>=7 and z+l>=6) and 1 or 0
            end
            '''):
            with self.subTest(obstruction=obstruction):
                self.setUp()
                self.lua.execute(obstruction+'''
                    advance(); assert(c.queueFinishClearance)
                    for i=1,300 do advance(); if finishes then break end end
                    assert(not finishes and not starts and c.queueFinishClearance)
                ''')

    def test_moving_final_unload_reverses_clear_before_combine_parks(self):
        self.lua.execute('''
            advance(); assert(c.queueFinishClearance)
            u.states={UNLOADING_MOVING_COMBINE={},MOVING_BACK={properties={}},
                MOVING_BACK_WITH_TRAILER_FULL={properties={}},IDLE={}}
            u.state=u.states.UNLOADING_MOVING_COMBINE
            u.combineToUnload=harvester
            u.isDriveUnloadNowRequested=function() return false end
            u.isServingPosition=function() return true end
            u.ppc.setNormalLookaheadDistance=function() end
            u.releaseCombine=function(self) self.combineToUnload=nil end
            u.startMovingBackFromCombine=function(self,state,target,hold)
                assert(target==harvester and not hold)
                self.state=state; state.properties.vehicle=target; reversed=true
            end
            g_currentMission.vehicleSystem.vehicles={harvester,neighbour,v}
            u:unloadMovingCombine()
            assert(reversed and not u.combineToUnload and u.state==u.states.MOVING_BACK)
            for i=1,20 do advance(); assert(not starts and not finishes) end
            -- Native reverse has physically cleared the reserved finish lane.
            place(65,-60,0); v.lastSpeedReal=0
            u.state=u.states.IDLE
            plan(); assert(starts==1 and not finishes)
        ''')

    def near_final_release(self):
        self.lua.execute('''
            c.state=c.states.WORKING; c.unloadState=nil
            c.course:setCurrentWaypointIx(c.course:getNumberOfWaypoints()-10)
            move(-20)
            u.state=u.states.UNLOADING_MOVING_COMBINE; u.combineToUnload=harvester
            u.isServingPosition=function() return true end
            u.ppc.setNormalLookaheadDistance=function() end
            u.startMovingBackFromCombine=function(self,state,target,hold)
                assert(target==harvester and not hold)
                self.state=state; state.properties.vehicle=target
                reversed=(reversed or 0)+1
            end
            assert(Q.releaseFinishedCombine(u))
            assert(reversed==1 and u.state==u.states.MOVING_BACK and not u.combineToUnload)
            assert(not Q.releaseFinishedCombine(u) and reversed==1)
            assert(not Q.holdFinalRelease(u),'priority wait prevented native reverse')
            u.state=u.states.IDLE
        ''')

    def test_empty_before_last_waypoint_reverses_then_waits_for_physical_length(self):
        self.near_final_release()
        self.lua.execute('''
            assert(Q.holdFinalRelease(u) and not u:isAllowedToBeCalled())
            Q.tick(u); assert(u.speed==0 and u.state==u.states.IDLE)
            local pause=u.queueData.finalRelease
            -- Waypoint jumps and sideways displacement are not forward clearance.
            c.course:setCurrentWaypointIx(c.course:getNumberOfWaypoints())
            movePose({x=30,z=-20,t=0}); assert(Q.holdFinalRelease(u))
            movePose({x=0,z=-20+pause.length-0.1,t=0}); assert(Q.holdFinalRelease(u))
            move(-20+pause.length); assert(not Q.holdFinalRelease(u))
            assert(not u.queueData.finalRelease)
        ''')

    def test_final_release_wait_cannot_deadlock_next_load_or_restarted_combine(self):
        for change in ('fill=100; c.isWaitingForUnload=function() return true end',
                       'harvester.active=false', 'c.fieldWorkCourse={}',
                       'harvester.getCpDriveStrategy=function() return nil end'):
            with self.subTest(change=change):
                self.setUp(); self.near_final_release()
                self.lua.execute(change+'''
                    assert(not Q.holdFinalRelease(u))
                    assert(not u.queueData.finalRelease)
                ''')

    def test_final_lane_reserves_header_and_complete_parked_trailer(self):
        self.lua.execute('''
            c.state=c.states.WORKING; c.unloadState=nil
            c.course:setCurrentWaypointIx(c.course:getNumberOfWaypoints()-10); move(-20)
            local model=W.model(v)
            -- Tractor has cleared the lane, but its trailer still crosses it.
            local goal={x=30,z=12,t=math.pi/2}
            local poses=W.settledPoses(model,goal)
            local area=assert(Q.finishLane(c))
            assert(not area(W.rectangle(model.bodies[1],poses[1])))
            assert(area(W.rectangle(model.bodies[2],poses[2])))
            assert(not Q.stagingClear(u,poses,model))
            assert(Q.stagingClear(u,W.settledPoses(model,{x=65,z=-60,t=0}),model))
            harvester.active=false
            assert(Q.stagingClear(u,poses,model),'completed job left stale reservation')
        ''')

    def test_already_parked_final_lane_blocker_gets_persistent_checked_yield(self):
        self.lua.execute('''
            place(0,24,math.pi/2); Q.take(u,'prepare')
            AIUtil.isStopped=function() return true end
            includeHarvesterCollision()
            Q.clearFinishTraffic(c)
            local data=u.queueData
            assert(data.operation=='yield' and data.yieldRequests[harvester])
            local request=data.yieldRequests[harvester]
            assert(request.finishCourse==c.fieldWorkCourse and request.turnClearance)
            request.clearSince=-201; request.checked=-201
            Q.clearFinishTraffic(c)
            assert(data.yieldRequests[harvester]==request and request.checked==-201)
            -- Moving the tractor alone does not release a still-crossing trailer.
            place(30,12,math.pi/2); Q.yieldTarget(u,true)
            assert(data.yieldRequests[harvester])
            place(65,-60,0); c.near=false
            Q.yieldTarget(u,true); g_currentMission.time=g_currentMission.time+2001
            Q.yieldTarget(u,true)
            assert(not data.yieldRequests or not data.yieldRequests[harvester])
            assert(Q.stagingClear(u,W.poses(W.model(v)),W.model(v)))
        ''')

    def test_short_final_row_released_trailer_can_clear_before_combine_parks(self):
        self.near_final_release()
        self.lua.execute('''
            -- The remaining row is shorter than the required forward wait.
            move(-15); place(0,24,math.pi/2)
            c.state=c.states.UNLOADING_ON_FIELD
            c.unloadState=c.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED
            AIUtil.isStopped=function() return true end
            includeHarvesterCollision()
            assert(Q.holdFinalRelease(u))
            assert(Q.clearFinishTraffic(c))
            assert(not u.queueData.finalRelease and u.queueData.operation=='yield')
            assert(not Q.holdFinalRelease(u))
            local goal=assert(Q.yieldTarget(u))
            Q.request(u,goal); local data=u.queueData
            local done,path,reason
            for i=1,300000 do
                done,path,reason=CpUnloaderQueueSearch.step(data.search,1)
                if done then break end
            end
            assert(done and path,reason or 'final-lane escape search did not complete')
            Q.startRoute(data,path)
            local poses=W.poses(data.world.model)
            for i=2,#path do
                poses=W.advance(data.world.model,poses,path[i]); assert(W.clear(data.world,poses))
            end
            for i,p in ipairs(poses) do
                local node=i==1 and v.rootNode or trailer.rootNode
                node.x=p.x; node.z=p.z; node.t=p.t
            end
            local x,z=H.math.position(v.rootNode,0,-3.3)
            trailer.joint.node.x=x; trailer.joint.node.z=z; trailer.joint.node.t=v.rootNode.t
            assert(Q.onLast(u)); c.near=false
            Q.yieldTarget(u,true); g_currentMission.time=g_currentMission.time+2001
            Q.yieldTarget(u,true)
            assert(data.operation=='prepare' and not Q.clearFinishTraffic(c))
            assert(Q.stagingClear(u,W.poses(W.model(v)),W.model(v)))
        ''')

    def test_full_post_reverse_trailer_keeps_native_departure_after_finish_escape(self):
        self.near_final_release()
        self.lua.execute('''
            move(-15); place(0,24,math.pi/2)
            c.state=c.states.UNLOADING_ON_FIELD
            c.unloadState=c.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED
            AIUtil.isStopped=function() return true end
            includeHarvesterCollision()
            local data=u.queueData; data.nativeDeparture=true
            u.getAllTrailersFull=function() return true end
            u.state=u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL
            u.invertedStartPositionMarkerNode={x=100,z=100,t=0}
            assert(not Q.clearFinishTraffic(c))
            assert(data.finalRelease and not Q.owns(u))
            g_currentMission.time=g_currentMission.time+10001
            assert(Q.clearFinishTraffic(c))
            assert(not data.finalRelease and Q.departureClearanceActive(u) and data.nativeDeparture)
            local replanned=0
            u.startPathfindingToInvertedGoalPositionMarker=function() replanned=replanned+1 end
            place(65,-60,0); c.near=false
            Q.yieldTarget(u,true); g_currentMission.time=g_currentMission.time+2001
            Q.yieldTarget(u,true)
            assert(replanned==1 and data.nativeDeparture and not Q.owns(u))
        ''')

    def test_unavailable_finish_geometry_does_not_reserve_entire_field(self):
        self.lua.execute('''
            local native=W.rigidModel; W.rigidModel=function() return nil end
            place(65,-60,0); Q.take(u,'prepare')
            assert(not Q.finishLane(c) and not Q.clearFinishTraffic(c))
            assert(Q.stagingClear(u,W.poses(W.model(v)),W.model(v)))
            assert(u.queueData.operation=='prepare')
            W.rigidModel=native
        ''')

    def test_finish_lane_never_takes_native_unloading_or_reverse(self):
        self.lua.execute('''
            AIUtil.isStopped=function() return true end
            for _,state in ipairs({u.states.UNLOADING_MOVING_COMBINE,u.states.MOVING_BACK,
                    u.states.MOVING_BACK_WITH_TRAILER_FULL}) do
                place(0,24,math.pi/2); Q.data(u); u.state=state
                u.combineToUnload=harvester
                Q.clearFinishTraffic(c)
                assert(u.state==state and u.combineToUnload==harvester)
                assert(not u.queueData.yieldRequests)
            end
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
            assert(not finishes and c.queueFinishClearance and c.speed==0)
            plan(); assert(c.queueFinishClearance.driving)
        ''')

    def test_unsupported_mode_keeps_native_completion(self):
        for setup in ('c.settings.selfUnload.getValue=function() return true end',
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

    def test_crop_crossing_is_limited_to_the_owned_empty_final_parking_world(self):
        self.lua.execute('''
            g_fruitTypeManager.getFruitTypes=function()
                return {{name='CANOLA',terrainDataPlaneId=1,startStateChannel=0,numStateChannels=4,cutStates={[11]=true}}}
            end
            densityStates={[11]=367,[6]=1}; densityTotal=368
            advance(); assert(c.queueFinishClearance)
            local world=c.queueFinishClearance.world
            assert(W.rigidClear(world,W.pose(harvester.rootNode)))
            -- The incident's residual sample and real standing crop are both
            -- permitted here. Ordinary queue worlds still reject either.
            densityStates={[6]=368}
            assert(W.rigidClear(world,W.pose(harvester.rootNode)))
            local ordinary=W.new(c,W.rigidModel(harvester))
            local clear,reason=W.rigidClear(ordinary,W.pose(harvester.rootNode))
            assert(not clear and reason=='standing crop')
            fill=100
            clear,reason=W.rigidClear(world,W.pose(harvester.rootNode))
            assert(not clear and reason=='standing crop')
            fill=0; Q.clearFinishClearance(c)
            clear,reason=W.rigidClear(ordinary,W.pose(harvester.rootNode))
            assert(not clear and reason=='standing crop')
            densityTotal=0
            clear,reason=W.rigidClear(ordinary,W.pose(harvester.rootNode))
            assert(not clear and reason=='invalid crop density')
            W.delete(ordinary)
        ''')

    def test_ordinary_empty_wait_cannot_acquire_crop_permission(self):
        self.lua.execute('''
            c.unloadState={}; assert(not Q.beginFinishClearance(c))
            c.state=c.states.WORKING; c.course:setCurrentWaypointIx(1)
            assert(not Q.beginFinishClearance(c))
            c.course:setCurrentWaypointIx(2); fill=1
            assert(not Q.beginFinishClearance(c))
        ''')

    def test_blocked_straight_uses_a_checked_curve_and_follows_its_live_sweep(self):
        self.lua.execute('''
            local obstacle={x=0,z=24}
            overlapBox=function(x,y,z,rx,ry,rz,w,h,l,callback,detector)
                local rect=G.rectangle({x=x,z=z,heading=ry},{width=2*w,length=2*l},0)
                detector.collidingShapes=(collision==1 or G.inside(rect,obstacle)) and 1 or 0
            end
            advance(); plan()
            local data=c.queueFinishClearance
            assert(data and data.driving and data.route.angle~=0 and starts==1)
            local points=data.route.points
            assert(c.course:getNumberOfWaypoints()==#points)
            for i,p in ipairs(points) do
                local x,_,z=c.course:getWaypointPosition(i)
                assert(math.abs(x-p.x)<0.00001 and math.abs(z-p.z)<0.00001)
                if i>1 then
                    local a=points[i-1]
                    local travel=math.sqrt((a.x-p.x)^2+(a.z-p.z)^2)+data.corner*math.abs(H.math.delta(p.t,a.t))
                    assert(travel<=0.50001,'wide header sweep undersampled')
                end
            end
            local halfway=math.floor(#points/2)
            for i=1,halfway do
                local p=points[i]
                harvester.rootNode.x=p.x; harvester.rootNode.z=p.z; harvester.rootNode.t=p.t
                header.rootNode.x,header.rootNode.z=H.math.position(p,0,5); header.rootNode.t=p.t
                advance(); assert(not finishes and c.speed==5)
            end
            collision=1; advance(); advance(); assert(c.speed==0 and not finishes)
            collision=0; advance(); advance(); assert(c.speed==5)
            for i=halfway+1,#points do
                local p=points[i]
                harvester.rootNode.x=p.x; harvester.rootNode.z=p.z; harvester.rootNode.t=p.t
                header.rootNode.x,header.rootNode.z=H.math.position(p,0,5); header.rootNode.t=p.t
                advance(); if finishes then break end
                assert(c.speed==5)
            end
            assert(finishes==1 and not c.queueFinishClearance)
        ''')

    def test_finished_combine_travels_parallel_to_headland_before_entering_row(self):
        for heading in (0, 1.57, 3.14):
            with self.subTest(heading=heading):
                self.setUp()
                self.lua.globals().heading = heading
                self.lua.execute('''
                    -- Rotate both the completed row and complete unfolded rig.
                    local worked={}
                    for _,p in ipairs(c.fieldWorkCourse:getAllWaypoints()) do
                        local x,z=H.math.position({x=0,z=0,t=heading},p.x,p.z)
                        worked[#worked+1]={x=x,z=z}
                    end
                    c.fieldWorkCourse=Course(harvester,worked,false); c.course=c.fieldWorkCourse
                    movePose({x=0,z=0,t=heading})
                    g_currentMission.vehicleSystem.vehicles={harvester}
                    advance(); plan()
                    local data=c.queueFinishClearance; local route=data.route
                    local option=route.options[route.option]
                    assert(option.headland and option.headland>=8)
                    local straight=0
                    for i,p in ipairs(route.points) do
                        assert(W.rigidClear(data.world,p))
                        local previous=route.points[i-1]
                        if previous and math.abs(math.abs(H.math.delta(p.t,heading))-math.pi/2)<0.001
                                and math.abs(H.math.delta(previous.t,p.t))<0.001 then
                            straight=straight+math.sqrt((p.x-previous.x)^2+(p.z-previous.z)^2)
                        end
                    end
                    assert(straight>=8)
                    assert(not c.fieldWorkCourse:isOnHeadland(route.ix))
                    followParking(); assert(finishes==1)
                ''')

    def test_narrow_row_spacing_uses_a_checked_direct_fallback(self):
        self.lua.execute('''
            local worked={}
            for z=60,-90,-2 do worked[#worked+1]={x=-22,z=z} end
            worked[#worked+1]={x=0,z=-90}
            for z=-88,0,2 do worked[#worked+1]={x=0,z=z} end
            c.fieldWorkCourse=Course(harvester,worked,false); c.course=c.fieldWorkCourse
            g_currentMission.vehicleSystem.vehicles={harvester}
            advance(); plan()
            local data=c.queueFinishClearance
            assert(not data.route.options[data.route.option].headland)
            for _,p in ipairs(data.route.points) do assert(W.rigidClear(data.world,p)) end
            followParking(); assert(finishes==1)
        ''')

    def test_curve_header_tip_obstacle_rejects_that_candidate(self):
        self.lua.execute('''
            advance()
            local route=c.queueFinishClearance.candidates[1]
            assert(Q.finishRoute(c.queueFinishClearance,c,route))
            local p=route.points[math.floor(#route.points/2)]
            local x,z=H.math.position(p,7.5,5)
            local obstacle={x=x,z=z}
            assert(math.abs(x-p.x)>1.75 or math.abs(z-p.z)>4)
            overlapBox=function(x,y,z,rx,ry,rz,w,h,l,callback,detector)
                local rect=G.rectangle({x=x,z=z,heading=ry},{width=2*w,length=2*l},0)
                detector.collidingShapes=(G.inside(rect,{x=0,z=24}) or G.inside(rect,obstacle)) and 1 or 0
            end
            plan()
            local data=c.queueFinishClearance
            assert(data and not finishes)
            if data.driving then assert(data.route~=route or data.route.option>1) end
            if data.driving then
                for _,point in ipairs(data.route.points) do assert(W.rigidClear(data.world,point)) end
            end
        ''')

    def test_terminal_position_reserves_neighbour_pipe_entry_and_reverse_lane(self):
        self.lua.execute('''
            other.combineController.getFillLevel=function() return 100 end
            neighbour.rootNode.x=0; neighbour.rootNode.z=0
            -- Keep the actual mounted header at the moved combine pose.
            local nh=neighbour:getAttachedImplements()[1].object
            nh.rootNode.x=0; nh.rootNode.z=5
            u.isServingPosition=function() return true end
            u.settings.combineOffsetX={getValue=function() return 0 end}
            u.settings.combineOffsetZ={getValue=function() return 0 end}
            g_currentMission.vehicleSystem.vehicles={harvester,neighbour,v}
            local model=W.rigidModel(harvester)
            local clear,reason=Q.finishParkingClear(c,model,{x=11,z=-20,t=0})
            assert(not clear and reason=='neighbour unloading access')
            clear,reason=Q.finishParkingClear(c,model,{x=13,z=10,t=0})
            assert(not clear and reason=='neighbour unloading access')
            assert(Q.finishParkingClear(c,model,{x=35,z=20,t=0}))
            g_currentMission.vehicleSystem.vehicles={harvester,neighbour}
            clear,reason=Q.finishParkingClear(c,model,{x=35,z=20,t=0})
            assert(not clear and reason=='neighbour unloader geometry unavailable')
        ''')

    def test_terminal_lane_uses_the_attached_harvester_pipe_reference(self):
        self.lua.execute('''
            other.combineController.getFillLevel=function() return 100 end
            u.isServingPosition=function() return true end
            u.settings.combineOffsetX={getValue=function() return 0 end}
            u.settings.combineOffsetZ={getValue=function() return 0 end}
            -- Pipe reference 20 m ahead of the towing vehicle: a relative rear
            -- extent cannot be added to this node without transforming it.
            other.getPipeOffsetReferenceNode=function() return {x=15,z=0,t=0} end
            g_currentMission.vehicleSystem.vehicles={harvester,neighbour,v}
            local model=W.rigidModel(harvester)
            local clear,reason=Q.finishParkingClear(c,model,{x=26,z=-50,t=0})
            assert(not clear and reason=='neighbour unloading access')
        ''')

    def test_terminal_access_is_rechecked_after_neighbour_moves(self):
        self.lua.execute('''
            advance(); plan(); local goal=c.queueFinishClearance.goal
            neighbour.rootNode.x=goal.x; neighbour.rootNode.z=goal.z
            local nh=neighbour:getAttachedImplements()[1].object
            nh.rootNode.x=goal.x; nh.rootNode.z=goal.z+5
            movePose(goal); advance()
            assert(not finishes and c.speed==0 and c.queueFinishClearance)
            neighbour.rootNode.x=40; nh.rootNode.x=40
            advance(); assert(finishes==1)
        ''')

    def test_planning_checks_are_sliced_and_yaw_uses_actual_turning_radius(self):
        self.lua.execute('''
            c.turningRadius=18; advance()
            local data=c.queueFinishClearance
            local calls=0; local native=W.rigidClear
            W.rigidClear=function(...) calls=calls+1; return native(...) end
            advance(); assert(calls<=8 and not starts)
            W.rigidClear=native
            for _,route in ipairs(data.candidates) do
                assert(Q.finishRoute(data,c,route))
                for i=2,#route.points do
                    local a,b=route.points[i-1],route.points[i]
                    assert(math.abs(H.math.delta(b.t,a.t))/(b.s-a.s)<=1/18+0.000001)
                end
            end
        ''')

    def test_refill_revokes_parking_and_returns_to_final_unloading(self):
        self.lua.execute('''
            advance(); plan(); assert(starts==1)
            local world=c.queueFinishClearance.world
            fill=1; advance()
            assert(not c.queueFinishClearance and not world.node and not finishes and c.speed==0)
            assert(c.unloadState==c.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED)
            assert(not c.queueFinishAttempted)
        ''')

    def test_crop_permission_does_not_relax_islands_or_revoked_ownership(self):
        self.lua.execute('''
            densityCount=10; advance()
            local data=c.queueFinishClearance
            local pose=W.pose(harvester.rootNode)
            data.world.boundary.islands={{{x=-1,z=-1},{x=1,z=-1},{x=1,z=1},{x=-1,z=1}}}
            local clear,reason=W.rigidClear(data.world,pose)
            assert(not clear and (reason=='field boundary' or reason=='island'))
            data.world.boundary.islands={}; c.queueFinishClearance=nil
            clear,reason=W.rigidClear(data.world,pose)
            assert(not clear and reason=='standing crop')
            c.queueFinishClearance=data; Q.clearFinishClearance(c)
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

    def test_lead_parks_before_distant_follower_or_when_alone(self):
        for alone in (False, True):
            with self.subTest(alone=alone):
                self.setUp()
                self.lua.globals().alone = alone
                self.lua.execute('''
                    neighbour.rootNode.z=-135
                    neighbour:getAttachedImplements()[1].object.rootNode.z=-130
                    if alone then g_currentMission.vehicleSystem.vehicles={harvester} end
                    fill=100; advance(); assert(not c.queueFinishClearance and not finishes)
                    fill=0; advance(); assert(c.queueFinishClearance and not finishes)
                    plan(); followParking(); assert(finishes==1)
                ''')

    def test_missing_geometry_at_last_waypoint_holds_and_retries(self):
        self.lua.execute('''
            local original=W.rigidModel
            W.rigidModel=function() return nil,'temporarily unavailable' end
            c.state=c.states.WORKING; c.unloadState=nil
            c:onLastWaypointPassed()
            assert(c.queueFinishClearance and c.state==c.states.UNLOADING_ON_FIELD and raised)
            for i=1,40 do advance(); assert(c.speed==0 and not starts and not finishes) end
            W.rigidModel=original
            plan(); followParking(); assert(finishes==1)
        ''')

    def test_headland_or_connector_cannot_be_the_parking_destination(self):
        for attribute in ('setHeadlandPassNumber(1)', 'setOnConnectingPath(true)'):
            with self.subTest(attribute=attribute):
                self.setUp()
                self.lua.execute('for _,wp in ipairs(c.fieldWorkCourse:getAllWaypoints()) do wp.attributes:'+attribute+' end')
                self.lua.execute('''
                    advance()
                    for i=1,30 do g_currentMission.time=g_currentMission.time+4000; advance() end
                    assert(c.queueFinishClearance and not starts and not finishes and c.speed==0)
                    assert(c.queueFinishClearance.reason=='no completed centre-run destination available')
                ''')

    def test_unharvested_destination_waits_unfolded_then_recovers(self):
        self.lua.execute('''
            densityCount=10; advance()
            for i=1,1000 do advance(); assert(not finishes and not starts) end
            assert(c.queueFinishClearance and c.speed==0)
            densityCount=0; plan(); followParking(); assert(finishes==1)
        ''')

    def test_followers_future_end_lane_is_reserved_before_it_is_full(self):
        self.lua.execute('''
            neighbour.rootNode.x=0; neighbour.rootNode.z=-135
            local nh=neighbour:getAttachedImplements()[1].object
            nh.rootNode.x=0; nh.rootNode.z=-130
            other.fieldWorkCourse=Course(neighbour,{{x=0,z=-150},{x=0,z=0}},false)
            other.combineController.getFillLevel=function() return 0 end
            u.isServingPosition=function() return true end
            u.settings.combineOffsetX={getValue=function() return 0 end}
            u.settings.combineOffsetZ={getValue=function() return 0 end}
            g_currentMission.vehicleSystem.vehicles={harvester,neighbour,v}
            local model=W.rigidModel(harvester)
            local clear,reason=Q.finishParkingClear(c,model,{x=11,z=-20,t=0})
            assert(not clear and reason=='neighbour unloading access')
            assert(Q.finishParkingClear(c,model,{x=-45,z=0,t=math.pi}))
        ''')

    def test_more_than_twenty_four_nearby_rejections_reach_farther_centre_run(self):
        self.lua.execute('''
            local worked={}
            for z=60,-180,-2 do worked[#worked+1]={x=-45,z=z} end
            worked[#worked+1]={x=0,z=-180}
            for z=-178,0,2 do worked[#worked+1]={x=0,z=z} end
            c.fieldWorkCourse=Course(harvester,worked,false); c.course=c.fieldWorkCourse
            local original=Q.finishParkingClear
            local rejected=0
            Q.finishParkingClear=function(combine,model,p)
                if p.z>-79.5 then rejected=rejected+1; return false,'occupied waiting spaces' end
                return original(combine,model,p)
            end
            advance(); assert(#c.queueFinishClearance.candidates>24)
            for i=1,10000 do
                advance()
                if c.queueFinishClearance.driving then break end
            end
            assert(c.queueFinishClearance.driving and not finishes and rejected>=24)
            assert(c.queueFinishClearance.goal.z<=-80)
            followParking(); assert(finishes==1)
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
