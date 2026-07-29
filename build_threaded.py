import pickle,clov18 as C,lift_threaded as LT
r=C.Proto(pickle.load(open('proto18.pkl','rb')))
names={}; order=[]
def nm(p,path):
    names[id(p)]='fn_'+('_'.join(map(str,path)) or 'main'); order.append(p)
    for k,c in enumerate(p.children): nm(c,path+[k+1])
nm(r,[])
out=['-- Fully threaded (1:1 with VM) reconstruction — behavioral verifier','local F={}']
for p in order:
    ups=len(p.upvals)//2
    upn=['U%d'%(i+1) for i in range(ups)]
    fn=names[id(p)]
    body=LT.lift(p, upn, lambda ch: 'F["%s"]'%names[id(ch)])
    hdr=', '.join(upn)
    out.append('F["%s"] = function(%s)'%(fn,hdr))
    out.append('  return '+body)
    out.append('end')
out.append('THREADED = F["fn_main"]()')
open('harness18/recon_threaded.lua','w').write('\n'.join(out)+'\n')
print('protos emitted',len(order))
