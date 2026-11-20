#!/usr/bin/env python3
"""The AI Denoise example in Help: Atelier's built-in PMRID model (Sources/AtelierCore/Models)
run on the RAW mosaic of Rosh's DSC_0348 (Nikon D3100, ISO 2800, a doe at dusk), the same way
the AT-067 test kit ran it. Writes the doe at 100% before and after into Scripts/help/data, so
Help builds without the NEF. Only the pixels are kept.

    pip install rawpy onnxruntime numpy pillow
    python3 Scripts/help/pmrid_example.py "/path/to/for Atelier/DSC_0348.NEF"
"""
import sys, numpy as np, rawpy, onnxruntime as ort
from PIL import Image
def estimate(planes, block=16):
    """planes: 4,H,W in [0,1]. Returns (a, b) with noise variance = a*x + b."""
    means, vars_ = [], []
    for p in planes:
        d = (4*p[1:-1,1:-1] - p[:-2,1:-1] - p[2:,1:-1] - p[1:-1,:-2] - p[1:-1,2:]) / np.sqrt(20.0)
        q = p[1:-1,1:-1]
        H, W = (q.shape[0]//block)*block, (q.shape[1]//block)*block
        qb = q[:H,:W].reshape(H//block, block, W//block, block)
        db = d[:H,:W].reshape(H//block, block, W//block, block)
        means.append(qb.mean(axis=(1,3)).ravel()); vars_.append(db.var(axis=(1,3)).ravel())
    m = np.concatenate(means); v = np.concatenate(vars_)
    ok = (m > 0.002) & (m < 0.9)
    m, v = m[ok], v[ok]
    edges = np.quantile(m, np.linspace(0, 1, 41))
    xs, ys = [], []
    for lo, hi in zip(edges[:-1], edges[1:]):
        sel = (m >= lo) & (m < hi)
        if sel.sum() < 20: continue
        vv = np.sort(v[sel]); xs.append(m[sel].mean()); ys.append(vv[:max(5, len(vv)//10)].mean())
    xs, ys = np.array(xs), np.array(ys)
    # flattest 10% underestimates variance by a constant factor for chi-square spread; correct it
    ys = ys * 1.22  # the flattest tenth of 16x16 blocks reads about 0.82 of the true variance (checked on synthetic noise)
    a, b = np.polyfit(xs, ys, 1)
    return a, b, xs, ys

V=959.0; K=np.poly1d([0.0005995267,0.00868861]); S_=np.poly1d([7.11772e-7,6.514934e-4,0.11492713]); KA,SA=K(1600),S_(1600)
import os
ROOT=os.path.abspath(os.path.join(os.path.dirname(__file__),'..','..'))
nef=sys.argv[1]; out=os.path.join(ROOT,'Scripts/help/data'); box=(0.135,0.28,0.17,0.30)
sess=ort.InferenceSession(os.path.join(ROOT,'Sources/AtelierCore/Models/PMRID.onnx'))
def pack(raw):
    data=raw.raw_image_visible.astype(np.float32); black=np.array(raw.black_level_per_channel,np.float32); white=float(raw.white_level)
    pat=raw.raw_pattern; desc=raw.color_desc.decode(); H,W=(data.shape[0]//2)*2,(data.shape[1]//2)*2; data=data[:H,:W]
    planes,where={}, {}; g=0
    for dy in range(2):
        for dx in range(2):
            idx=pat[dy,dx]; ch=desc[idx]; p=(data[dy::2,dx::2]-black[idx])/(white-black[idx])
            key=ch if ch!='G' else 'G'+str(g); g+= ch=='G'; planes[key]=p; where[key]=(dy,dx,idx)
    o=['R','G0','G1','B']; return np.stack([planes[k] for k in o]),[where[k] for k in o],black,white
def tiled(x,tile=512,ov=64,mul=32):
    C,H,W=x.shape; out=np.zeros_like(x); wt=np.zeros((H,W),np.float32); st=tile-ov
    ys=list(range(0,max(H-tile,0)+1,st)) or [0]; xs=list(range(0,max(W-tile,0)+1,st)) or [0]
    if ys[-1]+tile<H: ys.append(H-tile)
    if xs[-1]+tile<W: xs.append(W-tile)
    for y in ys:
        for x0 in xs:
            p=x[:,y:y+tile,x0:x0+tile]; h,w=p.shape[1:]
            pp=np.pad(p,((0,0),(0,tile-h),(0,tile-w)),mode='reflect')  # the app's model takes 512 x 512 tiles
            r=sess.run(None,{'input':pp[None].astype(np.float32)})[0][0][:,:h,:w]
            ry=np.minimum(np.arange(h)+1,np.arange(h)[::-1]+1).astype(np.float32); rx=np.minimum(np.arange(w)+1,np.arange(w)[::-1]+1).astype(np.float32)
            m=np.minimum(np.minimum.outer(ry,rx),ov/2+1); out[:,y:y+h,x0:x0+w]+=r*m; wt[y:y+h,x0:x0+w]+=m
    return out/wt
def render(raw):
    return raw.postprocess(use_camera_wb=True,no_auto_bright=True,gamma=(1,1),output_bps=16,output_color=rawpy.ColorSpace.sRGB,user_flip=0).astype(np.float32)/65535
enc=lambda x: np.where(x<=0.0031308,12.92*x,1.055*np.power(np.clip(x,0,1),1/2.4)-0.055)
with rawpy.imread(nef) as raw:
    planes,where,black,white=pack(raw); a,b,_,_=estimate(planes)
    H2,W2=planes.shape[1:]; y0,y1=int(box[1]*H2)-40,int((box[1]+box[3])*H2)+40; x0,x1=int(box[0]*W2)-40,int((box[0]+box[2])*W2)+40
    orig=render(raw)
    k,s=a*V,b*V*V; ck=KA/k; cb=(s/k**2-SA/KA**2)*KA
    sub=planes[:,y0:y1,x0:x1]; x=(sub*V*ck+cb)/V*256
    y=tiled(x.astype(np.float32)); den=((y/256*V)-cb)/ck/V
    full=planes.copy(); full[:,y0:y1,x0:x1]=den
    data=raw.raw_image_visible
    for p,(dy,dx,idx) in zip(full,where):
        h,w=p.shape; data[dy:dy+2*h:2,dx:dx+2*w:2]=np.round(np.clip(p,0,1)*(white-black[idx])+black[idx]).astype(data.dtype)
    clean=render(raw)
H,W=orig.shape[:2]; c=(slice(int(box[1]*H),int((box[1]+box[3])*H)),slice(int(box[0]*W),int((box[0]+box[2])*W)))
o,cl=orig[c],clean[c]; gain=0.62/max(np.percentile(o,99.5),1e-4)
for name,img in (('before',o),('after',cl)):
    Image.fromarray((enc(img*gain)*255+.5).astype(np.uint8)).convert('RGB').save(f'{out}/deer-pmrid-{name}.jpg',quality=93)
print('gain',gain,'noise',a*V,b*V*V)
