# E2 positive control: a spec that reaches its build dependencies through
# target macros and FHS paths, the hazard class of design §1.5 item 2
# (glibc: --with-headers=%{_prefix}/include).  Built by lib/rocky/e2 with and
# without the view; it must build in both (result recorded, not asserted).
Name:           e2probe
Version:        1
Release:        1%{?dist}
Summary:        E2 positive control for the tool shim view
License:        MIT

%description
Records which build dependencies were reachable through %%{_includedir},
%%{_libdir} and FHS paths, and compiles against a header found that way.

%prep
%setup -c -T

%build
r=probe-result.txt
: > $r
for p in %{_includedir}/e2probe-dep/e2probe-dep.h %{_libdir}/pkgconfig/e2probe-dep.pc \
         /usr/include/e2probe-dep/e2probe-dep.h /usr/bin/true /bin/sh /usr/bin/perl; do
  if [ -e "$p" ]; then echo "found   ${p#%{_prefix}/}" >> $r; else echo "missing ${p#%{_prefix}/}" >> $r; fi
done
cat > probe.c <<'EOF'
#if __has_include(<e2probe-dep.h>)
#include <e2probe-dep.h>
#else
#define E2PROBE_DEP 0
static inline int e2probe_dep(int x) { return x; }
#endif
int main(int argc, char **argv) { (void)argv; return e2probe_dep(argc) == 42 ? 0 : 1; }
EOF
gcc %{optflags} -I%{_includedir}/e2probe-dep -o probe probe.c %{build_ldflags}
if ./probe; then echo "compiled-with-dep yes" >> $r; else echo "compiled-with-dep no" >> $r; fi
cat $r

%install
mkdir -p %{buildroot}%{_bindir} %{buildroot}%{_datadir}/e2probe
install -m755 probe %{buildroot}%{_bindir}/e2probe
install -m644 probe-result.txt %{buildroot}%{_datadir}/e2probe/

%files
%{_bindir}/e2probe
%{_datadir}/e2probe/probe-result.txt
