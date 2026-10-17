"""Two real clients: cooperative rewards, choices, targets and safe extraction."""
from pathlib import Path
import json,sys,time
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT))
from rqe.hub.client import StudioBridge
from rqe.hub.native_test import run_native_test
OUT=ROOT/'games/aetherworks/artifacts/refinement-coop.json'
data={'source':'studio-bridge','fixture':'battle-lab, two seeded nonpersistent profiles','validationLevel':'NOT_VALIDATED'}
def save():OUT.write_text(json.dumps(data,indent=2),encoding='utf-8')
def exercise(b,receipt):
    for _ in range(45):
        players=b.call('run.players',{})['players']
        if len(players)==2 and all(p.get('health',0)>0 and p.get('attributes',{}).get('FactoryLevel')==32 for p in players):break
        time.sleep(1)
    data['players']=players;save();assert len(players)==2,players
    def remote(player,event,args={}):return b.call('client.fire_remote',{'path':'ReplicatedStorage.ForgeNet.'+event,'args':[args],'player':player['name']})
    for p in players:remote(p,'Travel')
    for p in players:remote(p,'EnterCoop')
    time.sleep(3)
    data['partyPositions']=b.call('run.players',{});save()
    positions=[p['position'] for p in data['partyPositions']['players']]
    assert abs(positions[0][1]-positions[1][1])<8 and positions[0][1]>200,positions
    data['arena']=b.call('dm.find',{'className':'Model','name':'TowerExpedition_*','limit':10})
    samples=[];targeted=False;choiceWaves=set();best=0
    for step in range(145):
        if step%3==0:
            found=b.call('dm.find',{'tag':'AetherEnemy','limit':15})['results']
            observed=[b.call('dm.properties',{'path':e['path'],'properties':['Name']}) for e in found]
            if observed:
                best=max(best,max(e['attributes'].get('TargetId',0)//100 for e in observed))
                if not targeted:
                    remote(players[1],'TowerTarget',{'id':observed[-1]['attributes']['TargetId']});targeted=True
            if not observed and best and best not in choiceWaves:
                choiceWaves.add(best);remote(players[0],'TowerChoice',{'id':'risk' if best==1 else 'focus'})
            samples.append({'step':step,'bestWave':best,'enemies':observed})
            data['samples']=samples;save()
            if best>=6:break
        for p in players:remote(p,'Attack')
        if step%4==0:
            for p in players:remote(p,'Dodge')
        time.sleep(.3)
    assert best>=5,{'bestWave':best,'logs':b.call('log.tail',{'limit':100})}
    data['beforeExtraction']=b.call('run.players',{})
    for p in reversed(players):remote(p,'LeaveTower')
    time.sleep(1)
    data['afterExtraction']=b.call('run.players',{})
    data['gui']={p['name']:b.call('client.gui_tree',{'includeHidden':True,'player':p['name']}) for p in players}
    data['serverLogs']=b.call('log.tail',{'limit':100})
    data['clientLogs']={p['name']:b.call('client.logs',{'limit':100,'player':p['name']}) for p in players}
    assert all(p['position'][1]<100 for p in data['afterExtraction']['players'])
    assert data['serverLogs']['counts']['error']==0,data['serverLogs']
    assert all(v['counts']['error']==0 for v in data['clientLogs'].values()),data['clientLogs']
    data['validationLevel']='RUNTIME_VALIDATED';save();return {'bestWave':best,'targetSelectionSent':targeted,'choicesSent':sorted(choiceWaves),'bothExtracted':True}
result=run_native_test(StudioBridge(),mode='multiplayer',players=2,args={'game':'aetherworks','profileMode':'battle-lab'},timeout=240,exercise=exercise)
data['native']=result;save();print(json.dumps(result,indent=2));sys.exit(0 if result['status']=='COMPLETED' else 1)
