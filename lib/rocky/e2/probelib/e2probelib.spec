# E2 library-hazard probe (review finding on E2): a shared library reached
# through the view instead of a cc-wrapper -L.  Two programs link
# libe2lib.so (lib/rocky/e2/default.nix, probeLibDep) the two ways specs do:
#   e2probelib-libdir   -L%{_libdir} -le2lib   (the alias: $out/lib64)
#   e2probelib-builtin  -le2lib                (no -L: ld's built-in
#                                               SEARCH_DIR("=/usr/lib64") = the view)
# Each is run inside the build (what a %check would see); the derivation runs
# the installed copies again outside the shim (nix-support/run-outside.txt).
# Results are recorded, not asserted: a link that fails is reported.
Name:           e2probelib
Version:        1
Release:        1%{?dist}
Summary:        E2 library-hazard probe for the tool shim view
License:        MIT

%description
Links a library found only through the tool shim's view and records whether
the result links, runs inside the build and carries a RUNPATH for it.

%prep
%setup -c -T

%build
r=probelib-result.txt
: > $r
printf 'int e2lib(void);\nint main(void) { return e2lib() == 42 ? 0 : 1; }\n' > m.c
for v in libdir builtin; do
  case $v in libdir) l="-L%{_libdir} -le2lib" ;; builtin) l="-le2lib" ;; esac
  if gcc %{optflags} -o e2probelib-$v m.c %{build_ldflags} $l; then
    echo "$v linked" >> $r
    if ./e2probelib-$v; then echo "$v ran-inside" >> $r; else echo "$v failed-inside rc=$?" >> $r; fi
  else
    echo "$v link-failed" >> $r
  fi
done
cat $r

%install
mkdir -p %{buildroot}%{_bindir} %{buildroot}%{_datadir}/e2probelib
for v in libdir builtin; do
  if [ -e e2probelib-$v ]; then install -m755 e2probelib-$v %{buildroot}%{_bindir}/; else : > %{buildroot}%{_bindir}/e2probelib-$v; fi
done
install -m644 probelib-result.txt %{buildroot}%{_datadir}/e2probelib/

%files
%{_bindir}/e2probelib-libdir
%{_bindir}/e2probelib-builtin
%{_datadir}/e2probelib/probelib-result.txt
