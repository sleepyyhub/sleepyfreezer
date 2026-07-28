import clov
def linearize(p):
    ins=clov.walk(p)
    order=[]; emitted={}
    def succ_next(i):
        n=i['name']
        if n=='RETURN': return None
        if n=='JMP': return None
        if n=='FORPREP': return None
        return i['next']
    stack=[p.entry]
    while stack:
        pc=stack.pop(0)
        if pc in emitted: continue
        while pc is not None and pc not in emitted:
            i=ins[pc]; emitted[pc]=len(order); order.append(i)
            n=i['name']
            if n=='JMP': stack.insert(0,i['B']); break
            if n=='FORPREP': stack.insert(0,i['C']); break
            if n=='RETURN': break
            if n in ('TFORLOOP','FORLOOP'):
                stack.insert(0,i['next']); pc=i['C']; continue
            elif n in clov.BRANCH: stack.append(i['C'])
            pc=i['next']
    # build linear list with explicit jumps
    lin=[]; pos={}
    for i in order:
        pos[i['pc']]=len(lin); lin.append(dict(i))
    # fix: after each instr, if its natural successor != following instr, add JMP
    out=[]; newpos={}
    for k,i in enumerate(lin):
        newpos[i['pc']]=len(out); out.append(i)
        n=i['name']
        if n in ('RETURN','JMP','FORPREP'): continue
        nx=i['next']
        if k+1>=len(lin) or lin[k+1]['pc']!=nx:
            out.append(dict(name='JMP',op=None,B=nx,C=0,D=0,next=nx,pc=-1))
    for i in out:
        i['t']=None
        if i['name']=='JMP': i['t']=newpos[i['B']]
        elif i['name']=='FORPREP': i['t']=newpos[i['C']]
        elif i['name'] in clov.BRANCH: i['t']=newpos[i['C']]
    return out
