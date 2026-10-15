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
            u.state=u.states.IDLE
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
            if data.driving then assert(data.route~=route) end
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
