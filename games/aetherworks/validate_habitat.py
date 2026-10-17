"""Real Studio player: buy a pet home through UI, verify effects and capture it.

Battle-lab progression is a seeded nonpersistent fixture, never earned progress.
Remote probes are gray-box diagnostics; this is not a black-box E2E claim.
"""
from pathlib import Path
import hashlib,json,sys,time
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT))
from rqe.hub.client import StudioBridge
from rqe.hub.native_test import run_native_test
from rqe.capture import capture_native_viewpoint
OUT=ROOT/'games/aetherworks/artifacts'
data={'source':'studio-bridge','fixture':'battle-lab: nonpersistent seeded progression','validationLevel':'NOT_VALIDATED','authorizesRelease':False}
data['buildHash']=hashlib.sha256((OUT.parent/'aetherworks.rbxlx').read_bytes()).hexdigest()
def save():(OUT/'habitat-runtime.json').write_text(json.dumps(data,indent=2,ensure_ascii=False),encoding='utf-8')
def exercise(b,receipt):
    data['nativeIdentity']=receipt;save()
    for _ in range(45):
        players=b.call('run.players',{})['players']
        if players and players[0].get('health',0)>0:break
        time.sleep(1)
    data['initial']=players
    data['suite']=b.call('dm.properties',{'path':'ReplicatedStorage.ForgeTests.Report','properties':['Value']})
    save();assert json.loads(data['suite']['properties']['Value'])['ok'],data['suite']
    def remote(name,args={}):return b.call('client.fire_remote',{'path':'ReplicatedStorage.ForgeNet.'+name,'args':[args]})
    def click(name):
        gui=b.call('client.gui_tree',{'includeHidden':True})
        found=[e for e in gui['elements'] if e.get('interactable') and e.get('path','').endswith('.'+name)]
        assert len(found)==1,(name,found)
        loc=b.call('client.gui_locate',{'path':found[0]['path']})
        data.setdefault('clicks',[]).append({'name':name,'element':found[0],'location':loc});save()
        result=b.call('client.input',{'action':'click','x':loc['x'],'y':loc['y']});assert result.get('delivered'),result
        time.sleep(.5)
    def attrs():
        time.sleep(1.1)
        return b.call('run.players',{})['players'][0]['attributes']

    def photo(name,pos=None,look=None):
        if pos:b.call('client.camera_set',{'position':pos,'lookAt':look,'fieldOfView':60})
        time.sleep(.6)
        shot=capture_native_viewpoint(
            b,
            target='',
            output=OUT/(name+'.png'),
            expected_session=b.pinned_session,
            viewpoint=name,
            build_hash=data['buildHash'],
            include_ui=True,
            settle_seconds=.35,
        )
        data[name]=shot.to_dict();save();assert shot.trustworthy,shot.to_dict()
    click('Start');b.call('client.input',{'action':'keys','keys':['U'],'duration':.1});time.sleep(.6)
    photo('pet-open-ui');click('VisitHabitat')
    photo('pet-lot-ui');click('BuyHabitat')
    data['afterLot']=attrs();save()
    assert data['afterLot']['PetCapacity']==2 and abs(data['afterLot']['PetProductionMultiplier']-1.06)<1e-6,data['afterLot']
    assert abs(data['afterLot']['PetManualMultiplier']-1.12)<1e-6
    photo('pet-first-floor-ui');click('CloseHabitat')
    photo('pet-first-floor',[-339,57,-122],[-292,47,-80])
    click('Pets');click('BuyHabitat');click('Pet_fern');click('AdoptPet');click('UpgradePet')
    data['afterUpgrade']=attrs();save()
    assert data['afterUpgrade']['PetCapacity']==4 and abs(data['afterUpgrade']['PetProductionMultiplier']-1.185)<1e-6,data['afterUpgrade']
    click('PetSlot_4');click('EquipPet')
    data['afterMove']=attrs();assert abs(data['afterMove']['PetProductionMultiplier']-1.185)<1e-6
    click('UnequipPet');data['afterReserve']=attrs();assert abs(data['afterReserve']['PetProductionMultiplier']-1.06)<1e-6
    click('EquipPet');click('BuyHabitat');time.sleep(.6);click('BuyHabitat');time.sleep(.6);click('BuyHabitat')
    data['finalCapacity']=attrs();assert data['finalCapacity']['PetCapacity']==10
    photo('pet-house-ui');click('CloseHabitat')
    photo('pet-house',[-347,88,-135],[-291,70,-80])
    # Finish front-facing captures requested in the previous visual pass.
    photo('refined-collector',[-265,49,39],[-253,44,24])
    photo('refined-garrison',[-310,57,93],[-281,44,75])
    click('Army');photo('refined-army-ui');click('CloseIndustry')
    click('Collection');photo('refined-collection-ui');click('CloseCollection')
    remote('Travel');time.sleep(1);photo('refined-arsenal-ui');click('CloseArsenal')
    data['serverLogs']=b.call('log.tail',{'limit':100});data['clientLogs']=b.call('client.logs',{'limit':100})
    assert data['serverLogs']['counts']['error']==0,data['serverLogs']
    assert data['clientLogs']['counts']['error']==0,data['clientLogs']
    data['validationLevel']='RUNTIME_VALIDATED';save()
    return {'purchasedThroughUI':True,'capacityObserved':[2,4,10],'productionBonusObserved':1.185,'reserveRemovesBonus':True,'duplicateMoveDoesNotStack':True}
result=run_native_test(StudioBridge(),mode='play',players=1,args={'game':'aetherworks','profileMode':'battle-lab'},timeout=200,exercise=exercise)
data['native']=result;save();print(json.dumps(result,indent=2));sys.exit(0 if result['status']=='COMPLETED' else 1)
