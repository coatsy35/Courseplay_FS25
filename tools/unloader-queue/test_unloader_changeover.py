"""Stationary replacement admission through native calls at the GIANTS boundary."""
from pathlib import Path
import sys
import unittest
from lupa.lua52 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE / 'tools/unloader-queue'))
import test_runtime as runtime
runtime.ROOT = ROOT


class ChangeoverTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().ROOT = ROOT.as_posix()
        self.lua.execute((SOURCE / 'tools/double-pivot/engine-boundary.lua').read_text())
        self.lua.execute('AIDriveStrategyCourse={}; AIDriveStrategyFieldWorkCourse={}')
        for name in ('AIDriveStrategyUnloadCombine', 'AIDriveStrategyCombineCourse'):
            self.lua.execute((ROOT / f'scripts/ai/strategies/{name}.lua').read_text())
        runtime.load_queue(self.lua)
        self.lua.execute('''
            Q=CpUnloaderQueue; W=CpUnloaderQueueWorld
            v,_,trailer=fixture({single=true})
            v.size.length=5; trailer.size={width=3,length=6}; trailer.getAIMarkers=nil
            v.rootNode.x=-400; trailer.rootNode.x=-400; trailer.joint.node.x=-400
            v.getRootVehicle=function() return v end
            trailer.getRootVehicle=function() return v end
            local setting=function(value) return {getValue=function() return value end} end
            u=setmetatable({vehicle=v,states=AIDriveStrategyUnloadCombine.myStates,
                settings={fullThreshold=setting(85),
                combineOffsetX=setting(0),combineOffsetZ=setting(0)}},AIDriveStrategyUnloadCombine)
            v.getCpDriveStrategy=function() return u end
            v.stopCurrentAIJob=function() stopped=true end
            u.state=u.states.IDLE; u.debug=function() end; u.debugSparse=function() end
            u.getAllTrailersFull=function() return false end
            u.setMaxSpeed=function() end
            u.setNewState=function(self,state) self.state=state end
            -- Node handles are planar tables at this engine boundary.
            u.getTargetNode=function(_,node) return node end
            u.isOkToStartUnloadingCombine=function() return false end
            searches=0
            u.startPathfindingToWaitingCombine=function(self,x,z)
                searches=searches+1; observed={x=x,z=z,node=self:getPipeOffsetReferenceNode()}
            end
            hv={rootNode={x=100,z=100,t=0},size={width=4,length=9}}
            hv.getRootVehicle=function() return hv end
            header={rootNode={x=100,z=100,t=0},size={width=15.2,length=3}}
            header.getRootVehicle=function() return hv end
            hv.getAttachedImplements=function() return {{object=header}} end
            c=setmetatable({vehicle=hv},AIDriveStrategyCombineCourse)
            hv.getCpDriveStrategy=function() return c end
            pipe=12.2; autoAim=false; pulledBack=false
            c.getPipeOffset=function(_,x,z) return pipe+x,2+z end
            c.getMeasuredBackDistance=function() return 6.4 end
            c.hasAutoAimPipe=function() return autoAim end
            c.isWaitingForUnloadAfterPulledBack=function() return pulledBack end
            reference=hv.rootNode
            c.getPipeOffsetReferenceNode=function() return reference end
            c.debug=function() end
            c.timeToCallUnloader=CpTemporaryObject(true); c.unloader=CpTemporaryObject(nil)
            c.isWaitingForUnload=function() return true end
            c.findUnloader=function() selections=(selections or 0)+1; return v end
            g_currentMission.time=0; g_time=1
            function obstacle(x,z,length)
                local vehicle={rootNode={x=x,z=z,t=0},size={width=3,length=length or 5}}
                vehicle.getRootVehicle=function() return vehicle end
                return vehicle
            end
            -- Outgoing CP/AD ownership is intentionally absent. Occupancy is physical.
            outgoing=obstacle(112.2,111.6)
            outgoingTrailer=obstacle(112.2,91.6,10)
            outgoing.getAttachedImplements=function() return {{object=outgoingTrailer}} end
            outgoingTrailer.getRootVehicle=function() return outgoing end
            g_currentMission.vehicleSystem={vehicles={v,trailer,hv,header,outgoing,outgoingTrailer}}
            function clearOutgoing()
                outgoing.rootNode.x=200; outgoingTrailer.rootNode.x=200
            end
        ''')

    def test_native_call_cycle_waits_for_whole_outgoing_rig_then_accepts(self):
        self.lua.execute('''
            Q.take(u,'prepare')
            local data=u.queueData; data.search={}; data.assignment='reserved'
            local search,generation,state=data.search,data.generation,u.state
            c:callUnloaderWhenNeeded()
            assert(searches==0 and not stopped and not u.combineToUnload)
            assert(data.search==search and data.generation==generation and u.state==state)
            assert(data.assignment=='reserved' and u:isAllowedToBeCalled())
            -- Tractor is already clear; the attached trailer still occupies the goal.
            outgoing.rootNode.x=200
            g_time=3002; c:callUnloaderWhenNeeded()
            assert(searches==0 and selections==2 and not stopped)
            clearOutgoing()
            g_time=6001; c:callUnloaderWhenNeeded()
            assert(searches==0 and selections==2) -- native timer, no busy retry loop
            g_time=6003; c:callUnloaderWhenNeeded()
            assert(searches==1 and selections==3 and not stopped)
            assert(u.combineToUnload==hv and u.state==u.states.WAITING_FOR_PATHFINDER)
            assert(not Q.owns(u) and data.search==nil and data.generation>generation)
            assert(observed.x==12.2 and math.abs(observed.z+8.4)<0.001)
        ''')

    def test_idle_replacement_remains_callable_after_ad_takes_outgoing_rig(self):
        self.lua.execute('''
            outgoing.ad={stateModule={isActive=function() return true end}}
            assert(next(Q.members)==nil)
            assert(u:call(hv,nil)==false and u:isIdle() and u:isAllowedToBeCalled())
            assert(not u.combineToUnload and searches==0 and not stopped)
            clearOutgoing()
            assert(u:call(hv,nil) and searches==1)
        ''')

    def test_blocker_under_incoming_trailer_counts_even_with_clear_tractor_goal(self):
        self.lua.execute('''
            outgoing.rootNode.x=200
            outgoingTrailer.rootNode.z=81.8; outgoingTrailer.size.length=2
            assert(u:call(hv,nil)==false and searches==0)
            clearOutgoing(); assert(u:call(hv,nil) and searches==1)
        ''')

    def test_vehicle_clear_of_actual_target_does_not_block(self):
        self.lua.execute('''
            outgoing.rootNode.x=125; outgoingTrailer.rootNode.x=125
            assert(u:call(hv,nil) and searches==1)
        ''')

    def test_other_harvester_can_call_same_available_replacement(self):
        self.lua.execute('''
            assert(not u:call(hv,nil))
            local other=obstacle(300,300,9)
            local otherDriver=setmetatable({vehicle=other}, {__index=c})
            otherDriver.getPipeOffsetReferenceNode=function() return other.rootNode end
            other.getCpDriveStrategy=function() return otherDriver end
            assert(u:call(other,nil) and u.combineToUnload==other and searches==1)
        ''')

    def test_excludes_incoming_and_target_complete_attachment_trees(self):
        self.lua.execute('''
            clearOutgoing()
            -- Both roots' own attachments may geometrically cover the proposed goal.
            header.rootNode.x=112.2; header.rootNode.z=91.6
            g_currentMission.vehicleSystem.vehicles={header,trailer,hv,v,header,trailer}
            assert(u:call(hv,nil) and searches==1)
        ''')

    def test_moving_rendezvous_is_unchanged(self):
        self.lua.execute('''
            local waypoint={x=112.2,z=91.6,t=0}
            u.startPathfindingToMovingCombine=function(_,wp,x,z)
                assert(wp==waypoint and x==12.2 and z==-11.4); moving=true
            end
            assert(u:call(hv,waypoint) and moving and searches==0)
        ''')

    def test_unsupported_rig_keeps_native_handling(self):
        self.lua.execute('''
            trailer.spec_wheels.wheels[1].steering.steeringAxleScale=1
            assert(u:call(hv,nil) and searches==1)
        ''')

    def test_close_rig_keeps_native_immediate_unload_entry(self):
        self.lua.execute('''
            v.rootNode.x=112.2; v.rootNode.z=91.6
            trailer.rootNode.x=112.2; trailer.rootNode.z=81.8
            trailer.joint.node.x=112.2; trailer.joint.node.z=88.3
            u.isOkToStartUnloadingCombine=function() return true end
            u.startUnloadingCombine=function() unloading=true end
            assert(u:call(hv,nil) and unloading and searches==0)
        ''')

    def test_native_aligned_entry_beyond_pathfinding_range_is_preserved(self):
        self.lua.execute('''
            v.rootNode.x=112.2; v.rootNode.z=80
            trailer.rootNode.x=112.2; trailer.rootNode.z=70.2
            trailer.joint.node.x=112.2; trailer.joint.node.z=76.7
            hv.lastSpeedReal=0; hv.getAIDirectionNode=function() return hv.rootNode end
            c.willWaitForUnloadToFinish=function() return true end
            u.isOkToStartUnloadingCombine=nil -- exercise native readiness and alignment
            assert(u.pathfindingRange==5)
            assert(u:isPathfindingNeeded(v,reference,12.2,-8.4))
            assert(Q.waitingApproachBlocker(u,hv)==nil and not u.combineToUnload)
            u.startUnloadingCombine=function() unloading=true end
            assert(u:call(hv,nil) and unloading and searches==0)
        ''')

    def test_close_unready_rig_retains_native_wait(self):
        self.lua.execute('''
            v.rootNode.x=112.2; v.rootNode.z=91.6
            trailer.rootNode.x=112.2; trailer.rootNode.z=81.8
            trailer.joint.node.x=112.2; trailer.joint.node.z=88.3
            u.startWaitingForSomethingToDo=function() waited=true end
            assert(u:call(hv,nil) and waited and searches==0)
        ''')

    def test_native_goal_offsets_and_rotation_match_all_stationary_branches(self):
        for pipe, auto, pulled, expected in [(12.2, False, False, -8.4),
                                            (-12.2, False, False, -8.4),
                                            (4, False, False, -11.4),
                                            (6, False, False, -11.4),
                                            (12, False, True, -16.4),
                                            (0, True, False, -12.4),
                                            (8, True, False, -6.4)]:
            with self.subTest(pipe=pipe, auto=auto, pulled=pulled):
                self.setUp()
                self.lua.execute(f'''
                    pipe={pipe}; autoAim={str(auto).lower()}; pulledBack={str(pulled).lower()}
                    u.autoAimPipeOffsetX={{get=function() return pipe end}}
                    Markers={{getFrontMarkerNode=function() return nil,4 end}}
                    -- Attached harvesters can use a reference different from the tractor.
                    reference={{x=200,z=-50,t=0.7}}
                    local x,_,z=localToWorld(reference,pipe,0,{expected})
                    outgoing.rootNode.x=x; outgoing.rootNode.z=z; outgoing.rootNode.t=0.7
                    outgoingTrailer.rootNode.x=500
                    assert(not u:call(hv,nil) and not u.combineToUnload and searches==0)
                    outgoing.rootNode.x=500
                    assert(u:call(hv,nil) and searches==1)
                    assert(observed.x==pipe and math.abs(observed.z-({expected}))<0.001)
                    assert(observed.node==reference)
                ''')

    def test_non_vehicle_path_failure_still_uses_native_retry_and_stop(self):
        self.lua.execute('''
            clearOutgoing(); assert(u:call(hv,nil))
            local context={maxFruitPercent=function(self) return self end,
                offFieldPenalty=function(self) return self end}
            PathfinderContext={defaultOffFieldPenalty=10}
            u.getMaxFruitPercent=function() return 10 end
            local controller={retry=function() retries=(retries or 0)+1 end}
            AIMessageCpErrorNoPathFound={new=function() return {} end}
            for attempt=1,3 do
                u:onPathfindingFailedToStationaryTarget(controller,context,false,attempt,false,0,0)
            end
            u:onPathfindingFailedToStationaryTarget(controller,context,true,4,false,0,0)
            assert(retries==3 and stopped)
        ''')


if __name__ == '__main__':
    unittest.main()
