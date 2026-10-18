nix eval --impure --json --expr 'let x = import ./reloc-spike.nix {}; in builtins.mapAttrs (n: v: v.outPath) (x.reloc // (builtins.listToAttrs (map (n: {name = "control-"+n; value = x.control.${n};}) (builtins.attrNames x.control))) // { glibc = x.glibc.reloc; })' > paths.json
python3 -c "
import json,os
for n,p in sorted(json.load(open('paths.json')).items()):
    if os.path.exists(p): print('%-30s rc=%s %s'%(n,open(p+'/rc').read().strip(),open(p+'/phase').read().strip()[:28]))
    else: print('%-30s pending'%n)
"
