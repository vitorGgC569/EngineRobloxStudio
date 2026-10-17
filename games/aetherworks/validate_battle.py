"""Two native players: observe deployed soldiers, ownership and real damage."""
from pathlib import Path
import json,sys,time
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT))
from rqe.hub.client import StudioBridge
from rqe.hub.native_test import run_native_test
out=ROOT/'games/aetherworks/artifacts/upgrade-multiplayer.json'
evidence={'source':'studio-bridge','fixture':'battle-lab: seeded profiles','validationLevel':'NOT_VALIDATED'}
def exercise(b,receipt):
    deadline=time.monotonic()+65
    players=[]
    while time.monotonic()<deadline:
        players=b.call('run.players',{})['players']
        if len(players)==2 and all(p.get('health',0)>0 and p.get('attributes',{}).get('FactoryLevel')==32 for p in players): break
        time.sleep(2)
    else: raise AssertionError({'playersNotReady':players,'logs':b.call('log.tail',{'limit':100})})
    evidence['players']=players
    for p in players:
        b.call('client.fire_remote',{'path':'ReplicatedStorage.ForgeNet.ArmyOrder','args':[{'id':'advance'}],'player':p['name']})
    evidence['samples']=[]
    for index in range(10):
        if index==4:
            b.call('client.fire_remote',{'path':'ReplicatedStorage.ForgeNet.ArmyOrder','args':[{'id':'regroup'}],'player':players[1]['name']})
        time.sleep(8)
        soldiers=b.call('dm.find',{'tag':'AetherSoldier','limit':30})
        sample={'seconds':(index+1)*8,'soldiers':[]}
        for soldier in soldiers['results']:
            observed=b.call('dm.properties',{'path':soldier['path']+'.Humanoid','properties':['Health','MaxHealth','MoveDirection','WalkToPoint']})
            observed['root']=b.call('dm.properties',{'path':soldier['path']+'.HumanoidRootPart','properties':['Position','CFrame']})
            sample['soldiers'].append(observed)
        for p in players:
            gui=b.call('client.gui_tree',{'includeHidden':True,'player':p['name']})
            sample[p['name']]=[e.get('text') for e in gui.get('elements',[]) if 'DOMINA' in e.get('text','') or 'GUARNIÇÃO' in e.get('text','') or 'CONTESTADO' in e.get('text','')]
        sample['players']=b.call('run.players',{})['players']
        evidence['samples'].append(sample)
        out.write_text(json.dumps(evidence,indent=2,ensure_ascii=False),encoding='utf-8')
        print('battle sample',index+1,flush=True)
    evidence['serverLogs']=b.call('log.tail',{'limit':100})
    evidence['clientLogs']={p['name']:b.call('client.logs',{'player':p['name'],'limit':100}) for p in players}
    raw=b.call('dm.properties',{'path':'ReplicatedStorage.ForgeDebug.Snapshot','properties':['Value']})
    evidence['runtimeSnapshot']=json.loads(raw['properties']['Value'])
    errors=[e for log in evidence['clientLogs'].values() for e in log['entries'] if e['severity']=='error']
    evidence['platformErrors']=[e for e in errors if e['message'].startswith(('[Roblox][CoreGui.','[Roblox][Script Context.StarterScript]'))]
    evidence['gameErrors']=[e for e in errors if e not in evidence['platformErrors']]
    assert not evidence['gameErrors'],evidence['gameErrors']
    assert evidence['serverLogs']['counts']['error']==0,evidence['serverLogs']
    evidence['damageObserved']=any(s['properties']['Health']<s['properties']['MaxHealth'] for sample in evidence['samples'] for s in sample['soldiers'])
    assert evidence['damageObserved'],'No troop damage was measured in the observation window'
    evidence['captureObserved']=any('DOMINA' in text for sample in evidence['samples'] for p in players for text in sample[p['name']])
    assert evidence['captureObserved'],'No completed capture was observed after the opponent regrouped'
    base=players[0]['attributes']['IncomePerSecond']
    evidence['incomeMultiplierObserved']=any(p['name']==players[0]['name'] and abs(p['attributes'].get('IncomePerSecond',0)-base*1.5)<1 for sample in evidence['samples'] for p in sample['players'])
    assert evidence['incomeMultiplierObserved'],'The owning base did not receive 1.5x income'
    evidence['validationLevel']='RUNTIME_VALIDATED'
    return {'damageObserved':True,'evidence':str(out)}
result=run_native_test(StudioBridge(),mode='multiplayer',players=2,args={'game':'aetherworks','profileMode':'battle-lab'},timeout=240,exercise=exercise)
evidence['nativeTest']=result;out.write_text(json.dumps(evidence,indent=2,ensure_ascii=False),encoding='utf-8')
print(json.dumps(result,indent=2));sys.exit(result.get('status')!='COMPLETED')
