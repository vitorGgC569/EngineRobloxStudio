"""Publish original geometry through RQE. Reuse matching upload receipts."""
from pathlib import Path
import json,hashlib,sys
ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT))
from rqe.hub.client import StudioBridge
from rqe.geometry.publication import publish_mesh
BASE=Path(__file__).parent;receipt=BASE/'published.json'
saved=json.loads(receipt.read_text()) if receipt.exists() else {}
b=StudioBridge();b.pin_to_context('edit')
for path in sorted((BASE/'meshes').glob('*.json')):
    name=path.stem;sha=hashlib.sha256(path.read_bytes()).hexdigest();old=saved.get(name,{})
    if old.get('sha256')==sha and old.get('status')=='PUBLISHED':continue
    if old.get('status')=='UNCERTAIN':raise RuntimeError('Review uncertain publication before retrying '+name)
    saved[name]={'status':'UNCERTAIN','sha256':sha};receipt.write_text(json.dumps(saved,indent=2))
    with b.lease_scope(agent_id='snackroll-art',context='edit',ttl_seconds=120):
        result=publish_mesh(b,json.loads(path.read_text()),'Snack Roll original '+name+' v1')
    result=result.get('result',result);saved[name]={**result,'sha256':sha};receipt.write_text(json.dumps(saved,indent=2));print(name,result,flush=True)
    if result.get('status')!='PUBLISHED':raise RuntimeError(result)
rows=['-- Original Snack Roll shapes, uploaded through RQE.','return {','    rounded="rbxassetid://77601218900559", -- shared original RQE casing geometry','    ring="rbxassetid://98849397847335", -- shared original RQE collar geometry']
for key,value in saved.items():
    if value.get('status')=='PUBLISHED':rows.append('    '+key+'="rbxassetid://'+str(value['assetId'])+'",')
rows.append('}');(BASE.parent/'src/shared/PublishedShapes.lua').write_text('\n'.join(rows),encoding='utf-8')
