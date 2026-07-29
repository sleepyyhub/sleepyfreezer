CELLSEQ=[0]
import pickle,clov18 as clov,lin18 as lin,dec,sys
sys.setrecursionlimit(200000)
from dec import q,BIN

PREC={'or':1,'and':2,'cmp':3,'..':4,'add':5,'mul':6,'unary':7,'^':8,'call':9,'atom':10}
def par(e,need):
    return '('+e[0]+')' if e[1]<need else e[0]

class E:
    pass

class Gen:
    def __init__(self,p,upnames,idc):
        self.p=p; self.up=upnames; self.idc=idc
        self.L=lin.linearize(p)
        self.n=len(self.L)
        self.be={}
        for k in range(self.n):
            for t in self.tg(k):
                if t<=k: self.be.setdefault(t,[]).append(k)
        self.leaders=set([0])
        for k in range(self.n):
            ts=self.tg(k)
            for t in ts: self.leaders.add(t)
            if self.L[k]['name'] in ('JMP','RETURN','FORPREP') or self.L[k]['name'] in clov.BRANCH:
                if k+1<self.n: self.leaders.add(k+1)
        for k,I in enumerate(self.L):
            if I['name']=='GETTABLE' and I['C']==I['B']+1:
                B=I['B']
                import live18 as _lv
                for j in range(k+1,len(self.L)):
                    J=self.L[j]
                    if J['name']=='CALL' and J['B']==B and J['C']>=2: I['name']='SELF'; J['selfcall']=True; break
                    if B+1 in _lv.rdwr(self.L,self.p,j)[1]: break
                    if J['name'] in ('JMP','TEST','TESTNOT','RETURN','FORPREP','FORLOOP','TFORCALL','TFORLOOP'): break
                    if J['name']=='CALL': break
                    if J['B']==B and J['name'] not in ('SETTABLE','SETCELL','SETGLOBAL','SETUPVAL','SETLIST'): break
        import live18 as live
        self.IN,self.RD,self.WR,self.WIDE=live.liveness(self)
        # cell registers created by NEWTABLE
        self.iscell={}
        for k,I in enumerate(self.L):
            if I['name']=='NEWTABLE2': self.iscell[k]=True
            elif I['name']=='NEWTABLE':
                B=I['B']; f=False
                for j in range(k+1,len(self.L)):
                    J=self.L[j]
                    if J['name']=='SETCELL' and J['B']==B: f=True;break
                    if J['name']=='GETCELL' and J['C']==B: f=True;break
                    if J['name']=='CLOSURE' and B in self.RD[j]: f=True;break
                    if B in self.WR[j]: break
                self.iscell[k]=f
        self.cellname={}   # reg -> current name
        self.used=set()
    def tg(self,k):
        i=self.L[k]; n=i['name']; r=[]
        if n=='RETURN': return r
        if n in ('JMP','FORPREP'): return [i['t']]
        if n in clov.BRANCH: r.append(i['t'])
        if k+1<self.n: r.append(k+1)
        return r
    def v(self,i):
        self.used.add(i); return 'v%d'%i

    # ---------- block emission with expression folding ----------
    def emitblock(self,a,b,ind,out):
        st={}   # reg -> (expr,prec,impure,deps set)
        order=[]
        def flush(reg):
            if reg in st:
                e=st.pop(reg); order.remove(reg)
                if isinstance(e[0],tuple) and e[0][0]=='SELF':
                    _,obj,k=e[0]
                    out.append(ind+'%s = %s'%(self.v(reg+1),obj))
                    out.append(ind+'%s = %s'%(self.v(reg),index(self.v(reg+1),k)))
                else:
                    out.append(ind+'%s = %s'%(self.v(reg),mexpr(e)))
        def flushall():
            for r in list(order): flush(r)
        def flushimpure():
            for r in list(order):
                if st[r][2]: flush(r)
        def kill(reg):
            for r in list(order):
                if reg in st[r][3] and r!=reg: flush(r)
            st.pop(reg,None)
            if reg in order: order.remove(reg)
        cur=[0]
        def get(reg):
            if reg in st:
                k=cur[0]
                if reg not in self.IN[k+1] or reg in self.WR[k]:
                    e=st.pop(reg); order.remove(reg); return e
                flush(reg)
            return (self.v(reg),PREC['atom'],False,{reg},False)
        def put(reg,expr,prec,impure,deps,multi=False):
            kill(reg)
            st[reg]=(expr,prec,impure,deps,multi); order.append(reg)
        def setd(reg,expr):
            kill(reg); out.append(ind+'%s = %s'%(self.v(reg),expr))
        i=a
        opn=[None]
        while i<b:
            I=self.L[i]; n=I['name']; B,C,D=I['B'],I['C'],I['D']
            cur[0]=i
            for rr in list(self.RD[i]):
                if list(self.RD[i]).count(rr)>1: flush(rr)
            if n=='MOVE':
                e=get(C)
                if e[3]=={C}: put(B,self.v(C),PREC['atom'],False,{C})
                else: put(B,e[0],e[1],e[2],e[3])
            elif n=='LOADK': put(B,q(self.p.const(C)),PREC['atom'],False,set())
            elif n=='LOADNIL': put(B,'nil',PREC['atom'],False,set())
            elif n=='LOADBOOL': put(B,'true' if C else 'false',PREC['atom'],False,set())
            elif n=='GETGLOBAL': put(B,gname(self.p.const(C)),PREC['atom'],False,set())
            elif n=='SETGLOBAL':
                e=get(B); flushimpure(); out.append(ind+'%s = %s'%(gname(self.p.const(C)),mexpr(e)))
            elif n=='GETTABLE':
                t=get(C); k=get(D)
                put(B,index(par(t,PREC['call']),k),PREC['call'],t[2] or k[2],t[3]|k[3])
            elif n=='SETTABLE':
                t=get(B); k=get(C); val=get(D); flushimpure()
                out.append(ind+'%s = %s'%(index(par(t,PREC['call']),k),mexpr(val)))
            elif n=='SELF':
                t=get(C); k=get(D)
                put(B,('SELF',par(t,PREC['call']),k),10,t[2] or k[2],t[3]|k[3])  # marker
            elif n in ('NEWTABLE','NEWTABLE2'):
                if self.iscell.get(i):
                    CELLSEQ[0]+=1; nm='c%d_%d'%(B,CELLSEQ[0]); self.cellname[B]=nm
                    flushimpure(); out.append(ind+'local %s = nil'%nm); kill(B)
                else: put(B,'{}',PREC['atom'],False,set())
            elif n=='NEWCELL':
                e=get(B); CELLSEQ[0]+=1
                nm='c%d_%d'%(B,CELLSEQ[0]); self.cellname[B]=nm
                flushimpure(); out.append(ind+'local %s = %s'%(nm,mexpr(e)))
                kill(B)
            elif n=='GETCELL': put(B,self.cellname.get(C,'v%d_cell'%C),PREC['atom'],False,set())
            elif n=='SETCELL':
                e=get(C); flushimpure(); out.append(ind+'%s = %s'%(self.cellname.get(B,'v%d_cell'%B),mexpr(e)))
            elif n=='GETUPVAL': put(B,self.up[C-1],PREC['atom'],False,set())
            elif n=='SETUPVAL':
                e=get(B); flushimpure(); out.append(ind+'%s = %s'%(self.up[C-1],mexpr(e)))
            elif n in BIN:
                x=get(C); y=get(D); o=BIN[n]
                pr={'..':PREC['..'],'+':PREC['add'],'-':PREC['add'],'*':PREC['mul'],'/':PREC['mul'],'%':PREC['mul'],'//':PREC['mul'],'^':PREC['^']}.get(o,PREC['cmp'])
                if o=='..': s='%s .. %s'%(par(x,pr+1),par(y,pr))
                elif o=='^': s='%s ^ %s'%(par(x,pr+1),par(y,pr))
                else: s='%s %s %s'%(par(x,pr),o,par(y,pr+1))
                put(B,s,pr,x[2] or y[2],x[3]|y[3])
            elif n=='NOT':
                x=get(C); put(B,'not '+par(x,PREC['unary']),PREC['unary'],x[2],x[3])
            elif n=='UNM':
                x=get(C); put(B,'-'+par(x,PREC['unary']),PREC['unary'],x[2],x[3])
            elif n=='LEN':
                x=get(C); put(B,'#'+par(x,PREC['unary']),PREC['unary'],x[2],x[3])
            elif n=='CLOSURE':
                ch=self.p.children[C-1]; desc=ch.upvals; ups=[]
                for x in range(len(desc)//2):
                    aa=clov.dec32(desc[2*x],2*x+1,ch.kA0,ch.kB0,0)
                    bb=clov.dec32(desc[2*x+1],2*x+2,ch.kA0,ch.kB0,0)
                    ups.append(self.cellname.get(bb,'v%d_cell'%bb) if aa==1 else self.up[bb])
                g=Gen(ch,ups,self.idc)
                sub=g.render(ind)
                put(B,('CLOSURE',sub),10,False,set())
            elif n=='VARARG':
                if C==0: opn[0]=B; put(B,('MULTI','...'),10,False,set(),True)
                else:
                    vs=', '.join(self.v(B+x) for x in range(C-1))
                    flushimpure()
                    for x in range(C-1): kill(B+x)
                    out.append(ind+'%s = ...'%vs if C-1==1 else ind+'%s = ...'%vs)
            elif n=='CALL':
                f=get(B)
                dep=set(f[3]) if f[3] else set()
                args=[]
                def _g(rr):
                    e=get(rr)
                    if e[3]: dep.update(e[3])
                    return e
                if C==0:
                    base=opn[0] if (opn[0] is not None and opn[0]>=B+1) else B+1
                    args=[mexpr(_g(B+1+x)) for x in range(base-(B+1))]+[mexpr(_g(base))]
                else:
                    for x in range(C-1):
                        e=_g(B+1+x)
                        args.append(trunc(e) if x==C-2 else mexpr(e))
                if isinstance(f[0],tuple) and f[0][0]=='SELF':
                    _,obj,k=f[0]
                    args=args[1:]
                    kk=k[0]
                    if isinstance(kk,str) and kk.startswith('"') and isname(kk[1:-1]):
                        cs='%s:%s(%s)'%(obj,kk[1:-1],', '.join(args))
                    else:
                        cs='%s[%s](%s)'%(obj,kk,', '.join(['__self__']+args))
                else:
                    cs='%s(%s)'%(par((mexpr(f),f[1] if not isinstance(f[0],tuple) else 10),PREC['call']),', '.join(args))
                if D==0: opn[0]=B; put(B,('MULTI',cs),10,True,dep,True)
                elif D==1: flushimpure(); flushall(); out.append(ind+cs)
                elif D==2: flushimpure(); put(B,cs,PREC['call'],True,dep,True)
                else:
                    flushimpure(); flushall()
                    vs=', '.join(self.v(B+x) for x in range(D-1))
                    for x in range(D-1): kill(B+x)
                    out.append(ind+'%s = %s'%(vs,cs))
            elif n=='SETLIST':
                t=get(B)
                if C==0:
                    base=opn[0] if (opn[0] is not None and opn[0]>=B+1) else B+1
                    fixed=[mexpr(get(B+1+x)) for x in range(base-(B+1))]
                    e=get(base); flushimpure()
                    tn=mexpr(t)
                    for x,it in enumerate(fixed): out.append(ind+'%s[%d] = %s'%(tn,D+1+x,it))
                    out.append(ind+'table.move(table.pack(%s), 1, -1, %d, %s)'%(mexpr(e),D+1+len(fixed),tn))
                else:
                    flushimpure()
                    tn=t[0]
                    if tn!='{}' and not isname(tn): pass
                    _it=[get(B+1+x) for x in range(C-1)]
                    items=[trunc(e) if x==C-2 else mexpr(e) for x,e in enumerate(_it)]
                    if t[0]=='{}' and D==0:
                        put(B,'{ '+', '.join(items)+' }',PREC['atom'],False,set())
                    else:
                        setd(B,tn)
                        for x,it in enumerate(items): out.append(ind+'%s[%d] = %s'%(self.v(B),D+x+1,it))
            elif n=='RETURN':
                if C==1: flushall(); out.append(ind+'return')
                elif C==0:
                    base=opn[0] if (opn[0] is not None and opn[0]>=B) else B
                    es=[mexpr(get(B+x)) for x in range(base-B)]+[mexpr(get(base))]
                    flushall(); out.append(ind+'return '+', '.join(es))
                else:
                    es=[get(B+x) for x in range(C-1)]
                    es=[trunc(e) if x==C-2 else mexpr(e) for x,e in enumerate(es)]
                    flushall(); out.append(ind+'return '+', '.join(es))
            elif n in ('TEST','TESTNOT','JMP','FORPREP','FORLOOP','TFORCALL','TFORLOOP'):
                if n in ('TEST','TESTNOT'):
                    e=get(B); self.cond=e
                flushall(); return i
            else:
                out.append(ind+'-- ?? '+n)
            i+=1
        flushall()
        return i

import re
def isname(s): return bool(re.match(r'^[A-Za-z_]\w*$',s)) and s not in ('end','then','do','local','function','if','while','for','return','nil','true','false','and','or','not','repeat','until','else','elseif','in','break','continue')
def gname(s): return s if isname(s) else 'ENV[%s]'%q(s)
def index(t,k):
    kk=k[0]
    if isinstance(kk,str) and kk.startswith('"') and isname(kk[1:-1]): return '%s.%s'%(t,kk[1:-1])
    return '%s[%s]'%(t,par(k,0))
def trunc(e):
    return '('+mexpr(e)+')' if (len(e)>4 and e[4]) else mexpr(e)
def mexpr(e):
    if isinstance(e[0],tuple):
        if e[0][0]=='MULTI': return e[0][1]
        if e[0][0]=='CLOSURE': return e[0][1]
        if e[0][0]=='SELF': return '%s%s'%(e[0][1],index('',e[0][2]))
    return e[0]

def _nexthdr(self,a,b):
    for h in range(a+1,b):
        if h in self.be and any(a<=j<b for j in self.be[h]): return h
    return b
Gen._nexthdr=_nexthdr

def body(self,a,b,ctx,ind,skiph=None):
    out=[]; i=a
    while i<b:
        if i!=skiph and i in self.be and any(a<=j<b for j in self.be[i]):
            end=max(j for j in self.be[i] if a<=j<b)
            out+=self.loop(i,end,ctx,ind); i=end+1; continue
        lim=self._nexthdr(i,b)
        j=self.emitblock(i,lim,ind,out)
        if j>=lim: i=lim; continue
        I=self.L[j]; n=I['name']
        if n in ('TEST','TESTNOT'):
            t=I['t']
            if j<t<=b:
                c=self.cond
                cond=('not '+par(c,PREC['unary'])) if n=='TEST' else par(c,0)
                thn=(j+1,t); els=None; nxt=t
                if t-1>j and self.L[t-1]['name']=='JMP' and t<self.L[t-1]['t']<=b:
                    e=self.L[t-1]['t']; thn=(j+1,t-1); els=(t,e); nxt=e
                bl=self.body(thn[0],thn[1],ctx,ind+'\t')
                if els is None and len(bl)==1:
                    tgt='%s = '%self.v(I['B'])
                    ln=bl[0].strip()
                    if ln.startswith(tgt):
                        ex=ln[len(tgt):]
                        if ' or ' in ex or ' and ' in ex: ex='('+ex+')'
                        op='and' if n=='TESTNOT' else 'or'
                        rc=par(c,0)
                        if ' or ' in rc or ' and ' in rc: rc='('+rc+')'
                        out.append(ind+'%s = %s %s %s'%(self.v(I['B']),rc,op,ex))
                        i=nxt; continue
                out.append(ind+'if %s then'%cond)
                out+=bl
                if els:
                    out.append(ind+'else')
                    out+=self.body(els[0],els[1],ctx,ind+'\t')
                out.append(ind+'end'); i=nxt; continue
            if self.L[t]['name']=='RETURN':
                c=self.cond
                cond=par(c,0) if n=='TEST' else ('not '+par(c,PREC['unary']))
                out.append(ind+'if %s then %s end'%(cond,self.retstmt(t))); i=j+1; continue
            act=None
            for kind,tgt in reversed(ctx):
                if t==tgt: act='break' if kind=='loop' else 'continue'; break
            if act:
                c=self.cond
                cond=par(c,0) if n=='TEST' else ('not '+par(c,PREC['unary']))
                out.append(ind+'if %s then %s end'%(cond,act)); i=j+1; continue
            out.append(ind+'-- UNSTRUCTURED TEST -> %d'%t); i=j+1; continue
        if n=='JMP':
            t=I['t']
            if t>j:
                e=t
                while e<self.n and self.L[e]['name'] not in ('TEST','TESTNOT','JMP','RETURN','FORPREP','FORLOOP','TFORCALL','TFORLOOP'): e+=1
                if e<self.n and self.L[e]['name']=='TFORCALL' and e+1<self.n and self.L[e+1]['name']=='TFORLOOP' and self.L[e+1]['t']==j+1:
                    T=self.L[e]; B=T['B']; nv=max(T['D'],1)
                    vs=', '.join(self.v(B+3+x) for x in range(nv))
                    out.append(ind+'for %s in %s, %s, %s do'%(vs,self.v(B),self.v(B+1),self.v(B+2)))
                    out+=self.body(j+1,t,ctx+[('loop',e+2)],ind+'\t')
                    out.append(ind+'end'); i=e+2; continue
                if e<self.n and self.L[e]['name'] in ('TEST','TESTNOT') and self.L[e]['t']==j+1:
                    out.append(ind+'while true do')
                    sub=[]
                    self.emitblock(t,e+1,ind+'\t',sub)
                    c=self.cond
                    cond=par(c,PREC['unary']) if self.L[e]['name']=='TEST' else ('not '+par(c,PREC['unary']))
                    out+=sub
                    out.append(ind+'\tif %s then break end'%cond)
                    out+=self.body(j+1,t,ctx+[('loop',e+1)],ind+'\t')
                    out.append(ind+'end'); i=e+1; continue
                if e<self.n and self.L[e]['name']=='FORLOOP' and self.L[e]['t']==j+1:
                    B=self.L[e]['B']
                    out.append(ind+'for %s = %s, %s, %s do'%(self.v(B+3),self.v(B),self.v(B+1),self.v(B+2)))
                    out+=self.body(j+1,t,ctx+[('loop',e+1)],ind+'\t')
                    out.append(ind+'end'); i=e+1; continue
            done=False
            for kind,tgt in reversed(ctx):
                if t==tgt:
                    out.append(ind+('break' if kind=='loop' else 'continue')); done=True; break
            if done: i=j+1; continue
            if t==b: i=j+1; continue
            if self.L[t]['name']=='RETURN':
                out.append(ind+self.retstmt(t)); i=j+1; continue
            if j<t<=b: i=t; continue
            out.append(ind+'-- UNSTRUCTURED JMP -> %d'%t); i=j+1; continue
        if n=='RETURN': i=j+1; continue
        if n=='FORPREP':
            f=I['t']; B=I['B']
            if f<self.n and self.L[f]['name']=='FORLOOP' and f+1<self.n and self.L[f+1]['name']=='JMP':
                bs=self.L[f]['t']; ex=self.L[f+1]['t']
                out.append(ind+'for %s = %s, %s, %s do'%(self.v(B+3),self.v(B),self.v(B+1),self.v(B+2)))
                out+=self.body(bs,ex,ctx+[('loop',ex),('cont',f)],ind+'\t')
                out.append(ind+'end'); i=ex; continue
            if f>j:
                out.append(ind+'for %s = %s, %s, %s do'%(self.v(B+3),self.v(B),self.v(B+1),self.v(B+2)))
                out+=self.body(j+1,f,ctx+[('loop',f+1)],ind+'\t')
                out.append(ind+'end'); i=f+1; continue
        out.append(ind+'-- UNSTRUCTURED %s'%n); i=j+1; continue
    return out
Gen.body=body

def loop(self,h,end,ctx,ind):
    I=self.L[end]
    if I['name']=='FORLOOP' and I['t']==h:
        B=I['B']
        r=[ind+'for %s = %s, %s, %s do'%(self.v(B+3),self.v(B),self.v(B+1),self.v(B+2))]
        r+=self.body(h,end,ctx+[('loop',end+1)],ind+'\t'); r.append(ind+'end'); return r
    if I['name']=='TFORLOOP' and I['t']==h:
        j=end-1
        while j>h and self.L[j]['name']!='TFORCALL': j-=1
        T=self.L[j]; B=T['B']; nv=max(T['D'],1)
        vs=', '.join(self.v(B+3+x) for x in range(nv))
        r=[ind+'for %s in %s, %s, %s do'%(vs,self.v(B),self.v(B+1),self.v(B+2))]
        r+=self.body(h,j,ctx+[('loop',end+1)],ind+'\t'); r.append(ind+'end'); return r
    if self.L[h]['name']=='TFORCALL' and h+1<self.n and self.L[h+1]['name']=='TFORLOOP' and self.L[h+1]['t']==h+3:
        T=self.L[h]; B=T['B']; nv=max(T['D'],1)
        vs=', '.join(self.v(B+3+x) for x in range(nv))
        ex=self.L[h+2]['t'] if self.L[h+2]['name']=='JMP' else end+1
        r=[ind+'for %s in %s, %s, %s do'%(vs,self.v(B),self.v(B+1),self.v(B+2))]
        r+=self.body(h+3,max(ex,end+1) if ex<=h else ex,ctx+[('loop',ex),('cont',h)],ind+'\t'); r.append(ind+'end')
        self.jumpout=ex; return r
    hdr=self.L[h]
    if hdr['name'] in ('TEST','TESTNOT') and hdr['t']==end+1:
        o=[]; self.emitblock(h,h,'',o)
        e=self.emitblock(h,h+1,ind,o)
        c=self.cond
        cond=('not '+par(c,PREC['unary'])) if hdr['name']=='TEST' else par(c,0)
        r=[ind+'while %s do'%cond]
        r+=self.body(h+1,end,ctx+[('loop',end+1)],ind+'\t'); r.append(ind+'end'); return r
    r=[ind+'while true do']
    e=end+(0 if self.L[end]['name']=='JMP' and self.L[end]['t']==h else 1)
    r+=self.body(h,e,ctx+[('loop',end+1),('cont',h)],ind+'\t',skiph=h)
    r.append(ind+'end'); return r
Gen.loop=loop

def render(self,ind):
    self.be={}
    for k in range(self.n):
        for t in self.tg(k):
            if t<=k: self.be.setdefault(t,[]).append(k)
    params=[ 'v%d'%i for i in range(self.p.nparam)]
    if self.p.vararg: params.append('...')
    b=self.body(0,self.n,[],ind+'\t')
    decl=sorted(x for x in self.used if x>=self.p.nparam)
    head=[]
    if decl:
        head=[ind+'\tlocal '+', '.join('v%d'%x for x in decl)]
    return 'function(%s)\n'%(', '.join(params))+'\n'.join(head+b)+'\n'+ind+'end'
Gen.render=render

def retstmt(self,t):
    I=self.L[t]; B,C=I['B'],I['C']
    if C==1: return 'return'
    if C==0: return 'return %s'%self.v(B)
    return 'return '+', '.join(self.v(B+x) for x in range(C-1))
Gen.retstmt=retstmt

def prune(src):
    L=src.split('\n'); out=[]; i=0
    def ind(s): return len(s)-len(s.lstrip('\t'))
    while i<len(L):
        s=L[i]; out.append(s); t=s.strip()
        if ('function' not in t) and (t=='return' or t.startswith('return ') or t=='break' or t=='continue'):
            d=ind(s); i+=1
            while i<len(L) and ind(L[i])>=d: i+=1
            continue
        i+=1
    return '\n'.join(out)

def render_threaded(self, ind):
    # Guaranteed-correct fallback: emit a pc-threaded basic-block dispatch loop.
    self.be={}
    for k in range(self.n):
        for t in self.tg(k):
            if t<=k: self.be.setdefault(t,[]).append(k)
    leaders=set([0])
    for k in range(self.n):
        for t in self.tg(k): leaders.add(t)
        if self.L[k]['name'] in ('JMP','RETURN','FORPREP','FORLOOP','TFORLOOP','TEST','TESTNOT'):
            if k+1<self.n: leaders.add(k+1)
    leaders={x for x in leaders if 0<=x<self.n}
    order=sorted(leaders)
    params=['v%d'%i for i in range(self.p.nparam)]
    if self.p.vararg: params.append('...')
    out=[ind+'\tlocal __pc = %d'%0]
    out.append(ind+'\twhile true do')
    for bi,b in enumerate(order):
        end=self.n
        for nb in order:
            if nb>b: end=nb; break
        kw='if' if bi==0 else 'elseif'
        out.append(ind+'\t\t%s __pc == %d then'%(kw,b))
        body=[]
        self._emit_block_threaded(b,end,ind+'\t\t\t',body)
        out+=body
    out.append(ind+'\t\telse return end')
    out.append(ind+'\tend')
    # collect declared regs
    decl=sorted(x for x in self.used if x>=self.p.nparam)
    head=''
    if decl: head=ind+'\tlocal '+', '.join('v%d'%x for x in decl)+'\n'
    return 'function(%s)\n%s'%(', '.join(params),head)+'\n'.join(out)+'\n'+ind+'end'

def _emit_block_threaded(self,a,b,ind,out):
    # straight-line ops until a terminator, then set __pc
    i=a
    while i<b:
        I=self.L[i]; n=I['name']
        if n in ('TEST','TESTNOT'):
            o=[]; self.emitblock(i,i,'',o)  # ensure cond captured
            self.emitblock(i,i+1,ind,out)
            c=self.cond
            cond=('not '+par(c,PREC['unary'])) if n=='TEST' else par(c,0)
            out.append(ind+'if %s then __pc = %d else __pc = %d end'%(cond,I['t'],i+1))
            out.append(ind+'-- fallthrough'); return
        if n=='JMP':
            self.emitblock(i,i,ind,out)
            out.append(ind+'__pc = %d'%I['t']); return
        if n in ('FORPREP','FORLOOP','TFORLOOP'):
            self.emitblock(i,i+1,ind,out)
            # these set pc via C on branch; approximate with explicit
            out.append(ind+'__pc = %d'%(I['t'] if n=='FORPREP' else I['t']))
            return
        if n=='RETURN':
            self.emitblock(i,i+1,ind,out); return
        i+=1
    self.emitblock(a,b,ind,out) if False else None
    out.append(ind+'__pc = %d'%b)
Gen.render_threaded=render_threaded
Gen._emit_block_threaded=_emit_block_threaded
