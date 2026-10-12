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

    def test_working_header_requests_clearance_before_proximity_and_keeps_course(self):
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,0,0)
            c.states={WORKING={}}; c.state=c.states.WORKING
            c.course=Course(harvester,{{x=0,z=0},{x=0,z=60}},true)
            local course=c.course
            place(0,30,math.pi); c.near=false
            Q.take(u,'prepare')
            Q.requestWorkingClearance(c)
            assert(u.queueData.operation=='yield' and c.course==course)
            local generation=u.queueData.generation
            g_currentMission.time=201
            Q.requestWorkingClearance(c); assert(u.queueData.generation==generation)
            place(0,46,0); g_currentMission.time=402
            Q.requestWorkingClearance(c); assert(u.queueData.yieldRequests[harvester],'trailing body still in header sweep')
            place(30,46,0); g_currentMission.time=603
            Q.requestWorkingClearance(c); assert(c.course==course)
        ''')

    def test_native_unloading_and_departure_are_not_seized(self):
        self.lua.execute('''
            c.states={WORKING={}}; c.state=c.states.WORKING
            c.course=Course(harvester,{{x=0,z=12},{x=0,z=-40}},true)
            Q.take(u,'prepare'); u.combineToUnload=harvester
            Q.requestWorkingClearance(c); assert(u.combineToUnload==harvester and u.queueData.operation=='prepare')
            u.combineToUnload=nil; u.queueData.nativeDeparture=true
            g_currentMission.time=201
            Q.requestWorkingClearance(c); assert(u.queueData.operation=='prepare')
        ''')

    def test_failed_yield_does_not_override_native_combine_speed_or_proximity_stop(self):
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,0,0)
            c.states={WORKING={}}; c.state=c.states.WORKING
            c.course=Course(harvester,{{x=0,z=0},{x=0,z=60}},true)
            place(0,30,math.pi); c.near=false
            Q.take(u,'prepare')
            Q.checkCombineTurns=function() return false end
            Q.checkParkedTrailerTravel=function() return false end
            Q.holdHeadlandCorner=function() return false end
            nativeSpeed=10
            AIDriveStrategyCombineCourse.getDriveData=function() return 12,34,true,nativeSpeed,0.8 end
        ''')
        # Run the production integration wrapper around the engine speed decision.
        hooks=(ROOT/'scripts/ai/CpUnloaderQueueHooks.lua').read_text()
        wrapper=hooks[hooks.index('local combineDrive ='):hooks.index('-- Preparation ends here.')]
        self.lua.execute('local Q=CpUnloaderQueue; local C=AIDriveStrategyCombineCourse; '+wrapper)
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
            -- A headland-free course must retain its existing centre-row
            -- option rather than holding at AD indefinitely.
            Q.combines.pool=nil; Q.combines.duplicate=nil; place(-70,0,0)
            goal=assert(Q.target(u))
            assert(not goal.arrival and goal.x==0)
        ''')


if __name__ == '__main__':
    unittest.main()
