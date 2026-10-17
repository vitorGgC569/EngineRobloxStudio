"""Publish authored meshes through the typed Studio asset API, including seams."""
from typing import Any
import math
from rqe.hub.client import StudioBridge

def publish_mesh(bridge: StudioBridge, data: dict[str, Any], name: str) -> dict[str, Any]:
    p,n,u,i=(data.get(k,[]) for k in ('positions','normals','uvs','indices'))
    if len(p)<9 or len(p)%3 or not i or len(i)%3 or (n and len(n)!=len(p)) or (u and len(u)!=len(p)//3*2):
        raise ValueError('inconsistent mesh attributes')
    if any(isinstance(v,bool) or not isinstance(v,(int,float)) or not math.isfinite(v) for values in (p,n,u) for v in values):raise ValueError('non-finite or invalid vertex attribute')
    if any(isinstance(index,bool) or not isinstance(index,int) or index<0 or index>=len(p)//3 for index in i):raise ValueError('triangle outside vertex array')
    params={'name':name,'description':'Original geometry authored through the RQE Blender pipeline.',
            'vertices':p,'triangles':[index+1 for index in i]}
    if n:params['normals']=n
    if u:params['uvs']=u
    return bridge.call('assets.create_mesh',params,timeout=90)
