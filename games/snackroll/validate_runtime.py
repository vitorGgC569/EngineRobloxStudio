"""Player UI smoke test through RQE. No seeded progression or direct remotes.

Internal math checks are reported separately from the actual played economy.
"""
from pathlib import Path
import hashlib,json,sys,time
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT))
from rqe.hub.client import StudioBridge
from rqe.hub.native_test import run_native_test
from rqe.capture import capture,Win32CaptureBackend
BASE=Path(__file__).parent/'artifacts';BASE.mkdir(exist_ok=True)
OUT=BASE/('play-'+str(time.time_ns()));OUT.mkdir()
data={'source':'studio-bridge','validationLevel':'NOT_VALIDATED','authorizesRelease':False,'profile':'fresh, nonpersistent Studio profile'}
data['buildHash']=hashlib.sha256((BASE.parent/'snackroll.rbxlx').read_bytes()).hexdigest()
def save():(OUT/'runtime.json').write_text(json.dumps(data,indent=2,ensure_ascii=False),encoding='utf-8')
def exercise(b,receipt):
    data['identity']=receipt;save()
    for _ in range(30):
        players=b.call('run.players',{})['players']
        if players and players[0].get('health',0)>0:break
        time.sleep(1)
    def attrs():
        time.sleep(.4)
        return b.call('run.players',{})['players'][0]['attributes']
    def click(name):
        tree=b.call('client.gui_tree',{'includeHidden':False})
        matches=[e for e in tree['elements'] if e.get('interactable') and e.get('path','').endswith('.'+name)]
        assert len(matches)==1,(name,matches)
        loc=b.call('client.gui_locate',{'path':matches[0]['path']})
        result=b.call('client.input',{'action':'click','x':loc['x'],'y':loc['y']})
        assert result.get('delivered'),result
        data.setdefault('clicks',[]).append(name);save();time.sleep(.35)
    def photo(name,pos,look):
        b.call('client.camera_set',{'position':pos,'lookAt':look,'fieldOfView':65})
        time.sleep(.5)
        windows=[w for w in Win32CaptureBackend().studio_windows() if 'snackroll' in w.title.lower()]
        assert len(windows)==1,windows
        w=windows[0]
        shot=capture(OUT/(name+'.png'),b,window=w,expected_hwnd=w.hwnd,expected_pid=w.pid,expected_session=b.pinned_session,viewpoint=name,build_hash=data['buildHash'])
        data[name]=shot.to_dict();save()
    data['initial']=attrs()
    data['suite']=b.call('dm.properties',{'path':'ReplicatedStorage.ForgeTests.Report','properties':['Value']})
    save();assert json.loads(data['suite']['properties']['Value'])['ok'],data['suite']
    photo('restaurant',[17,19,60],[0,6,-23])
    photo('growth-comparison',[5000,33,5035],[5000,30,5000])
    b.call('client.camera_release',{})
    # Ten real eat-button clicks, then one completed course attempt.
    for _ in range(10):click('Eat')
    data['afterEating']=attrs();assert data['afterEating']['Weight']==40,data['afterEating']
    b.call('client.camera_release',{})
    click('Roll')
    for _ in range(20):
        current=attrs()
        if current['Runs']>=1 and not current['Rolling']:break
        time.sleep(.4)
    data['afterRun']=current;save()
    assert current['Best']==3 and current['Coins']==51,current
    click('Foods');click('BuyFood_2')
    data['afterUpgrade']=attrs();assert data['afterUpgrade']['Food']==2 and data['afterUpgrade']['Coins']==1,data['afterUpgrade']
    photo('food-shop',[17,19,60],[0,6,-23]);click('Close')
    click('Eat');data['afterDonut']=attrs();assert data['afterDonut']['Weight']==50,data['afterDonut']
    click('Gifts');click('ClaimDaily');data['daily']=attrs();click('ClaimDaily')
    assert attrs()['Coins']==data['daily']['Coins'],'daily reward paid twice'
    click('Close');click('Pets');click('PetAction_1')
    data['petEquipped']=attrs();assert data['petEquipped']['PetCount']==1,data['petEquipped']
    photo('pet-shop',[17,19,60],[0,6,-23]);click('Close');click('Eat')
    data['afterPetBite']=attrs();assert data['afterPetBite']['Weight']==61,data['afterPetBite']
    click('Pets');click('PetAction_1');click('Close');click('Eat')
    data['afterUnequip']=attrs();assert data['afterUnequip']['Weight']==71,data['afterUnequip']
    photo('course',[46,41,-65],[0,3,-240])
    data['serverLogs']=b.call('log.tail',{'limit':100});data['clientLogs']=b.call('client.logs',{'limit':100});save()
    assert data['serverLogs']['counts']['error']==0,data['serverLogs']
    assert data['clientLogs']['counts']['error']==0,data['clientLogs']
    data['validationLevel']='RUNTIME_VALIDATED';save()
    return {'eatRunUpgrade':True,'freshProfile':True,'petBonusObserved':True,'dailyDuplicateDenied':True}
result=run_native_test(StudioBridge(),mode='play',players=1,args={'game':'snackroll','artReview':True},timeout=230,exercise=exercise)
data['native']=result;save()
manifest={'buildHash':data['buildHash'],'authorizesRelease':False,'files':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in OUT.iterdir() if p.is_file()}}
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
(BASE/'latest-play.json').write_text(json.dumps({'diagnosticOnly':True,'authorizesRelease':False,'run':OUT.name,'manifestHash':hashlib.sha256((OUT/'manifest.json').read_bytes()).hexdigest()},indent=2),encoding='utf-8')
print(json.dumps(result,indent=2));print('Evidence:',OUT);sys.exit(0 if result['status']=='COMPLETED' else 1)
