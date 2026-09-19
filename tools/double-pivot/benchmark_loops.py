"""Compare saved loop routes and median planning time on the same interpreter.

This measures the planar harness, not GIANTS frame time. Route fingerprints,
candidate counts and return metadata must agree before timings are compared.
"""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import time
from lupa.lua52 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
CASES = ('first', 'third', 'straight', 'mirrored')


def run(case):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().ROOT = ROOT.as_posix()
    lua.execute((ROOT / 'tools/double-pivot/engine-boundary.lua').read_text())
    lua.execute((ROOT / 'tools/double-pivot/saxlingham-corner.lua').read_text())
    lua.globals().benchmarkCase = case
    start = time.perf_counter()
    data = lua.execute('''
        local v,c,m
        if benchmarkCase=='third' then v,c,m=saxlinghamThirdCorner()
        else
            v,c,m=saxlinghamCorner(0,benchmarkCase=='mirrored' and -1 or 1)
            if benchmarkCase=='first' then c.loopFieldWorkCourse=saxlinghamReturn(v);c.turnEndWpIx=1 end
        end
        local course,reason=HeadlandLoopGeometry.plan({vehicle=v,vehicleDirectionNode=v.rootNode,
            turnContext=c,turningRadius=10,workWidth=25.6,steeringLength=9.8},m,1.68)
        assert(course,reason)
        local result={reason}
        for i=1,course:getNumberOfWaypoints() do
            local x,_,z=course:getWaypointPosition(i)
            result[#result+1]=string.format('%.9f,%.9f,%.9f,%s',x,z,course:getWaypointYRotation(i),
                tostring(TurnManeuver.hasTurnControl(course,i,TurnManeuver.LOWER_IMPLEMENT_AT_TURN_END)))
        end
        local r=course.chainReturn
        result[#result+1]=string.format('%.9f,%.9f,%.9f,%.9f,%s',r.x,r.z,r.t,r.lateralTolerance,tostring(r.fieldEndIx))
        return result
    ''')
    elapsed = time.perf_counter() - start
    values = [data[i] for i in range(1, len(data) + 1)]
    return elapsed, hashlib.sha256('\n'.join(values).encode()).hexdigest(), values[0]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--repeat', type=int, default=3)
    args = parser.parse_args()
    report = {}
    baseline = json.loads(args.baseline.read_text()) if args.baseline else None
    for case in CASES:
        results = [run(case) for _ in range(args.repeat)]
        assert len({r[1] for r in results}) == 1, f'{case}: non-deterministic route'
        report[case] = dict(seconds=statistics.median(r[0] for r in results),
                            fingerprint=results[0][1], reason=results[0][2])
        if baseline:
            assert report[case]['fingerprint'] == baseline[case]['fingerprint'], f'{case}: route changed'
            report[case]['improvement_percent'] = 100 * (1 - report[case]['seconds'] / baseline[case]['seconds'])
        print(case, json.dumps(report[case]), flush=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
