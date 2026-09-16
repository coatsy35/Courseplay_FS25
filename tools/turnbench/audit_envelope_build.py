"""Audit the delivered ZIP with explicitly synthetic execution perturbations.

This is a qualification report, not a claim that these parameters reproduce
GIANTS tyre/soil/joint physics. Failed cases remain in the report.
"""
import argparse
import hashlib
import json
import time
from pathlib import Path
from zipfile import ZipFile
from test_envelope_deployment import DeploymentTests

ROOT=Path(__file__).resolve().parents[2]


def audit(archive,output):
    cases=[('recorded-right',{}),('recorded-left',{'side':-1}),
           ('30-fps',{'timeStep':1/30}),('60-fps',{'timeStep':1/60}),
           ('irregular-frames',{'steps':[1/60,1/30,.1,.05]}),
           ('braking-1.2',{'braking':1.2}),('braking-3.0',{'braking':3}),
           ('steering-lag-0.2s',{'steeringTimeConstant':.2}),
           ('steering-lag-0.5s',{'steeringTimeConstant':.5}),
           ('steering-lag-1.0s',{'steeringTimeConstant':1}),
           ('response-10.4m',{'physicsLength':10.4}),('response-11.6m',{'physicsLength':11.6}),
           ('response-10.4m-left',{'physicsLength':10.4,'side':-1}),
           ('response-11.6m-left',{'physicsLength':11.6,'side':-1}),
           ('pike-25-lag',{'angle':25,'steeringTimeConstant':.2}),
           ('pike-41.5-lag',{'angle':41.5,'steeringTimeConstant':.2}),
           ('pike-negative-25-lag',{'angle':-25,'steeringTimeConstant':.2}),
           ('pike-negative-41.5-lag',{'angle':-41.5,'steeringTimeConstant':.2}),
           ('pike-negative-41.5-response',{'angle':-41.5,'physicsLength':10.8}),
           ('pike-positive-41.5-response',{'angle':41.5,'physicsLength':10.8}),
           ('lowering-5cm-sideways',{'lowerShiftX':.05}),
           ('lowering-5cm-forwards',{'lowerShiftZ':.05})]
    cases += [(f'first-row-exit-offset-{offset}',{'firstExitOffset':offset}) for offset in (0,.5,-.5)]
    cases += [('v023-bent-arrival',{'v023Arrival':True}),
              ('v023-bent-arrival-lag',{'v023Arrival':True,'steeringTimeConstant':.2}),
              ('v024-bent-arrival',{'v024Arrival':True}),
              ('v024-bent-arrival-lag',{'v024Arrival':True,'steeringTimeConstant':.2}),
              ('v025-second-exit',{'v025Exit':True}),
              ('v025-second-exit-lag',{'v025Exit':True,'steeringTimeConstant':.2}),
              ('v025-second-exit-slower-steering',{'v025Exit':True,'steeringTimeConstant':.5})]
    cases += [('v026-later-exit',{'v026Exit':True}),
              ('v026-default-cp-speeds',{'v026Exit':True,'turnSpeed':8,'fieldSpeed':20}),
              ('default-cp-speeds',{'turnSpeed':8,'fieldSpeed':20}),
              ('configured-cp-speeds',{'turnSpeed':12,'fieldSpeed':25})]
    cases += [('v027-later-exit',{'v027Exit':True}),
              ('v027-later-exit-lag',{'v027Exit':True,'steeringTimeConstant':.2}),
              ('v027-default-cp-speeds',{'v027Exit':True,'turnSpeed':8,'fieldSpeed':20})]
    cases += [('v030-measured-exit',{'v030Exit':True}),
              ('v030-measured-exit-lag',{'v030Exit':True,'steeringTimeConstant':.2})]
    cases += [('v031-saved-cp-speeds',{'v031Exit':True}),
              ('v031-saved-cp-speeds-lag',{'v031Exit':True,'steeringTimeConstant':.2}),
              ('v031-saved-cp-speeds-slower-steering',{'v031Exit':True,'steeringTimeConstant':.5})]
    cases += [(f'narrow-1km-angle-{angle}',{'narrowAngle':angle}) for angle in (-60,-25,25,60)]
    with ZipFile(archive) as z:
        runtime={n:z.read(n) for n in z.namelist() if n.endswith('.lua')}
        mismatches=[n for n,data in runtime.items() if (ROOT/n).read_bytes()!=data]
        if mismatches: raise RuntimeError('ZIP/source mismatch: '+str(mismatches))
        report={'archive':str(archive),'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),
                'allPackagedLuaMatchesSource':True,'packagedLuaFiles':len(runtime),
                'limitations':'Synthetic field and planar physics; parameter sweeps are not measured GIANTS behaviour.',
                'cases':[]}
        for name,options in cases:
            test=DeploymentTests();test.setUp()
            # Use the shipped experimental modules, after loading the regular
            # CP/scene fixture. Every other packaged Lua source was compared too.
            for module in ('EnvelopeTurnPlanner','EnvelopeTurnGeometry','EnvelopeCourseTurn','EnvelopeKTurn'):
                test.lua.execute(runtime[f'scripts/ai/turns/{module}.lua'].decode())
            test.lua.globals().options=test.lua.table_from(options)
            if 'firstExitOffset' in options or 'v023Arrival' in options or 'v024Arrival' in options or 'v025Exit' in options or 'v026Exit' in options or 'v027Exit' in options:
                points=json.loads((ROOT/'tools/turnbench/fixtures/t7-first-pike-outer-headland.json').read_text())
                test.lua.globals().savedField=test.lua.table_from([test.lua.table_from(p) for p in points])
            if 'v030Exit' in options or 'v031Exit' in options:
                points=json.loads((ROOT/'tools/turnbench/fixtures/t7-v030-detected-field.json').read_text())
                test.lua.globals().savedField=test.lua.table_from([test.lua.table_from(p) for p in points])
            start=time.perf_counter()
            error=None
            try:
                test.lua.execute('''
p,f=deploymentFixture(options.side or 1)
if options.v025Exit then configureV025SecondExit(p,f,savedField) end
if options.v026Exit then configureV026Exit(p,f,savedField) end
if options.v027Exit then configureV027Exit(p,f,savedField) end
if options.v030Exit then configureV030Exit(p,f,savedField) end
if options.v031Exit then configureV031Exit(p,f,savedField) end
if options.narrowAngle then p,f=narrowAngledDeploymentFixture(options.narrowAngle) end
if options.firstExitOffset~=nil then configureRecordedFirstExit(p,f,savedField,options.firstExitOffset) end
if options.v023Arrival or options.v024Arrival then
    if options.v024Arrival then configureV024Entry(p,f) else configureV023Entry(p,f) end
    f.vehicle.cpGetFieldPolygon=function() return savedField end
end
for _,key in ipairs({'timeStep','braking','steeringTimeConstant','physicsLength','turnSpeed','fieldSpeed'}) do if options[key]~=nil then p[key]=options[key] end end
if options.steps then
    p.stepSequence={}
    for i=0,3 do p.stepSequence[i+1]=options.steps[i] end
end
if options.angle then p.slope=math.tan(math.rad(options.angle));f.turn.entrySlope=p.slope end
local original=p.stateFixture;local shifted=false
p.stateFixture=function(current,state)
    original(current,state)
    if current.turn.lowerRequested and not shifted then
        shifted=true
        for _,marker in ipairs(p.work) do
            marker.x=marker.x+(options.lowerShiftX or 0)
            marker.z=marker.z+(options.lowerShiftZ or 0)
        end
    end
end
local originalTick=p.tickFixture
p.tickFixture=function(current)
    if originalTick then originalTick(current) end
    current.peakSpeed=math.max(current.peakSpeed or 0,current.vehicle:getLastSpeed())
end
attachFieldworkHandover(p,f)
driveEnvelopeLiveFixture(p,f)
if options.fieldSpeed then assert(f.peakSpeed>8,'CP configured field speed was capped') end
if options.v031Exit then assert(f.peakSpeed>20,'saved CP field speed was capped') end
''')
            except Exception as exc: error=str(exc)
            f=test.lua.globals().f
            logs=[v for _,v in f.logs.items()] if f else []
            entry={'name':name,'parameters':options,'passed':error is None,
                   'cpuWallSeconds':round(time.perf_counter()-start,3),
                   'handoverCount':f.strategy.resumed if f else None,
                   'workedDistance':f.workedDistance if f else None,
                   'peakSpeedKmh':f.peakSpeed if f else None,
                   'initialCandidates':f.initialAttempts if f else None,
                   'transitions':[s for s in logs if not s.startswith('TRACK:')],
                   'failure':error}
            report['cases'].append(entry)
            report['passed']=sum(c['passed'] for c in report['cases'])
            report['failed']=sum(not c['passed'] for c in report['cases'])
            report['complete']=len(report['cases'])==len(cases)
            report['qualified']=report['complete'] and report['failed']==0
            output.write_text(json.dumps(report,indent=2),encoding='utf-8')
            print(name, 'PASS' if error is None else 'FAIL',entry['cpuWallSeconds'],flush=True)
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('archive',type=Path)
    parser.add_argument('output',type=Path)
    args=parser.parse_args()
    report=audit(args.archive,args.output)
    raise SystemExit(0 if report['qualified'] else 1)
