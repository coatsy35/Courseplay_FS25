"""Read an installed AD ZIP and verify its real route-return contract offline.

Usage: python -B tools/unloader-queue/verify_installed_ad.py PATH_TO_AD_ZIP
No game, AD configuration or installed mod is modified. The queue uses the
usual mocked engine boundary; AD's route calculation and graph wrapper are
loaded verbatim from the supplied ZIP and run on a small directed network.
"""
from pathlib import Path
from zipfile import ZipFile
import hashlib
import sys
import xml.etree.ElementTree as ET

zip_path = Path(sys.argv[1])
sys.argv = [sys.argv[0]]  # test_runtime accepts an optional source root.
from test_runtime import EngineBoundaryTests

with ZipFile(zip_path) as archive:
    manifest = ET.fromstring(archive.read('modDesc.xml'))
    calculator = archive.read('scripts/PathCalculation.lua').decode('utf-8-sig')
    graph = archive.read('scripts/Manager/GraphManager.lua').decode('utf-8-sig')
start = graph.index('function ADGraphManager:pathFromTo(')
end = graph.index('\nfunction ', start + 1)

test = EngineBoundaryTests()
test.setUp()
test.ad_exit_network()
lua = test.lua
lua.execute('''
    ADGraphManager=FS25_AutoDrive.ADGraphManager
    ADGraphManager.wayPoints=nodes
    ADGraphManager.areWayPointsPrepared=function() return true end
    ADGraphManager.getWayPoints=function() return nodes end
    ADGraphManager.getDriveTimeBetweenNodes=function(_,a,b)
        a,b=nodes[a],nodes[b]
        return math.sqrt((a.x-b.x)^2+(a.z-b.z)^2)
    end
    AutoDrive={FLAG_SUBPRIO=1,getSetting=function() return 0 end}
    table.contains=function(items,value)
        for _,item in pairs(items) do if item==value then return true end end
        return false
    end
    SortedQueue={new=function()
        return {items={},enqueue=function(self,item) table.insert(self.items,item) end,
            empty=function(self) return #self.items==0 end,
            dequeue=function(self)
                table.sort(self.items,function(a,b) return a.distance<b.distance end)
                return table.remove(self.items,1)
            end}
    end}
    for i,node in ipairs(nodes) do
        node.incoming=i>1 and {i-1} or {}
        node.transitMapping={}; node.flags=0
    end
''')
lua.execute(calculator)
lua.execute(graph[start:end])
lua.execute('''
    local route=ADGraphManager:pathFromTo(1,3)
    assert(#route==2 and route[1].id==2 and route[2].id==3,
        'Installed AD route contract has changed; review queue compatibility')
    local node,heading=CpUnloaderQueue.connectedNode(u,{x=0,z=0,t=0},saved)
    assert(node==nodes[1] and heading==0)
    assert(CpUnloaderQueue.canFinishExit(u))
    destination=2
    route=ADGraphManager:pathFromTo(1,2)
    assert(#route==1 and route[1].id==2)
    assert(CpUnloaderQueue.canFinishExit(u))
    nodes[1].out={}
    assert(not CpUnloaderQueue.canFinishExit(u))
''')
print(f"PASS: real AD {manifest.findtext('version')} route calculation: multi-hop, single-hop, disconnected exit")
print(f"Read-only ZIP SHA-256: {hashlib.sha256(zip_path.read_bytes()).hexdigest()}")
