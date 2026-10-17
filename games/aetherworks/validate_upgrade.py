"""Real Studio integration evidence; seeded progression is explicitly identified."""
from pathlib import Path
import json, sys, time
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))
from rqe.hub.client import StudioBridge
from rqe.hub.native_test import run_native_test
OUT=ROOT/'games/aetherworks/artifacts/upgrade-runtime.json'
data={"source":"studio-bridge","validationLevel":"NOT_VALIDATED","fixture":"battle-lab: seeded progress, no persistence claim"}
def exercise(b,receipt):
    data['session']=b.pinned_session
    def record(key,method,params=None):
        result=b.call(method,params or {},timeout=25);data[key]=result
        OUT.write_text(json.dumps(data,indent=2,ensure_ascii=False),encoding='utf-8')
        print(key,flush=True);return result
    for attempt in range(35):
        try:
            result=b.call('dm.properties',{'path':'ReplicatedStorage.ForgeTests.Report','properties':['Value']},timeout=15)
            raw=result.get('properties',{}).get('Value')
            if raw: break
        except Exception: pass
        time.sleep(1)
    else: raise AssertionError('Studio did not publish its internal suite')
    data['suite']=json.loads(raw)
    assert data['suite']['ok'],data['suite']
    players=record('players','run.players')
    info=record('studio','studio.info')
    record('serverLogs','log.tail',{'limit':100})
    record('clientLogs','client.logs',{'limit':100})
    record('gui','client.gui_tree',{'includeHidden':True})
    # runtime.metrics v1 accepts Run mode only; this is a native player session.
    # These invoke the same remotes as the UI. Server results are captured below.
    for event,payload in [('Legacy',{'perk':'magnet'}),('ResearchNode',{'tree':'legacy','id':'industry'}),('MachineUpgrade',{'id':'extractor','count':10}),('ResearchNode',{'tree':'towerResearch','id':'power'}),('ArmyOrder',{'id':'regroup'}),('Daily',{}),('Travel',{})]:
        record('command-'+event+str(payload),'client.fire_remote',{'path':'ReplicatedStorage.ForgeNet.'+event,'args':[payload]})
        time.sleep(.7)
    machine=record('upgradedMachine','dm.properties',{'path':'Workspace.Aetherworks.Aurora.Machines.Machine_1','properties':['Name']})
    assert machine['attributes']['MachineRank']==85 and machine['attributes']['CrystalTier']==5,machine
    gui=record('postPurchaseGui','client.gui_tree',{'includeHidden':True})
    texts=[e.get('text','') for e in gui.get('elements',[])]
    assert 'Herança industrial · N1' in texts and 'Foco de aether · N1' in texts,texts
    record('enterTower','client.fire_remote',{'path':'ReplicatedStorage.ForgeNet.EnterTower','args':[{}]})
    time.sleep(8)
    record('enemies','dm.find',{'tag':'AetherEnemy','limit':25})
    data['towerSamples']=[]
    roles=set()
    for attempt in range(112):
        if attempt%8==0:
            found=b.call('dm.find',{'tag':'AetherEnemy','limit':25})
            enemies=[b.call('dm.properties',{'path':e['path'],'properties':['Name']}) for e in found['results']]
            roles.update(e['attributes'].get('EnemyRole') for e in enemies)
            data['towerSamples'].append({'shot':attempt,'enemies':enemies,'players':b.call('run.players',{})})
            if {'boss','warden','mender'}<=roles and any(e['attributes'].get('Elite') for e in enemies): break
        b.call('client.fire_remote',{'path':'ReplicatedStorage.ForgeNet.Attack','args':[{}]},timeout=15)
        if attempt%3==0: b.call('client.fire_remote',{'path':'ReplicatedStorage.ForgeNet.Dodge','args':[{}]},timeout=15)
        time.sleep(.5)
    data['enemyRolesObserved']=sorted(roles)
    record('towerGui','client.gui_tree',{'includeHidden':True})
    record('finalServerLogs','log.tail',{'limit':150})
    record('finalClientLogs','client.logs',{'limit':150})
    assert data['finalServerLogs']['counts']['error']==0,data['finalServerLogs']
    assert data['finalClientLogs']['counts']['error']==0,data['finalClientLogs']
    assert data['enemies']['matched']>=2,data['enemies']
    assert {'boss','warden','mender'}<=roles,{'missingRoles':sorted({'boss','warden','mender'}-roles)}
    data['validationLevel']='RUNTIME_VALIDATED'
    return {'suite':data['suite'],'observations':str(OUT)}
b=StudioBridge()
if len(sys.argv)>1:
    test_id=sys.argv[1];b.pin_to_running()
    observed=b.call('test.status',{})
    assert observed.get('args',{}).get('rqeTestId')==test_id,observed
    with b.lease_scope(agent_id='aetherworks-upgrade-resume',session_id=b.pinned_session,ttl_seconds=300):
        try:
            exercised=exercise(b,{})
            result={'status':'COMPLETED','testId':test_id,'result':exercised,'resumed':True}
        except Exception as exc:
            result={'status':'FAILED','testId':test_id,'error':str(exc),'resumed':True}
        finally:
            b.call('test.finish',{'testId':test_id,'result':result},timeout=15)
else:
    result=run_native_test(b,mode='play',players=1,args={'game':'aetherworks','profileMode':'battle-lab'},timeout=240,exercise=exercise)
data['nativeTest']=result
OUT.write_text(json.dumps(data,indent=2,ensure_ascii=False),encoding='utf-8')
print(json.dumps({k:v for k,v in result.items() if k!='result'},indent=2),flush=True)
sys.exit(0 if result.get('status')=='COMPLETED' else 1)
