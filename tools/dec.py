import clov,lin,pickle,sys
sys.setrecursionlimit(100000)

def q(s):
    if isinstance(s,str):
        r=repr(s)
        if r.startswith("'") and '"' not in s: r='"'+r[1:-1].replace('\\\'',"'")+'"'
        return r
    if isinstance(s,float):
        if s==float('inf'): return 'math.huge'
        if s==float('-inf'): return '-math.huge'
        return repr(s)
    return str(s)

BIN={'ADD':'+','SUB':'-','MUL':'*','DIV':'/','MOD':'%','POW':'^','IDIV':'//','CONCAT':'..',
     'EQ':'==','NE':'~=','LT':'<','LE':'<=','GT':'>','GE':'>='}

class Dec:
    def __init__(self,p,name,fnnames):
        self.p=p; self.name=name; self.fn=fnnames
        self.L=lin.linearize(p)
        self.n=len(self.L)
        self.top={}   # register holding "top" marker after open call
        self.preds={}
        for k,i in enumerate(self.L):
            for t in self.targets(k):
                self.preds.setdefault(t,set()).add(k)
    def targets(self,k):
        i=self.L[k]; n=i['name']; r=[]
        if n=='RETURN': return r
        if n in ('JMP','FORPREP'): return [i['t']]
        if n in clov.BRANCH: r.append(i['t'])
        if k+1<self.n: r.append(k+1)
        return r
    def R(self,i): return 'r%d'%i
    def const(self,c): return q(self.p.const(c))

    # ---- statement emission for straight-line ops
    def stmt(self,k,out):
        i=self.L[k]; n=i['name']; B,C,D=i['B'],i['C'],i['D']; R=self.R
        if n=='MOVE': out.append(f"{R(B)} = {R(C)}")
        elif n=='LOADK': out.append(f"{R(B)} = {self.const(C)}")
        elif n=='LOADNIL': out.append(f"{R(B)} = nil")
        elif n=='LOADBOOL': out.append(f"{R(B)} = {'true' if C!=0 else 'false'}")
        elif n=='GETGLOBAL': out.append(f"{R(B)} = ENV[{self.const(C)}]")
        elif n=='SETGLOBAL': out.append(f"ENV[{self.const(C)}] = {R(B)}")
        elif n=='GETTABLE': out.append(f"{R(B)} = {R(C)}[{R(D)}]")
        elif n=='SETTABLE': out.append(f"{R(B)}[{R(C)}] = {R(D)}")
        elif n=='SELF': out.append(f"{R(B+1)} = {R(C)}"); out.append(f"{R(B)} = {R(C)}[{R(D)}]")
        elif n in ('NEWTABLE','NEWTABLE2'): out.append(f"{R(B)} = {{}}")
        elif n=='NEWCELL': out.append(f"{R(B)} = {{{R(B)}}}")
        elif n=='GETCELL': out.append(f"{R(B)} = {R(C)}[1]")
        elif n=='SETCELL': out.append(f"{R(B)}[1] = {R(C)}")
        elif n=='GETUPVAL': out.append(f"{R(B)} = u{C}[1]")
        elif n=='SETUPVAL': out.append(f"u{C}[1] = {R(B)}")
        elif n in BIN: out.append(f"{R(B)} = {R(C)} {BIN[n]} {R(D)}")
        elif n=='NOT': out.append(f"{R(B)} = not {R(C)}")
        elif n=='UNM': out.append(f"{R(B)} = -{R(C)}")
        elif n=='LEN': out.append(f"{R(B)} = #{R(C)}")
        elif n=='CLOSURE':
            ch=self.p.children[C-1]
            ups=[]
            d=self.p.t[12]
            desc=ch.t[12]
            for x in range(len(desc)//2):
                a=clov.dec32(desc[2*x],2*x+1,ch.kA,ch.kB,0)
                b=clov.dec32(desc[2*x+1],2*x+2,ch.kA,ch.kB,0)
                ups.append(R(b) if a==1 else 'u%d'%(b+1))
            out.append(f"{R(B)} = {self.fn[id(ch)]}({', '.join(ups)})" if ups else f"{R(B)} = {self.fn[id(ch)]}()")
        elif n=='VARARG':
            cnt=C-1
            if C==0: out.append(f"local __v = table.pack(...) -- vararg expand at {R(B)}"); out.append(f"TOP_SPREAD({R(B)}, __v)")
            else:
                for x in range(cnt): out.append(f"{R(B+x)} = (select({x+1}, ...))")
        elif n=='CALL':
            na=C-1; nr=D-1
            args=', '.join(R(B+1+x) for x in range(na)) if C!=0 else 'TOPARGS'
            if D==0: out.append(f"MULTI_CALL {R(B)}({args})")
            elif nr==0: out.append(f"{R(B)}({args})")
            else: out.append(f"{', '.join(R(B+x) for x in range(nr))} = {R(B)}({args})")
        elif n=='SETLIST':
            nn=C-1
            if C==0: out.append(f"SETLIST_MULTI({R(B)}, {D})")
            else:
                for x in range(1,nn+1): out.append(f"{R(B)}[{D+x}] = {R(B+x)}")
        else: out.append(f"-- ?? {n} {B} {C} {D}")

    def backedges(self):
        be={}
        for k in range(self.n):
            for t in self.targets(k):
                if t<=k: be.setdefault(t,[]).append(k)
        return be

    def body(self,a,b,ctx,ind,skiph=None):
        out=[];i=a
        BE=self.be
        while i<b:
            I=self.L[i]; n=I['name']
            # loop header?
            if i!=skiph and i in BE and any(a<=j<b for j in BE[i]):
                end=max(j for j in BE[i] if a<=j<b)
                out+=self.loop(i,end,ctx,ind); i=end+1; continue
            if n=='FORPREP':
                f=I['t']
                if f>i:
                    B=I['B']
                    out.append(ind+f"for r{B+3} = r{B}, r{B+1}, r{B+2} do")
                    out+=self.body(i+1,f,ctx+[('loop',f+1)],ind+'\t')
                    out.append(ind+"end"); i=f+1; continue
            if n in ('TEST','TESTNOT'):
                t=I['t']
                if i<t<=b:
                    cond=('not r%d'%I['B']) if n=='TEST' else ('r%d'%I['B'])
                    thn=(i+1,t); els=None; nxt=t
                    if t-1>i and self.L[t-1]['name']=='JMP' and t<self.L[t-1]['t']<=b:
                        e=self.L[t-1]['t']; thn=(i+1,t-1); els=(t,e); nxt=e
                    out.append(ind+f"if {cond} then")
                    out+=self.body(thn[0],thn[1],ctx,ind+'\t')
                    if els:
                        out.append(ind+"else")
                        out+=self.body(els[0],els[1],ctx,ind+'\t')
                    out.append(ind+"end"); i=nxt; continue
            if n=='JMP':
                t=I['t']
                done=False
                for kind,tgt in reversed(ctx):
                    if t==tgt:
                        out.append(ind+('break' if kind=='loop' else 'continue')); done=True; break
                if done: i+=1; continue
                if t==b: i+=1; continue
                if t>i and t<=b:
                    # forward jump inside: treat as skip
                    out+=self.body(i+1,t,ctx,ind); i=t; continue
                out.append(ind+f"-- UNSTRUCTURED JMP -> {t}"); i+=1; continue
            if n=='RETURN':
                B,C=I['B'],I['C']
                if C==1: out.append(ind+"return")
                elif C==0: out.append(ind+f"return RETMULTI(r{B})")
                else: out.append(ind+"return "+', '.join('r%d'%(B+x) for x in range(C-1)))
                i+=1; continue
            s=[]; self.stmt(i,s)
            out+= [ind+x for x in s]; i+=1
        return out

    def loop(self,h,end,ctx,ind):
        I=self.L[end]
        if I['name']=='FORLOOP' and I['t']==h:
            B=I['B']
            r=[ind+f"for r{B+3} = r{B}, r{B+1}, r{B+2} do"]
            r+=self.body(h,end,ctx+[('loop',end+1)],ind+'\t'); r.append(ind+"end"); return r
        if I['name']=='TFORLOOP' and I['t']==h:
            # find tforcall just before
            j=end-1
            while j>h and self.L[j]['name']!='TFORCALL': j-=1
            T=self.L[j]; B=T['B']; nv=T['D']
            vs=', '.join('r%d'%(B+3+x) for x in range(max(nv,1)))
            r=[ind+f"for {vs} in r{B}, r{B+1}, r{B+2} do"]
            r+=self.body(h,j,ctx+[('loop',end+1)],ind+'\t'); r.append(ind+"end"); return r
        hdr=self.L[h]
        if hdr['name'] in ('TEST','TESTNOT') and hdr['t']==end+1:
            cond=('not r%d'%hdr['B']) if hdr['name']=='TEST' else ('r%d'%hdr['B'])
            r=[ind+f"while {cond} do"]
            r+=self.body(h+1,end,ctx+[('loop',end+1)],ind+'\t'); r.append(ind+"end"); return r
        r=[ind+"while true do"]
        r+=self.body(h,end+(0 if self.L[end]['name']=='JMP' and self.L[end]['t']==h else 1),ctx+[('loop',end+1),('cont',h)],ind+'\t',skiph=h)
        r.append(ind+"end"); return r

    def run(self):
        self.be=self.backedges()
        return self.body(0,self.n,[],'\t')
