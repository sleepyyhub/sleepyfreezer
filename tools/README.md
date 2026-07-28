# Clovyre 1.7.1 devirtualiser

Pipeline (pure static, no execution of the artifact required):

    art.lua ──► strings.json      layer-1 string table (positional Caesar)
            ──► proto.pkl         parsed nested proto tree (17-slot records)
    clov.py     Feistel/keystream primitives, Proto decoder, opcode table
    lin.py      reachability walk + linearisation of the next-pointer graph
    live.py     read/write sets + backward liveness dataflow
    gen2.py     expression folding + control-flow structuring -> Luau
    gen.py      register-level ("assembly") emitter, used for cross-checking

    python3 -c "import pickle,clov,gen2; r=clov.Proto(pickle.load(open('proto.pkl','rb'))); \
                open('recon.lua','w').write(gen2.prune(gen2.Gen(r,[],{}).render('')))"

`harness/` contains the differential test rigs (see REPORT.md §7).
