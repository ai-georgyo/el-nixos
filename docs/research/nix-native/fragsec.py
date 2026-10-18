import sys,subprocess,re
root=sys.argv[1]; f=sys.argv[2]; P=root.encode(); H=P[11:43]
b=open(f,'rb').read()
secs=[]
for l in subprocess.run(['readelf','-SW',f],capture_output=True,text=True).stdout.splitlines():
  m=re.match(r'\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+[0-9a-f]+\s+([0-9a-f]+)\s+([0-9a-f]+)',l)
  if m: secs.append((m.group(1),int(m.group(2),16),int(m.group(3),16)))
def sec(i):
  for n,o,s in secs:
    if o<=i<o+s and n!='NULL': return n
  return '?'
full=[];i=b.find(P)
while i>=0: full.append(i); i=b.find(P,i+1)
cov=set()
for s in full: cov.update(range(s,s+len(P)))
from collections import Counter
fs=Counter(); fullsec=Counter(sec(s) for s in full); ex={}
for k in range(len(P)-7):
  w=P[k:k+8]; i=b.find(w)
  while i>=0:
    if i not in cov:
      n=sec(i); fs[n]+=1; ex.setdefault(n,set()).add(i)
    i=b.find(w,i+1)
print("full:",dict(fullsec)); print("frag windows by section:",dict(fs))
for n in ex:
  if n.startswith('.debug'): continue
  for i in sorted(ex[n])[:6]: print(n,hex(i),b[i-8:i+24])
