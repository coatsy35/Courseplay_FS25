"""Read-only native CP departure check against the installed AD event handler.
Usage: python -B tools/unloader-queue/verify_installed_ad.py PATH_TO_AD_ZIP
Game services are mocked; no installed file or saved configuration is changed.
"""
from pathlib import Path
from zipfile import ZipFile
import hashlib
import sys
import xml.etree.ElementTree as ET

zip_path=Path(sys.argv[1])
sys.argv=[sys.argv[0]]
from test_native_departure import NativeDepartureTests
with ZipFile(zip_path) as archive:
    manifest=ET.fromstring(archive.read('modDesc.xml'))
    source=archive.read('scripts/ExternalInterface.lua').decode('utf-8-sig')
test=NativeDepartureTests()
test.setUp()
lua=test.lua
lua.execute("""
    AutoDrive={debugPrint=function() end,modesToStartFromCP={2,5}}
    ADStateModule={HELPER_CP=1}
    table.contains=function(items,value)
        for _,item in pairs(items) do if item==value then return true end end
        return false
    end
    modeStarted=0; helperEnabled=true; adActive=false
    local v=u.vehicle
    v.isServer=true; v.startAutoDrive=function() end
    v.getRootVehicle=function() return v end
    v.ad={stateModule={isActive=function() return adActive end,
        getStartHelper=function() return helperEnabled end,getUsedHelper=function() return 1 end,
        getMode=function() return 2 end,
        getCurrentMode=function() return {start=function() modeStarted=modeStarted+1; adActive=true end} end}}
""")
for name in ('handleCPFieldWorker','onCpFull'):
    start=source.index('function AutoDrive:'+name+'(')
    end=source.index('\nfunction ',start+1)
    lua.execute(source[start:end])
lua.execute("""
    u.vehicle.stopCurrentAIJob=function(self) AutoDrive.onCpFull(self) end
    Q.take(u,'prepare'); u:startUnloadingTrailers()
    assert(modeStarted==0 and not Q.owns(u))
    finishSearch(true); assert(modeStarted==0)
    u:onLastWaypointPassed()
    assert(modeStarted==1 and u.vehicle.ad.isCpFull and u.vehicle.ad.restartCP)
    AutoDrive.onCpFull(u.vehicle); assert(modeStarted==1)
    adActive=false; helperEnabled=false
    AutoDrive.onCpFull(u.vehicle); assert(modeStarted==1)
""")
print(f"PASS: native CP marker completion starts installed AD {manifest.findtext('version')} once; disabled helper respected")
print(f"Read-only ZIP SHA-256: {hashlib.sha256(zip_path.read_bytes()).hexdigest()}")
