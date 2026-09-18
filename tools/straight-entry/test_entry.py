"""Run real CP turn generation at a planar GIANTS boundary; no game-physics claim."""
import math
from pathlib import Path
import sys
import unittest

from lupa.lua52 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else SOURCE


class EntryTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().ROOT = ROOT.as_posix()
        self.lua.globals().SOURCE = SOURCE.as_posix()
        self.lua.execute((SOURCE / 'tools/straight-entry/engine-boundary.lua').read_text())

    def test_short_headland_handover_respects_corner_and_missing_continuation(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/handover-fixture.lua').read_text())
        # A short incoming leg followed by a lateral corner/return, like the JD
        # screenshot. Rotate and mirror to ensure this is not direction-specific.
        for side in [-1, 1]:
            for degrees in [0, 37, 90, 192, 270]:
                angle = math.radians(degrees)
                def world(x, z):
                    return (100+x*math.cos(angle)+z*math.sin(angle),
                            200-x*math.sin(angle)+z*math.cos(angle))
                points = []
                for x, z in [(0, 0), (0, 2), (side*4, 2), (side*4, -4), (0, 15)]:
                    x, z = world(x, z)
                    points.append(self.lua.table_from(dict(x=x, z=z)))
                pts = self.lua.table_from(points)
                def run(z, corner=2):
                    x, z = world(0, z)
                    return self.lua.globals().handoverFixture(pts, corner, x, z, angle)
                self.assertEqual(run(5), 'turn:2')  # forward point beyond corner must not skip it
                self.assertEqual(run(1), 'turn:2')  # corner itself is the next point
                self.assertEqual(run(-3), 'lookahead,wait,lower,work:1')
                self.assertEqual(run(30, 0), 'raise,stop:noPath')
                self.assertEqual(run(5, 0), 'lookahead,wait,lower,work:5')

    def test_saved_jd_headland_leg_is_shorter_than_rear_marker(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/handover-fixture.lua').read_text())
        # savegame18/CpAssignedCourses.xml, 8RT 410, first headland points.
        original = [(-61.40, -207.51), (-65.71, -206.82), (-64.69, -213.18),
                    (-63.65, -219.54), (-63.21, -222.26)]
        for side in [-1, 1]:
            coords = [(side*x, z) for x, z in original]
            dx, dz = coords[1][0]-coords[0][0], coords[1][1]-coords[0][1]
            length = math.hypot(dx, dz)
            self.assertLess(length, 10.3)
            points = self.lua.table_from([self.lua.table_from(dict(x=x,z=z)) for x,z in coords])
            for overrun in [5.5, 10.3, 12.0]:
                x, z = coords[0][0]+dx/length*overrun, coords[0][1]+dz/length*overrun
                result = self.lua.globals().handoverFixture(points, 1, x, z, math.atan2(dx,dz))
                self.assertEqual(result, 'turn:1')

    def test_headland_finish_checks_required_marker_distance_not_reserve(self):
        self.lua.execute("""
        function finishCheck(side, late, corner, front, back, boundaryEnabled)
            local node={x=0,z=0,t=0}
            local vehicle={getAIDirectionNode=function() return node end,
                cpGetFieldPolygon=function() if boundaryEnabled then return {
                    {x=-20,z=-20},{x=20,z=-20},{x=20,z=20},{x=-20,z=20}} end end}
            local context=setmetatable({vehicle=vehicle,workWidth=5.6,
                frontMarkerDistance=front,backMarkerDistance=back,
                isHeadlandCorner=function() return corner end},TurnContext)
            return context:getHeadlandFinishLimit(vehicle,{x=0,z=side*4,t=side==1 and 0 or math.pi},late) == nil
        end
        """)
        for side in [-1, 1]:
            run = self.lua.globals().finishCheck
            self.assertTrue(run(side, False, True, -4, -17.7, True))
            self.assertFalse(run(side, True, True, -4, -17.7, True))
            self.assertTrue(run(side, True, False, -4, -17.7, True))
            self.assertTrue(run(side, True, True, -4, -17.7, False))
            self.assertTrue(run(side, True, True, -1, -2, True))

    def test_unsafe_finish_raises_before_starting_checked_turn(self):
        self.lua.execute("""
        AIDriveStrategyCourse=AIDriveStrategyCourse or {onFinishRowEvent='finish'}
        for _, speed in ipairs({5,12,20,35}) do
            local events={}
            local node={x=0,z=0,t=0}
            local turn=setmetatable({workWidth=5.6,headlandFinishLimit=20,
                vehicle={getAIDirectionNode=function() return node end,getLastSpeed=function() return speed end},
                getRaiseImplementNode=function() return {x=0,z=0,t=0} end,debug=function() end,
                turnContext={isHeadlandCorner=function() return true end},
                workEndHandler={raiseImplementsAsNeeded=function() events[#events+1]='check' end,
                    allRaised=function() return false end},
                driveStrategy={raiseImplements=function() events[#events+1]='raise' end,
                    raiseControllerEvent=function() events[#events+1]='event' end},
                startTurn=function() events[#events+1]='turn' end},AITurn)
            turn:finishRow(16)
            assert(table.concat(events,',')=='check') -- keep working while there is room
            events={}; node.z=20-math.max(2.8,2*speed/3.6)
            assert(turn:finishRow(16)==false)
            assert(table.concat(events,',')=='raise,event,turn')
        end
        """)

    def test_pathfinder_tail_preserves_straight_row_and_reverse_behaviour(self):
        self.lua.execute("""
        for _, kind in ipairs({'straight','row','reverse','pastCorner'}) do
            local source=Course({},{{x=0,z=0},{x=0,z=5},{x=0,z=10},{x=0,z=20}},false)
            local finish=kind=='pastCorner' and 2 or -2
            local course=Course({},{{x=0,z=finish-1},{x=0,z=finish}},true)
            if kind=='reverse' then course.isForwardOnly=function() return false end end
            local context=setmetatable({fieldWorkCourse=source,turnEndWpIx=1,workWidth=5.6,
                frontMarkerDistance=-4,backMarkerDistance=-17.7,
                turnEndWpNode={node={x=0,z=0,t=0}},
                isHeadlandCorner=function() return kind~='row' end,
                appendEndingTurnCourse=function(_,c,extra)
                    assert(c==course and extra==0 and c:getNumberOfWaypoints()==2)
                    return 123
                end},TurnContext)
            assert(context:appendPathfinderEndingTurnCourse(course,0)==123)
        end
        """)

    def test_saved_pw100_curved_recovery_rejoins_actual_headland(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/handover-fixture.lua').read_text())
        # savegame18/CpAssignedCourses.xml, T7.300, 18 September 2026:
        # original headland waypoints 4411..4423; 4410 is the turn start.
        original=[(-100.79,-145.47),(-98.53,-143.20),(-96.75,-141.42),
                  (-94.75,-137.71),(-94.02,-133.29),(-93.81,-131.62),
                  (-94.69,-129.40),(-95.25,-127.64),(-95.64,-126.82),
                  (-97.08,-125.24),(-99.62,-121.63),(-102.92,-117.69),(-104.69,-115.59)]
        self.lua.execute("""
        function recoveryTail(points, nextCorner)
            local source=Course({},points,false)
            if nextCorner>0 then source.waypoints[nextCorner+1].attributes:setHeadlandTurn(true) end
            local node={x=points[1].x,z=points[1].z,t=math.atan2(points[2].x-points[1].x,points[2].z-points[1].z)}
            local ax,_,az=localToWorld(node,0,0,-12)
            local bx,_,bz=localToWorld(node,0,0,-11)
            local course=Course({},{{x=ax,z=az},{x=bx,z=bz}},true)
            local context=setmetatable({fieldWorkCourse=source,turnEndWpIx=1,
                frontMarkerDistance=-4,backMarkerDistance=-17.7,workWidth=5.6,
                turnEndWpNode={node=node},isHeadlandCorner=function() return true end,
                debug=function() end},TurnContext)
            local length=context:appendPathfinderEndingTurnCourse(course,0)
            return course,source,length
        end
        """)
        for side in [-1, 1]:
            for degrees in [0, 37, 90, 192, 270]:
                a=math.radians(degrees)
                coords=[(side*x*math.cos(a)+z*math.sin(a),-side*x*math.sin(a)+z*math.cos(a)) for x,z in original]
                pts=self.lua.table_from([self.lua.table_from(dict(x=x,z=z)) for x,z in coords])
                course,source,length=self.lua.globals().recoveryTail(pts,0)
                self.assertGreater(length,13.7)
                end=course.waypoints[len(course.waypoints)]
                self.assertAlmostEqual(end.x,coords[4][0])
                self.assertAlmostEqual(end.z,coords[4][1])
                # Real handover must accept the new tail along the curved pass.
                heading=math.atan2(coords[5][0]-coords[4][0],coords[5][1]-coords[4][1])
                result=self.lua.globals().handoverFixture(pts,0,end.x,end.z,heading)
                self.assertTrue(result.startswith('lookahead,wait,lower,work:'),result)
                # The former tangent extension misses this same saved pass.
                tangent=math.atan2(coords[1][0]-coords[0][0],coords[1][1]-coords[0][1])
                oldx=coords[0][0]+math.sin(tangent)*13.7
                oldz=coords[0][1]+math.cos(tangent)*13.7
                self.assertEqual(self.lua.globals().handoverFixture(pts,0,oldx,oldz,tangent),'raise,stop:noPath')
                for i,(x,z) in enumerate(coords,1):
                    self.assertAlmostEqual(source.waypoints[i].x,x)
                    self.assertAlmostEqual(source.waypoints[i].z,z)

                # A second pending corner truncates the tail and is not skipped.
                course,_,_=self.lua.globals().recoveryTail(pts,3)
                end=course.waypoints[len(course.waypoints)]
                self.assertAlmostEqual(end.x,coords[2][0])
                self.assertAlmostEqual(end.z,coords[2][1])

    def test_full_center_first_generator_connects_final_row_forward(self):
        self.lua.execute("""
        package.path=ROOT..'/scripts/courseGenerator/geometry/?.lua;'..
            ROOT..'/scripts/courseGenerator/genetic/?.lua;'..SOURCE..'/scripts/test/?.lua;'..package.path
        local attributes=CourseGenerator.WaypointAttributes
        require('CourseGenerator')
        CourseGenerator.WaypointAttributes=attributes
        dofile(SOURCE..'/scripts/courseGenerator/test/require.lua')
        Logger.debug=function() end; Logger.info=function() end; Logger.warning=function() end
        for _, clockwise in ipairs({false,true}) do
        for _, count in ipairs({1,3,6}) do
            local boundary=Polygon({{x=0,y=0},{x=250,y=0},{x=250,y=300},{x=0,y=300}})
            local field=CourseGenerator.Field('test',1,boundary)
            local context=CourseGenerator.FieldworkContext(field,4,9,count)
            context:setHeadlandFirst(false)
            context.headlandClockwise=clockwise
            context:setBypassIslands(false)
            context.autoRowAngle=false; context.rowAngle=math.rad(20)
            local course=CourseGenerator.FieldworkCourse(context)
            local blocks=course.center:getBlocks()
            local row=blocks[#blocks]:getLastRow()
            local a,b=row[#row-1],row[#row]
            local p=course:getHeadlandPath()[1]
            local dx,dy=b.x-a.x,b.y-a.y
            local ex,ey=p.x-b.x,p.y-b.y
            assert(math.abs(dx*ey-dy*ex)<0.001, 'headland connection is not collinear')
            assert(dx*ex+dy*ey>=-0.001, 'headland connection goes backwards')
            assert(course.center.path==nil, 'headland connection prematurely cached the centre path')
            assert(#course:getPath()>#row)
        end
        end
        """)

    def test_multi_vehicle_final_connections_follow_each_offset_lane(self):
        self.lua.execute("""
        package.path=ROOT..'/scripts/courseGenerator/geometry/?.lua;'..
            ROOT..'/scripts/courseGenerator/genetic/?.lua;'..SOURCE..'/scripts/test/?.lua;'..package.path
        local attributes=CourseGenerator.WaypointAttributes
        require('CourseGenerator')
        CourseGenerator.WaypointAttributes=attributes
        dofile(SOURCE..'/scripts/courseGenerator/test/require.lua')
        Logger.debug=function() end; Logger.info=function() end; Logger.warning=function() end
        local connector=CourseGenerator.HeadlandConnector.connectHeadlandsFromInside
        local connections={}
        local projected,fallbacks=0,0
        CourseGenerator.HeadlandConnector.connectHeadlandsFromInside=function(headlands,start,width,radius,approach)
            assert(approach and #approach>=2, 'missing offset lane')
            local polygon=headlands[#headlands]:getPolygon()
            local inside=polygon:isVectorInside(approach[#approach])
            local nearest=polygon:findClosestVertexToPoint(start)
            local fallback=polygon[nearest.ix]:clone()
            local result=connector(headlands,start,width,radius,approach)
            connections[result]={approach=approach,inside=inside,fallback=fallback}
            return result
        end
        for _, vehicles in ipairs({2,3,4,5}) do
        for _, clockwise in ipairs({false,true}) do
        for _, sameWidth in ipairs({false,true}) do
        for _, passes in ipairs({1,2}) do
            local boundary=Polygon({{x=0,y=0},{x=350,y=0},{x=350,y=400},{x=0,y=400}})
            local field=CourseGenerator.Field('multi',1,boundary)
            local context=CourseGenerator.FieldworkContext(field,4,9,vehicles*passes)
            context:setNumberOfVehicles(vehicles):setUseSameTurnWidth(sameWidth)
            context:setHeadlandFirst(false)
            context.headlandClockwise=clockwise
            context:setBypassIslands(false)
            context.autoRowAngle=false; context.rowAngle=math.rad(sameWidth and 70 or 20)
            local course=CourseGenerator.FieldworkCourseMultiVehicle(context)
            local seen={}
            for _, position, path in course:pathIterator() do
                local row=course:getCenterPath(position)
                local headland=course:getHeadlandPath(position)
                local a,b=row[#row-1],row[#row]
                local p=headland[1]
                local dx,dy=b.x-a.x,b.y-a.y
                local ex,ey=p.x-b.x,p.y-b.y
                local connection=connections[headland]
                assert(connection.approach==row, 'wrong vehicle offset lane was used')
                if connection.inside then
                    assert(math.abs(dx*ey-dy*ex)<0.001, 'offset lane connection is not collinear')
                    assert(dx*ex+dy*ey>=-0.001, 'offset lane connection goes backwards')
                    projected=projected+1
                else
                    -- The adjusted outer lane can already end past its assigned headland.
                    -- Keep the established fallback rather than project back across the field.
                    assert((p-connection.fallback):length()<0.001, 'outside-row fallback changed')
                    fallbacks=fallbacks+1
                end
                assert(path[#row].x==b.x and path[#row].y==b.y, 'final row was modified')
                assert(path[#row+1].x==p.x and path[#row+1].y==p.y)
                assert(#course.headlandsForVehicle[course:_positionToHeadlandIndex(position,clockwise)]==passes)
                assert(not seen[headland], 'vehicles share a headland path')
                seen[headland]=true
            end
        end
        end
        end
        end
        assert(projected>0 and fallbacks>0, 'exercise valid intersections and outside-row fallbacks')
        """)

    def test_multi_vehicle_headland_first_and_no_headland_courses_still_generate(self):
        self.lua.execute("""
        package.path=ROOT..'/scripts/courseGenerator/geometry/?.lua;'..
            ROOT..'/scripts/courseGenerator/genetic/?.lua;'..SOURCE..'/scripts/test/?.lua;'..package.path
        local attributes=CourseGenerator.WaypointAttributes
        require('CourseGenerator')
        CourseGenerator.WaypointAttributes=attributes
        dofile(SOURCE..'/scripts/courseGenerator/test/require.lua')
        Logger.debug=function() end; Logger.info=function() end; Logger.warning=function() end
        for _, vehicles in ipairs({2,3}) do
        for _, headlandFirst in ipairs({false,true}) do
            local boundary=Polygon({{x=0,y=0},{x=200,y=0},{x=200,y=220},{x=0,y=220}})
            local field=CourseGenerator.Field('multi',1,boundary)
            local context=CourseGenerator.FieldworkContext(field,4,9,headlandFirst and vehicles*2 or 0)
            context:setNumberOfVehicles(vehicles):setHeadlandFirst(headlandFirst)
            context:setBypassIslands(false)
            context.autoRowAngle=false; context.rowAngle=0
            local course=CourseGenerator.FieldworkCourseMultiVehicle(context)
            local count=0
            for _, position, path in course:pathIterator() do
                local center=course:getCenterPath(position)
                local headland=course:getHeadlandPath(position)
                assert(#center>0 and #path==#center+#headland)
                if headlandFirst then
                    assert(#headland>0 and path[1]==headland[1])
                    assert(path[#headland+1]==center[1])
                else
                    assert(#headland==0 and path[1]==center[1])
                end
                count=count+1
            end
            assert(count==vehicles)
        end
        end
        """)

    def load_headland_connector(self):
        self.lua.execute("""
        package.path=ROOT..'/scripts/courseGenerator/geometry/?.lua;'..package.path
        require('WrapAroundIndex'); require('Vertex'); require('LineSegment'); require('Polyline'); require('Polygon')
        require('HeadlandConnector')
        function connectRow(poly, row, directed)
            local polygon=Polygon(poly)
            local originalLength=polygon:getLength()
            local headland={polygon=polygon,getPolygon=function(self) return self.polygon end,
                getPath=function(self) return self.polygon end}
            local result=CourseGenerator.HeadlandConnector.connectHeadlandsFromInside(
                {headland},Vector(row[#row].x,row[#row].y),4,9,directed and row or nil)
            return result, originalLength
        end
        """)

    def test_row_headland_intersection_replaces_nearest_vertex_without_changing_coverage(self):
        self.load_headland_connector()
        for side in [-1, 1]:
            for angle in [0, .7, math.pi/2, 3.4]:
                def points(coords):
                    return self.lua.table_from([self.lua.table_from(dict(
                        x=side*x*math.cos(angle)-y*math.sin(angle),
                        y=side*x*math.sin(angle)+y*math.cos(angle))) for x,y in coords])
                polygon=points([(-10,-20),(10,-20),(10,5),(-10,15)])
                row=points([(0,-5),(0,0)])
                path,length=self.lua.globals().connectRow(polygon,row,True)
                expected=points([(0,10)])[1]
                self.assertAlmostEqual(path[1].x,expected.x)
                self.assertAlmostEqual(path[1].y,expected.y)
                self.assertEqual(len(path),6) # split edge, then close the single headland
                self.assertAlmostEqual(path.getLength(path),length)
                self.assertAlmostEqual(path[len(path)].x,path[1].x)
                self.assertAlmostEqual(path[len(path)].y,path[1].y)
                old,_=self.lua.globals().connectRow(polygon,row,False)
                self.assertGreater(math.hypot(old[1].x-path[1].x,old[1].y-path[1].y),1)

    def test_headland_projection_uses_first_exit_and_keeps_fallbacks(self):
        self.load_headland_connector()
        self.lua.execute("""
        local C=CourseGenerator.HeadlandConnector
        local square=function() return Polygon({{x=-10,y=-10},{x=10,y=-10},{x=10,y=10},{x=-10,y=10}}) end
        local p=square()
        assert(C.getForwardRowIntersection(p,{{x=0,y=0},{x=5,y=5}})==3)
        assert(#p==4) -- exact vertex, no duplicates
        p=square()
        local ix=C.getForwardRowIntersection(p,{{x=0,y=0},{x=0,y=-1}})
        assert(p[ix].x==0 and p[ix].y==-10) -- closing/lower edge
        assert(C.getForwardRowIntersection(square(),{{x=0,y=12},{x=0,y=13}})==nil)
        assert(C.getForwardRowIntersection(square(),{{x=0,y=12},{x=0,y=11}})==nil)
        assert(C.getForwardRowIntersection(square(),{{x=0,y=0},{x=0,y=0}})==nil)
        assert(C.getForwardRowIntersection(square(),{{x=0,y=0}})==nil)
        p=Polygon({{x=-10,y=-10},{x=10,y=-10},{x=10,y=20},{x=2,y=20},
            {x=2,y=5},{x=-2,y=5},{x=-2,y=20},{x=-10,y=20}})
        ix=C.getForwardRowIntersection(p,{{x=0,y=-5},{x=0,y=0}})
        assert(p[ix].x==0 and p[ix].y==5) -- first exit, not a distant lobe
        p=square()
        p[3]:getAttributes():setIslandBypass(true)
        assert(C.getForwardRowIntersection(p,{{x=0,y=-1},{x=0,y=0}})==nil)
        assert(#p==4)
        p=square()
        local origin=Vertex(0,0)
        origin.getAttributes=function() return {_getAtIsland=function() return {} end} end
        assert(C.getForwardRowIntersection(p,{{x=0,y=-1},origin})==nil)
        assert(#p==4)

        """)

    def test_saved_jd_transition_has_forward_collinear_connection(self):
        self.load_headland_connector()
        # Saved JD row end and adjacent headland edge from savegame18.
        self.lua.execute("""
        local row={{x=-42.74,y=-324.25},{x=-63.14,y=-208.59}}
        local polygon=Polygon({{x=-61.4,y=-207.51},{x=-65.71,y=-206.82},
            {x=-64.69,y=-213.18},{x=-40,y=-330},{x=-20,y=-330}})
        local ix=CourseGenerator.HeadlandConnector.getForwardRowIntersection(polygon,row)
        assert(ix)
        local p=polygon[ix]
        local dx,dy=row[2].x-row[1].x,row[2].y-row[1].y
        local ex,ey=p.x-row[2].x,p.y-row[2].y
        assert(math.abs(dx*ey-dy*ex)<0.0001)
        assert(dx*ex+dy*ey>0)
        assert(p.x < -61.4 and p.x > -65.71)
        """)

    def test_recovery_plough_lifts_then_centres_once_on_both_sides(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute("""
        PlowCenterTurnEvent={sendEvent=function(tool) tool.centres=(tool.centres or 0)+1; tool.playing=true end}
        for _, side in ipairs({0,1}) do
            for _, centre in ipairs({0.35,0.5,0.7}) do
                local f=preparationFixture(20,false,false)
                local c,t=f.controller,f.tool
                c.plowSpec.ai={centerPosition=centre}
                t.animation=side; t.lowered=true; t.allowed=false
                t.getIsLowered=function(self) return self.lowered end
                t.getIsPlowRotationAllowed=function(self) return self.allowed end
                c:onRecoveryStart()
                assert(not c:getRecoveryPreparationState() and t.centres==nil)
                t.lowered=false
                assert(not c:getRecoveryPreparationState() and t.centres==nil)
                t.allowed=true
                assert(not c:getRecoveryPreparationState() and t.centres==1)
                for i=1,100 do assert(not c:getRecoveryPreparationState()) end
                assert(t.centres==1)
                t.playing=false; t.animation=centre+0.05
                assert(not c:getRecoveryPreparationState()) -- stopped off-centre is not ready
                t.animation=centre
                assert(c:getRecoveryPreparationState())
                c:onRecoveryStart(); t.allowed=false
                assert(c:getRecoveryPreparationState() and t.centres==1) -- already centred needs no rotation
                t.animation=side; t.allowed=true
                assert(not c:getRecoveryPreparationState() and t.centres==2)
                c.plowSpec.rotationPart.turnAnimation=nil
                assert(c:getRecoveryPreparationState())
            end
        end
        """)

    def test_recovery_preparation_precedes_reverse_or_pathfinding(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute("""
        -- Only vehicle geometry/event boundaries are replaced; real recovery and
        -- base constructors, preparation dispatch and reverse Course run below.
        AIUtil.getSteeringParameters=function() return nil,12.5 end
        AIUtil.getLastAttachedImplement=function(v) return v end
        for _, allowReverse in ipairs({false,true}) do
            local f=preparationFixture(20,false,false)
            local events={}; local ready=false
            f.vehicle.rootNode=f.vehicle:getAIDirectionNode()
            f.strategy.raiseImplements=function() events[#events+1]='raise' end
            f.controller.onRecoveryStart=function() events[#events+1]='prepare' end
            f.controller.getRecoveryPreparationState=function() return ready end
            f.strategy.raiseControllerEventWithLambda=function(self,event,callback)
                for _, c in ipairs(self.controllers) do if c[event] then callback(c[event](c)) end end
            end
            f.strategy.getAllowReversePathfinding=function() return allowReverse end
            local ppc={registerListeners=function() end,setCourse=function() events[#events+1]='course' end,
                initialize=function() events[#events+1]='initialise' end}
            local proximity={registerBlockingObjectListener=function() end}
            local context={setStraightEntryDistance=function() end}
            local recovery=RecoveryTurn(f.vehicle,f.strategy,ppc,proximity,context,{},5.6,9,1)
            recovery.generatePathfinderTurn=function(self)
                self.state=self.states.WAITING_FOR_PATHFINDER; events[#events+1]='pathfinder'
            end
            assert(table.concat(events,',')=='raise,prepare')
            for i=1,20 do
                local _,_,_,speed=recovery:getDriveData(16)
                assert(speed==0)
                recovery:onBlocked() -- intentional animation wait cannot consume retries
            end
            assert(table.concat(events,',')=='raise,prepare' and recovery.retryCount==1)
            ready=true
            local _,_,_,speed=recovery:getDriveData(16)
            assert(speed==0)
            assert(table.concat(events,',')==(allowReverse and 'raise,prepare,pathfinder' or 'raise,prepare,course,initialise'))
            assert(recovery.workStartHandler.recoveryTurn)
        end
        """)

    def test_headland_recovery_waits_for_working_rotation_before_lowering(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute("""
        for _, side in ipairs({false,true}) do
            local f=preparationFixture(20,side,false)
            f.handler.recoveryTurn=true
            f.tool.rootNode.t=0
            f:position(-1)
            assert(f:drive()==0 and f.tool.rotateCount==1 and f.tool.lowerCount==0)
            f.tool.playing=false; f.tool.animation=side and 1 or 0
            assert(f:drive()==20 and f.tool.lowerCount==1)
        end
        """)

    def course(self, **overrides):
        p = dict(side=1, pike=.8, length=12.5, duration=1000,
                 speed=20, room=24, enabled=True)
        p.update(overrides)
        points, context, course = self.lua.globals().entryCourse(self.lua.table_from(p))
        return [dict(points[i]) for i in range(1, len(points) + 1)], context, course

    @staticmethod
    def straight_start(points):
        bends = [p for p in points if abs(math.atan2(math.sin(p['heading'] - math.pi),
                                                   math.cos(p['heading'] - math.pi))) > math.radians(5)]
        return bends[-1]['z']

    def test_recorded_turns_have_more_straight_approach_after_field_fitting(self):
        # Log-derived radius, marker distances, length and available room.
        # World positions are normalised, not a reconstruction of map collision geometry.
        for room, pike, length in [(24, .8, 12.5), (29, 3.3, 12.4)]:
            for side in [-1, 1]:
                for signed_pike in [pike, -pike]:
                    with self.subTest(room=room, side=side, pike=signed_pike):
                        args = dict(room=room, pike=signed_pike, length=length, side=side)
                        stock, _, _ = self.course(enabled=False, **args)
                        changed, _, _ = self.course(**args)
                        self.assertGreater(self.straight_start(changed), self.straight_start(stock))
                        _, hydraulic = self.lua.globals().TurnContext.getStraightEntryAllowance(length,1000,20)
                        lowering_z = signed_pike - 4 + hydraulic
                        straight = []
                        for p in reversed(changed):
                            if p['z'] > lowering_z + 1.5*length:
                                break
                            if p['z'] >= lowering_z:
                                straight.append(p)
                        self.assertGreater(len(straight), int(1.5*length)-1)
                        for p in straight:
                            self.assertAlmostEqual(p['x'], side*5.6, places=6)
                        self.assertFalse(changed[-1].get('reverse', False))
                        self.assertAlmostEqual(changed[-1]['x'], side * 5.6, places=6)
                        self.assertLess(changed[-1]['z'], signed_pike - 17.7)

    def test_geometry_speed_and_pike_sweep(self):
        # Exercise CP's actual solver, offsets, reverse fitting and appended work course.
        for length in [3, 8, 12.5, 20]:
            for speed in [6, 20, 35]:
                for room in [15, 24, 50, 100]:
                    for side in [-1, 1]:
                        for pike in [-20, 0, 20]:
                            with self.subTest(length=length, speed=speed, room=room, side=side, pike=pike):
                                pts, _, _ = self.course(length=length, speed=speed, room=room, side=side, pike=pike)
                                self.assertGreater(len(pts), 2)
                                self.assertTrue(all(math.isfinite(p[k]) for p in pts for k in ['x', 'z', 'heading']))
                                self.assertAlmostEqual(pts[-1]['x'], side * 5.6, places=6)
                                if not pts[-1].get('reverse', False):
                                    self.assertLess(pts[-1]['z'], pike)
                                # A pike is not a perpendicular field edge: stock CP
                                # adjusts its forward space estimate by half the row
                                # stagger. Reverse-ending legs use implement coordinates.
                                self.assertLessEqual(max(p['z'] for p in pts), 17.8 + room + pike / 2 + .5)

    def test_corner_targets_stay_stock_and_mounted_get_short_run_in(self):
        self.lua.execute('''
            local c=setmetatable({frontMarkerDistance=-4,turnEndForwardOffset=4,
                workStartNode={},vehicleAtTurnEndNode={}},TurnContext)
            c.debug=function() end
            for _,corner in ipairs({false,true}) do
                c.isHeadlandCorner=function() return corner end
                for _,length in ipairs({0,12.5}) do
                    if corner or length==0 then
                        c.straightEntryDistance=nil
                        local n,z=c:getTurnEndNodeAndOffsets(length)
                        c:setStraightEntryDistance(length,1000,20)
                        local nn,zz=c:getTurnEndNodeAndOffsets(length)
                        if corner then
                            assert(n==nn and z==zz and c.straightEntryDistance==nil)
                        else
                            assert(c.mountedStraightEntry and not c.entrySteeringLength)
                            assert(c.straightEntryDistance>6 and c.straightEntryDistance<11)
                            assert(zz<z)
                        end
                    end
                end
            end
        ''')

    def test_front_and_rear_markers_and_existing_larger_allowance(self):
        self.lua.execute('''
            for _,front in ipairs({-17.7,-4,3}) do
                local c=setmetatable({frontMarkerDistance=front,turnEndForwardOffset=-front,
                    workStartNode={},vehicleAtTurnEndNode={}},TurnContext)
                c.debug=function() end
                c.isHeadlandCorner=function() return false end
                local node,stock=c:getTurnEndNodeAndOffsets(12.5)
                c:setStraightEntryDistance(12.5,1000,20)
                local n,z=c:getTurnEndNodeAndOffsets(12.5)
                assert(n==node and z<stock)
                local position=front>0 and 0 or -front
                assert(position-z>=c.straightEntryDistance-1e-9)
            end
            local c=setmetatable({frontMarkerDistance=-100,turnEndForwardOffset=100,
                workStartNode={},vehicleAtTurnEndNode={}},TurnContext)
            c.debug=function() end; c.isHeadlandCorner=function() return false end
            c:setStraightEntryDistance(3,1000,20)
            local _,z=c:getTurnEndNodeAndOffsets(3)
            assert(z==-100) -- never shorten a stock allowance
        ''')

    def test_no_reverse_permission_does_not_expand_an_unfitting_turn(self):
        for side in [-1, 1]:
            stock, _, _ = self.course(enabled=False, allowReverse=False, side=side)
            changed, _, _ = self.course(allowReverse=False, side=side)
            self.assertEqual(stock, changed)
        stock, _, _ = self.course(enabled=False, allowReverse=False, room=100)
        changed, _, _ = self.course(allowReverse=False, room=100)
        self.assertGreater(self.straight_start(changed), self.straight_start(stock) + 5)

    def test_pathfinder_receives_the_same_reserved_approach(self):
        self.lua.execute('''
            local c=setmetatable({frontMarkerDistance=-4,turnEndForwardOffset=4,
                workStartNode={},vehicleAtTurnEndNode={}},TurnContext)
            c.debug=function() end; c.isHeadlandCorner=function() return false end
            c.getBoundaryId=function() return 'field' end
            c:setStraightEntryDistance(12.5,1000,20)
            local expectedNode,expectedOffset=c:getTurnEndNodeAndOffsets(12.5)
            local s={getFrontAndBackMarkers=function() return -4,-17.7 end,
                getAllowReversePathfinding=function() return false end,
                getWorkWidth=function() return 5.6 end,
                isTurnOnFieldActive=function() return true end,
                setPathfindingDoneCallback=function() end}
            local t=setmetatable({turnContext=c,steeringLength=12.5,driveStrategy=s,
                vehicle={},turningRadius=9,states={WAITING_FOR_PATHFINDER={}},debug=function() end},CourseTurn)
            local saved=PathfinderUtil.findPathForTurn
            PathfinderUtil.findPathForTurn=function(v,x,node,z,r,reverse)
                assert(node==expectedNode and z==expectedOffset and r==9 and reverse==false)
                return {},{done=false}
            end
            g_currentMission.time=0
            t:generatePathfinderTurn(false)
            assert(t.state==t.states.WAITING_FOR_PATHFINDER)
            PathfinderUtil.findPathForTurn=saved
        ''')

    def test_independent_passive_trailer_settling_estimate(self):
        # Numerical integration, rather than repeating the production closed-form
        # expression. This verifies the distance estimate only, not GIANTS dynamics.
        for length in [3, 8, 12.5, 20]:
            for speed in [6, 20, 35]:
                _, c, _ = self.course(length=length, speed=speed, room=1000)
                available = c.straightEntryDistance - (speed / 3.6 + .5)
                for error in [-90, -45, 30, 90]:
                    for length_error in [.85, 1, 1.15]:
                        angle = math.radians(error)
                        steps = math.ceil(available / .01)
                        ds = available / steps
                        for _ in range(steps):
                            angle -= ds * math.sin(angle) / (length * length_error)
                        self.assertLess(abs(math.degrees(angle)), 8)

    def test_production_constructor_sets_allowance_and_preserves_speed_selection(self):
        self.lua.execute('''
            local saved=AITurn.init
            local function setting(v) return {getValue=function() return v end} end
            AITurn.init=function(t,v,s,ppc,prox,c,w)
                t.turnContext=c; t.steeringLength=12.5; t.driveStrategy=s
                t.settings={turnSpeed=setting(20),fieldSpeed=setting(30),reverseSpeed=setting(8)}
            end
            local c=setmetatable({},TurnContext)
            c.debug=function() end; c.isHeadlandCorner=function() return false end
            local t=CourseTurn({}, {getLoweringDurationMs=function() return 1000 end}, {}, {}, c, {}, 5.6)
            AITurn.init=saved
            assert(c.straightEntryDistance>35)
            assert(t:getForwardSpeed()==20 and t:getReverseSpeed()==8)
            t.turnCourse={getCurrentWaypointIx=function() return 10 end,
                getDistanceFromFirstWaypoint=function() return 50 end,
                getDistanceToLastWaypoint=function() return 50 end}
            assert(t:getForwardSpeed()==30)
            t.turnCourse.getDistanceToLastWaypoint=function() return 10 end
            assert(t:getForwardSpeed()==20)
        ''')

    def test_all_runtime_lua_compiles(self):
        compile_lua = self.lua.eval('function(s,n) local f,e=load(s,n); return f~=nil,e end')
        for file in ROOT.rglob('*.lua'):
            if any(p in {'tools', 'test', 'tests', 'out', '.git'} for p in file.relative_to(ROOT).parts):
                continue
            ok, error = compile_lua(file.read_text(encoding='utf-8-sig'), str(file))
            self.assertTrue(ok, error)

    def test_turnover_preserves_run_in_before_lowering_and_handover(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute('''
            for _,speed in ipairs({6,20,35}) do
                for _,side in ipairs({false,true}) do
                    for _,duration in ipairs({1,7,15}) do
                        for _,dt in ipairs({16,33,100}) do
                            local f=preparationFixture(speed,side,true)
                            assert(f:drive()==0 and f.tool.playing and f.tool.wanted==side)
                            -- Replay variable animation lengths through the real turn loop.
                            for elapsed=0,duration*1000,dt do
                                f.tool.animation=.5 + (side and -1 or 1)*.49*elapsed/(duration*1000)
                                assert(f:drive()==0)
                                assert(f.tool.lowerCount==0 and f.turn.resumed==0)
                            end
                            f.tool.animation=side and 0 or 1
                            -- Endpoint alone is insufficient while the animation is active.
                            assert(f:drive()==0 and f.tool.lowerCount==0)
                            f.tool.playing=false
                            assert(f:drive()==speed and f.tool.lowerCount==0)
                            -- Driving is needed to settle; do not wait stationary for alignment.
                            f:position(-20)
                            assert(f:drive()==speed and f.tool.lowerCount==0)
                            f:position(-.2)
                            assert(f:drive()==speed and f.tool.lowerCount==1 and f.turn.resumed==1)
                            assert(f.tool.rotateCount==1)
                        end
                    end
                end
            end
        ''')

    def test_turnover_blocks_lowering_even_when_marker_reaches_work_start(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute('''
            local f=preparationFixture(20,false,true)
            f:position(-.1)
            assert(f:drive()==0 and f.tool.lowerCount==0 and f.turn.resumed==0)
            f.tool.playing=false; f.tool.animation=1
            assert(f:drive()==20 and f.tool.lowerCount==1 and f.turn.resumed==1)
        ''')

    def test_unstarted_turnover_does_not_deadlock_alignment(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute('''
            local f=preparationFixture(20,false,true)
            f.tool.rootNode.t=math.rad(60)
            assert(f:drive()==20 and f.tool.rotateCount==0 and f.tool.lowerCount==0)
            f.tool.rootNode.t=math.rad(20)
            assert(f:drive()==0 and f.tool.rotateCount==1)
        ''')

    def test_plain_stock_entry_and_nonrotating_tools_do_not_wait(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute('''
            local stock=preparationFixture(20,false,false)
            assert(stock:drive()==20) -- original startup/corner contexts
            local fixed=preparationFixture(20,false,true)
            fixed.controller.plowSpec.rotationPart.turnAnimation=nil
            assert(fixed:drive()==20 and fixed.tool.rotateCount==0)
            -- A generic work-readiness check must not hold a tool that needs lowering.
            fixed.strategy.controllers[2]={canContinueWork=function() return false end}
            fixed:position(-.1)
            assert(fixed:drive()==20 and fixed.tool.lowerCount==1)
        ''')

    def test_entry_has_no_kick_and_preserves_existing_curve(self):
        self.lua.execute('''
            for _,length in ipairs({0,3,12.5,20}) do
                for _,speed in ipairs({6,20,35}) do
                    for _,side in ipairs({-1,1}) do
                        for _,start in ipairs({true,false}) do
                            local v={}
                            local c=setmetatable({vehicle=v,workWidth=5.6,turnStartWpIx=1,
                                turnEndWpIx=start and 1 or 2,
                                workStartNode={x=0,z=0,t=0},vehicleAtTurnEndNode={x=0,z=4,t=0},
                                frontMarkerDistance=-4,backMarkerDistance=-17.7},TurnContext)
                            c.isHeadlandCorner=function() return false end
                            c:setStraightEntryDistance(length,1000,speed)
                            local path=Course(v,{{x=side*4,z=-50},{x=side,z=-45},{x=0,z=-40}},true)
                            c:appendEndingTurnCourse(path,length)
                            assert(path.waypoints[1].x==side*4 and path.waypoints[1].z==-50)
                            assert(path.waypoints[2].x==side and path.waypoints[2].z==-45)
                            assert(path.waypoints[3].x==0 and path.waypoints[3].z==-40)
                            for i=4,path:getNumberOfWaypoints() do
                                assert(math.abs(path.waypoints[i].x)<1e-9)
                                assert(path.waypoints[i].z>path.waypoints[i-1].z)
                            end
                        end
                    end
                end
            end
        ''')

    def test_towed_turnover_starts_on_straight_with_unequal_headings(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute("""
            for _,speed in ipairs({6,20,35}) do
                for _,side in ipairs({-1,1}) do
                    for _,toolHeading in ipairs({-29,-20,0,20,29}) do
                        local f=preparationFixture(speed,side<0,true)
                        f.tool.rootNode.t=math.rad(toolHeading)
                        f.vehicle:getAIDirectionNode().t=side*math.rad(5.1)
                        assert(f:drive()==speed and f.tool.rotateCount==0 and f.tool.lowerCount==0)
                        f.vehicle:getAIDirectionNode().t=side*math.rad(4.9)
                        -- Still 28 m before work: deployment must not require
                        -- the plough root to match the tractor within 15 degrees.
                        assert(f:drive()==0 and f.tool.rotateCount==1 and f.tool.lowerCount==0)
                        assert(f.tool.wanted==(side<0))
                        assert(f:drive()==0 and f.tool.rotateCount==1)
                        f.tool.playing=false; f.tool.animation=1
                        assert(f:drive()==speed and f.tool.lowerCount==0)
                        f:position(-.1)
                        assert(f:drive()==speed and f.tool.lowerCount==1)
                    end
                end
            end
            -- Keep the stock implement-to-row condition and reverse behaviour.
            local f=preparationFixture(20,false,true)
            f.tool.rootNode.t=math.rad(31)
            assert(f:drive()==20 and f.tool.rotateCount==0)
            f.tool.rootNode.t=math.rad(29)
            f.controller:onTurnEndProgress({x=0,z=0,t=0},true,false,false)
            assert(f.tool.rotateCount==0)
            assert(f:drive()==0 and f.tool.rotateCount==1)
            local mounted=preparationFixture(20,false,true)
            mounted.controller.towed=false
            mounted.vehicle:getAIDirectionNode().t=math.rad(-20)
            assert(mounted:drive()==0 and mounted.tool.rotateCount==1)
        """)

    def test_turnover_trigger_is_independent_of_world_heading(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute("""
            for _,heading in ipairs({-179,-95,-45,45,95,179}) do
                for _,side in ipairs({-1,1}) do
                    local f=preparationFixture(20,side<0,true)
                    local target=f.turn:getLowerImplementNode()
                    local angle=math.rad(heading)
                    for _,node in ipairs({target,f.vehicle:getAIDirectionNode(),f.tool.rootNode,
                            f.tool.left,f.tool.right,f.tool.back}) do
                        local x,z=node.x,node.z
                        node.x=x*math.cos(angle)+z*math.sin(angle)
                        node.z=-x*math.sin(angle)+z*math.cos(angle)
                        node.t=node.t+angle
                    end
                    f.tool.rootNode.t=angle+side*math.rad(25)
                    f.vehicle:getAIDirectionNode().t=angle+side*math.rad(6)
                    assert(f:drive()==20 and f.tool.rotateCount==0)
                    f.vehicle:getAIDirectionNode().t=angle
                    assert(f:drive()==0 and f.tool.rotateCount==1 and f.tool.lowerCount==0)
                    f.tool.animation=1; f.tool.playing=false
                    assert(f:drive()==20 and f.tool.lowerCount==0)
                end
            end
        """)

    def test_bulb_gains_a_little_more_crossing_distance(self):
        self.lua.execute("""
            for _,side in ipairs({-1,1}) do
                local a={x=0,z=17.8,t=0}; local b={x=side*5.6,z=42,t=math.pi}
                local path,_,solution=PathfinderUtil.findAnalyticPath(PathfinderUtil.dubinsSolver,a,0,0,b,0,0,9)
                local _,across=BulbTurnExtension.extend(path,solution,5.6,12.5,18)
                assert(math.abs(across-2.8)<1e-7)
                local _,tight=BulbTurnExtension.extend(path,solution,5.6,12.5,2)
                assert(tight<across)
            end
        """)

    def test_bulb_extension_preserves_prefix_radius_and_row_join(self):
        self.lua.execute("""
            for _,side in ipairs({-1,1}) do
                for _,radius in ipairs({4.7,9,14}) do
                    for _,available in ipairs({0,2,20}) do
                        local a={x=0,z=17.8,t=0}
                        local b={x=side*5.6,z=60,t=math.pi}
                        local path,_,solution=PathfinderUtil.findAnalyticPath(PathfinderUtil.dubinsSolver,a,0,0,b,0,0,radius)
                        local changed,across=BulbTurnExtension.extend(path,solution,5.6,12.5,available)
                        if available==0 then
                            assert(changed==path and across==0)
                        else
                            assert(across>0)
                            local cut=solution:getLength(radius)-radius*math.pi/2
                            local step=solution:getLength(radius)/(#path-1)
                            for i=1,#path do
                                if (i-1)*step>=cut then break end
                                assert(changed[i]==path[i], 'original bulb prefix changed')
                            end
                            local last=changed[#changed]
                            assert(math.abs(last.x-side*5.6)<1e-7)
                            assert(last.y+60>0 and last.y+60<=available+1e-7)
                            assert(math.abs(math.sin(last.t-math.pi/2))<1e-7)
                            local farthest=0
                            for i=2,#changed do
                                local p,q=changed[i-1],changed[i]
                                local d=math.sqrt((q.x-p.x)^2+(q.y-p.y)^2)
                                assert(d>0 and d<1.1, 'gap or duplicate at join')
                                local angle=math.abs(math.atan2(math.sin(q.t-p.t),math.cos(q.t-p.t)))
                                assert(2*math.sin(angle/2)/d<=1/radius+1e-7, 'radius tightened')
                                farthest=math.max(farthest,side*q.x-5.6)
                            end
                            assert(farthest>across*.95, 'did not cross beyond the row')
                        end
                        local mounted=BulbTurnExtension.extend(path,solution,5.6,0,20)
                        assert(mounted==path)
                    end
                end
            end
        """)

    def test_extended_bulb_is_checked_against_field_boundary(self):
        self.lua.execute("""
            local a={x=0,z=17.8,t=0}; local b={x=5.6,z=42,t=math.pi}
            local path,_,solution=PathfinderUtil.findAnalyticPath(PathfinderUtil.dubinsSolver,a,0,0,b,0,0,9)
            local changed,across=BulbTurnExtension.extend(path,solution,5.6,12.5,18)
            local boundary={polygon={{x=-100,z=-100},{x=6.5,z=-100},{x=6.5,z=100},{x=-100,z=100}},margin=0,islands={}}
            assert(across>1)
            local original={}
            for i,p in ipairs(path) do original[i]=table.clone(p) end
            assert(FieldworkBoundary.containsCourse(boundary,Course.createFromAnalyticPath({},original,true)))
            assert(not FieldworkBoundary.containsCourse(boundary,Course.createFromAnalyticPath({},changed,true)))
        """)

    def test_bulb_extension_reduces_trailer_error_before_work(self):
        build=self.lua.eval("""function(side,length)
            local a={x=0,z=17.8,t=0}; local b={x=side*5.6,z=42,t=math.pi}
            local path,_,solution=PathfinderUtil.findAnalyticPath(PathfinderUtil.dubinsSolver,a,0,0,b,0,0,9)
            local changed,across=BulbTurnExtension.extend(path,solution,5.6,length,18)
            return path,changed,across
        end""")
        def residual(path, side, length):
            points=[dict(path[i]) for i in range(1,len(path)+1)]
            points.append(dict(x=side*5.6,y=-2))
            theta=-math.pi/2
            for a,b in zip(points,points[1:]):
                dx,dy=b['x']-a['x'],b['y']-a['y']
                distance=math.hypot(dx,dy)
                heading=math.atan2(dy,dx)
                steps=max(1,math.ceil(distance/.02))
                for _ in range(steps):
                    theta+=distance/steps/length*math.sin(heading-theta)
            return abs(length*math.cos(theta))
        for side in [-1,1]:
            for length in [12.5,20]:
                original,changed,across=build(side,length)
                self.assertGreater(across,0)
                self.assertLess(residual(changed,side,length),residual(original,side,length))

    def test_mounted_lowering_waits_for_heading_without_stopping_alignment(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute('''
            for _,speed in ipairs({6,20,35}) do
                for _,side in ipairs({-1,1}) do
                    local f=preparationFixture(speed,false,true)
                    f.controller.plowSpec.rotationPart.turnAnimation=nil
                    f.turn.turnContext.mountedStraightEntry=true
                    local node={x=0,z=0,t=side*math.rad(30)}
                    f.vehicle.getAIDirectionNode=function() return node end
                    f:position(-.1)
                    assert(f:drive()==speed and f.tool.lowerCount==0 and f.turn.resumed==0)
                    node.t=side*math.rad(5.1)
                    assert(f:drive()==speed and f.tool.lowerCount==0)
                    node.t=side*math.rad(4.9)
                    assert(f:drive()==speed and f.tool.lowerCount==1 and f.turn.resumed==1)
                end
            end
            -- Reverse entry retains stock lowering/direction-change semantics.
            local f=preparationFixture(20,false,true)
            f.controller.plowSpec.rotationPart.turnAnimation=nil
            f.turn.turnContext.mountedStraightEntry=true
            f.vehicle.getAIDirectionNode=function() error('reverse must not use forward heading gate') end
            f.turn.ppc.isReversing=function() return true end
            f:position(-1)
            assert(f.turn:endTurn(33) and f.tool.lowerCount==1 and f.turn.resumed==1)
        ''')

    def test_mounted_approach_is_short_and_speed_scaled(self):
        for speed in [6, 20, 35]:
            for side in [-1, 1]:
                points, context, _ = self.course(length=0, speed=speed, side=side, room=21)
                self.assertTrue(context['mountedStraightEntry'])
                self.assertIsNone(context['entrySteeringLength'])
                self.assertLess(context['straightEntryDistance'], 15)
                self.assertAlmostEqual(points[-1]['x'], side*5.6, places=6)
        settle, hydraulic = self.lua.globals().TurnContext.getStraightEntryAllowance(0, 1000, 20, 4.7)
        self.assertAlmostEqual(settle+hydraulic, 8.4055555556, places=5)

    def test_field_boundary_fits_run_in_and_rejects_crossing_segments(self):
        self.lua.execute('''
            local b={polygon={{x=-20,z=-20},{x=20,z=-20},{x=20,z=40},{x=-20,z=40}},margin=2,islands={}}
            assert(FieldworkBoundary.fitOffset(b,0,0,0,-45)==-18)
            assert(FieldworkBoundary.fitOffset(b,0,0,0,-10)==-10)
            assert(not FieldworkBoundary.contains(b,19,0))
            b.islands={{{x=-2,z=-2},{x=2,z=-2},{x=2,z=2},{x=-2,z=2}}}
            local cross=Course({},{{x=-10,z=0},{x=10,z=0}},true)
            assert(not FieldworkBoundary.containsCourse(b,cross))
            local clear=Course({},{{x=-10,z=10},{x=10,z=10}},true)
            assert(FieldworkBoundary.containsCourse(b,clear))
        ''')

    def test_boundary_applies_to_analytic_pathfinder_nodes_and_startup_fallback(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/startup-fixture.lua').read_text())
        self.lua.execute('''
            PathfinderConstraintInterface={}
            require('PathfinderConstraints')
            local b={polygon={{x=-20,z=-20},{x=20,z=-20},{x=20,z=40},{x=-20,z=40}},margin=2,islands={}}
            local constraints=setmetatable({fieldworkBoundary=b},PathfinderConstraints)
            -- Even analytic nodes marked offFieldValid must respect the explicit boundary.
            assert(not constraints:isValidNode({x=30,y=0},false,true))
            local s,c=startupFixture(12.5,20,-4)
            s.vehicle.cpGetFieldPolygon=function() return b.polygon end
            s:startCourseWithPathfinding(c,1)
            assert(s.request.z >= -17.2 and s.request.z < -16)
            local stopped,started=false,false
            s.vehicle.stopCurrentAIJob=function() stopped=true end
            AIMessageCpErrorNoPathFound={new=function() return {} end}
            s.startCourse=function() started=true end
            local outside=Course({},{{x=0,z=0},{x=30,z=0}},true)
            outside.adjustForTowedImplements=function() end
            s:onPathfindingFinished(nil,true,outside)
            assert(stopped and not started)
            stopped=false
            s.createAlignmentCourse=function() return outside end
            s:onPathfindingFinished(nil,false,nil)
            assert(stopped and not started)
        ''')

    def test_normal_calculated_turn_outside_boundary_uses_pathfinder(self):
        self.lua.execute('''
            local polygon={{x=-20,z=-20},{x=20,z=-20},{x=20,z=40},{x=-20,z=40}}
            local t=setmetatable({vehicle={cpGetFieldPolygon=function() return polygon end},
                workWidth=4,turningRadius=9,debug=function() end,
                turnContext={isHeadlandCorner=function() return false end,isPathfinderTurn=function() return false end},
                settings={allowPathfinderTurns={getValue=function() return false end}},
                states={TURNING={},WAITING_FOR_PATHFINDER={}}},CourseTurn)
            AITurn.canTurnOnField=function() return true end
            t.generateCalculatedTurn=function(self)
                self.turnCourse=Course({},{{x=0,z=0},{x=30,z=0}},true)
            end
            local searched=false
            t.generatePathfinderTurn=function(self) searched=true; self.state=self.states.WAITING_FOR_PATHFINDER end
            t:startTurn()
            assert(searched and t.state==t.states.WAITING_FOR_PATHFINDER)
        ''')

    def test_boundary_fit_reduces_optional_entry_and_restores_failed_attempts(self):
        self.lua.execute("""
            for _,side in ipairs({-1,1}) do
                local polygon={{x=-20,z=-20},{x=20,z=-20},{x=20,z=40},{x=-20,z=40}}
                local c={straightEntryDistance=40,isHeadlandCorner=function() return false end}
                local t=setmetatable({vehicle={cpGetFieldPolygon=function() return polygon end},
                    turnContext=c,workWidth=4,debug=function() end},CourseTurn)
                local tries=0
                t.generateCalculatedTurn=function(self)
                    tries=tries+1
                    self.turnCourse=Course({},{{x=0,z=0},{x=side*c.straightEntryDistance,z=15}},true)
                end
                t:generateCalculatedTurn()
                assert(t:fitCalculatedTurnToBoundary())
                assert(c.straightEntryDistance==10 and c.disableBulbExtension and tries==5)
                assert(FieldworkBoundary.containsCourse(FieldworkBoundary.forVehicle(t.vehicle,4),t.turnCourse))
                -- Last fallback is the stock target, not a disabled preparation
                -- flag (zero remains truthy in Lua).
                polygon[1].x=-4; polygon[2].x=4; polygon[3].x=4; polygon[4].x=-4
                c.straightEntryDistance=40; c.disableBulbExtension=nil
                t:generateCalculatedTurn()
                assert(t:fitCalculatedTurnToBoundary() and c.straightEntryDistance==0)
                -- An impossible corridor must still fail, without leaking reduced
                -- targets into a subsequent pathfinder request.
                c.straightEntryDistance=40; c.disableBulbExtension=nil
                t.generateCalculatedTurn=function(self)
                    self.turnCourse=Course({},{{x=0,z=0},{x=30,z=0}},true)
                end
                t:generateCalculatedTurn(); local original=t.turnCourse
                assert(not t:fitCalculatedTurnToBoundary())
                assert(c.straightEntryDistance==40 and c.disableBulbExtension==nil and t.turnCourse==original)
                c.isHeadlandCorner=function() return true end
                t.settings={loopTurnsOnHeadland={getValue=function() return false end}}
                t.generateCalculatedTurn=function() error('must not change headland turn selection') end
                assert(not t:fitCalculatedTurnToBoundary())
            end
        """)

    def test_jd_scalar_geometry_fits_after_reducing_extension(self):
        self.lua.execute("""
            local recovered=0
            for _,speed in ipairs({6,20,35}) do
                for _,side in ipairs({-1,1}) do
                    for _,slope in ipairs({-.75,0,.75}) do
                        -- Logged JD/drill dimensions and room; this angled
                        -- polygon is synthetic, not the game's field scan.
                        local _,c,course=entryCourse{side=side,pike=-2.5,length=6.9,duration=1000,
                            speed=speed,room=21,enabled=true,width=4,radius=4.8,front=-5,back=-9.7,
                            workOffset=5,startZ=0,headlandAngle=math.rad(126.8)}
                        local polygon={{x=-40,z=-80},{x=40,z=-80},
                            {x=40,z=21+40*slope},{x=-40,z=21-40*slope}}
                        c.vehicle.cpGetFieldPolygon=function() return polygon end
                        c.getDistanceToFieldEdge=function() return 21 end
                        local t=setmetatable({vehicle=c.vehicle,turnContext=c,turnCourse=course,workWidth=4,
                            steeringLength=6.9,turningRadius=4.8,debug=function() end,
                            driveStrategy={isTurnOnFieldActive=function() return true end}},CourseTurn)
                        local before=FieldworkBoundary.containsCourse(FieldworkBoundary.forVehicle(c.vehicle,4),course)
                        local requested=c.straightEntryDistance
                        assert(t:fitCalculatedTurnToBoundary())
                        assert(FieldworkBoundary.containsCourse(FieldworkBoundary.forVehicle(c.vehicle,4),t.turnCourse))
                        assert(c.straightEntryDistance<=requested)
                        if before then assert(t.turnCourse==course) else recovered=recovered+1 end
                    end
                end
            end
            assert(recovered>=8, 'must exercise real rejected Dubins turns, not just fitting routes')
        """)

    def test_forward_headland_loop_can_move_inward_without_reversing(self):
        self.lua.execute("""
            for _,side in ipairs({-1,1}) do
                local node={x=0,z=25,t=0}
                local goal={x=side*10,z=0,t=side*math.pi/2}
                local v={getAIDirectionNode=function() return node end}
                local c=setmetatable({frontMarkerDistance=-8.2,backMarkerDistance=-11.1,
                    turnEndForwardOffset=0,workStartNode=goal,vehicleAtTurnEndNode=goal},TurnContext)
                c.isHeadlandCorner=function() return true end
                c.isLeftTurn=function() return side<0 end
                local t=setmetatable({vehicle=v,turnContext=c,workWidth=25.6,steeringLength=9.8,
                    turningRadius=10,debug=function() end,
                    settings={loopTurnsOnHeadland={getValue=function() return true end}}},CourseTurn)
                -- Quadtrac/Seed Hawk scalar dimensions, synthetic field edge.
                local top=42
                v.cpGetFieldPolygon=function() return {{x=-100,z=-100},{x=100,z=-100},
                    {x=100,z=top},{x=-100,z=top}} end
                local b=FieldworkBoundary.forVehicle(v,25.6)
                local original,recovered
                for candidateTop=42,100 do
                    top=candidateTop; c.loopTurnPullForward=nil;c.loopTurnEntryDistance=nil
                    t:generateCalculatedTurn(); original=t.turnCourse
                    if not FieldworkBoundary.containsCourse(b,original) and t:fitCalculatedTurnToBoundary() then
                        recovered=true
                        break
                    end
                end
                assert(recovered, 'no rejected width-checked loop recovered with an alternative placement')
                b=FieldworkBoundary.forVehicle(v,25.6)
                assert(t.turnCourse:isForwardOnly(), 'recovered loop reverses')
                assert(FieldworkBoundary.containsCourse(b,t.turnCourse), 'recovered loop leaves centre corridor')
                assert(c.loopTurnPullForward~=nil and t.turningRadius==10, 'placement or configured radius changed')
                if original then
                    local x,_,z=original:getWaypointPosition(original:getNumberOfWaypoints())
                    local nx,_,nz=t.turnCourse:getWaypointPosition(t.turnCourse:getNumberOfWaypoints())
                    assert(math.abs(x-nx)<1e-6 and math.abs(z-nz)<1e-6, 'headland coverage target changed')
                end
                -- Already fitting paths stay byte-for-byte the same object.
                local fitted=t.turnCourse
                assert(t:fitCalculatedTurnToBoundary() and t.turnCourse==fitted)
                -- No fitting forward loop: do not fall back to reversing or
                -- retain trial settings from a rejected candidate.
                top=30; c.loopTurnPullForward=nil;c.loopTurnEntryDistance=nil
                t:generateCalculatedTurn(); original=t.turnCourse
                assert(not t:fitCalculatedTurnToBoundary())
                assert(t.turnCourse==original and c.loopTurnPullForward==nil and c.loopTurnEntryDistance==nil)
            end
        """)

    def test_startup_pathfinder_and_analytic_targets_share_allowance(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/startup-fixture.lua').read_text())
        self.lua.execute('''
            for _,length in ipairs({3,12.6,20}) do
                for _,speed in ipairs({6,20,35}) do
                    for _,front in ipairs({-4,3}) do
                        for _,ix in ipairs({1,9,21}) do
                            local s,c=startupFixture(length,speed,front)
                            s:startCourseWithPathfinding(c,ix)
                            local settling,lowering=TurnContext.getStraightEntryAllowance(length,1000,speed)
                            local expected=-front-settling-lowering
                            assert(s.request.course==c and s.request.ix==ix)
                            assert(math.abs(s.request.z-expected)<1e-6)
                            local approach=s:createAlignmentCourse(c,ix)
                            local x,_,z=approach:getWaypointPosition(approach:getNumberOfWaypoints())
                            -- Stock analytic sampling can finish one sample before the goal.
                            assert(math.sqrt(x*x+(z-((ix-1)*5+expected))^2)<1.5,
                                string.format('length %.1f speed %.1f front %.1f ix %d: end %.3f %.3f expected %.3f',
                                    length,speed,front,ix,x,z,(ix-1)*5+expected))
                        end
                    end
                end
            end
            local mounted,c=startupFixture(0,20,-4)
            mounted:startCourseWithPathfinding(c,1)
            assert(mounted.request.z < -6 and mounted.request.z > -7)
            assert(mounted:getWorkStartApproachOffset(-80)==-80)
            local s=startupFixture(12.6,20,-4)
            assert(s:getWorkStartApproachOffset(-80)==-80)
        ''')

    def test_start_row_constructor_reserves_approach_and_appends_to_work(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute('''
            local f=preparationFixture(20,false,false)
            AIUtil.getSteeringParameters=function() return 9,12.6 end
            AIUtil.getTurningRadius=function() return 9 end
            local c=setmetatable(f.turn.turnContext,RowStartOrFinishContext)
            c.turnStartWpIx=c.turnEndWpIx
            c.workWidth=5.6
            c.workStartNode={x=0,z=0,t=0}
            c.vehicleAtTurnEndNode={x=0,z=4,t=0}
            c.frontMarkerDistance=-4; c.backMarkerDistance=-17.7
            local approach=Course(f.vehicle,{{x=0,z=-43},{x=0,z=-42},{x=0,z=-41}},true)
            local starter=StartRowOnly(f.vehicle,f.strategy,f.turn.ppc,c,approach)
            assert(c.straightEntryDistance>45 and c.straightEntryDistance<46)
            assert(starter.state==starter.states.DRIVING_TO_ROW)
            local _,_,z=approach:getWaypointPosition(approach:getNumberOfWaypoints())
            assert(z>17.7)
            local marked=false
            for i=1,approach:getNumberOfWaypoints() do
                if TurnManeuver.hasTurnControl(approach,i,TurnManeuver.LOWER_IMPLEMENT_AT_TURN_END) then
                    marked=true
                end
            end
            assert(marked)
        ''')

    def test_start_row_waits_for_turnover_then_resumes_configured_speed(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute('''
            for _,speed in ipairs({6,20,35}) do
                for _,side in ipairs({false,true}) do
                    local f=preparationFixture(speed,side,true)
                    local t=f.turn
                    t.states.APPROACHING_ROW={name='APPROACHING_ROW'}
                    t.states.IMPLEMENTS_LOWERING={name='IMPLEMENTS_LOWERING'}
                    t.state=t.states.APPROACHING_ROW
                    local _,_,_,v=StartRowOnly.getDriveData(t)
                    assert(v==0 and f.tool.lowerCount==0)
                    f.tool.playing=false; f.tool.animation=side and 1 or 0
                    _,_,_,v=StartRowOnly.getDriveData(t)
                    assert(v==speed and f.tool.lowerCount==0)
                    f:position(-.1)
                    StartRowOnly.getDriveData(t)
                    assert(t.state==t.states.IMPLEMENTS_LOWERING and f.tool.lowerCount==1)
                    StartRowOnly.getDriveData(t)
                    assert(t.resumed==1)
                end
            end
        ''')

    def test_reverse_entry_keeps_stock_lowering_and_direction_change(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute('''
            local f=preparationFixture(20,false,true)
            f.turn.ppc.isReversing=function() return true end
            f:position(20)
            assert(f.turn:endTurn(33)==true)
            assert(f.tool.rotateCount==0 and f.tool.lowerCount==0 and f.turn.resumed==0)
            f:position(-1)
            assert(f.turn:endTurn(33)==true)
            assert(f.tool.lowerCount==1 and f.turn.resumed==1)
            assert(f.tool.rotateCount==1) -- stock onLowering initiates turnover
        ''')

    def test_multiple_implements_wait_before_any_lowering(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute('''
            local f=preparationFixture(20,false,true)
            f:position(-.1)
            local second={rootNode=f.tool.rootNode,left=f.tool.left,right=f.tool.right,back=f.tool.back,lowerCount=0}
            function second:aiImplementStartLine() self.lowerCount=self.lowerCount+1 end
            f.handler.objectsToLower[second]=true; f.handler.nObjectsToLower=2
            assert(f:drive()==0 and f.tool.lowerCount==0 and second.lowerCount==0)
            f.tool.animation=1; f.tool.playing=false
            assert(f:drive()==20 and f.tool.lowerCount==1 and second.lowerCount==1)
            assert(f.handler:allLowered())
        ''')

    def test_consecutive_turns_reset_preparation(self):
        self.lua.execute((SOURCE / 'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute('''
            local f=preparationFixture(20,false,true)
            for turn=1,3 do
                f.turn.workStartHandler=WorkStartHandler(f.vehicle,f.strategy,f.turn.turnContext)
                f.handler=f.turn.workStartHandler
                f.tool.animation=.5; f.tool.playing=false; f:position(-28)
                assert(f:drive()==0)
                f.tool.animation=1; f.tool.playing=false
                assert(f:drive()==20)
                f:position(-.1)
                assert(f:drive()==20 and f.tool.lowerCount==turn and f.turn.resumed==turn)
                assert(f.tool.rotateCount==turn)
            end
        ''')


if __name__ == '__main__':
    unittest.main(verbosity=2)
