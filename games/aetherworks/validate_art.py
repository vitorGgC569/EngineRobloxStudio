"""Capture the authored kit in a real native player, preserving source evidence."""
from pathlib import Path
import json,sys,time,hashlib
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT))
from rqe.hub.client import StudioBridge
from rqe.hub.native_test import run_native_test
from rqe.capture import capture_native_viewpoint
OUT=ROOT/'games/aetherworks/artifacts'
data={'source':'studio-bridge','fixture':'completed factory, Studio-only profile','validationLevel':'NOT_VALIDATED'}
def exercise(b,receipt):
    data['session']=b.pinned_session
    for _ in range(45):
        players=b.call('run.players',{})['players']
        if players and players[0].get('health',0)>0:break
        time.sleep(1)
    data['players']=players
    data['logs']=b.call('log.tail',{'limit':100})
    (OUT/'art-runtime.json').write_text(json.dumps(data,indent=2),encoding='utf-8')
    data['clientLogs']=b.call('client.logs',{'limit':100})
    data['templates']=b.call('dm.tree',{'path':'ReplicatedStorage.AetherArtTemplates','depth':1})
    assert players and players[0].get('health',0)>0,data['logs']
    data['suite']=b.call('dm.properties',{'path':'ReplicatedStorage.ForgeTests.Report','properties':['Value']})
    assert json.loads(data['suite']['properties']['Value'])['ok'],data['suite']
    gui=b.call('client.gui_tree',{'includeHidden':True});data['gui']=gui
    def click(name):
        current=b.call('client.gui_tree',{'includeHidden':True})
        found=[e for e in current['elements'] if e.get('path','').endswith('.'+name) and e.get('interactable')]
        assert len(found)==1,(name,found)
        location=b.call('client.gui_locate',{'path':found[0]['path']})
        result=b.call('client.input',{'action':'click','x':location['x'],'y':location['y']});data['click-'+name]=result
        (OUT/'art-runtime.json').write_text(json.dumps(data,indent=2),encoding='utf-8')
        assert result.get('delivered'),result
    click('Start')
    data['nativeTestIdentity']=receipt
    def photograph(name,position=None,look=None):
        if position:b.call('client.camera_set',{'position':position,'lookAt':look,'fieldOfView':60})
        time.sleep(1)
        shot=capture_native_viewpoint(
            b,
            target='',
            output=OUT/(name+'.png'),
            expected_session=b.pinned_session,
            viewpoint=name,
            build_hash=hashlib.sha256((OUT.parent/'aetherworks.rbxlx').read_bytes()).hexdigest(),
            include_ui=True,
            settle_seconds=.35,
        )
        data[name]=shot.to_dict();(OUT/'art-runtime.json').write_text(json.dumps(data,indent=2),encoding='utf-8')
        assert shot.trustworthy,shot.to_dict()
    photograph('art-factory',[-267,58,-55],[-310,47,-12])
    click('Machines');photograph('art-machine-ui');click('CloseIndustry')
    click('Collection');photograph('art-collection');click('CloseCollection')
    b.call('client.fire_remote',{'path':'ReplicatedStorage.ForgeNet.Travel','args':[{}]});time.sleep(1)
    photograph('art-arsenal-ui',[73,57,56],[49,47,16]);click('CloseArsenal')
    photograph('art-arsenal',[73,57,56],[49,47,16])
    photograph('art-tower-entry',[-12,56,-15],[-32,53,-55])
    photograph('art-collector',[-243,53,42],[-260,45,24])
    photograph('art-garrison',[-244,67,97],[-287,45,76])
    data['finalServerLogs']=b.call('log.tail',{'limit':100});data['finalClientLogs']=b.call('client.logs',{'limit':100})
    data['validationLevel']='RUNTIME_VALIDATED'
    (OUT/'art-runtime.json').write_text(json.dumps(data,indent=2),encoding='utf-8')
    return {'artLoaded':True}
result=run_native_test(StudioBridge(),mode='play',players=1,args={'game':'aetherworks','profileMode':'battle-lab'},timeout=180,exercise=exercise)
data['native']=result;(OUT/'art-runtime.json').write_text(json.dumps(data,indent=2),encoding='utf-8')
print(json.dumps(result,indent=2));sys.exit(0 if result['status']=='COMPLETED' else 1)
