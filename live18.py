import clov18 as clov
WIDE=object()
def rdwr(L,p,k):
    I=L[k]; n=I['name']; B,C,D=I['B'],I['C'],I['D']
    rd=set(); wr=set(); wide=False
    if n=='MOVE': rd={C}; wr={B}
    elif n in ('LOADK','LOADNIL','LOADBOOL','GETGLOBAL','NEWTABLE','NEWTABLE2','GETUPVAL'): wr={B}
    elif n=='SETGLOBAL' or n=='SETUPVAL': rd={B}
    elif n=='GETTABLE': rd={C,D}; wr={B}
    elif n=='SETTABLE': rd={B,C,D}
    elif n=='SELF': rd={C,D}; wr={B,B+1}
    elif n=='NEWCELL': rd={B}; wr={B}
    elif n=='GETCELL': rd={C}; wr={B}
    elif n=='SETCELL': rd={B,C}
    elif n in ('ADD','SUB','MUL','DIV','MOD','POW','IDIV','CONCAT','EQ','NE','LT','LE','GT','GE'): rd={C,D}; wr={B}
    elif n in ('NOT','UNM','LEN'): rd={C}; wr={B}
    elif n=='CLOSURE':
        ch=p.children[C-1]; d=ch.upvals
        for x in range(len(d)//2):
            a=clov.dec32(d[2*x],2*x+1,ch.kA0,ch.kB0,0); b=clov.dec32(d[2*x+1],2*x+2,ch.kA0,ch.kB0,0)
            if a==1: rd.add(b)
        wr={B}
    elif n=='VARARG':
        if C==0: wr={B}; wide=True
        else: wr=set(range(B,B+C-1))
    elif n=='CALL':
        if C==0: rd={B,B+1}; wide=True
        else: rd=set(range(B,B+C))-({B+1} if I.get('selfcall') else set())
        if D==0: wr={B}; wide=True
        else: wr=set(range(B,B+D-1))
    elif n=='SETLIST':
        if C==0: rd={B,B+1}; wide=True
        else: rd=set(range(B,B+C))
    elif n=='RETURN':
        if C==0: rd={B}; wide=True
        else: rd=set(range(B,B+C-1))
    elif n in ('TEST','TESTNOT'): rd={B}
    elif n=='FORPREP': rd={B,B+2}; wr={B}
    elif n=='FORLOOP': rd={B,B+1,B+2}; wr={B,B+3}
    elif n=='TFORCALL': rd={B,B+1,B+2}; wr=set(range(B+3,B+3+max(D,1)))
    elif n=='TFORLOOP': rd={B+3}; wr={B+2}
    return rd,wr,wide

def liveness(g):
    L=g.L; n=len(L); RD=[];WR=[];WIDE=[]
    for k in range(n):
        a,b,w=rdwr(L,g.p,k); RD.append(a);WR.append(b);WIDE.append(w)
    IN=[set() for _ in range(n+1)]
    changed=True
    while changed:
        changed=False
        for k in range(n-1,-1,-1):
            out=set()
            for t in g.tg(k): out|=IN[t]
            new=(out-WR[k])|RD[k]
            if WIDE[k]: new=set(range(0,256))
            if new!=IN[k]: IN[k]=new; changed=True
    return IN,RD,WR,WIDE
