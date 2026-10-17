"""Reproducible Aetherworks geometry authored through the RQE Blender worker."""
from pathlib import Path
import json, math, sys
ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT))
from rqe.geometry.worker import GeometryWorker
from rqe.geometry.program import compile_program
from rqe.geometry.luau import module_source
BASE=Path(__file__).resolve().parent

def box(name,size,location=(0,0,0),bevel=.12):
    return [{'op':'box','name':name,'size':size,'location':list(location)},
            {'op':'bevel','target':name,'width':bevel,'segments':2}]

def cyl(name,radius,depth,location=(0,0,0),vertices=24,top=None):
    p={'op':'cylinder' if top is None else 'cone','name':name,'radius':radius,'depth':depth,'location':list(location),'vertices':vertices}
    if top is not None:p['radiusTop']=top
    return [p]

def program(name,steps,parts,smooth=False):
    result=parts[0]
    if len(parts)>1: steps+=[{'op':'join','name':'asset','targets':parts}];result='asset'
    if smooth:steps+=[{'op':'smooth_shade','target':result,'angle':35}]
    steps+=[{'op':'uv_unwrap','target':result,'method':'smart'},{'op':'triangulate','target':result}]
    return {'schemaVersion':1,'id':name,'result':result,'units':'studs','steps':steps,
            'metadata':{'author':'Aetherworks','license':'project-original','purpose':'finished modular industrial art'}}

def kit():
    out=[]
    for tier in range(1,6):
        n=[5,6,8,10,7][tier-1];parts=['body','crown','foot']
        steps=cyl('body',1.1,2.2,(0,0,.1),n,top=.85)
        steps+=cyl('crown',.85,1.5,(0,0,1.95),n,top=.18 if tier>1 else 0)
        steps+=cyl('foot',.5,.7,(0,0,-1.35),n,top=1.1)
        if tier in (1,4,5):
            for j in range(3):
                a=j*math.tau/3;name='splinter'+str(j);parts.append(name)
                steps+=cyl(name,.3,.9,(math.cos(a)*.95,math.sin(a)*.95,-.6),5,top=0)
        if tier==3:steps+=[{'op':'scale','target':p,'factor':[1.15,1.15,.75]} for p in parts]
        out.append(program('crystal_'+str(tier),steps,parts))
    out.append(program('casing',box('case',(1,1,1),bevel=.12),['case']))
    steps=cyl('wheel',1,.2,vertices=32)+cyl('hole',.5,.5)
    steps+=[{'op':'boolean','target':'wheel','tool':'hole','operation':'difference'},{'op':'bevel','target':'wheel','width':.05,'segments':2}]
    out.append(program('collar',steps,['wheel'],True))
    steps=[];parts=[]
    for j in range(12):
        a=j*math.tau/12;name='tooth'+str(j);parts.append(name)
        steps+=box(name,(.35,.28,.22),(math.cos(a)*1.04,math.sin(a)*1.04,0),.03)
        steps+=[{'op':'rotate','target':name,'angles':[0,0,math.degrees(a)]}]
    steps+=cyl('hub',1,.2,vertices=24);parts.append('hub')
    steps+=cyl('bore',.28,.6)+[{'op':'boolean','target':'hub','tool':'bore','operation':'difference'}]
    out.append(program('gear',steps,parts))
    points=[]
    for j in range(97):
        t=j/96;a=t*math.tau*4;r=.4+t*.8
        points.append([math.cos(a)*r,math.sin(a)*r,t*5-2.5])
    steps=[{'op':'sweep','name':'flight','points':points,'radius':.23,'sides':4,'smoothness':0,'caps':True}, {'op':'decimate','target':'flight','triangleBudget':1600}]
    steps+=cyl('shaft',.3,5)+cyl('tip',.01,.9,(0,0,-2.95),16,top=.45)
    out.append(program('auger',steps,['flight','shaft','tip'],True))
    points=[[0,0,0],[.2,0,.6],[.3,0,1.5],[.8,0,2],[1.8,0,2],[2.3,0,1.5],[2.3,0,.3]]
    out.append(program('pipe', [{'op':'sweep','name':'pipe','points':points,'radius':.18,'sides':8,'smoothness':.5,'caps':True}],['pipe'],True))
    steps=box('outer',(8,3,9),bevel=.45)+box('cut',(5.2,5,5.2),(0,0,-.9),.6)
    steps+=[{'op':'boolean','target':'outer','tool':'cut','operation':'difference'}]
    out.append(program('arch',steps,['outer']))
    steps=cyl('vessel',3,6,vertices=32)+cyl('shoulder',3,1.5,(0,0,3.75),32,top=2)+cyl('bottom',2,.9,(0,0,-3.45),32,top=3)
    steps+=[{'op':'bevel','target':p,'width':.16,'segments':2} for p in ['vessel','shoulder','bottom']]
    out.append(program('vessel',steps,['vessel','shoulder','bottom'],True))
    steps=box('beam',(2,1,9),bevel=.18)+box('joint',(2.8,1.6,1),(0,0,3.7),.15)+box('joint2',(2.8,1.6,1),(0,0,-3.7),.15)
    out.append(program('girder',steps,['beam','joint','joint2']))
    steps=[{'op':'sphere','name':'rock','radius':1,'segments':12,'rings':8},{'op':'scale','target':'rock','factor':[1.5,1,1.3]}, {'op':'displace','target':'rock','strength':.25,'scale':.7,'detail':2}]
    out.append(program('rock',steps,['rock']))
    steps=box('housing',(1.25,2.3,.8),bevel=.23)+box('handguard',(1.8,.4,1.1),(0,.65,.5),.18)
    out.append(program('gauntlet',steps,['housing','handguard']))
    steps=box('blade',(3.5,.3,.9),bevel=.2)+cyl('socket',.35,.6,vertices=12)
    out.append(program('pickaxe',steps,['blade','socket']))
    return out

def main():
    worker=GeometryWorker();manifest={};mods=BASE.parent/'src/shared/MeshKit';mods.mkdir(parents=True,exist_ok=True)
    for doc in kit():
        name=doc['id'];package=BASE/'generated'/name
        package.mkdir(parents=True,exist_ok=True)
        source=package/'program.json';text=json.dumps(doc,indent=2)
        unchanged=source.exists() and source.read_text()==text
        compiled=compile_program(doc)
        resultfile=package/'build.json'
        if unchanged and resultfile.exists():result=json.loads(resultfile.read_text())
        else:
            built=worker.build(compiled.to_dict(),package)
            if not built.ok:raise RuntimeError((name,built.error,built.traceback))
            result=built.data;resultfile.write_text(json.dumps(result,indent=2))
            source.write_text(text)
        data=json.loads(Path(result['meshData']).read_text())
        (mods/(name+'.lua')).write_text(module_source(data,keep_uvs=True),encoding='utf-8')
        manifest[name]={'triangles':len(data['indices'])//3,'meshData':str(Path(result['meshData']).relative_to(BASE.parent)),'fbx':str(Path(result['fbx']).relative_to(BASE.parent)),'license':'project-original'}
        print(name,manifest[name]['triangles'],flush=True)
    (BASE/'kit.json').write_text(json.dumps(manifest,indent=2))
    print('Authored kit complete',flush=True)
if __name__=='__main__':main()
