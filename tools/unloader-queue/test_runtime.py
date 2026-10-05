"""Integrated queue ownership and real route code at a mocked GIANTS boundary."""
from pathlib import Path
import sys
import unittest
from lupa.lua52 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE / 'tools/unloader-queue'))
import test_native_contract as native
native.ROOT = ROOT

FILES = ['Policy', 'Geometry', 'World', 'Search', '', 'Manoeuvres', 'Hooks']

def load_queue(lua, hooks=True):
    for suffix in FILES if hooks else FILES[:-1]:
        lua.execute((ROOT / f'scripts/ai/CpUnloaderQueue{suffix}.lua').read_text())


class AutomaticContractTests(native.NativeContractTests):
    """Run native contracts with automatic coordination and the authorised departure exception."""
    def setUp(self):
        super().setUp()
        self.lua.execute('HeadlandLoopGeometry={}; g_currentMission={time=0}')
        load_queue(self.lua)


    def test_departure_returns_to_valid_start_before_handover(self):
        self.lua.execute('u.combineToUnload=nil; u.invertedStartPositionMarkerNode=1; u:startUnloadingTrailers()')
        self.assertTrue(self.lua.eval("CpUnloaderQueue.owns(u) and u.queueData.operation=='exit'"))
        self.assertNotIn('handover', self.lua.eval('result()'))

    def test_baseline_gap_missing_marker_currently_hands_over_midfield(self):
        # Automatic integration must close this documented native gap without a setting.
        self.lua.execute('u.combineToUnload=nil; u:startUnloadingTrailers(); u:onTrailerFull()')
        self.assertNotIn('handover', self.lua.eval('result()'))
        self.assertTrue(self.lua.eval('CpUnloaderQueue.owns(u)'))

    def test_baseline_gap_failed_return_path_currently_hands_over_midfield(self):
        self.lua.execute('u.combineToUnload=nil; u:onPathfindingDoneToInvertedGoalPositionMarker(nil,false,nil,false)')
        self.assertNotIn('handover', self.lua.eval('result()'))
        self.assertTrue(self.lua.eval('CpUnloaderQueue.owns(u)'))


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        native.NativeContractTests.setUp(self)
        self.lua.execute('HeadlandLoopGeometry={}; g_currentMission={time=0}')
        load_queue(self.lua)
    def test_automatic_without_settings_or_with_obsolete_false_setting(self):
        self.lua.execute("""
            assert(CpUnloaderQueue.enabled(u))
            u.settings={unloaderQueue={getValue=function() error('obsolete option read') end}}
            assert(CpUnloaderQueue.enabled(u))
        """)

    def test_idle_unloader_joins_preparation_automatically(self):
        self.lua.execute("""
            u.settings={fullThreshold={getValue=function() return 85 end}}
            u.isDriveUnloadNowRequested=function() return false end
            u.getAllTrailersFull=function() return false end
            -- Fleet/route discovery is an external boundary for this ownership test.
            CpUnloaderQueue.refresh=function() end
            CpUnloaderQueue.target=function() return nil end
            CpUnloaderQueue.schedule=function() end
            CpUnloaderQueue.tick(u)
            assert(CpUnloaderQueue.members[u]==u.queueData)
            assert(CpUnloaderQueue.owns(u) and u.queueData.operation=='prepare')
        """)

    def test_other_unloading_modes_keep_native_ownership(self):
        for mode in ['augerWagon', 'fieldUnloadPositionNode', 'useGiantsUnload']:
            with self.subTest(mode=mode):
                self.lua.execute(f"u.{mode}=true; assert(not CpUnloaderQueue.enabled(u)); CpUnloaderQueue.tick(u)")
                self.assertFalse(self.lua.eval('CpUnloaderQueue.owns(u) or CpUnloaderQueue.members[u]~=nil'))
                self.lua.execute(f'u.{mode}=nil')

    def test_automatic_missing_marker_retains_cp(self):
        self.lua.execute('''
            u.combineToUnload=nil
            u:startUnloadingTrailers()
            assert(CpUnloaderQueue.owns(u))
            assert(u.queueData.operation=='exit')
            u:onTrailerFull()
        ''')
        self.assertNotIn('handover', self.lua.eval('result()'))

    def test_automatic_failed_return_never_grants_handover(self):
        self.lua.execute('''
            u.combineToUnload=nil
            u:onPathfindingDoneToInvertedGoalPositionMarker(nil,false,nil,false)
            assert(CpUnloaderQueue.owns(u) and u.queueData.operation=='exit')
        ''')
        self.assertNotIn('handover', self.lua.eval('result()'))

    def test_queue_call_uses_native_rear_pathfinder(self):
        self.lua.execute('''
            u.combineToUnload=nil
            u.getPipeOffset=function() return 8,2 end
            u.getCombinesMeasuredBackDistance=function() return 6 end
            u.isPathfindingNeeded=function(_,vehicle,waypoint,x,z,limit) assert(limit==25); return true end
            u.setNewState=function(self,state) self.state=state end
            u.startPathfindingToMovingCombine=function(self,waypoint,x,z)
                assert(x==8 and z==-11); nativeApproach=true
            end
            CpUnloaderQueue.take(u,'prepare')
            u.queueData.search={}; local generation=u.queueData.generation
            assert(u:call(c,{})==true)
            assert(nativeApproach and u.combineToUnload==c)
            assert(u.state==u.states.WAITING_FOR_PATHFINDER)
            assert(u.queueData.search==nil and u.queueData.generation>generation)
        ''')

    def test_exit_is_not_available_to_a_new_native_call(self):
        self.lua.execute('''
            CpUnloaderQueue.take(u,'exit')
            assert(not u:isAllowedToBeCalled())
            assert(u:call(c,{})==false)
        ''')

    def test_stale_search_cannot_replace_native_course(self):
        self.lua.execute('''
            CpUnloaderQueue.take(u,'prepare')
            u.queueData.searchGeneration=u.queueData.generation
            u.state=u.states.BACKING_UP_FOR_REVERSING_COMBINE
            u.startCourse=function() error('queue overwrote native backup') end
            CpUnloaderQueue.startRoute(u.queueData,{{x=0,z=0},{x=0,z=10}})
            assert(u.state==u.states.BACKING_UP_FOR_REVERSING_COMBINE)
        ''')

    def test_generation_invalidation_blocks_old_completion(self):
        self.lua.execute('''
            CpUnloaderQueue.take(u,'prepare')
            u.queueData.searchGeneration=u.queueData.generation
            CpUnloaderQueue.cancel(u)
            u.startCourse=function() error('stale completion applied') end
            CpUnloaderQueue.startRoute(u.queueData,{{x=0,z=0},{x=0,z=10}})
        ''')

    def test_chopper_native_rear_approach_takes_over_preparation(self):
        for offset,expected,auto_aim in [(0,-12,True),(8,-6,True),(2,-11,False)]:
            with self.subTest(offset=offset):
                self.lua.execute(f"""
                    u.combineToUnload=nil
                    c.isWaitingForUnloadAfterPulledBack=function() return false end
                    c.hasAutoAimPipe=function() return {str(auto_aim).lower()} end
                    local harvester={{getCpDriveStrategy=function() return c end}}
                    u.getPipeOffset=function() return {offset},0 end
                    u.getAutoAimPipeOffsetX=function() return {offset} end
                    u.getCombinesMeasuredBackDistance=function() return 6 end
                    Markers={{getFrontMarkerNode=function() return nil,4 end}}
                    u.isOkToStartUnloadingCombine=function() return false end
                    u.isPathfindingNeeded=function() return true end
                    u.getPipeOffsetReferenceNode=function() return 123 end
                    u.setNewState=function(self,state) self.state=state end
                    u.startPathfindingToWaitingCombine=function(_,x,z) assert(x=={offset} and z=={expected}) end
                    CpUnloaderQueue.take(u,'prepare')
                    assert(u:call(harvester,nil))
                    assert(u.combineToUnload==harvester and not CpUnloaderQueue.owns(u))
                    assert(u.state==u.states.WAITING_FOR_PATHFINDER)
                """)

    def test_chopper_keeps_native_fullness_and_reverse_changeover(self):
        self.lua.execute("""
            c.isTurning=function() return false end
            c.isAboutToTurn=function() return false end
            c.isAboutToReturnFromPocket=function() return false end
            u.isDriveUnloadNowRequested=function() return false end
            u.getAllTrailersFull=function(_,threshold) assert(threshold==nil); return false end
            assert(not u:changeToUnloadWhenTrailerFull())
            u.getAllTrailersFull=function(_,threshold) assert(threshold==nil); return true end
            u.startMovingBackFromCombine=function(_,state) assert(state==u.states.MOVING_BACK_WITH_TRAILER_FULL); backed=true end
            assert(u:changeToUnloadWhenTrailerFull() and backed)
        """)

    def test_native_chopper_following_is_not_replaced_by_queue_yield(self):
        self.lua.execute("""
            u.vehicle.getIsCpActive=function() return true end
            c.alwaysNeedsUnloader=function() return true end
            local h=u.combineToUnload
            AIDriveStrategyCombineCourse.isActiveCpCombine=function() return true end
            u.state=u.states.FOLLOW_CHOPPER_THROUGH_TURN
            assert(not CpUnloaderQueue.priority(u,h))
            assert(u.combineToUnload==h and u.state==u.states.FOLLOW_CHOPPER_THROUGH_TURN)
        """)

    def test_transfer_balance_prevents_an_unavailable_future_reservation(self):
        self.lua.execute('''
            local combines={
                {id='a',owner='busy',capacity=20000,fill=18000,rate=0,callPercent=80,sampleTime=1000},
                {id='b',capacity=10000,fill=1000,rate=50,callPercent=80,sampleTime=1000}}
            local trailers={
                {id='busy',owner='a',capacity=32000,fill=7000,departPercent=85,enabled=true,available=false,
                    compatible={a=true,b=true},transferring=true,transferRate=500},
                {id='spare',capacity=32000,fill=0,departPercent=85,enabled=true,available=true,compatible={a=true,b=true}}}
            CpUnloaderQueue.accountForTransfer(combines,trailers,{a={owner='busy',fill=18400,sampleTime=0}})
            assert(combines[1].rate==100)
            local plan=CpUnloaderQueuePolicy.plan(combines,trailers,function() return 10 end)
            assert(plan.leads.b and plan.leads.b.trailer=='spare')
            assert(not CpUnloaderQueuePolicy.remainingAfterTransfer(trailers[1],{a=combines[1]}))
            local alone=CpUnloaderQueuePolicy.plan({combines[1]},trailers,function() return 10 end)
            assert(alone.successors.a and alone.successors.a.trailer=='spare')
        ''')

    def test_transfer_owner_change_does_not_claim_a_measured_forecast(self):
        self.lua.execute('''
            local c={id='a',owner='new',fill=10000,rate=0,sampleTime=1000}
            local t={id='new',transferring=true,transferRate=500}
            CpUnloaderQueue.accountForTransfer({c},{t},{a={owner='old',fill=11000,sampleTime=0}})
            assert(not t.transferring)
        ''')


class HarvesterSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute((ROOT/'scripts/CpObject.lua').read_text())
        self.lua.execute('HeadlandLoopGeometry={}; ImplementController={}')
        self.lua.execute((ROOT/'scripts/ai/controllers/CombineController.lua').read_text())
        load_queue(self.lua,hooks=False)
        self.lua.execute("""
            FillType={UNKNOWN=0}; output=1; supported={[1]=true,[2]=true}; contents=0; free=32000
            rawCapacity=math.huge; tankLevel=0; accepted=1
            local source={getFillUnitCapacity=function() return rawCapacity end,
                getFillUnitFillLevel=function() return tankLevel end,
                getCurrentDischargeNode=function() return {fillUnitIndex=7} end,
                getFillUnitSupportedFillTypes=function() error('wrong implement/outlet') end}
            local pipe={getFillUnitSupportedFillTypes=function(_,ix) assert(ix==2); return supported end}
            local controller=setmetatable({implement=source,combineSpec={fillUnitIndex=1,loadingDelay=0}},CombineController)
            c={combineController=controller,pipeController={implement=pipe},
                getCurrentDischargeNode=function() return {fillUnitIndex=2} end,
                alwaysNeedsUnloader=function() return controller:alwaysNeedsUnloader() end,
                getFillType=function() return output end,
                settings={callUnloaderPercent={getValue=function() return 80 end}},
                isWaitingForUnload=function() return true end,unloader={get=function() return registered end}}
            h={rootNode=1,getCpDriveStrategy=function() return c end,getAIDirectionNode=function() return 1 end}
            c.vehicle=h
            local trailer={getFillUnitCapacity=function() return 32000 end,
                getFillUnitFillLevel=function() return contents end,getFillUnitFreeCapacity=function() return free end,
                getFillUnitAllowsFillType=function(_,ix,ft) return ft==accepted end}
            u={states={IDLE={}},vehicle={rootNode=2,getIsCpActive=function() return true end,
                getAIDirectionNode=function() return 2 end},
                trailerNodes={{trailer=trailer,fillUnitIx=1}},
                settings={fullThreshold={getValue=function() return 85 end}},
                isServingPosition=function() return true end,
                getDistanceAndEteToVehicle=function() return 50,10 end}
            u.state=u.states.IDLE
            CpUnloaderQueueWorld.pose=function() return {x=0,z=0,t=0} end
            AIDriveStrategyCombineCourse={isActiveCpCombine=function() return true end}
            g_currentMission={time=0,vehicleSystem={vehicles={h}}}
            CpUnloaderQueue.data(u)
        """)

    def test_native_controller_classifies_grain_beet_and_vegetable_tanks(self):
        for label,volume,level,fill_type in [('grain',20000,12000,1),('beet',45000,30000,3),('vegetables',12000,8000,4)]:
            with self.subTest(harvester=label):
                self.lua.execute(f"""
                    rawCapacity={volume}; tankLevel={level}; output={fill_type}; accepted={fill_type}
                    CpUnloaderQueue.nextPlan=0; CpUnloaderQueue.refresh()
                    local c=CpUnloaderQueue.combines['1']
                    assert(not c.continuous and c.capacity=={volume} and c.fill=={level})
                    assert(c.fillType=={fill_type} and CpUnloaderQueue.plan.leads['1'].trailer=='2')
                """)

    def test_native_controller_classifies_forage_and_continuous_vegetables(self):
        for label,volume,fill_type in [('forage','math.huge',1),('vegetable conveyor','10000001',4)]:
            with self.subTest(harvester=label):
                self.lua.execute(f"""
                    rawCapacity={volume}; output={fill_type}; accepted={fill_type}
                    CpUnloaderQueue.nextPlan=0; CpUnloaderQueue.refresh()
                    local c=CpUnloaderQueue.combines['1']
                    assert(c.continuous and c.capacity==0 and c.fillType=={fill_type})
                    assert(CpUnloaderQueue.plan.leads['1'].trailer=='2')
                """)

    def test_vegetable_loading_delay_is_included_in_tank_forecast(self):
        self.lua.execute("""
            rawCapacity=12000; tankLevel=7000
            c.combineController.combineSpec.loadingDelay=5
            c.combineController.combineSpec.loadingDelaySlots={{valid=true,fillLevelDelta=2000}}
            CpUnloaderQueue.refresh()
            assert(CpUnloaderQueue.combines['1'].fill==9000)
        """)

    def test_continuous_harvester_is_in_snapshot_and_has_lead(self):
        self.lua.execute("""
            CpUnloaderQueue.refresh()
            local c=CpUnloaderQueue.combines['1']
            assert(c.continuous and c.capacity==0 and c.fill==0)
            assert(CpUnloaderQueue.plan.leads['1'].trailer=='2')
        """)

    def test_unknown_output_prepares_using_supported_discharge_types(self):
        self.lua.execute("""
            output=0; CpUnloaderQueue.refresh()
            assert(CpUnloaderQueue.plan.leads['1'].trailer=='2')
            assert(not CpUnloaderQueue.findUnloader(c,h,nil))
            g_currentMission.time=1000; output=2; CpUnloaderQueue.refresh()
            assert(CpUnloaderQueue.plan.leads['1']==nil)
        """)

    def test_unknown_output_without_compatible_supported_type_only_parks(self):
        self.lua.execute("""
            output=0; supported={[2]=true}; CpUnloaderQueue.refresh()
            assert(CpUnloaderQueue.plan.leads['1']==nil)
            assert(CpUnloaderQueue.plan.trailers['2'].pool)
        """)

    def test_native_accepted_call_prevents_duplicate_lead_before_registration(self):
        self.lua.execute("""
            u.combineToUnload=h; u.state={}; CpUnloaderQueue.refresh()
            assert(CpUnloaderQueue.combines['1'].owner=='2')
            assert(CpUnloaderQueue.plan.leads['1']==nil)
        """)


class EngineBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().ROOT=ROOT.as_posix()
        self.lua.execute((SOURCE/'tools/double-pivot/engine-boundary.lua').read_text())
        load_queue(self.lua, hooks=False)
        self.lua.execute('''
            g_currentMission.time=0
            g_currentMission.vehicleSystem={vehicles={}}
            getRootNode=function() return 0 end
            CpUtil.getDefaultCollisionFlags=function() return 255 end
            densityCount=0; densityTotal=100; cutCount=0; queryCount=0
            DensityCoordType={POINT_POINT_POINT=1}
            DensityValueCompareType={GREATER=1,EQUAL=2}
            DensityMapModifier={new=function()
                return {setParallelogramWorldCoords=function() end,
                    executeGet=function(_,filter)
                        queryCount=queryCount+1
                        if densityStates then
                            local count=0
                            for state,pixels in pairs(densityStates) do
                                if (filter.mode==1 and state>filter.value) or
                                        (filter.mode==2 and state==filter.value) then count=count+pixels end
                            end
                            return 0,count,densityTotal
                        end
                        if filter.mode==2 then return 0,filter.value==10 and cutCount or 0,densityTotal end
                        return 0,densityCount,densityTotal
                    end}
            end}
            DensityMapFilter={new=function()
                return {setValueCompareParams=function(self,mode,value) self.mode=mode; self.value=value end}
            end}
            g_fruitTypeManager={getFruitTypes=function()
                return {{terrainDataPlaneId=1,startStateChannel=0,numStateChannels=4,cutStates={[10]=true}}}
            end}
            PathfinderUtil.setWorldPositionAndRotationOnTerrain=function(node,x,z,t) node.x=x;node.z=z;node.t=t end
            collision=0
            PathfinderCollisionDetector=function()
                return {collisionMask=255}
            end
            overlapBox=function(x,y,z,rx,ry,rz,w,h,l,callback,object,mask)
                assert(mask==255); object.collidingShapes=collision
            end
            local field={{x=-100,z=-100},{x=100,z=-100},{x=100,z=200},{x=-100,z=200}}
            v,context,trailer=fixture({single=true,field=field})
            v.size.length=5
            trailer.size={width=3,length=6}; trailer.getAIMarkers=nil
            v.getIsCpActive=function() return true end
            u={vehicle=v,turningRadius=10,debug=function() end}
            world=assert(CpUnloaderQueueWorld.new(u))
            poses=CpUnloaderQueueWorld.poses(world.model)
        ''')

    def test_single_trailer_uses_real_chain_model(self):
        self.lua.execute('assert(#world.model.links==1); assert(CpUnloaderQueueWorld.clear(world,poses))')

    def test_unsupported_rig_is_not_approximated(self):
        self.lua.execute('''
            trailer.spec_wheels.wheels[1].steering.steeringAxleScale=1
            local model,reason=CpUnloaderQueueWorld.model(v)
            assert(not model and reason=='steered implement axle')
        ''')

    def test_reverse_path_uses_trailer_tracking_node(self):
        self.lua.execute('''
            u.ppc={getReverserNode=function() return trailer.steeringAxleNode end}
            local search=assert(CpUnloaderQueueSearch.new(world,{x=0,z=-20,t=0,reverse=true}))
            local done,path
            for i=1,2000 do
                done,path=CpUnloaderQueueSearch.step(search,4)
                if done then break end
            end
            assert(done and path and path.reverse)
            assert(math.abs(path[1].trackZ+9.8)<.01)
            assert(math.abs(path[#path].z+20)<.01)
            assert(math.abs(path[#path].trackZ+29.8)<.01)
        ''')

    def test_reverse_unknown_reference_is_rejected(self):
        self.lua.execute('''
            u.ppc={getReverserNode=function() return {} end}
            local search,reason=CpUnloaderQueueSearch.new(world,{x=0,z=-20,t=0,reverse=true})
            assert(not search and reason=='unsupported reverse tracking node')
        ''')

    def test_clearance_compares_whole_train_time_in_both_directions(self):
        self.lua.execute('''
            u.ppc={getReverserNode=function() return trailer.steeringAxleNode end}
            u.settings={reverseSpeed={getValue=function() return 10 end}}
            u.getFieldSpeed=function() return 15 end
            local G=CpUnloaderQueueGeometry
            local corridor=G.rectangle({x=0,z=0,heading=0},{width=10,length=5},0)
            local function accept(poses,model)
                for i,p in ipairs(poses) do
                    if G.overlap(CpUnloaderQueueWorld.rectangle(model.bodies[i],p),corridor) then return false end
                end
                return true
            end
            local search=CpUnloaderQueueSearch.choices(world,{
                {x=0,z=40,t=0,clearance=corridor,accept=accept},
                {x=0,z=-10,t=0,reverse=true,clearance=corridor,accept=accept}})
            local done,path
            for i=1,5000 do
                done,path=CpUnloaderQueueSearch.step(search,4)
                if done then break end
            end
            assert(done and path and path.reverse)
        ''')

    def test_each_search_step_has_bounded_geometry_work(self):
        self.lua.execute('''
            local search=assert(CpUnloaderQueueSearch.new(world,{x=0,z=30,t=0}))
            for i=1,100 do
                local before=queryCount
                CpUnloaderQueueSearch.step(search,1)
                assert(queryCount-before<=4)
            end
        ''')

    def test_shared_scheduler_advances_only_once_per_frame(self):
        self.lua.execute('''
            u.setMaxSpeed=function() end
            local data=CpUnloaderQueue.take(u,'prepare')
            data.world=world
            data.search=assert(CpUnloaderQueueSearch.new(world,{x=0,z=30,t=0}))
            data.searchGeneration=data.generation; data.searchStarted=0
            u.startCourse=function() error('unexpected completion in two samples') end
            local ticks=0
            openIntervalTimer=function() ticks=0; return 1 end
            readIntervalTimerMs=function() ticks=ticks+1; return ticks end
            closeIntervalTimer=function() end
            g_updateLoopIndex=1
            CpUnloaderQueue.schedule()
            local work=queryCount
            CpUnloaderQueue.schedule()
            assert(queryCount==work)
            local search=data.search
            local fake={getCpDriveStrategy=function() return {pathfinderController={pathfinder={}}} end}
            g_currentMission.vehicleSystem.vehicles={fake}; g_updateLoopIndex=2
            CpUnloaderQueue.schedule()
            assert(queryCount==work and data.search==search)
        ''')

    def test_growing_crop_rejected(self):
        self.lua.execute('densityCount=20; assert(not CpUnloaderQueueWorld.clear(world,poses))')

    def test_native_search_wait_does_not_consume_preparation_budget(self):
        self.lua.execute('''
            u.setMaxSpeed=function() end
            local data=CpUnloaderQueue.take(u,'prepare')
            data.world=world
            data.search=assert(CpUnloaderQueueSearch.new(world,{x=0,z=30,t=0}))
            data.searchGeneration=data.generation; data.searchStarted=0; data.searchActiveMs=0
            local search=data.search
            local native={getCpDriveStrategy=function() return {pathfinderController={pathfinder={}}} end}
            g_currentMission.vehicleSystem.vehicles={native}
            local ticks=0
            openIntervalTimer=function() ticks=0; return 1 end
            readIntervalTimerMs=function() ticks=ticks+1; return ticks end
            closeIntervalTimer=function() end
            for i=1,200 do
                g_updateLoopIndex=i; g_currentMission.time=i*100
                CpUnloaderQueue.schedule()
            end
            assert(data.search==search and data.searchActiveMs==0)
            g_currentMission.vehicleSystem.vehicles={}
            g_updateLoopIndex=201; g_currentMission.time=20100
            CpUnloaderQueue.schedule()
            assert(data.search==search and data.searchActiveMs==100)
        ''')

    def test_only_scheduled_search_uses_budget_and_active_exhaustion_still_stops(self):
        self.lua.execute('''
            u.setMaxSpeed=function() end
            local data=CpUnloaderQueue.take(u,'prepare')
            data.search={}; data.searchGeneration=data.generation
            data.searchStarted=0; data.searchActiveMs=14900
            local other={state={},debug=function() end}
            local waiting={driver=other,state=other.state,search={},generation=1,searchGeneration=1,
                searchStarted=0,searchActiveMs=100,lastAdvance=100000}
            CpUnloaderQueue.members[other]=waiting
            CpUnloaderQueueSearch.step=function() return false end
            openIntervalTimer=function() return 1 end
            readIntervalTimerMs=function() return 2 end
            closeIntervalTimer=function() end
            CpUnloaderQueue.schedulerTime=20000
            g_updateLoopIndex=1; g_currentMission.time=20100
            CpUnloaderQueue.schedule()
            assert(data.search and data.searchActiveMs==15000 and waiting.searchActiveMs==100)
            g_updateLoopIndex=2; g_currentMission.time=20200
            CpUnloaderQueue.schedule()
            assert(not data.search and data.reason=='search budget exhausted; retaining CP control')
            assert(waiting.search and waiting.searchActiveMs==100)
        ''')

    def test_new_search_is_not_charged_for_idle_time_before_creation(self):
        self.lua.execute('''
            u.setMaxSpeed=function() end
            local data=CpUnloaderQueue.take(u,'prepare')
            data.search={}; data.searchGeneration=data.generation
            data.searchStarted=20000; data.searchActiveMs=0
            CpUnloaderQueueSearch.step=function() return false end
            openIntervalTimer=function() return 1 end
            readIntervalTimerMs=function() return 2 end
            closeIntervalTimer=function() end
            CpUnloaderQueue.schedulerTime=0
            g_updateLoopIndex=1; g_currentMission.time=20000
            CpUnloaderQueue.schedule()
            assert(data.search and data.searchActiveMs==0)
        ''')

    def test_ad_start_outside_field_has_a_bounded_entrance(self):
        self.lua.execute('''
            local boundary={{x=-40,z=10},{x=40,z=10},{x=40,z=150},{x=-40,z=150}}
            v.cpGetFieldPolygon=function() return boundary end
            u.queueData={operation='prepare'}
            u.invertedStartPositionMarkerNode={x=0,z=0,t=0}
            local nativeLength=AIUtil.getLength
            AIUtil.getLength=function() return 18 end
            local entry=assert(CpUnloaderQueueWorld.new(u))
            AIUtil.getLength=nativeLength
            assert(entry.entrance)
            assert(CpUnloaderQueueWorld.clear(entry,CpUnloaderQueueWorld.poses(entry.model)))
            local outside=CpUnloaderQueueWorld.settledPoses(entry.model,{x=90,z=0,t=0})
            assert(not CpUnloaderQueueWorld.clear(entry,outside))
            densityCount=20
            assert(not CpUnloaderQueueWorld.clear(entry,CpUnloaderQueueWorld.poses(entry.model)))
        ''')

    def test_grass_verge_does_not_waive_grain_crop(self):
        self.lua.execute('''
            local rect=CpUnloaderQueueWorld.rectangle(world.model.bodies[1],poses[1])
            densityCount=20
            world.fruit[1].grass=true
            assert(CpUnloaderQueueWorld.cropFree(world,rect,true))
            assert(not CpUnloaderQueueWorld.cropFree(world,rect,false))
            world.fruit[1].grass=false
            assert(not CpUnloaderQueueWorld.cropFree(world,rect,true))
        ''')

    def test_rejected_start_reports_marker_distance_without_loosening_boundary(self):
        self.lua.execute('''
            v.cpGetFieldPolygon=function()
                return {{x=-40,z=10},{x=40,z=10},{x=40,z=150},{x=-40,z=150}}
            end
            u.queueData={operation='prepare'}
            u.invertedStartPositionMarkerNode={x=200,z=0,t=0}
            AIUtil.getLength=function() return 18 end
            local entry=assert(CpUnloaderQueueWorld.new(u))
            assert(not entry.entrance)
            local search,reason,phase=CpUnloaderQueueSearch.new(entry,{x=0,z=40,t=0})
            assert(not search and phase=='start')
            assert(reason:find('start: field boundary',1,true))
            assert(reason:find('root 0.0, 0.0',1,true))
            assert(reason:find('saved start marker 200.0 m away',1,true))
            assert(not CpUnloaderQueueWorld.clear(entry,CpUnloaderQueueWorld.poses(entry.model)))
        ''')

    def test_cut_crop_permitted(self):
        self.lua.execute('densityCount=20; cutCount=20; assert(CpUnloaderQueueWorld.clear(world,poses))')

    def test_installed_foliage_state_numbers_preserve_crop_protection(self):
        # Explicit one-based density values from FS25 foliage XML. In particular,
        # potato/beet cutHaulm is still harvestable: cut state + 1 is NOT safe.
        fixtures = [
            ('wheat', (10,), (1, 7, 8, 9)),
            ('canola', (11,), (1, 8, 9, 10)),
            ('grass', (5,), (1, 3, 4, 6)),
            ('potato', (8,), (1, 6, 7, 9)),
            ('sugarBeet', (10,), (1, 8, 9, 11)),
            ('carrot', (7,), (1, 5, 6, 8)),
            ('parsnip', (7,), (1, 5, 6, 8)),
            ('maize', (9, 10), (1, 5, 7, 8)),
        ]
        for crop, cut_states, blocked_states in fixtures:
            cuts = ','.join(f'[{state}]=true' for state in cut_states)
            self.lua.execute(f'''
                CpUnloaderQueueWorld.delete(world)
                g_fruitTypeManager.getFruitTypes=function()
                    return {{{{name='{crop}',terrainDataPlaneId=1,startStateChannel=0,
                        numStateChannels=4,cutStates={{{cuts}}}}}}}
                end
                world=assert(CpUnloaderQueueWorld.new(u))
            ''')
            for state in (*cut_states, *blocked_states):
                with self.subTest(crop=crop, state=state):
                    self.lua.execute(f'densityStates={{[{state}]=20}}')
                    clear = self.lua.eval('(CpUnloaderQueueWorld.clear(world,poses))')
                    self.assertEqual(clear, state in cut_states)
            # Mixed harvested states are allowed, but one live pixel still blocks.
            densities = ','.join(f'[{state}]=10' for state in cut_states)
            self.lua.execute(f'densityStates={{{densities}}}; assert(CpUnloaderQueueWorld.clear(world,poses))')
            self.lua.execute(f'densityStates[{blocked_states[0]}]=1; assert(not CpUnloaderQueueWorld.clear(world,poses))')

    def test_preparation_route_completes_on_harvested_stubble(self):
        self.lua.execute('''
            densityStates={[10]=100}
            local search=assert(CpUnloaderQueueSearch.new(world,{x=0,z=30,t=0}))
            local done,path
            for i=1,2000 do
                done,path=CpUnloaderQueueSearch.step(search,4)
                if done then break end
            end
            assert(done and path and math.abs(path[#path].z-30)<1.5)
        ''')

    def test_blocked_start_does_not_blacklist_clear_destination(self):
        self.lua.execute('''
            u.setMaxSpeed=function() end
            local data=CpUnloaderQueue.take(u,'prepare')
            densityStates={[8]=100}
            local goal={x=0,z=30,t=0}
            CpUnloaderQueue.request(u,goal)
            assert(not data.search and data.reason=='start: standing crop')
            assert(not data.failedGoals and data.nextAttempt==3000)
            densityStates={[10]=100}
            assert(CpUnloaderQueue.targetAvailable(u,goal))
            CpUnloaderQueue.request(u,goal)
            assert(data.search)
        ''')

    def test_invalid_destination_is_identified_and_temporarily_excluded(self):
        self.lua.execute('''
            u.setMaxSpeed=function() end
            local data=CpUnloaderQueue.take(u,'prepare')
            local goal={x=150,z=30,t=0}
            CpUnloaderQueue.request(u,goal)
            assert(not data.search and data.reason=='destination: field boundary')
            assert(not CpUnloaderQueue.targetAvailable(u,goal))
            g_currentMission.time=15000
            assert(CpUnloaderQueue.targetAvailable(u,goal))
        ''')

    def test_missing_density_rejected(self):
        self.lua.execute('densityCount=nil; assert(not CpUnloaderQueueWorld.clear(world,poses))')

    def test_empty_density_area_rejected(self):
        self.lua.execute('densityTotal=0; assert(not CpUnloaderQueueWorld.clear(world,poses))')

    def test_collision_with_other_vehicle_rejected(self):
        self.lua.execute('collision=1; assert(not CpUnloaderQueueWorld.clear(world,poses))')

    def test_trailer_outside_field_rejected(self):
        self.lua.execute('poses[2].x=101; assert(not CpUnloaderQueueWorld.clear(world,poses))')

    def test_start_in_crop_does_not_get_free_search_steps(self):
        self.lua.execute('densityCount=20; assert(not CpUnloaderQueueSearch.new(world,{x=0,z=30,t=0}))')

    def test_real_direct_search_checks_train_and_finishes_parallel(self):
        self.lua.execute('''
            local search=assert(CpUnloaderQueueSearch.new(world,{x=0,z=30,t=0}))
            local done,path
            for i=1,2000 do
                done,path=CpUnloaderQueueSearch.step(search,8)
                if done then break end
            end
            assert(done and path and #path>30)
            assert(math.abs(path[#path].z-30)<1.5)
            assert(queryCount>100)
        ''')

    def test_search_cannot_cut_across_exit_corridor(self):
        self.lua.execute('''
            local function corridor(rectangle)
                for _,p in ipairs(rectangle) do if math.abs(p.x)>4 then return false end end
                return true
            end
            local search,reason=CpUnloaderQueueSearch.new(world,{x=20,z=30,t=0},corridor)
            assert(not search and reason=='destination: outside harvested exit corridor')
        ''')

    def test_headland_handover_requires_tail_inside(self):
        self.lua.execute('''
            local data=CpUnloaderQueue.data(u)
            data.departure={width=10,headlands={{{x=-50,z=0},{x=50,z=0}}}}
            assert(not CpUnloaderQueue.canFinishExit(u))
        ''')

    def test_new_route_resets_progress_clock_and_retains_validation_mapping(self):
        self.lua.execute('''
            u.setMaxSpeed=function() end
            u.startCourse=function(self,course) self.course=course end
            local data=CpUnloaderQueue.take(u,'prepare')
            data.searchGeneration=data.generation
            data.progressTime=0
            g_currentMission.time=30000
            local path={}
            for i=0,80 do path[#path+1]={x=0,z=i*.25,t=0} end
            CpUnloaderQueue.startRoute(data,path)
            assert(data.progressTime==30000)
            assert(u.course:getNumberOfWaypoints()==21)
            assert(data.courseToPath[21]==81)
        ''')

    def test_capture_uses_saved_work_course_and_survives_second_release(self):
        self.lua.execute('''
            local course=Course(v,{{x=-50,z=0},{x=0,z=0},{x=50,z=0},
                {x=0,z=10},{x=0,z=20},{x=0,z=30}},false)
            course.workWidth=15; course.currentWaypoint=5
            for i=1,3 do
                course:getWaypoint(i).attributes:setHeadlandPassNumber(1)
                course:getWaypoint(i).attributes:setBoundaryId('F')
            end
            course:getWaypoint(4).attributes:setRowStart(true)
            local combine={fieldWorkCourse=course,course={temporary=true}}
            u.combineToUnload={getIsCpActive=function() return true end,getCpDriveStrategy=function() return combine end}
            CpUnloaderQueue.capture(u)
            local saved=assert(u.queueData.departure)
            assert(#saved.row==2 and saved.row[1].z==10 and saved.row[2].z==20)
            course.waypoints[4].z=999
            assert(saved.row[1].z==10)
            u.combineToUnload=nil; CpUnloaderQueue.capture(u)
            assert(u.queueData.departure==saved)
        ''')

    def test_headland_origin_does_not_require_a_previous_centre_row(self):
        self.lua.execute('''
            local course=Course(v,{{x=-50,z=0},{x=0,z=0},{x=50,z=0}},false)
            course.workWidth=15
            for i=1,3 do
                course:getWaypoint(i).attributes:setHeadlandPassNumber(1)
                course:getWaypoint(i).attributes:setBoundaryId('F')
            end
            local saved=assert(CpUnloaderQueue.departureFor(course,2))
            assert(saved.headlandOrigin and #saved.row==1 and #saved.headlands==1)
            course:getWaypoint(1).attributes:setBoundaryId('I1')
            course:getWaypoint(2).attributes:setBoundaryId('I1')
            course:getWaypoint(3).attributes:setBoundaryId('I1')
            assert(not CpUnloaderQueue.departureFor(course,2))
        ''')

    def test_ad_connection_requires_correct_headland_and_direction(self):
        self.lua.execute('''
            local nodes={{id=1,x=0,z=0,out={2}},{id=2,x=0,z=10,out={}}}
            FS25_AutoDrive={ADGraphManager={getWayPointById=function(_,i) return nodes[i] end,
                getWayPointsInRange=function() return {nodes[1]} end,
                pathFromTo=function() return nodes end}}
            v.ad={stateModule={getMode=function() return 2 end,getSecondWayPoint=function() return 2 end}}
            local saved={width=10,headlands={{{x=-50,z=0},{x=50,z=0}}}}
            assert(CpUnloaderQueue.connectedNode(u,{x=0,z=0,t=0},saved))
            assert(not CpUnloaderQueue.connectedNode(u,{x=0,z=0,t=math.pi},saved))
            saved.headlands={{{x=-50,z=30},{x=50,z=30}}}
            assert(not CpUnloaderQueue.connectedNode(u,{x=0,z=0,t=0},saved))
        ''')

    def ad_exit_network(self):
        # AD 3.0.1.2 PathCalculation.lua reconstructs a non-trivial route from
        # the destination back to (but excluding) the requested start node.
        self.lua.execute('''
            nodes={{id=1,x=0,z=0,out={2}},{id=2,x=0,z=10,out={3}},
                {id=3,x=0,z=20,out={}}}
            adPath={nodes[2],nodes[3]}; destination=3
            FS25_AutoDrive={ADGraphManager={getWayPointById=function(_,i) return nodes[i] end,
                getWayPointsInRange=function() return {1} end,
                pathFromTo=function(_,start,goal) assert(start==1 and goal==destination); return adPath end}}
            v.ad={stateModule={getMode=function() return 2 end,
                getSecondWayPoint=function() return destination end}}
            saved={width=20,row={{x=0,z=80},{x=0,z=100}},position={x=0,z=100},
                headlands={{{x=0,z=-60,t=0},{x=0,z=60,t=0}}}}
            CpUnloaderQueue.data(u).departure=saved
        ''')

    def test_ad_route_omitting_start_provides_exit_site_and_heading(self):
        self.ad_exit_network()
        self.lua.execute('''
            local node,heading,site=CpUnloaderQueue.connectedNode(u,{x=0,z=0,t=0},saved)
            assert(node==nodes[1] and heading==0 and site.x==0 and site.z==0)
            local target=assert(CpUnloaderQueue.exitTarget(u))
            assert(target.x==0 and target.z==0 and target.t==0)
            assert(not CpUnloaderQueue.connectedNode(u,{x=0,z=0,t=math.pi},saved))
        ''')

    def test_ad_single_hop_and_start_included_are_both_supported(self):
        self.ad_exit_network()
        self.lua.execute('''
            destination=2; adPath={nodes[2]}
            assert(CpUnloaderQueue.connectedNode(u,{x=0,z=0,t=0},saved))
            adPath={nodes[1],nodes[2]}
            assert(CpUnloaderQueue.connectedNode(u,{x=0,z=0,t=0},saved))
        ''')

    def test_ad_route_must_connect_every_directed_edge_and_reach_destination(self):
        self.ad_exit_network()
        self.lua.execute('''
            for _,path in ipairs({{}, {nodes[1]}, {nodes[2]}, {nodes[3]}, {nodes[2],nodes[1],nodes[3]}}) do
                adPath=path
                assert(not CpUnloaderQueue.connectedNode(u,{x=0,z=0,t=0},saved))
            end
            adPath={nodes[2],nodes[3]}; nodes[2].out={}
            assert(not CpUnloaderQueue.connectedNode(u,{x=0,z=0,t=0},saved))
        ''')

    def test_ad_native_shape_allows_handover_only_after_whole_train_clears(self):
        self.ad_exit_network()
        self.lua.execute('''
            local handedOver=0
            u.onTrailerFull=function() handedOver=handedOver+1 end
            assert(CpUnloaderQueue.canFinishExit(u))
            CpUnloaderQueue.finishExit(u)
            assert(handedOver==1)
            -- The tractor is on this shorter band, but its trailer is not.
            saved.headlands={{{x=0,z=-3,t=0},{x=0,z=60,t=0}}}
            assert(not CpUnloaderQueue.canFinishExit(u))
            CpUnloaderQueue.finishExit(u)
            assert(handedOver==1)
        ''')

    def test_ad_connected_route_does_not_waive_crop_or_collision_checks(self):
        self.ad_exit_network()
        self.lua.execute('''
            densityStates={[8]=100}
            assert(not CpUnloaderQueue.canFinishExit(u))
            densityStates={[10]=100}; collision=1
            assert(not CpUnloaderQueue.canFinishExit(u))
            collision=0
            assert(CpUnloaderQueue.canFinishExit(u))
        ''')


if __name__=='__main__': unittest.main()
