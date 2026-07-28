import pickle,json
M32=4294967296; M31=2147483648; M2=2147483647
S=[x.encode('latin1') for x in json.load(open('strings.json'))]
def F(x,rk,r): return (x*(50916+r*415)+(rk%65536)+r*22464)%65536
def dec32(v,idx,kA,kB,prev=0):
    rk=(kA+idx*kB+(prev or 0)*33304)%M32
    hi=v//65536; lo=v%65536
    for r in (6,5,4,3,2,1):
        t=hi; hi=(lo-F(t,rk,r))%65536; lo=t
    o=hi*65536+lo
    return o-M32 if o>=M31 else o
def enc32(v,idx,kA,kB,prev=0):
    v%=M32; rk=(kA+idx*kB+(prev or 0)*33304)%M32
    hi=v//65536; lo=v%65536
    for r in (1,2,3,4,5,6):
        hi,lo=lo,(hi+F(lo,rk,r))%65536
    return hi*65536+lo
def lin(idx,xk,prev): return (xk+idx*63076+prev*59016+(idx%257)*4701)%M32
def sub(v,idx,xk,prev):
    o=(v-lin(idx,xk,prev))%M32
    return o-M32 if o>=M31 else o
def strdec(b,idx,kA,k1):
    out=bytearray(); st=(kA%M2+idx*4023+k1*29229+len(b)*3135)%M2
    for i in range(1,len(b)+1):
        st=(st*73160+i*98237+idx*4023)%M2
        out.append((b[i-1]-st%256)%256)
    return bytes(out)

class Proto:
    def __init__(self,t):
        self.t=t
        self.cKB=t[0]; self.kB=t[4]; self.kA=t[10]
        self.cKA=t[3]
        self.xk=dec32(t[2],725817,self.kA,self.kB,0)
        self.u1=dec32(t[15],515945,self.kA,self.kB,0)
        self.u2=dec32(t[16],671020,self.kA,self.kB,0)
        self.nparam=dec32(t[5],119285,self.kA,self.kB,0)
        self.vararg=dec32(t[8],209172,self.kA,self.kB,0)
        self.entry=dec32(t[9],407647,self.kA,self.kB,0)
        self.instr=t[13]; self.consts=t[11]; self.upvals=t[12]
        self._ic={}; self._cc={}
        self.children=[Proto(c) for c in t[7]]
    def ins(self,pc):
        if pc in self._ic: return self._ic[pc]
        v=self._ins(pc); self._ic[pc]=v; return v
    def _ins(self,pc):
        I=self.instr; b=pc*8
        def g(off,prev):
            i=b+off
            return sub(dec32(I[i-1],i,self.kA,self.kB,prev),i,self.xk,prev)
        s=g(5,0)
        A=g(3,s); B=g(7,s); C=g(2,s); D=g(1,s); E=g(4,s); chk=g(8,s)
        exp=(A*64+B*93+C*88+D*14+E*52+s*13)%M31
        assert chk==exp,(pc,chk,exp)
        op=((A-self.u1)*self.u2)%65521
        return dict(op=op,B=B,C=C,D=D,next=E,seed=s,raw=A)
    def const(self,idx):
        if idx in self._cc: return self._cc[idx]
        v=self._const(idx); self._cc[idx]=v; return v
    def _const(self,idx):
        e=self.consts[idx-1]
        i2=(idx-1)*4+2; i3=(idx-1)*4+3
        k1=dec32(e[1],i2,self.cKA,self.cKB,0)
        v=dec32(e[2],i3,self.cKA,self.cKB,k1)
        raw=e[0]
        raw=S[raw[1]-1] if isinstance(raw,tuple) else raw
        st=strdec(raw,idx,self.cKA,k1)
        if v==1807967222: return st.decode('latin1')
        if v==286231453: return float('inf')
        if v==277167739: return float('-inf')
        return float(st) if (b'.' in st or b'e' in st or b'n' in st) else int(st)

OPS={}
def _o(name,*ids):
    for i in ids: OPS[i]=name
_o('GE',7602,38098,46559); _o('MUL',51212,60858,22263); _o('RETURN',41767,35479,13663)
_o('SETLIST',46564,16769,51002); _o('TFORCALL',34961,20287,23990); _o('SUB',54908,20988,10778)
_o('POW',60732,55942,19296); _o('FORLOOP',42954,33052,6705); _o('LE',54543,29633,28955)
_o('UNM',47444,5176,35466); _o('TFORLOOP',52797,34444,52611); _o('CALL',34963,61257,26750)
_o('CLOSURE',8150,35413,12905); _o('MOVE',45999,32361,9046); _o('GETTABLE',56960,46786,65338)
_o('JMP',41822,52837,44167); _o('MOD',15861,27931,50318); _o('IDIV',14040,5823,40762)
_o('LT',62583,25728,13713); _o('NEWCELL',30586,29393,60002); _o('SETGLOBAL',25433,20384,50179)
_o('GETUPVAL',56679,59247,32078); _o('FORPREP',18760,33932,51005); _o('LOADNIL',31571,60208,22488)
_o('TEST',55236,64176,8194); _o('SETCELL',31238,38566,43805); _o('NEWTABLE',20468,52269,14367)
_o('DIV',28622,63059,33134); _o('NE',48178,45000,20421); _o('SELF',24553,35812,13221)
_o('GT',9381,20369,46238); _o('LOADK',13880,21673,40041); _o('ADD',17917,58382,51565)
_o('VARARG',30306,48922,26748); _o('TESTNOT',40519,65399,43087); _o('SETUPVAL',40256,15161,53347)
_o('NEWTABLE2',38230,49821,18575); _o('GETCELL',11283,50674,57035); _o('LEN',44713,42315,34259)
_o('SETTABLE',22173,30676,51946); _o('LOADBOOL',62089,62615,6816); _o('GETGLOBAL',13065,18187,42445)
_o('EQ',61552,12201,50784); _o('CONCAT',37674,41898,31535); _o('NOT',46838,14145,41727)

BRANCH={'TEST','TESTNOT','FORLOOP','TFORLOOP'}
TERM={'RETURN'}
def walk(p):
    seen={}; stack=[p.entry]
    while stack:
        pc=stack.pop()
        if pc in seen: continue
        i=p.ins(pc); i['pc']=pc; seen[pc]=i
        n=OPS[i['op']]; i['name']=n
        if n in TERM: continue
        if n=='JMP': stack.append(i['B']); continue
        if n=='FORPREP': stack.append(i['C']); continue
        if n in BRANCH: stack.append(i['C'])
        stack.append(i['next'])
    return seen
