import os,sys
root=sys.argv[1]; P=root.encode(); H=P[11:43]
res=[]
for dp,dn,fn in os.walk(root):
  for f in fn:
    p=os.path.join(dp,f)
    if os.path.islink(p) or not os.path.isfile(p): continue
    b=open(p,'rb').read()
    if b[:4]!=b'\x7fELF': continue
    full=[]; i=b.find(P)
    while i>=0: full.append(i); i=b.find(P,i+1)
    covered=set()
    for s in full: covered.update(range(s,s+len(P)))
    hashes=0; i=b.find(H)
    while i>=0:
      hashes+=1; i=b.find(H,i+1)
    frags=set()
    for k in range(0,len(P)-8+1):
      w=P[k:k+8]; i=b.find(w)
      while i>=0:
        if i not in covered: frags.add(i)
        i=b.find(w,i+1)
    # hash-split: a fragment window inside the hash area not matched by a full hash
    hfrag=0
    for k in range(0,32-8+1):
      w=H[k:k+8]; i=b.find(w)
      while i>=0:
        if not any(j<=i<j+32 for j in [x+11 for x in full]) :
          # check whether the full hash appears around
          if b[max(0,i-k):max(0,i-k)+32]!=H: hfrag+=1
        i=b.find(w,i+1)
    if frags or hfrag: res.append((os.path.relpath(p,root),len(full),hashes,len(frags),hfrag))
for r in sorted(res,key=lambda r:-r[3]): print(*r)
print("files with fragments:",len(res))
