# Transparently-correct per-instruction threaded lifter (mirrors the VM 1:1).
import clov18 as C, gen2_18 as G
from gen2_18 import q, isname, gname, index, par, PREC, BIN, mexpr

def R(i): return 'R[%d]'%i
def kconst(p,idx): return q(p.const(idx))

def lift(p, upnames, fnnamer):
    L=[]
    reach=set(C.walk(p).keys())
    n=len(p.instr)//8
    params=['A%d'%i for i in range(p.nparam)]
    if p.vararg: params.append('...')
    out=[]
    out.append('function(%s)'%', '.join(params))
    out.append('\tlocal R = {}')
    for i in range(p.nparam): out.append('\tR[%d] = A%d'%(i,i))
    if p.vararg:
        out.append('\tlocal VA = table.pack(...)')
    out.append('\tlocal __pc = %d'%p.entry)
    out.append('\tlocal __top = 0')
    out.append('\twhile true do')
    for pc in sorted(reach):
        I=p.ins(pc); nm=C.OPS[I['op']]; B,Bc,D,E=I['B'],I['C'],I['D'],I['next']
        s=[]
        def emit(x): s.append('\t\t\t'+x)
        nxt='__pc = %d'%E
        if nm=='LOADK': emit('%s = %s'%(R(B),kconst(p,Bc))); emit(nxt)
        elif nm=='LOADNIL': emit('%s = nil'%R(B)); emit(nxt)
        elif nm=='LOADBOOL': emit('%s = %s'%(R(B),'true' if Bc!=0 else 'false')); emit(nxt)
        elif nm=='MOVE': emit('%s = %s'%(R(B),R(Bc))); emit(nxt)
        elif nm=='GETGLOBAL': emit('%s = %s'%(R(B),gname(p.const(Bc)))); emit(nxt)
        elif nm=='SETGLOBAL': emit('%s = %s'%(gname(p.const(Bc)),R(B))); emit(nxt)
        elif nm=='GETTABLE': emit('%s = %s[%s]'%(R(B),R(Bc),R(D))); emit(nxt)
        elif nm=='SETTABLE': emit('%s[%s] = %s'%(R(B),R(Bc),R(D))); emit(nxt)
        elif nm=='SELF': emit('%s = %s'%(R(B+1),R(Bc))); emit('%s = %s[%s]'%(R(B),R(Bc),R(D))); emit(nxt)
        elif nm in ('NEWTABLE','NEWTABLE2'): emit('%s = {}'%R(B)); emit(nxt)
        elif nm=='NEWCELL': emit('%s = {%s}'%(R(B),R(B))); emit(nxt)
        elif nm=='GETCELL': emit('%s = %s[1]'%(R(B),R(Bc))); emit(nxt)
        elif nm=='SETCELL': emit('%s[1] = %s'%(R(B),R(Bc))); emit(nxt)
        elif nm=='GETUPVAL': emit('%s = %s[1]'%(R(B),upnames[Bc-1])); emit(nxt)
        elif nm=='SETUPVAL': emit('%s[1] = %s'%(upnames[Bc-1],R(B))); emit(nxt)
        elif nm in BIN: emit('%s = %s %s %s'%(R(B),R(Bc),BIN[nm],R(D))); emit(nxt)
        elif nm=='NOT': emit('%s = not %s'%(R(B),R(Bc))); emit(nxt)
        elif nm=='UNM': emit('%s = -%s'%(R(B),R(Bc))); emit(nxt)
        elif nm=='LEN': emit('%s = #%s'%(R(B),R(Bc))); emit(nxt)
        elif nm=='CONCAT': emit('%s = %s .. %s'%(R(B),R(Bc),R(D))); emit(nxt)
        elif nm=='JMP': emit('__pc = %d'%B)
        elif nm=='TEST': emit('if %s then __pc = %d else __pc = %d end'%(R(B),Bc,E))
        elif nm=='TESTNOT': emit('if not %s then __pc = %d else __pc = %d end'%(R(B),Bc,E))
        elif nm=='FORPREP': emit('%s = %s - %s'%(R(B),R(B),R(B+2))); emit('__pc = %d'%Bc)
        elif nm=='FORLOOP':
            emit('%s = %s + %s'%(R(B),R(B),R(B+2)))
            emit('if (%s > 0 and %s <= %s) or (%s <= 0 and %s >= %s) then %s = %s; __pc = %d else __pc = %d end'%(R(B+2),R(B),R(B+1),R(B+2),R(B),R(B+1),R(B+3),R(B),Bc,E))
        elif nm=='TFORCALL':
            emit('local f,st,ctl = %s,%s,%s'%(R(B),R(B+1),R(B+2)))
            emit('local rr = table.pack(f(st,ctl))')
            for x in range(max(D,1)): emit('%s = rr[%d]'%(R(B+3+x),x+1))
            emit(nxt)
        elif nm=='TFORLOOP':
            emit('if %s ~= nil then %s = %s; __pc = %d else __pc = %d end'%(R(B+3),R(B+2),R(B+3),Bc,E))
        elif nm=='CALL':
            na=Bc-1; nr=D-1
            if Bc==0: args='table.unpack(R, %d, __top)'%(B+1)
            else: args=', '.join(R(B+1+x) for x in range(na))
            call='%s(%s)'%(R(B),args)
            if D==0:
                emit('local rr = table.pack(%s)'%call)
                emit('__top = %d + rr.n - 1'%B)
                emit('for i=1,rr.n do R[%d+i-1]=rr[i] end'%B)
            elif nr==0: emit(call)
            else:
                emit('local rr = table.pack(%s)'%call)
                for x in range(nr): emit('%s = rr[%d]'%(R(B+x),x+1))
            emit(nxt)
        elif nm=='CLOSURE':
            ch=p.children[Bc-1]; desc=ch.upvals; ups=[]
            for x in range(len(desc)//2):
                a=C.dec32(desc[2*x],2*x+1,ch.kA0,ch.kB0,0)
                b=C.dec32(desc[2*x+1],2*x+2,ch.kA0,ch.kB0,0)
                ups.append(R(b) if a==1 else upnames[b])
            emit('%s = %s(%s)'%(R(B),fnnamer(ch),', '.join(ups)))
            emit(nxt)
        elif nm=='VARARG':
            if Bc==0:
                emit('__top = %d + VA.n - 1'%B)
                emit('for i=1,VA.n do R[%d+i-1]=VA[i] end'%B)
            else:
                for x in range(Bc-1): emit('%s = VA[%d]'%(R(B+x),x+1))
            emit(nxt)
        elif nm=='SETLIST':
            if Bc==0:
                emit('for i=%d,__top do %s[%s + i - %d]=R[i] end'%(B+1,R(B),R(B) if False else str(D),B))
            else:
                for x in range(1,Bc): emit('%s[%d] = %s'%(R(B),D+x,R(B+x)))
            emit(nxt)
        elif nm=='RETURN':
            if Bc==1: emit('return')
            elif Bc==0: emit('return table.unpack(R, %d, __top)'%B)
            else: emit('return '+', '.join(R(B+x) for x in range(Bc-1)))
        else: emit('error("unhandled %s")'%nm)
        kw='if' if pc==min(reach) else 'elseif'
        out.append('\t\t%s __pc == %d then'%(kw,pc))
        out+=s
    out.append('\t\telse error("bad pc") end')
    out.append('\tend')
    out.append('end')
    return '\n'.join(out)
