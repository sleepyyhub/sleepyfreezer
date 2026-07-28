import pickle,clov,dec
r=clov.Proto(pickle.load(open('proto.pkl','rb')))
names={}; order=[]
def nm(p,path):
    names[id(p)]='fn_'+('_'.join(map(str,path)) or 'main'); order.append(p)
    for k,c in enumerate(p.children): nm(c,path+[k+1])
nm(r,[])
out=[]
for p in reversed(order):
    d=dec.Dec(p,names[id(p)],names)
    ups=len(p.upvals)//2
    hdr=', '.join(['u%d'%(i+1) for i in range(ups)])
    params=', '.join('r%d'%i for i in range(p.nparam))+(', ...' if p.vararg else '')
    params=params.lstrip(', ')
    out.append(f"-- proto {names[id(p)]}  params={p.nparam} vararg={p.vararg} upvals={ups} instrs={len(d.L)}")
    out.append(f"local function {names[id(p)]}({hdr})")
    out.append(f"\treturn function({params})")
    body=d.run()
    out+=['\t'+x for x in body]
    out.append("\tend")
    out.append("end\n")
out.append("return fn_main()()")
open('out.lua','w').write('\n'.join(out))
print(len(out))
