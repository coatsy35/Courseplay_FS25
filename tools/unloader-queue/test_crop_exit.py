"""Crop-overlap recovery with production geometry, search and rig kinematics."""
from pathlib import Path
import sys
import unittest

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE/'tools/unloader-queue'))
import test_runtime as runtime
runtime.ROOT = ROOT


class CropExitTests(unittest.TestCase):
    def setUp(self):
        runtime.EngineBoundaryTests.setUp(self)
        self.lua.execute("""
            Q,W,G,S=CpUnloaderQueue,CpUnloaderQueueWorld,CpUnloaderQueueGeometry,CpUnloaderQueueSearch
            crops={{x=0,z=0},{x=0,z=-9.8}}
            DensityMapModifier.new=function()
                return {setParallelogramWorldCoords=function(self,ax,az,bx,bz,dx,dz)
                    self.area={{x=ax,z=az},{x=bx,z=bz},{x=bx+dx-ax,z=bz+dz-az},{x=dx,z=dz}}
                end,executeGet=function(self,filter)
                    local count=0
                    if filter.mode==1 then
                        for _,p in ipairs(crops) do if G.inside(self.area,p) then count=count+1 end end
                    end
                    return 0,count,100
                end}
            end
            g_fruitTypeManager.getFruitTypes=function()
                return {{name='CANOLA',terrainDataPlaneId=1,startStateChannel=0,numStateChannels=4,cutStates={[11]=true}}}
            end
            W.delete(world)
            u.settings={reverseSpeed={getValue=function() return 8 end}}
            u.getFieldSpeed=function() return 15 end
            u.setMaxSpeed=function() end
            u.states={IDLE={}}
            u.ppc={getReverserNode=function() return trailer.steeringAxleNode end}
            Q.take(u,'prepare')
            world=assert(W.new(u)); poses=world.startPoses
            function solve(search)
                local done,path,why
                for i=1,10000 do done,path,why=S.step(search,4); if done then break end end
                return path,why
            end
        """)

    def test_forward_and_reverse_leave_existing_crop_and_finish_fully_clear(self):
        for reverse in (False, True):
            with self.subTest(reverse=reverse):
                self.setUp()
                self.lua.execute("""
                    assert(not W.clear(world,poses))
                    assert(W.beginCropExit(world))
                    original=world.cropExit
                """)
                self.lua.execute(f"""
                    local goal={{x=0,z={-30 if reverse else 30},t=0,reverse={str(reverse).lower()},straight={str(not reverse).lower()}}}
                    local search=assert(S.new(world,goal))
                    local path,why=solve(search); assert(path,why)
                    local live=poses
                    for i=2,#path do
                        live=W.advance(world.model,live,path[i])
                        assert(W.clear(world,live),'recovery entered new crop')
                        assert(world.cropExit==original,'recovery grew the original footprint')
                    end
                    assert(W.clear(world,live,nil,true),'recovery did not finish crop-free')
                    assert(math.abs(live[1].z-goal.z)<1.5)
                    for _,p in ipairs(live) do assert(math.abs(p.t)<math.rad(10)) end
                """)

    def test_new_crop_in_the_exit_strip_blocks_both_directions(self):
        for reverse in (False, True):
            with self.subTest(reverse=reverse):
                self.setUp()
                self.lua.execute(f"""
                    assert(W.beginCropExit(world))
                    crops[#crops+1]={{x=0,z={-16 if reverse else 6}}}
                    local goal={{x=0,z={-30 if reverse else 30},t=0,reverse={str(reverse).lower()},straight={str(not reverse).lower()}}}
                    local search=assert(S.new(world,goal)); search.directOnly=true
                    local path=solve(search); assert(not path,'crossed new standing crop')
                """)

    def test_old_footprint_is_not_an_allowed_parking_destination(self):
        self.lua.execute("""
            assert(W.beginCropExit(world))
            local search,reason,phase=S.new(world,{x=0,z=0,t=0})
            assert(not search and phase=='destination' and reason=='destination: standing crop')
            local escape=assert(S.escape(world,function() return true end,nil,false))
            local path,why=solve(escape); assert(path,why)
            local live=poses
            for i=2,#path do live=W.advance(world.model,live,path[i]) end
            assert(W.clear(world,live,nil,true),'escape completed while crop remained under the rig')
        """)

    def test_obstacles_islands_and_boundary_are_not_exempted(self):
        for obstruction in ("collision=1",
                            "world.boundary.islands={G.rectangle({x=0,z=0,heading=0},{width=1,length=1},0)}",
                            "world.boundary.polygon=G.rectangle({x=0,z=0,heading=0},{width=1,length=1},0);world.entrance=nil"):
            with self.subTest(obstruction=obstruction):
                self.setUp()
                self.lua.execute(obstruction+"; assert(not W.beginCropExit(world)); assert(not world.cropExit)")

    def test_bad_density_and_moving_capture_are_rejected(self):
        self.lua.execute("""
            u.vehicle.lastSpeedReal=0.005
            assert(not W.beginCropExit(world)); assert(not world.cropExit)
            u.vehicle.lastSpeedReal=0
            world.fruit[1].modifier.executeGet=function() return 0,0,0 end
            assert(not W.beginCropExit(world)); assert(not world.cropExit)
        """)

    def test_harvester_or_non_queue_operation_cannot_enable_crop_exit(self):
        for change in ("u.queueData.operation=nil",
                       "world.model.relative={}",
                       "world.finalParking={}"):
            with self.subTest(change=change):
                self.setUp()
                self.lua.execute(change+"; assert(not W.beginCropExit(world)); assert(not world.cropExit)")

    def test_request_reaches_parallel_parking_after_crop_start_failure(self):
        self.lua.execute("""
            Q.request(u,{x=0,z=30,t=0,straight=true,parking=true})
            local data=u.queueData
            assert(data.search and data.world.cropExit,'request still rejects the starting crop')
            local path,why=solve(data.search); assert(path,why)
            local live=data.world.startPoses
            for i=2,#path do live=W.advance(data.world.model,live,path[i]) end
            assert(W.clear(data.world,live,nil,true))
            assert(math.abs(live[1].z-30)<1.5)
        """)

    def test_new_crop_after_planning_is_rejected_by_live_body_validation(self):
        self.lua.execute("""
            assert(W.beginCropExit(world))
            local path=assert(solve(assert(S.new(world,{x=0,z=30,t=0,straight=true}))))
            local live=poses
            for i=2,#path do live=W.advance(world.model,live,path[i]) end
            crops[#crops+1]={x=live[2].x,z=live[2].z}
            assert(not W.clear(world,live),'live check ignored crop outside the original capture')
        """)

    def test_clipping_vertices_exactly_on_the_edge_are_kept_in_both_halves(self):
        self.lua.execute("""
            local diamond={{x=0,z=0},{x=2,z=2},{x=0,z=4},{x=-2,z=2}}
            local occupied={G.rectangle({x=2.5,z=2,heading=0},{width=5,length=6},0)}
            local pieces=G.outsideFootprints(diamond,occupied)
            assert(#pieces==1 and G.inside(pieces[1],{x=-1,z=2}))
            assert(G.inside(pieces[1],{x=0,z=0}) and G.inside(pieces[1],{x=0,z=4}))
        """)

    def test_actual_body_cannot_enter_crop_in_the_original_safety_halo(self):
        self.lua.execute("""
            local side=world.model.bodies[1].collision.left
            crops[#crops+1]={x=side+.15,z=0}
            assert(W.beginCropExit(world))
            local shifted={}
            for i,p in ipairs(poses) do shifted[i]={x=p.x+.2,z=p.z,t=p.t} end
            assert(not W.clear(world,shifted),'physical body entered crop in the old safety halo')
        """)

    def test_ai_marker_extension_is_not_exempted_as_physical_ground(self):
        self.lua.execute("""
            local body=world.model.bodies[1]
            local side=body.collision.left
            body.left=side+1
            crops[#crops+1]={x=side+.15,z=0}
            assert(W.beginCropExit(world))
            local shifted={}
            for i,p in ipairs(poses) do shifted[i]={x=p.x+.2,z=p.z,t=p.t} end
            assert(not W.clear(world,shifted),'hull entered crop originally only under an AI marker')
        """)

    def test_empty_density_pixels_in_a_thin_fragment_do_not_block_exit(self):
        self.lua.execute("""
            local modifier=world.fruit[1].modifier
            local execute=modifier.executeGet
            modifier.executeGet=function(self,filter)
                local a,b,d=self.area[1],self.area[2],self.area[4]
                local area=math.abs((b.x-a.x)*(d.z-a.z)-(b.z-a.z)*(d.x-a.x))
                if area<.05 then return 0,0,0 end
                return execute(self,filter)
            end
            assert(W.beginCropExit(world))
            local moved=W.advance(world.model,poses,{x=0,z=.001,t=0})
            assert(W.clear(world,moved),'zero-pixel sliver stranded the rig')
            modifier.executeGet=function() return 0,1,0 end
            assert(not W.clear(world,moved),'malformed density was allowed')
        """)

    def test_turning_exit_reaches_a_clear_parallel_row(self):
        self.lua.execute("""
            assert(W.beginCropExit(world))
            local search=assert(S.new(world,{x=30,z=40,t=math.pi/2}))
            local path,why=solve(search); assert(path,why)
            local live=poses
            for i=2,#path do
                live=W.advance(world.model,live,path[i])
                assert(W.clear(world,live),'turn entered fresh crop')
            end
            assert(W.clear(world,live,nil,true))
            for _,p in ipairs(live) do assert(math.abs(p.t-math.pi/2)<math.rad(10)) end
        """)

    def test_subtraction_covers_every_new_point_in_rotated_articulated_footprints(self):
        self.lua.execute("""
            math.randomseed(3054)
            local initial={G.rectangle({x=0,z=0,heading=.2},{width=3,length=6},.3),
                G.rectangle({x=-2,z=-8,heading=-.35},{width=3,length=7},.3)}
            for sample=1,40 do
                local box=G.rectangle({x=math.random()*10-5,z=math.random()*20-10,heading=math.random()*6},
                    {width=3,length=6},.3)
                local pieces=G.outsideFootprints(box,initial)
                for x=-10,10,.5 do for z=-18,15,.5 do
                    local p={x=x,z=z}
                    local isNew=G.inside(box,p) and not G.inside(initial[1],p) and not G.inside(initial[2],p)
                    local covered=false
                    for _,poly in ipairs(pieces) do
                        local cover=assert(G.coveringRectangle(poly))
                        for _,corner in ipairs(poly) do assert(G.inside(cover,corner),'crop query under-covers piece') end
                        if G.inside(poly,p) then covered=true end
                    end
                    assert(not isNew or covered,'new ground omitted from crop checks')
                    assert(not covered or G.inside(box,p),'subtraction invented outside ground')
                end end
            end
        """)


if __name__=='__main__': unittest.main()
