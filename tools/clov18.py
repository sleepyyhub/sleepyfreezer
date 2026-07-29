import pickle,json
M32=4294967296; M31=2147483648; M2=2147483647
S=[x.encode('latin1') for x in json.load(open('strs18.json'))]
def F(x,rk,r): return (x*(37224+r*486)+(rk%65536)+r*32473)%65536
def dec32(v,idx,kA,kB,prev=0):
    rk=(kA+idx*kB+(prev or 0)*8579)%M32
    hi=v//65536; lo=v%65536
    for r in (3,2,1):
        t=hi; hi=(lo-F(t,rk,r))%65536; lo=t
    o=hi*65536+lo
    return o-M32 if o>=M31 else o
def enc32(v,idx,kA,kB,prev=0):
    v%=M32; rk=(kA+idx*kB+(prev or 0)*8579)%M32
    hi=v//65536; lo=v%65536
    for r in (1,2,3):
        hi,lo=lo,(hi+F(lo,rk,r))%65536
    return hi*65536+lo
def lin(idx,xk,prev): return (xk+idx*45170+prev*5142+(idx%257)*56028)%M32
def sub(v,idx,xk,prev):
    o=(v-lin(idx,xk,prev))%M32
    return o-M32 if o>=M31 else o
def strdec(b,idx,kA,k1):
    out=bytearray(); st=(kA%M2+idx*484+k1*51100+len(b)*2220)%M2
    for i in range(1,len(b)+1):
        st=(st*40347+i*10918+idx*484)%M2
        out.append((b[i-1]-st%256)%256)
    return bytes(out)
def chash(b):  # constant integrity hash l011_OIlO0(str, tag, idx)
    pass

# integrity residual (IOO00l): pure function of stored ints
def seedhash(h,v,c):
    if isinstance(v,int):
        return (h*275+(v%M2)+c*243+20043)%M2, c+1
    b=v if isinstance(v,bytes) else v.encode('latin1')
    h=(h*275+len(b)*3418+c*243+29536)%M2; c+=1
    for x in b:
        h=(h*275+x*36+c*243)%M2; c+=1
    return h,c

class Proto:
    def __init__(self,t):
        self.t=t
        raw=lambda x: S[x[1]-1] if isinstance(x,tuple) else x
        self.kA0=t[2]; self.kB0=t[4]         # slots 3,5 (base)
        self.ckA0=t[6]; self.ckB0=t[9]       # slots 7,10 (base)
        self.instr=t[13]; self.consts=t[3]; self.upvals=t[11]
        self.children=[Proto(c) for c in t[15]]
        self._ic={}; self._cc={}
        # residual from integrity
        self.residual=self._residual()
        off=(self.residual*33425)%M32
        self.kA=(self.kA0+off)%M32; self.kB=(self.kB0+off)%M32
        self.ckA=(self.ckA0+off)%M32; self.ckB=(self.ckB0+off)%M32
        self.xk=dec32(t[10],713243,self.kA,self.kB,0)     # slot 11
        self.entry=dec32(t[0],420329,self.kA,self.kB,0)   # slot 1
        self.nparam=dec32(t[1],132336,self.kA,self.kB,0)  # slot 2
        self.vararg=dec32(t[8],260355,self.kA,self.kB,0)  # slot 9
        self.u1=dec32(t[14],567059,self.kA,self.kB,0)     # slot 15
        self.u2=dec32(t[16],649796,self.kA,self.kB,0)     # slot 17
    def _residual(self):
        t=self.t; h=1581340426%M2; c=1
        def add(v):
            nonlocal h,c; h,c=seedhash(h,v,c)
        instr=t[13]; add(len(instr))
        for x in instr: add(x)
        cp=t[3]; add(len(cp))
        for e in cp:
            add(len(e))
            for x in e: add(S[x[1]-1] if isinstance(x,tuple) else x)
        up=t[11]; add(len(up))
        for x in up: add(x)
        ch=t[15]; add(len(ch))
        vec=[t[1],t[8],t[12],t[0],t[2],t[4],t[6],t[9],t[14],t[16],t[10]]
        add(len(vec))
        for x in vec: add(x)
        seal=dec32(t[5],859590,t[2],t[4],0)   # slot 6, base kA/kB (slots3,5)
        res=(h-seal)%M2
        for cc in ch: Proto(cc)  # children recurse for their own seals (ignored here)
        return res
    def ins(self,pc):
        if pc in self._ic: return self._ic[pc]
        I=self.instr; b=pc*8
        def g(off,prev):
            i=b+off
            return sub(dec32(I[i-1],i,self.kA,self.kB,prev),i,self.xk,prev)
        seed=g(5,0)
        A=g(7,seed); B=g(8,seed); C=g(4,seed); D=g(1,seed); E=g(3,seed); chk=g(6,seed)
        exp=(A*16+B*73+C*79+D*31+E*71+seed*34)%M31
        assert chk==exp,(pc,chk,exp)
        op1=((A-self.u1)*self.u2)%65521
        op=(op1*7935+27397)%65521
        r=dict(op=op,B=B,C=C,D=D,next=E,seed=seed,raw=A); self._ic[pc]=r; return r
    def const(self,idx):
        if idx in self._cc: return self._cc[idx]
        e=self.consts[idx-1]; base=(idx-1)*4
        raw=lambda x: S[x[1]-1] if isinstance(x,tuple) else x
        k1=dec32(e[2],base+3,self.ckA,self.ckB,0)
        tag=dec32(e[0],base+1,self.ckA,self.ckB,k1)
        st=strdec(raw(e[3]),idx,self.ckA,k1)
        if tag==1458442008: v=st.decode('latin1')
        elif tag==1533962859: v=float('inf')
        elif tag==796708246: v=float('-inf')
        else: v=float(st) if (b'.' in st or b'e' in st.lower()) else int(st)
        self._cc[idx]=v; return v

OPS={}
def _o(name,*ids):
    for i in ids: OPS[i]=name
_o('SETUPVAL',10749,60658,37307); _o('SELF',8910,53938,17270); _o('SETLIST',33335,61932,53593)
_o('CLOSURE',34725,5409,36554); _o('LEN',47646,44148,1856); _o('MOD',43929,48286,7598)
_o('LE',5510,52211,49835); _o('GT',41472,38887,34513); _o('LOADNIL',9856,50444,7348)
_o('RETURN',64726,52811,5786); _o('JMP',51458,18005,44340); _o('GE',39959,19981,65403)
_o('DIV',63648,41113,45882); _o('SETTABLE',26693,20481,11010); _o('SETCELL',56139,27424,15575)
_o('TESTNOT',58940,24496,59428); _o('GETTABLE',38577,27133,30058); _o('NEWTABLE',45459,48979,42722)
_o('LOADK',23780,48719,23201); _o('TFORCALL',12712,28374,43044); _o('LT',34395,19293,1826)
_o('ADD',35477,31653,57239); _o('IDIV',23909,52664,18859); _o('TFORLOOP',50580,64420,35915)
_o('POW',53002,50900,28640); _o('MUL',44903,22443,9802); _o('NOT',15746,58601,44585)
_o('NE',40511,37658,14212); _o('GETUPVAL',13197,11551,7339); _o('VARARG',39263,31845,2777)
_o('UNM',61555,34700,46878); _o('SETGLOBAL',3546,35534,3808); _o('MOVE',20561,34801,43517)
_o('CONCAT',12547,36792,52189); _o('FORLOOP',30331,63170,4133); _o('FORPREP',7358,38762,17443)
_o('NEWTABLE2',50707,52350,32635); _o('TEST',56451,39609,40926); _o('SUB',39915,29082,17583)
_o('EQ',39872,57870,37335); _o('LOADBOOL',56508,325,46494); _o('GETGLOBAL',31842,6368,5402)
_o('NEWCELL',2779,8086,4691); _o('CALL',33275,29728,42428); _o('GETCELL',59768,15358,36980)

BRANCH={'TEST','TESTNOT','FORLOOP','TFORLOOP'}
TERM={'RETURN','VARARGRET'}
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
