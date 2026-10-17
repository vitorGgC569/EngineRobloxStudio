"""Original smooth surfaces for Snack Roll. No downloaded game assets.

Analytic surfaces retain normals and UVs through RQE's mesh publication API.
"""
from pathlib import Path
import json,math
HERE=Path(__file__).parent
OUT=HERE/'meshes';OUT.mkdir(exist_ok=True)
def surface(name,fn,nu=40,nv=24,closed_v=False):
    positions=[];normals=[];uvs=[];indices=[]
    for j in range(nv+1):
        v=j/nv
        for i in range(nu+1):
            u=i/nu;p=fn(u,v);du=[(b-a) for a,b in zip(fn(u-.0001,v),fn(u+.0001,v))];dv=[b-a for a,b in zip(fn(u,v-.0001),fn(u,v+.0001))]
            n=[du[1]*dv[2]-du[2]*dv[1],du[2]*dv[0]-du[0]*dv[2],du[0]*dv[1]-du[1]*dv[0]]
            if name!='bun': n=[-x for x in n]
            mag=math.sqrt(sum(x*x for x in n))
            if mag<1e-9: n=[0,1 if v<.5 else -1,0];mag=1
            positions.extend(round(x,6) for x in p);normals.extend(round(x/mag,6) for x in n);uvs.extend([u,v])
    for j in range(nv):
        for i in range(nu):
            a=j*(nu+1)+i;b=a+1;c=a+nu+1;d=c+1
            indices.extend([a,b,c,b,d,c] if name=='bun' else [a,c,b,b,c,d])
    data={'id':'snackroll_'+name,'positions':positions,'normals':normals,'uvs':uvs,'indices':indices}
    (OUT/(name+'.json')).write_text(json.dumps(data,separators=(',',':')))
    print(name,len(positions)//3,'vertices',len(indices)//3,'triangles')
def torso(u,v):
    # Shoulder, chest, abdomen and hem form one continuous surface.
    theta=2*math.pi*u;y=(v-.5)*2
    ring=max(.025,math.cos((v-.5)*math.pi))**.2
    width=(.9+.18*math.sin(v*math.pi)-.2*v)*ring
    depth=(.58+.19*math.sin(v*math.pi))*ring
    x=width*math.cos(theta);z=depth*math.sin(theta)-.12*math.sin(v*math.pi)
    return x,y,z
def torus(u,v):
    a=u*2*math.pi;b=v*2*math.pi
    return (1+.36*math.cos(b))*math.cos(a),.36*math.sin(b),(1+.36*math.cos(b))*math.sin(a)
def bun(u,v):
    a=u*2*math.pi;t=v*math.pi
    r=max(0,math.sin(t))**.6
    return r*math.cos(a),math.cos(t)*.35,r*math.sin(a)
surface('shirt',torso,nv=28)
surface('donut',torus,nv=18,closed_v=True)
surface('bun',bun,nv=22)
