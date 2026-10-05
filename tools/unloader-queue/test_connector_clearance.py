"""Final connector sweeps and lifecycle with real Course/StartRowOnly code."""
from pathlib import Path
import sys
import unittest
from lupa.lua52 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE


class ConnectorClearanceTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().ROOT=ROOT.as_posix()
        self.lua.execute((SOURCE/'tools/straight-entry/engine-boundary.lua').read_text())
        self.lua.execute((SOURCE/'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute((ROOT/'scripts/pathfinder/PathfinderCollisionDetector.lua').read_text(encoding='utf-8'))
        self.lua.execute('''
            CpUtil.getDefaultCollisionFlags=function() return 334339 end
            getRootNode=function() return 0 end
            deleted=0; calls=0; samples={}; obstacles={}; stopped=0; installed=0; oldLast=0
            delete=function(n) assert(not n.deleted); n.deleted=true; deleted=deleted+1 end
            openIntervalTimer=function() return calls end
            readIntervalTimerMs=function(start) return (calls-start)*0.1 end
            closeIntervalTimer=function() end
            PathfinderUtil.setWorldPositionAndRotationOnTerrain=function(n,x,z,t)
                n.x=x; n.z=z; n.t=t
            end
            -- Engine scan boundary: combined harvester and 15.2 m header box.
            box={width=8.3,length=6.5,xOffset=0,zOffset=0}
            nativeVehicleData=PathfinderUtil.VehicleData
            PathfinderUtil.VehicleData=function(v,implements,buffer)
                assert(implements and buffer==0)
                return {getTowedImplement=function() return towed end,
                    getVehicleOverlapBoxParams=function() return box end}
            end
            overlapBox=function(x,y,z,rx,t,rz,w,h,l,callback,detector,mask)
                assert(mask==334339 and detector.ignoreFruitHeaps==false)
                calls=calls+1; samples[#samples+1]={x=x,z=z,t=t}
                detector.collidingShapes=0
                for _,p in ipairs(obstacles) do
                    local dx,dz=p.x-x,p.z-z
                    if math.abs(dx*math.cos(t)-dz*math.sin(t))<=w and
                            math.abs(dx*math.sin(t)+dz*math.cos(t))<=l then
                        detector.collidingShapes=1; detector.collidingShapesText='fixture tree'
                    end
                end
            end
            AIMessageCpErrorNoPathFound={new=function() return 'no-path' end}
            AIDriveStrategyCombineCourse={
                update=function() end,delete=function(self) self.deleted=true end,
                onLastWaypointPassed=function() oldLast=oldLast+1 end,
                onPathfindingFailedToConnectingPathEnd=function(self,controller,context,last,attempt)
                    controller:retry(context)
                end}
            AIDriveStrategyCombineCourse.__index=AIDriveStrategyCombineCourse
        ''')
        combine=(ROOT/'scripts/ai/strategies/AIDriveStrategyCombineCourse.lua').read_text(encoding='utf-8')
        offset=combine.split('function AIDriveStrategyCombineCourse:updateFieldworkOffset(course)',1)[1].split('\nend',1)[0]
        self.lua.execute('function AIDriveStrategyCombineCourse:updateFieldworkOffset(course)'+offset+'\nend')
        self.lua.execute((ROOT/'scripts/ai/CpHarvesterRouteClearance.lua').read_text(encoding='utf-8'))
        self.lua.execute('''
            R=CpHarvesterRouteClearance
            f=preparationFixture(20,false,false)
            v=f.vehicle; v.spec_combine={}; v.size={width=3.5}
            here={x=0,z=-43,t=0}
            speed=0; toolOffset=0
            v.getLastSpeed=function() return speed end
            v.getAIDirectionNode=function() return here end
            v.stopCurrentAIJob=function(_,reason) assert(reason=='no-path'); stopped=stopped+1 end
            AIUtil.getSteeringParameters=function() return 9,0 end
            AIUtil.getTurningRadius=function() return 9 end
            context=setmetatable(f.turn.turnContext,RowStartOrFinishContext)
            context.turnStartWpIx=context.turnEndWpIx; context.workWidth=15.2
            context.workStartNode={x=0,z=0,t=0}; context.vehicleAtTurnEndNode={x=0,z=0,t=0}
            context.frontMarkerDistance=4; context.backMarkerDistance=-6
            u=setmetatable(f.strategy,AIDriveStrategyCombineCourse)
            u.vehicle=v; u.ppc=f.turn.ppc; u.turnContext=context
            u.settings={toolOffsetX={getValue=function() return toolOffset end}}
            u.states={WAITING_FOR_PATHFINDER={},DRIVING_TO_WORK_START_WAYPOINT={},WORKING={}}
            u.state=u.states.WAITING_FOR_PATHFINDER
            u.setMaxSpeed=function(self,speed) self.speed=speed end
            u.raiseImplements=function(self) self.raised=true end
            u.debug=function() end
            u.ppc.setShortLookaheadDistance=function() end
            u.startCourse=function(self,course,ix) installed=installed+1; self.course=course; assert(ix==1) end
            route=Course(v,{{x=0,z=-43},{x=0,z=-42},{x=0,z=-41}},true)
            function tick()
                g_updateLoopIndex=(g_updateLoopIndex or 0)+1; R.update(u)
            end
            function drain()
                for i=1,5000 do
                    if not u.connectorClearance then return end
                    g_updateLoopIndex=(g_updateLoopIndex or 0)+1
                    R.update(u)
                end
                error('validator did not complete')
            end
            function checkCourse(course)
                local check=assert(R.new(v,course))
                for i=1,20000 do
                    local done,clear,why=R.step(check)
                    if done then R.delete(check); return clear,why end
                end
                error('sweep did not complete')
            end
        ''')

    def test_final_entry_is_prepared_once_and_installed_only_after_validation(self):
        self.lua.execute('''
            R.begin(u,route,nil)
            local prepared=u.connectorClearance.starter:getCourse()
            local count=prepared:getNumberOfWaypoints()
            assert(count>3 and route:getNumberOfWaypoints()==3)
            assert(installed==0 and u.speed==0 and u.raised)
            assert(u.state==u.states.WAITING_FOR_PATHFINDER)
            drain()
            assert(installed==1 and stopped==0 and u.course==prepared)
            assert(u.course:getNumberOfWaypoints()==count and deleted==1)
        ''')

    def test_tree_struck_by_header_is_rejected_even_with_clear_centreline(self):
        self.lua.execute('''
            obstacles={{x=7.6,z=20}}
            local clear,why=checkCourse(Course(v,{{x=0,z=0},{x=0,z=40}},true))
            assert(not clear and why:find('fixture tree'))
        ''')

    def test_obstacle_between_clear_waypoints_is_rejected(self):
        self.lua.execute('''
            here.z=0; obstacles={{x=0,z=20}}
            assert(not checkCourse(Course(v,{{x=0,z=0},{x=0,z=40}},true)))
        ''')

    def test_appended_entry_obstacle_is_checked(self):
        self.lua.execute('''
            R.begin(u,route,nil)
            local prepared=u.connectorClearance.starter:getCourse()
            local x,_,z=prepared:getWaypointPosition(prepared:getNumberOfWaypoints())
            assert(z>-30); obstacles={{x=x+7,z=z}}
            drain(); assert(stopped==1 and installed==0)
        ''')

    def test_unsafe_candidate_uses_validated_original_connector(self):
        self.lua.execute('''
            -- Candidate cuts across the tree; original connector stays at x=0.
            local bad=Course(v,{{x=0,z=-43},{x=30,z=-35},{x=0,z=-41}},true)
            obstacles={{x=30,z=-35}}
            u.workStarterCourse=route
            u:onPathfindingDoneToConnectingPathEnd(nil,true,bad,false)
            drain()
            assert(installed==1 and stopped==0 and deleted==2)
            assert(route:getNumberOfWaypoints()==3 and bad:getNumberOfWaypoints()==3)
            for i=1,u.course:getNumberOfWaypoints() do
                local x=u.course:getWaypointPosition(i); assert(math.abs(x)<0.01)
            end
        ''')

    def test_unsafe_original_fallback_stops_without_installing(self):
        self.lua.execute('''
            obstacles={{x=7,z=-42}}; u.workStarterCourse=route
            u:onPathfindingDoneToConnectingPathEnd(nil,false,nil,false)
            drain(); assert(stopped==1 and installed==0 and not u.connectorClearance)
        ''')

    def test_exhausted_retry_fallback_cannot_bypass_gate(self):
        self.lua.execute('''
            u.workStarterCourse=route; obstacles={{x=7,z=-42}}
            u:onPathfindingFailedToConnectingPathEnd(nil,{},true,1)
            assert(installed==0 and u.connectorClearance)
            drain(); assert(stopped==1 and installed==0)
        ''')

    def test_nonfinal_retry_keeps_original_policy(self):
        self.lua.execute('''
            local context={}; local retried=false
            u:onPathfindingFailedToConnectingPathEnd({retry=function(_,c) assert(c==context); retried=true end},context,false,1)
            assert(retried and not u.connectorClearance and installed==0)
        ''')

    def test_rotation_sweep_catches_obstacle_between_clear_orientations(self):
        self.lua.execute('''
            box={width=1,length=8,xOffset=0,zOffset=0}; here={x=0,z=0,t=0}
            obstacles={{x=5,z=5}}
            -- Initial north and final east footprint are clear; rotation clips tree.
            assert(not checkCourse(Course(v,{{x=0,z=0},{x=20,z=0}},true)))
        ''')

    def test_clear_edge_route_is_not_rejected_by_work_width_circle(self):
        self.lua.execute('''
            v.cpGetFieldPolygon=function() return {{x=0,z=-100},{x=50,z=-100},{x=50,z=100},{x=0,z=100}} end
            here.x=4
            assert(checkCourse(Course(v,{{x=4,z=-43},{x=4,z=20}},true)))
        ''')

    def test_reverse_uses_body_heading_and_wraps_angles(self):
        self.lua.execute('''
            here={x=0,z=0,t=0}
            assert(checkCourse(Course(v,{{x=0,z=0,rev=true},{x=0,z=-10,rev=true}},true)))
            for _,sample in ipairs(samples) do assert(math.abs(math.sin(sample.t))<0.01 and math.cos(sample.t)>0.99) end
        ''')

    def test_shared_frame_budget_and_hold(self):
        self.lua.execute('''
            R.begin(u,route,nil); g_updateLoopIndex=1
            R.update(u); local first=calls
            assert(first<=32 and first>0 and u.connectorClearance and installed==0)
            R.update(u); assert(calls==first)
            u:onLastWaypointPassed(); assert(oldLast==0)
            drain(); u:onLastWaypointPassed(); assert(oldLast==1)
        ''')

    def test_cancelled_or_deleted_validator_cannot_install_course(self):
        self.lua.execute('''
            R.begin(u,route,nil); tick(); u.turnContext={}; R.update(u)
            assert(deleted==1 and not u.connectorClearance and installed==0)
            u.turnContext=context; R.begin(u,route,nil); tick(); u:delete()
            assert(deleted==2 and u.deleted and not u.connectorClearance)
        ''')

    def test_changed_state_cancels_validation(self):
        self.lua.execute('''
            R.begin(u,route,nil); tick(); u.state=u.states.WORKING; R.update(u)
            assert(not u.connectorClearance and installed==0 and deleted==1)
        ''')

    def test_missing_geometry_and_towed_body_do_not_silently_pass(self):
        self.lua.execute('''
            assert(not R.new(v,Course(v,{{x=0,z=0}},true)))
            towed={}; assert(not R.new(v,route)); towed=nil
            box.width=0/0; assert(not R.new(v,route))
        ''')

    def test_superseded_candidate_is_cleaned_and_new_one_validated(self):
        self.lua.execute('''
            R.begin(u,route,nil); tick(); local old=u.connectorClearance.check.node
            R.begin(u,route,nil); assert(old.deleted and deleted==1)
            drain(); assert(installed==1 and deleted==2)
        ''')

    def test_braking_defers_capture_and_movement_restarts_scan(self):
        self.lua.execute('''
            speed=5; R.begin(u,route,nil); tick()
            assert(calls==0 and not u.connectorClearance.check and installed==0)
            here.z=-42; speed=0; tick()
            local old=u.connectorClearance.check
            assert(old.origin.z==-42 and calls>0)
            here.z=-41; tick()
            assert(old.node==nil and u.connectorClearance.check.origin.z==-41)
            speed=2; tick(); assert(not u.connectorClearance.check and installed==0)
            speed=0; drain(); assert(installed==1 and stopped==0)
        ''')

    def test_real_fieldwork_offsets_are_validated_and_changes_restart(self):
        self.lua.execute('''
            toolOffset=2; u.aiOffsetX=1; u.aiOffsetZ=3
            R.begin(u,route,nil); tick()
            local pending=u.connectorClearance
            assert(pending.offsetX==3 and pending.offsetZ==3)
            local old=pending.check
            toolOffset=4; tick()
            assert(old.node==nil and pending.check~=old and pending.offsetX==5)
            local x,_,z=pending.starter:getCourse():getWaypointPosition(1)
            assert(math.abs(x)>4.9 and z>-41)
            obstacles={{x=x+8,z=z}}
            drain(); assert(installed==0 and stopped==1)
        ''')

    def test_real_marker_geometry_gets_explicit_buffer_on_both_axes(self):
        self.lua.execute('''
            PathfinderUtil.VehicleData=nativeVehicleData
            VehicleSizeScanner=function() return {} end
            AIUtil.getFirstReversingImplementWithWheels=function() return nil end
            AIUtil.getDirectionNode=function() return here end
            AIUtil.getWidth=function(o) return o.size.width end
            ImplementUtil.getDistanceToImplementNode=function() return 0 end
            here={x=0,z=0,t=0}; v.rootNode=here
            v.size={width=3.5,length=8,lengthOffset=0}
            local header={rootNode=here,size={width=15.2,length=2,lengthOffset=0},
                left={x=7.6,z=6,t=0},right={x=-7.6,z=6,t=0},back={x=0,z=4,t=0}}
            v.getRootVehicle=function() return v end
            v.getAttachedImplements=function() return {{object=header}} end
            local check=assert(R.new(v,route))
            assert(math.abs(check.box.width-8.1)<0.001)
            assert(math.abs(check.box.length-5.5)<0.001 and check.box.zOffset==1)
            obstacles={{x=8,z=0}}; assert(not R.clear(check,here))
            obstacles={{x=0,z=6.4}}; assert(not R.clear(check,here))
            obstacles={{x=8.2,z=0}}; assert(R.clear(check,here))
            R.delete(check)
        ''')


if __name__=='__main__': unittest.main()
