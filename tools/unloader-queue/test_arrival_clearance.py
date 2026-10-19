"""3026: arrival priority and clearance without a guessed valid endpoint."""
from pathlib import Path
import sys
import unittest

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE/'tools/unloader-queue'))
import test_runtime as runtime
import test_yield as yielding
import test_combined_recovery as combined
runtime.ROOT = yielding.ROOT = combined.ROOT = ROOT


class ClearanceTests(unittest.TestCase):
    def setUp(self):
        yielding.YieldTests.setUp(self)

    def test_completed_search_cannot_start_after_rig_moves(self):
        self.lua.execute('''
            Q.take(u,'prepare')
            local data=u.queueData
            data.world=assert(W.new(u)); data.searchGeneration=data.generation
            data.goal={x=0,z=40,t=0}
            place(0,1,0)
            Q.startRoute(data,{{x=0,z=0,t=0},{x=0,z=40,t=0}})
            assert(not data.path and not data.world and not u.course)
            assert(data.reason:find('rig moved during parking search'))
        ''')

    def working_drive_wrapper(self):
        self.lua.execute('''
            Q.checkCombineTurns=function() return false end
            Q.checkParkedTrailerTravel=function() return false end
            Q.holdHeadlandCorner=function() return false end
            nativeSpeed=10
            AIDriveStrategyCombineCourse.getDriveData=function() return 12,34,true,nativeSpeed,0.8 end
        ''')
        hooks=(ROOT/'scripts/ai/CpUnloaderQueueHooks.lua').read_text()
        wrapper=hooks[hooks.index('local combineDrive ='):hooks.index('-- Preparation ends here.')]
        self.lua.execute('local Q=CpUnloaderQueue; local C=AIDriveStrategyCombineCourse; '+wrapper)

    def test_working_header_does_not_interrupt_preparation_before_native_request(self):
        self.working_drive_wrapper()
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,0,0)
            c.states={WORKING={}}; c.state=c.states.WORKING
            c.course=Course(harvester,{{x=0,z=0},{x=0,z=60}},true)
            local course=c.course
            place(0,30,math.pi); c.near=false
            Q.take(u,'prepare')
            local data=u.queueData
            local search={}; data.search=search
            local generation=data.generation
            for i=1,100 do
                g_currentMission.time=i*5000
                local x,z,forward,speed,acceleration=c:getDriveData()
                assert(x==12 and z==34 and forward and speed==10 and acceleration==0.8)
                assert(data.operation=='prepare' and c.course==course)
                assert(data.search==search and data.generation==generation)
                assert(u:isAllowedToBeCalled(),'early clearance removed native availability')
            end
            -- Actual native blockage still requests checked whole-train clearance.
            c.near=true; nativeRequest()
            assert(data.operation=='yield' and not data.search and c.course==course)
            assert(not u:isAllowedToBeCalled())
        ''')

    def test_native_unloading_and_departure_are_not_seized(self):
        self.working_drive_wrapper()
        self.lua.execute('''
            c.states={WORKING={}}; c.state=c.states.WORKING
            c.course=Course(harvester,{{x=0,z=12},{x=0,z=-40}},true)
            Q.take(u,'prepare'); u.combineToUnload=harvester
            c:getDriveData(); assert(u.combineToUnload==harvester and u.queueData.operation=='prepare')
            u.combineToUnload=nil; u.queueData.nativeDeparture=true
            g_currentMission.time=201
            c:getDriveData(); assert(u.queueData.operation=='prepare')
        ''')

    def test_failed_yield_does_not_override_native_combine_speed_or_proximity_stop(self):
        self.working_drive_wrapper()
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,0,0)
            c.states={WORKING={}}; c.state=c.states.WORKING
            c.course=Course(harvester,{{x=0,z=0},{x=0,z=60}},true)
            place(0,30,math.pi); c.near=true
            Q.take(u,'prepare'); nativeRequest()
        ''')
        self.lua.execute('''
            for i=1,100 do
                g_currentMission.time=i*5000
                local x,z,forward,speed,acceleration=c:getDriveData()
                assert(x==12 and z==34 and forward and speed==10 and acceleration==0.8)
                assert(u.queueData.operation=='yield')
                Q.failed(u.queueData,'search budget exhausted; retaining CP control')
            end
            nativeSpeed=0 -- an actual obstacle still stops the combine
            local _,_,_,speed=c:getDriveData(); assert(speed==0)
            nativeSpeed=10; Q.checkCombineTurns=function() return true end
            _,_,_,speed=c:getDriveData(); assert(speed==0,'existing turn protection removed')
        ''')

    def test_stalled_queue_routes_retry_despite_repeated_native_stops(self):
        for operation in ('prepare', 'yield'):
            with self.subTest(operation=operation):
                self.setUp()
                self.lua.globals().operation=operation
                self.lua.execute('''
                    Q.schedule=function() end
                    Q.yieldTarget=function() end
                    local data=Q.take(u,operation)
                    local goal={x=0,z=30,t=0}
                    data.path={{x=0,z=0,t=0},goal}; data.goal=goal
                    data.progressPosition=W.pose(v:getAIDirectionNode()); data.progressTime=0
                    local generation=data.generation
                    for i=1,10 do
                        g_currentMission.time=i*1000
                        data.nativeHold=true -- native speed remains zero behind an obstacle
                        Q.tick(u)
                        assert(data.path,'transient stop cancelled the route too early')
                    end
                    g_currentMission.time=11000; Q.tick(u)
                    assert(not data.path and not data.goal and data.generation>generation)
                    assert(data.reason=='route made no progress; trying another waiting position')
                    assert(data.nextAttempt==14000 and not Q.targetAvailable(u,goal))
                    assert(Q.owns(u) and data.operation==operation,'retry stole native ownership')
                ''')

    def test_progress_and_deliberate_turn_wait_preserve_queue_route(self):
        self.lua.execute('''
            Q.schedule=function() end
            local data=Q.take(u,'prepare')
            data.path={{x=0,z=0,t=0},{x=0,z=30,t=0}}
            data.progressPosition=W.pose(v:getAIDirectionNode()); data.progressTime=0
            place(0,2,0); g_currentMission.time=9000; Q.tick(u)
            assert(data.path and data.progressTime==9000)
            data.turnHold=c
            g_currentMission.time=25000; Q.tick(u)
            assert(data.path and data.progressTime==25000)
            data.turnHold=nil
            g_currentMission.time=34000; Q.tick(u); assert(data.path)
            g_currentMission.time=36000; Q.tick(u); assert(not data.path)
        ''')

    def test_scheduler_reaches_checked_escape_when_fixed_routes_consume_budget(self):
        self.assert_budgeted_escape(False)

    def test_scheduler_reaches_checked_forward_escape_when_reverse_search_stalls(self):
        self.assert_budgeted_escape(True)

    def assert_budgeted_escape(self, reverse_blocked):
        self.lua.globals().blockReverse = reverse_blocked
        self.lua.execute('''
            local S=CpUnloaderQueueSearch
            local data=Q.take(u,'yield'); data.world=world
            local blocked=G.rectangle({x=0,z=0,heading=0},{width=40,length=4},0)
            local function accept(poses,model)
                for i,p in ipairs(poses) do
                    if G.overlap(W.rectangle(model.bodies[i],p),blocked) then return false end
                end
                return true
            end
            local choices={{x=0,z=80,t=0},{x=50,z=80,t=0},{x=-50,z=80,t=0}}
            data.search=assert(S.choices(world,choices)); data.search.escape=accept
            data.searchGeneration=data.generation; data.searchStarted=0; data.searchWorkMs=0
            -- Model expensive, unfinished fixed candidates. The fallback uses
            -- the real search and all actual whole-train geometry validation.
            local nativeStep,nativeEscape=S.step,S.escape
            local tried={}
            S.new=function(w,goal,corridor) tried[goal]=true; return {expensive=true} end
            S.escape=function(w,accept,corridor,reverse)
                if reverse and blockReverse then return {expensive=true} end
                return nativeEscape(w,accept,corridor,reverse)
            end
            S.step=function(search,budget)
                if search.expensive then measuredWork=2; return false end
                measuredWork=measuredWork+0.01
                return nativeStep(search,budget)
            end
            openIntervalTimer=function() measuredWork=0; return 1 end
            readIntervalTimerMs=function() measuredWork=measuredWork+0.01; return measuredWork end
            closeIntervalTimer=function() end
            local completed
            Q.startRoute=function(_,path) completed=path end
            for i=1,600 do
                g_updateLoopIndex=i; g_currentMission.time=i*33
                Q.schedule()
                if not data.search then break end
            end
            for _,goal in ipairs(choices) do assert(tried[goal],'fixed candidate starved') end
            assert(completed and (not not completed.reverse)==(not blockReverse),data.reason or 'local escape starved')
            assert(data.searchWorkMs<=1000,'increased total search budget')
            local poses=W.poses(world.model)
            for i=2,#completed do
                poses=H.advance(world.model,poses,completed[i]); assert(W.clear(world,poses))
            end
            assert(accept(poses,world.model))
        ''')

    def test_reverse_escape_cannot_starve_forward_or_accept_partial_path(self):
        self.lua.execute('''
            local S=CpUnloaderQueueSearch
            local search={choices={},index=1,escape=function() return true end,fallback={partial=true}}
            assert(not S.chargeChoices(search,199,S.choicePhase(search)) and search.fallback.partial)
            assert(S.chargeChoices(search,1,S.choicePhase(search)) and search.escapeForward and not search.fallback)
            assert(not search.best and not search.path)
            -- Non-yield choice searches retain their existing allocation.
            local arrival={choices={{}},index=1,active={}}
            assert(not S.chargeChoices(arrival,1000,S.choicePhase(arrival)) and arrival.index==1 and arrival.active)
        ''')

    def test_expensive_completed_phase_does_not_skip_next_untried_destination(self):
        self.lua.execute('''
            local S=CpUnloaderQueueSearch
            local search={choices={{},{}},index=1,escape=function() return true end}
            local phase=S.choicePhase(search)
            search.index=2 -- previous candidate completed/rejected during S.step
            assert(not S.chargeChoices(search,200,phase) and search.index==2)
            phase=S.choicePhase(search); search.index=3
            assert(not S.chargeChoices(search,250,phase) and not search.escapeForward)
            assert(not S.chargeChoices(search,199,S.choicePhase(search)))
            assert(S.chargeChoices(search,1,S.choicePhase(search)) and search.escapeForward)
        ''')

    def test_clearance_finds_nearby_space_when_fixed_endpoints_cross_boundary(self):
        self.lua.execute('''
            -- All old endpoints overshoot a small harvested space. The actual
            -- train can clear the blocked strip with a shorter forward move.
            v.cpGetFieldPolygon=function() return {{x=-20,z=-16},{x=20,z=-16},{x=20,z=22},{x=-20,z=22}} end
            Q.take(u,'yield'); local w=assert(W.new(u)); assert(not w.entrance)
            local blocked=G.rectangle({x=0,z=0,heading=0},{width=40,length=4},0)
            local function accept(poses,model)
                for i,p in ipairs(poses) do
                    if G.overlap(W.rectangle(model.bodies[i],p),blocked) then return false end
                end
                return true
            end
            local choices={{x=0,z=40,t=0,accept=accept},{x=0,z=-40,t=0,reverse=true,accept=accept}}
            for _,goal in ipairs(choices) do
                local s,reason=CpUnloaderQueueSearch.new(w,goal)
                assert(not s and reason=='destination: field boundary')
            end
            local search=assert(CpUnloaderQueueSearch.choices(w,choices)); search.escape=accept
            local done,path,reason
            for i=1,300000 do
                done,path,reason=CpUnloaderQueueSearch.step(search,1)
                if done then break end
            end
            assert(done and path,reason or 'bounded escape did not finish')
            local poses=W.poses(w.model)
            for i=2,#path do poses=H.advance(w.model,poses,path[i]); assert(W.clear(w,poses)) end
            assert(accept(poses,w.model) and path.goal and path.goal.accept(poses,w.model))
            assert(path[#path].z<22 and path[#path].z>12)
            W.delete(w)
        ''')

    def test_escape_keeps_start_crop_obstacle_and_articulation_checks(self):
        self.lua.execute('''
            local S=CpUnloaderQueueSearch
            local function accept() return true end
            densityCount=10
            local search,reason=S.escape(world,accept)
            assert(not search and reason=='start: standing crop')
            densityCount=0; collision=1
            search,reason=S.escape(world,accept)
            assert(not search and reason=='start: vehicle or obstacle')
            collision=0; trailer.rootNode.t=math.pi/2
            trailer.rootNode.x=-6.5; trailer.rootNode.z=-3.3
            W.delete(world); world=assert(W.new(u))
            search,reason=S.escape(world,accept)
            assert(not search and reason=='start: articulation limit')
        ''')

    def test_short_reverse_clears_when_ten_metre_endpoint_overshoots_field(self):
        self.lua.execute('''
            v.cpGetFieldPolygon=function() return {{x=-6,z=-20},{x=6,z=-20},{x=6,z=6},{x=-6,z=6}} end
            Q.take(u,'yield'); local w=assert(W.new(u))
            local blocked=G.rectangle({x=0,z=0,heading=0},{width=40,length=4},0)
            local function accept(poses,model)
                for i,p in ipairs(poses) do
                    if G.overlap(W.rectangle(model.bodies[i],p),blocked) then return false end
                end
                return true
            end
            local choices={{x=0,z=40,t=0,accept=accept},{x=0,z=-10,t=0,reverse=true,accept=accept}}
            local search=assert(CpUnloaderQueueSearch.choices(w,choices)); search.escape=accept
            local done,path,reason
            for i=1,10000 do
                done,path,reason=CpUnloaderQueueSearch.step(search,1)
                if done then break end
            end
            assert(done and path and path.reverse,reason or 'short reverse not found')
            assert(path[#path].z>-10 and path[#path].z<=-4)
            local poses=W.poses(w.model)
            for i=2,#path do
                assert(path[i].trackX and path[i].trackZ)
                poses=H.advance(w.model,poses,path[i]); assert(W.clear(w,poses))
            end
            assert(accept(poses,w.model))
            W.delete(w)
        ''')

    def test_escape_does_not_cross_a_full_width_obstacle_to_reach_clear_ground(self):
        self.lua.execute('''
            v.cpGetFieldPolygon=function() return {{x=-6,z=-16},{x=6,z=-16},{x=6,z=35},{x=-6,z=35}} end
            Q.take(u,'yield'); local w=assert(W.new(u))
            overlapBox=function(x,y,z,rx,ry,rz,width,height,length,callback,detector)
                detector.collidingShapes=z+length>=5 and 1 or 0
            end
            local search=assert(CpUnloaderQueueSearch.escape(w,function(poses) return poses[1].z>=20 end))
            local done,path
            for i=1,100000 do
                done,path=CpUnloaderQueueSearch.step(search,1)
                if done then break end
            end
            assert(done and not path,'escape crossed an obstacle')
            W.delete(w)
        ''')


class ArrivalTests(unittest.TestCase):
    def setUp(self):
        combined.PreparationTests.setUp(self)

    def test_arrival_precedes_distant_assignment_and_tests_whole_train(self):
        self.lua.execute('''
            local points={}
            for z=0,600 do points[#points+1]={x=0,z=z} end
            local fc=Course(v,points,false)
            local c={vehicle={lastSpeedReal=0},fieldWorkCourse=fc,course=fc,
                getClosestFieldworkWaypointIx=function() return 401 end}
            local pool={}
            for z=-80,180 do pool[#pool+1]={x=-70,z=z} end
            local pc=Course(v,pool,false)
            for i=1,pc:getNumberOfWaypoints() do pc:getWaypoint(i).attributes:setHeadlandPassNumber(1) end
            Q.combines={a={driver=c,vehicle=c.vehicle,position={x=0,z=400},fill=0,capacity=20000,rate=50,callPercent=80},
                pool={driver={fieldWorkCourse=pc},position={x=-70,z=100}},
                duplicate={driver={fieldWorkCourse=pc},position={x=-70,z=100}}}
            u.isServingPosition=function() return true end
            u.invertedStartPositionMarkerNode={x=-70,z=0,t=0}; place(-70,0,0)
            local data=Q.take(u,'prepare'); data.assignment={combine='a'}
            local goal=assert(Q.target(u))
            assert(goal.transit and goal.straight and goal.x==-70 and goal.z>0)
            goal=assert(Q.poolTarget(u,true))
            assert(goal.arrival and goal.firstValid and #goal.choices>1 and goal.x==-70)
            assert(math.abs(goal.z)<100 and not data.stage)
            for _,candidate in ipairs(goal.choices) do
                local model=W.model(v)
                assert(Q.stagingClear(u,W.settledPoses(model,candidate),model))
            end
            for i,a in ipairs(goal.choices) do
                for j,b in ipairs(goal.choices) do assert(i==j or a.x~=b.x or a.z~=b.z or a.t~=b.t) end
            end
            place(-70,30,0); assert(not Q.arrivalClear(u),'trailer still occupies AD clearance')
            assert(Q.target(u).arrival)
            place(-70,50,0); assert(Q.arrivalClear(u))
            goal=assert(Q.target(u))
            assert(not goal.arrival and goal.x==0 and goal.z>100 and data.stage)
            -- A headland-free course can clear arrival on an aligned nearby
            -- centre row, without falling through to a distant assigned stage.
            Q.combines.pool=nil; Q.combines.duplicate=nil; place(-70,0,0)
            data.arrivalExitRetry=10000
            goal=assert(Q.target(u))
            assert(goal.arrival and goal.x==0 and math.abs(goal.z)<100)
        ''')

    def test_actual_arrival_survives_queue_transitions_and_keeps_return_marker(self):
        self.lua.execute('''
            local marker={x=500,z=500,t=1}; u.invertedStartPositionMarkerNode=marker
            place(-70,0,0); Q.captureArrival(u)
            assert(not Q.arrivalClear(u),'distant saved return marker hid the arriving rig')
            Q.take(u,'prepare'); Q.cancel(u); Q.release(u); Q.take(u,'prepare')
            assert(not Q.arrivalClear(u) and u.invertedStartPositionMarkerNode==marker)
            place(-70,30,0); assert(not Q.arrivalClear(u),'trailing body still blocks entrance')
            place(-70,50,0); assert(Q.arrivalClear(u))
            assert(not Q.stagingClear(u,W.settledPoses(world.model,{x=-70,z=0,t=0}),world.model))
            Q.remove(u); place(20,20,0); Q.captureArrival(u)
            assert(Q.data(u).arrivalOrigin.x==20 and not Q.arrivalClear(u),'new job reused old arrival')
            u.invertedStartPositionMarkerNode=nil; assert(not Q.arrivalClear(u))
        ''')

    def test_no_nearby_checked_slot_does_not_start_distant_preparation(self):
        self.lua.execute('''
            local points={}; for z=200,700 do points[#points+1]={x=0,z=z} end
            local fc=Course(v,points,false)
            local c={vehicle={lastSpeedReal=0},fieldWorkCourse=fc,course=fc,
                getClosestFieldworkWaypointIx=function() return 301 end}
            Q.combines={a={driver=c,vehicle=c.vehicle,position={x=0,z=500},fill=0,capacity=20000,rate=50,callPercent=80}}
            u.isServingPosition=function() return true end
            Q.captureArrival(u); local data=Q.take(u,'prepare'); data.assignment={combine='a'}
            assert(Q.target(u).transit and not data.stage)
            data.arrivalExitRetry=10000
            assert(not Q.target(u) and not data.stage)
            place(0,300,0); assert(Q.target(u),'normal preparation must resume after clearing entrance')
        ''')

    def test_later_fleet_member_does_not_skip_short_nearby_row(self):
        self.lua.execute('''
            local points={}; for z=0,100 do points[#points+1]={x=0,z=z} end
            local fc=Course(v,points,false)
            Q.combines={a={driver={fieldWorkCourse=fc},position={x=0,z=50}}}
            u.isServingPosition=function() return true end
            Q.captureArrival(u); Q.take(u,'prepare')
            for i=1,5 do Q.members[{vehicle={rootNode=i}}]={} end
            assert(Q.target(u).transit)
            local goal=assert(Q.poolTarget(u,true),'fleet index skipped all nearby staging ground')
            assert(goal.arrival and goal.z>=45 and goal.z<=85)
        ''')

    def test_native_search_pause_keeps_arrival_progress_without_partial_route(self):
        self.lua.execute('''
            Q.refresh=function() end
            local native={getCpDriveStrategy=function() return {pathfinderController={pathfinder={}}} end}
            g_currentMission.vehicleSystem.vehicles={native}
            Q.captureArrival(u); local data=Q.take(u,'prepare')
            local goal={x=0,z=60,t=0,arrival=true,choices={{x=0,z=60,t=0},{x=0,z=80,t=0}}}
            Q.request(u,goal); local search=data.search; assert(search)
            g_currentMission.time=100000; Q.tick(u)
            assert(data.search==search and data.searchWorkMs==0 and not data.path and not u.course)
            g_currentMission.vehicleSystem.vehicles={}
            g_updateLoopIndex=(g_updateLoopIndex or 0)+1; Q.schedule(); assert(data.searchWorkMs>0 or data.path)
        ''')

    def test_costly_valid_arrival_resumes_without_restarting_checked_edges(self):
        self.lua.execute('''
            local S=CpUnloaderQueueSearch
            local goals={{x=0,z=60,t=0},{x=0,z=80,t=0}}
            local search=assert(S.choices(world,goals)); search.arrival=true
            local original=S.new; local starts=0
            S.new=function(...) starts=starts+1; return original(...) end
            local done,path,work=false,nil,0
            for i=1,2000 do
                local phase=S.choicePhase(search)
                done,path=S.step(search,1)
                work=work+0.5 -- injected expensive whole-rig query budget
                if done then break end
                S.chargeChoices(search,0.5,phase)
            end
            assert(done and path and work>100 and work<1000,'valid route lost its validation progress')
            assert(starts<=#goals,'candidate restarted after time slice')
            local poses=W.poses(world.model)
            for i=2,#path do poses=H.advance(world.model,poses,path[i]); assert(W.clear(world,poses)) end
        ''')

    def test_scheduler_resumes_finite_fallback_after_its_quantum(self):
        self.lua.execute('''
            local S=CpUnloaderQueueSearch
            Q.refresh=function() end
            g_currentMission.vehicleSystem.vehicles={}
            local starts,work,frameWork=0,0,0
            local new,step=S.new,S.step
            S.new=function(...)
                starts=starts+1
                local state=assert(new(...))
                state.direct=nil -- actual A* fallback after a rejected direct candidate
                return state
            end
            S.step=function(s,budget)
                if not s.choices then frameWork=frameWork+0.5; work=work+0.5 end
                return step(s,budget)
            end
            openIntervalTimer=function() frameWork=0; return 1 end
            readIntervalTimerMs=function() return frameWork end
            Q.take(u,'prepare')
            Q.request(u,{x=0,z=60,t=0,arrival=true,choices={{x=0,z=60,t=0}}})
            local data=u.queueData; local search=data.search
            for i=1,1000 do
                g_updateLoopIndex=i; g_currentMission.time=i*30; Q.schedule()
                if not data.search then break end
            end
            assert(data.path and work>100 and work<1000,'finite fallback did not survive its quantum: '..work)
            assert(starts==1 and search.slots[1].fallback,'fallback recreated direct candidate')
            local poses=W.poses(data.world.model)
            for i=2,#data.path do poses=H.advance(data.world.model,poses,data.path[i]); assert(W.clear(data.world,poses)) end
        ''')

    def test_arrival_finishes_checked_fallback_after_more_than_one_second_cpu(self):
        self.lua.execute('''
            local S=CpUnloaderQueueSearch
            Q.refresh=function() end
            g_currentMission.vehicleSystem.vehicles={}
            local starts,work,frameWork=0,0,0
            local new,step=S.new,S.step
            S.new=function(...)
                starts=starts+1
                local state=assert(new(...))
                state.direct=nil -- actual A* fallback after a rejected direct candidate
                return state
            end
            S.step=function(s,budget)
                if not s.choices then frameWork=frameWork+2; work=work+2 end
                return step(s,budget)
            end
            openIntervalTimer=function() frameWork=0; return 1 end
            readIntervalTimerMs=function() return frameWork end
            Q.take(u,'prepare')
            Q.request(u,{x=0,z=60,t=0,arrival=true,choices={{x=0,z=60,t=0}}})
            local data=u.queueData; local search=data.search
            for i=1,20000 do
                g_updateLoopIndex=i; g_currentMission.time=i*30; Q.schedule()
                if not data.search then break end
            end
            assert(data.path and work>1000,'finite fallback did not survive its quantum: '..work)
            assert(starts==1 and search.slots[1].fallback,'fallback recreated direct candidate')
            local poses=W.poses(data.world.model)
            for i=2,#data.path do poses=H.advance(data.world.model,poses,data.path[i]); assert(W.clear(data.world,poses)) end
        ''')

    def test_expensive_arrival_candidate_cannot_starve_next_valid_route(self):
        self.lua.execute('''
            local S=CpUnloaderQueueSearch
            local goals={{x=0,z=50,t=0},{x=0,z=60,t=0}}
            local search=assert(S.choices(world,goals)); search.arrival=true; search.firstValid=true
            local new,step=S.new,S.step
            S.new=function(w,goal,corridor)
                if goal==goals[1] then return {expensive=true} end
                return new(w,goal,corridor)
            end
            S.step=function(s,budget) if s.expensive then return false end; return step(s,budget) end
            local done,path
            for i=1,10000 do
                local phase=S.choicePhase(search)
                done,path=S.step(search,1)
                if done then break end
                S.chargeChoices(search,0.1,phase)
            end
            assert(done and path and path.goal==goals[2],'nearby alternative starved')
            local poses=W.poses(world.model)
            for i=2,#path do poses=H.advance(world.model,poses,path[i]); assert(W.clear(world,poses)) end
        ''')

    def test_twelve_blocked_direct_entries_share_a_bounded_obstacle_search(self):
        self.lua.execute('''
            local S=CpUnloaderQueueSearch
            local goals={}
            for i=1,12 do goals[i]={x=0,z=50+i*3,t=0} end
            local search=assert(S.choices(world,goals)); search.arrival=true
            local new=S.new
            local states={}
            S.new=function(...)
                local state=assert(new(...)); state.direct=nil
                states[#states+1]=state; return state
            end
            local done,path,work
            for i=1,1200 do
                local phase=S.choicePhase(search)
                work=i; done,path=S.step(search,1)
                if done then break end
                S.chargeChoices(search,0.5,phase)
            end
            assert(done and path and work<1200,'shared parking search did not finish bounded fixture')
            assert(#states==12 and search.shared)
            local trees=0
            for _,state in ipairs(states) do if state.expanded>0 then trees=trees+1 end end
            assert(trees==1,'duplicate obstacle trees remain')
            local poses=W.poses(world.model)
            for i=2,#path do poses=W.advance(world.model,poses,path[i]); assert(W.clear(world,poses)) end
            assert(path.goal.accept==nil and math.abs(H.math.delta(path[#path].t,path.goal.t))<0.01)
        ''')

    def test_straight_exit_starts_without_combine_and_is_never_a_parking_slot(self):
        self.lua.execute('''
            Q.combines={}; Q.captureArrival(u)
            local data=Q.take(u,'prepare')
            local goal=assert(Q.target(u))
            assert(goal.transit and goal.straight and goal.z<40 and goal.x==0)
            Q.request(u,goal)
            local done,path,steps
            for i=1,1000 do
                steps=i; done,path=CpUnloaderQueueSearch.step(data.search,1)
                if done then break end
            end
            assert(done and path and steps<1000 and data.search.expanded==0)
            for _,p in ipairs(path) do assert(p.x==0 and p.t==0 and p.z>=0) end
            Q.startRoute(data,path)
            assert(Q.owns(u) and data.operation=='prepare','entry clearing changed queue ownership')
            place(goal.x,goal.z,goal.t); assert(Q.onLast(u))
            assert(data.arrivalDeparted and not data.parkedGoal and not data.path)
            assert(not Q.target(u),'temporary transit endpoint became a parking slot')
            local points={}; for z=-50,130 do points[#points+1]={x=15,z=z} end
            local course=Course(v,points,false)
            Q.combines={a={driver={fieldWorkCourse=course},position={x=15,z=100}}}
            u.isServingPosition=function() return true end
            local parked=assert(Q.target(u))
            assert(parked.parking and not parked.transit and parked.x==15)
            assert(math.abs(math.sin(parked.t))<0.01,'parking not parallel to centre row')
        ''')

    def test_transit_keeps_wide_clearance_from_a_distinct_return_marker(self):
        self.lua.execute('''
            Q.captureArrival(u); Q.take(u,'prepare')
            u.invertedStartPositionMarkerNode={x=12,z=28,t=0}
            local goal=Q.arrivalExit(u); local model=W.model(v)
            assert(goal.accept(W.settledPoses(model,goal),model),
                'pull-off target was left inside the distinct AD return lane')
            assert(not goal.accept(W.settledPoses(model,{x=0,z=26,t=0}),model),
                'short transit clearance weakened the distinct AD return lane')
            place(goal.x,goal.z,goal.t); assert(Q.arrivalClear(u))
        ''')

    def test_logged_arrival_and_saved_return_markers_produce_a_checked_exit(self):
        # Logged 3049 arrival; three distinct startPosition values in savegame20.
        # Body dimensions are the engine fixture, not a claim of exact live poses.
        for marker in ((-435.836121, -365.332764), (-433.976349, -355.294464),
                       (-434.645599, -356.307892)):
            with self.subTest(marker=marker):
                self.setUp()
                self.lua.globals().marker_x, self.lua.globals().marker_z = marker
                self.lua.execute('''
                    local origin={x=-451.1,z=-328.9,heading=math.rad(170.2)}
                    local polygon={}
                    for _,p in ipairs({{x=6,z=-100},{x=150,z=-100},{x=150,z=150},{x=6,z=150}}) do
                        polygon[#polygon+1]=CpUnloaderQueueGeometry.point(origin,p.x,p.z)
                    end
                    v.cpGetFieldPolygon=function() return polygon end
                    place(origin.x,origin.z,origin.heading)
                    AIUtil.getLength=function() return 6 end; u.turningRadius=9
                    u.invertedStartPositionMarkerNode={x=marker_x,z=marker_z,t=0}
                    Q.captureArrival(u); local data=Q.take(u,'prepare')
                    local model=W.model(v)
                    local x,z=H.math.position(model.root,0,26)
                    local old={x=x,z=z,t=model.root.t}
                    assert(not Q.stagingClear(u,W.settledPoses(model,old),model),
                        'fixture must reproduce the rejected 26 m destination')
                    local goal=assert(Q.arrivalExit(u))
                    assert(goal.accept(W.settledPoses(model,goal),model),
                        'computed exit still occupies the saved return marker')
                    Q.request(u,goal); assert(data.search,data.reason)
                    local done,path
                    for i=1,1000 do
                        done,path=CpUnloaderQueueSearch.step(data.search,1)
                        if done then break end
                    end
                    assert(done and path and data.search.expanded==0,
                        'arrival fell into the long parking fallback')
                    local poses=W.poses(data.world.model)
                    for i=2,#path do
                        poses=W.advance(data.world.model,poses,path[i]); assert(W.clear(data.world,poses))
                    end
                    assert(goal.accept(poses,data.world.model))
                    Q.startRoute(data,path); place(goal.x,goal.z,goal.t); assert(Q.onLast(u))
                    assert(data.arrivalDeparted and Q.arrivalClear(u) and not data.parkedGoal)
                ''')

    def test_pull_off_measures_long_trailer_and_ignores_remote_marker(self):
        self.lua.execute('''
            AIUtil.getLength=function() return 6 end; u.turningRadius=9
            trailer.size.length=24
            Q.captureArrival(u); Q.take(u,'prepare')
            local model=W.model(v)
            local goal=assert(Q.arrivalExit(u))
            assert(goal.accept(W.settledPoses(model,goal),model))
            place(goal.x,goal.z,goal.t)
            assert(Q.arrivalClear(u),'tractor cleared but long trailer still occupies arrival')
            place(0,0,0)
            u.invertedStartPositionMarkerNode={x=0,z=1000,t=0}
            assert(Q.arrivalExit(u).z==goal.z,'unrelated distant return marker enlarged pull-off')
        ''')

    def test_pull_off_continues_to_parallel_cleared_row_near_combine(self):
        self.lua.execute('''
            v.cpGetFieldPolygon=function()
                return {{x=6,z=-100},{x=150,z=-100},{x=150,z=200},{x=6,z=200}}
            end
            AIUtil.getLength=function() return 6 end; u.turningRadius=9
            u.invertedStartPositionMarkerNode={x=12,z=28,t=0}
            Q.captureArrival(u); local data=Q.take(u,'prepare')
            local points={}; for z=-50,180 do points[#points+1]={x=40,z=z} end
            local course=Course(v,points,false)
            local combine={fieldWorkCourse=course,course=course,
                getClosestFieldworkWaypointIx=function() return 201 end}
            Q.combines={a={driver=combine,position={x=40,z=150}}}
            u.isServingPosition=function() return true end
            local function follow(goal)
                Q.request(u,goal); assert(data.search,data.reason)
                local done,path,reason
                for i=1,10000 do
                    done,path,reason=CpUnloaderQueueSearch.step(data.search,1)
                    if done then break end
                end
                assert(done and path,tostring(reason))
                local poses=W.poses(data.world.model)
                for i=2,#path do
                    poses=W.advance(data.world.model,poses,path[i]); assert(W.clear(data.world,poses))
                end
                Q.startRoute(data,path)
                local destination=data.goal
                assert(destination.accept(poses,data.world.model))
                place(destination.x,destination.z,destination.t); assert(Q.onLast(u))
                return destination
            end
            assert(follow(assert(Q.target(u))).transit and not data.parkedGoal)
            local parked=follow(assert(Q.target(u)))
            assert(not parked.transit and data.parkedGoal==parked)
            assert(parked.x==40 and parked.z>0 and parked.z<150,
                'parking did not advance along a completed row towards the combine')
            assert(math.abs(math.sin(parked.t))<0.01,'rig parked across the harvested row')
            assert(Q.arrivalClear(u))
            assert(Q.target(u)==parked,'parallel waiting slot was not retained')
        ''')

    def test_blocked_verge_exit_keeps_opposite_approach_to_cleared_row(self):
        # The nearest twelve slots can all face forwards and need the same
        # obstructed loop. Rotate the physical field, crop and obstacle together.
        for angle in (0, 1.4):
            with self.subTest(angle=angle):
                yielding.YieldTests.setUp(self)
                self.lua.globals().arrivalAngle=angle
                self.lua.execute('''
                    local origin={x=119.1,z=-360.9,t=arrivalAngle}
                    local function point(x,z)
                        local px,pz=H.math.position(origin,x,z)
                        return {x=px,z=pz}
                    end
                    local function localX(x,z)
                        return (x-origin.x)*math.cos(origin.t)-(z-origin.z)*math.sin(origin.t)
                    end
                    v.cpGetFieldPolygon=function()
                        return {point(-100,-200),point(-6,-200),point(-6,30),point(-100,30)}
                    end
                    AIUtil.getLength=function() return 6 end; u.turningRadius=8
                    place(origin.x,origin.z,origin.t)
                    Q.target=nativeQueueTarget; Q.captureArrival(u)
                    local data=Q.take(u,'prepare')
                    local tree=point(0,30); tree.heading=origin.t
                    tree=G.rectangle(tree,{width=10,length=30},0)
                    overlapBox=function(x,y,z,rx,ry,rz,w,h,l,callback,detector)
                        local box=G.rectangle({x=x,z=z,heading=ry},{width=w*2,length=l*2},0)
                        detector.collidingShapes=G.overlap(box,tree) and 1 or 0
                    end
                    local raw=DensityMapModifier.new
                    DensityMapModifier.new=function(...)
                        local m=raw(...)
                        m.setParallelogramWorldCoords=function(self,ax,az,bx,bz,dx,dz)
                            self.crop=math.min(localX(ax,az),localX(bx,bz),localX(dx,dz),
                                localX(bx+dx-ax,bz+dz-az)) < -44
                        end
                        m.executeGet=function(self,filter)
                            return 0,(filter.mode==1 and self.crop) and 100 or 0,100
                        end
                        return m
                    end
                    Q.combines={}; u.isServingPosition=function() return true end
                    for j=0,3 do
                        local points={}; for z=-180,80 do points[#points+1]=point(-40-j*2,z) end
                        local course=Course(v,points,false)
                        local combine={fieldWorkCourse=course,course=course,
                            getClosestFieldworkWaypointIx=function() return 251 end}
                        Q.combines[j]={driver=combine,position=point(-40-j*2,70)}
                    end
                    local straight=assert(Q.target(u)); assert(straight.transit)
                    Q.request(u,straight)
                    assert(not data.search and not data.path and data.reason:find('obstacle'))
                    local goal=assert(Q.target(u)); assert(goal.parking and #goal.choices<=12)
                    local reversed={}; for j=0,3 do reversed[j]=Q.combines[3-j] end
                    Q.combines=reversed
                    local reordered=assert(Q.target(u))
                    assert(#reordered.choices==#goal.choices,'fleet order changed shortlist size')
                    for i,p in ipairs(goal.choices) do
                        local other=reordered.choices[i]
                        assert(p.x==other.x and p.z==other.z and p.t==other.t,
                            'fleet order changed arrival approaches')
                    end
                    Q.request(u,goal); local search=assert(data.search,data.reason)
                    local done,path,reason
                    for i=1,20000 do
                        done,path,reason=CpUnloaderQueueSearch.step(search,1)
                        if done or search.shared then break end
                    end
                    assert(done and path,'usable opposite-facing slot was lost: '..tostring(reason))
                    assert(not search.shared,'simple entry unnecessarily fell back to an obstacle tree')
                    local poses=W.poses(data.world.model)
                    for i=2,#path do
                        poses=W.advance(data.world.model,poses,path[i])
                        assert(W.clear(data.world,poses),'route crossed crop, obstacle or boundary')
                    end
                    Q.startRoute(data,path)
                    local parked=data.goal
                    assert(math.abs(H.math.delta(parked.t,origin.t+math.pi))<0.01)
                    assert(parked.accept(poses,data.world.model))
                    place(poses[1].x,poses[1].z,poses[1].t)
                    trailer.rootNode.x=poses[2].x; trailer.rootNode.z=poses[2].z; trailer.rootNode.t=poses[2].t
                    assert(Q.onLast(u) and data.parkedGoal and Q.arrivalClear(u))
                    assert(Q.target(u)==data.parkedGoal,'rig did not retain parallel parking')
                ''')

    def test_blocked_straight_exit_does_not_drive_or_loop(self):
        for obstacle in ('collision=1', 'densityCount=10'):
            with self.subTest(obstacle=obstacle):
                self.setUp()
                self.lua.execute('''
                    Q.combines={}; Q.captureArrival(u); local data=Q.take(u,'prepare')
                    local goal=Q.target(u)
                '''+obstacle+'''
                    Q.request(u,goal)
                    assert(not data.path and not data.search and not data.arrivalDeparted)
                    assert(data.arrivalExitRetry>g_currentMission.time and not Q.target(u))
                ''')


    def test_arrival_waits_for_fresh_boundary_before_first_search(self):
        self.lua.execute('''
            Q.refresh=function() end; Q.schedule=function() end
            Q.combines={}; Q.captureArrival(u)
            local ready=false
            v.cpIsFieldBoundaryDetectionRunning=function() return not ready end
            -- A previous job's polygon is still exposed during detection.
            v.cpGetFieldPolygon=function()
                if not ready then return {{x=-20,z=-20},{x=20,z=-20},{x=20,z=5},{x=-20,z=5}} end
                return {{x=-50,z=-50},{x=50,z=-50},{x=50,z=100},{x=-50,z=100}}
            end
            for i=1,72 do
                g_currentMission.time=i*34; Q.tick(u)
                assert(not u.queueData.world and not u.queueData.search and not u.queueData.path,
                    'arrival used the stale boundary while detection was running')
                assert(not u.queueData.failedGoals and not u.queueData.arrivalExitRetry)
            end
            ready=true; Q.tick(u)
            assert(u.queueData.search and u.queueData.goal.transit,
                'fresh boundary did not immediately permit the first pull-off')
            local done,path
            for i=1,1000 do
                done,path=CpUnloaderQueueSearch.step(u.queueData.search,1)
                if done then break end
            end
            assert(done and path,'fresh arrival was diverted into a parking search')
        ''')

    def test_straight_verge_exit_clears_arrival_without_expanding_parking_boundary(self):
        self.lua.execute('''
            -- Field lies to the right; the AD arrival faces along its edge.
            -- The native AI size may report only the tractor, while W models
            -- both bodies. A 26 m pull-off previously exceeded the entry gate.
            v.cpGetFieldPolygon=function()
                return {{x=6,z=-100},{x=150,z=-100},{x=150,z=150},{x=6,z=150}}
            end
            AIUtil.getLength=function() return 6 end; u.turningRadius=9
            Q.combines={}; Q.captureArrival(u); local data=Q.take(u,'prepare')
            local goal=assert(Q.arrivalExit(u)); assert(goal.z>26 and goal.z<50)
            local ordinary=assert(W.new(u))
            assert(not W.clear(ordinary,W.settledPoses(ordinary.model,goal)),
                'fixture no longer exposes the short entrance gate')
            Q.request(u,goal); assert(data.search,data.reason)
            local done,path
            for i=1,1000 do
                done,path=CpUnloaderQueueSearch.step(data.search,1)
                if done then break end
            end
            assert(done and path and data.search.expanded==0,'straight exit did not finish directly')
            local poses=W.poses(data.world.model)
            for i=2,#path do
                poses=W.advance(data.world.model,poses,path[i]); assert(W.clear(data.world,poses))
            end
            assert(goal.accept(poses,data.world.model),'trailer still occupies AD arrival')
            assert(not W.clear(data.world,W.settledPoses(data.world.model,{x=-30,z=26,t=0})),
                'straight exit admitted a sideways off-field excursion')
            assert(not W.clear(data.world,W.settledPoses(data.world.model,{x=0,z=goal.z+20,t=0})),
                'straight exit admitted an unbounded trip along the verge')
            Q.startRoute(data,path); place(goal.x,goal.z,goal.t); assert(Q.onLast(u))
            assert(data.arrivalDeparted and not data.parkedGoal)
            -- Once clear, parking must still use the field's existing boundary.
            local parking=assert(W.new(u))
            assert(not parking.entrance.transit)
            W.delete(ordinary); W.delete(parking)
        ''')

    def test_verge_pull_off_still_rejects_crop_obstacles_and_islands(self):
        for obstacle in ('densityCount=10', 'collision=1',
                         'v.cpGetIslandPolygons=function() return {{{x=-5,z=20},{x=5,z=20},{x=5,z=30},{x=-5,z=30}}} end'):
            with self.subTest(obstacle=obstacle):
                self.setUp()
                self.lua.execute('''
                    v.cpGetFieldPolygon=function()
                        return {{x=6,z=-100},{x=150,z=-100},{x=150,z=150},{x=6,z=150}}
                    end
                    AIUtil.getLength=function() return 6 end; u.turningRadius=9
                    Q.captureArrival(u); local data=Q.take(u,'prepare')
                    local goal=assert(Q.arrivalExit(u))
                '''+obstacle+'''
                    Q.request(u,goal)
                    assert(not data.search and not data.path and not data.arrivalDeparted)
                    assert(not data.reason:find('field boundary'),data.reason)
                ''')



    def test_verge_exit_uses_vehicle_heading_at_rotated_ad_arrivals(self):
        for angle in (90, 170, 270):
            with self.subTest(angle=angle):
                self.setUp()
                self.lua.globals().angle=angle
                self.lua.execute('''
                    local origin={x=-451.1,z=-328.9,heading=math.rad(angle)}
                    local polygon={}
                    for _,p in ipairs({{x=6,z=-100},{x=150,z=-100},{x=150,z=150},{x=6,z=150}}) do
                        polygon[#polygon+1]=CpUnloaderQueueGeometry.point(origin,p.x,p.z)
                    end
                    v.cpGetFieldPolygon=function() return polygon end
                    place(origin.x,origin.z,origin.heading)
                    AIUtil.getLength=function() return 6 end; u.turningRadius=9
                    Q.captureArrival(u); local data=Q.take(u,'prepare')
                    local goal=assert(Q.arrivalExit(u)); Q.request(u,goal)
                    assert(data.search,data.reason)
                    local done,path
                    for i=1,1000 do
                        done,path=CpUnloaderQueueSearch.step(data.search,1)
                        if done then break end
                    end
                    assert(done and path and data.search.expanded==0)
                    local poses=W.poses(data.world.model)
                    for i=2,#path do
                        poses=W.advance(data.world.model,poses,path[i]); assert(W.clear(data.world,poses))
                    end
                    assert(goal.accept(poses,data.world.model))
                ''')



    def test_boundary_wait_does_not_delay_full_or_manual_departure(self):
        self.lua.execute('''
            Q.refresh=function() end; Q.schedule=function() end
            v.cpIsFieldBoundaryDetectionRunning=function() return true end
            u.settings.fullThreshold={getValue=function() return 85 end}
            for _,full in ipairs({true,false}) do
                for _,owned in ipairs({true,false}) do
                    local departed=false
                    u.getAllTrailersFull=function() return full end
                    u.isDriveUnloadNowRequested=function() return not full end
                    u.startUnloadingTrailers=function() departed=true end
                    u.state=u.states.IDLE
                    if owned then Q.take(u,'prepare') end
                    Q.tick(u)
                    assert(departed,'boundary wait delayed native full/manual departure')
                end
            end
        ''')


if __name__ == '__main__':
    unittest.main()
