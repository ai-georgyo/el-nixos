# The stage0 base layer: an FHS root (RHEL 10 usrmerge layout) containing
#   - the stage0 toolchain as real files: kernel headers, glibc (x86_64+i686),
#     binutils, gcc -- all built with FHS paths (see the respective .nix files)
#   - rpm/rpmbuild + debugedit with FHS-compiled paths; %_rpmconfigdir
#     /usr/lib/rpm is a real directory so Rocky's macro packages install into
#     /usr/lib/rpm/macros.d, /usr/lib/rpm/redhat, ... unmodified
#   - the buildsys-build basics from nixpkgs, as symlinks /usr/bin/X -> /nix/store/...
#     (the store is bind-mounted read-only into stage0 chroots)
#   - /etc: passwd/group (root, mockbuild=1000, mock=135, ...), hosts,
#     nsswitch.conf, ld.so.conf(+cache), rpm/macros.stage0
#   - an empty rpmdb at /usr/lib/sysimage/rpm
{ pkgs, rpm, debugedit, tools
, fhsTrees            # [ kernelHeaders glibc binutils gcc ] (order matters: later wins)
, name ? "stage0-root"
, withToolchain ? true # false only for the dev/debug root used to test the machinery
}:
let
  inherit (pkgs) lib;
  rpmOutside = "env RPM_CONFIGDIR=${rpm}/usr/lib/rpm ${rpm}/usr/bin/rpm";
in
pkgs.runCommand name {
  passthru = { stage = 0; store = true; isBuildroot = true; };
} (''
  set -euo pipefail
  mkdir -p $out && cd $out

  # --- skeleton, as filesystem-3.18-17.el10's %install (x86_64) ---------------
  mkdir -p afs boot dev home media mnt opt root run srv tmp proc sys \
    etc/{X11/{applnk,fontpath.d,xinit/{xinitrc,xinput}.d},xdg/autostart,opt,pm/{config.d,power.d,sleep.d},skel,sysconfig,keys/ima,pki,bash_completion.d,default,rwtab.d,statetab.d} \
    usr/{bin,games,include,lib64/{bpf,games,X11,pm-utils/{module.d,power.d,sleep.d}},lib/{debug/{.dwz,usr},games,locale,modules,sysimage,systemd/{system,user},sysusers.d,tmpfiles.d},libexec,local/{bin,etc,games,lib,lib64/bpf,sbin,src,share/{applications,man/man{1,2,3,4,5,6,7,8,9,n},info},libexec,include},sbin,share/{aclocal,applications,doc,empty,info,licenses,man/man{1,2,3,4,5,6,7,8,9,n,0p,1p,3p},misc,pixmaps},src/{kernels,debug}} \
    var/{adm,empty,ftp,lib/{games,misc,rpm-state},local,log,nis,preserve,spool/{mail,lpd},tmp,db,cache/bpf,opt,games,yp}
  ln -snf ../var/tmp usr/tmp
  ln -snf spool/mail var/mail
  ln -snf usr/bin bin
  ln -snf usr/sbin sbin
  ln -snf usr/lib lib
  ln -snf usr/lib64 lib64
  ln -snf ../run var/run
  ln -snf ../run/lock var/lock
  ln -snf usr/bin usr/lib/debug/bin
  ln -snf usr/lib usr/lib/debug/lib
  ln -snf usr/lib64 usr/lib/debug/lib64
  ln -snf ../.dwz usr/lib/debug/usr/.dwz
  ln -snf usr/sbin usr/lib/debug/sbin
  # mount points: build dir, and the read-only store (stage0 only)
  mkdir -p builddir nix/store

  # --- toolchain trees (real files) ------------------------------------------
  for t in ${lib.concatStringsSep " " (map toString fhsTrees)}; do
    cp -a --no-preserve=ownership $t/usr/. usr/
    [ -d $t/etc ] && cp -a --no-preserve=ownership $t/etc/. etc/
    chmod -R u+w usr etc
  done

  # --- rpm + debugedit -------------------------------------------------------
  cp -a --no-preserve=ownership ${rpm}/usr/lib/rpm usr/lib/rpm
  chmod -R u+w usr/lib/rpm
  mkdir -p etc/rpm usr/lib/rpm/macros.d usr/lib/sysimage/rpm
  for f in ${rpm}/usr/bin/* ${debugedit}/usr/bin/*; do
    ln -s $f usr/bin/$(basename $f)
  done
  ln -sfn ../../bin/find-debuginfo usr/lib/rpm/find-debuginfo.sh
  cp ${./macros.stage0} etc/rpm/macros.stage0

  # --- nixpkgs tools (symlinks; first provider of a name wins) ---------------
  for p in ${lib.concatStringsSep " " (map (t: "${lib.getBin t}") tools)}; do
    for f in $p/bin/* $p/sbin/*; do
      [ -e "$f" ] || continue
      n=$(basename $f)
      case $n in .*) continue ;; esac
      [ -e usr/bin/$n ] || [ -L usr/bin/$n ] || ln -s $f usr/bin/$n
    done
  done
  ln -sfn bash usr/bin/sh
  [ -e usr/bin/awk ] || ln -s gawk usr/bin/awk

  # --- /etc ------------------------------------------------------------------
  cat > etc/passwd <<'EOF'
root:x:0:0:Super User:/root:/bin/bash
bin:x:1:1:bin:/bin:/usr/sbin/nologin
daemon:x:2:2:daemon:/sbin:/usr/sbin/nologin
adm:x:3:4:adm:/var/adm:/usr/sbin/nologin
lp:x:4:7:lp:/var/spool/lpd:/usr/sbin/nologin
sync:x:5:0:sync:/sbin:/bin/sync
shutdown:x:6:0:shutdown:/sbin:/sbin/shutdown
halt:x:7:0:halt:/sbin:/sbin/halt
mail:x:8:12:mail:/var/spool/mail:/usr/sbin/nologin
operator:x:11:0:operator:/root:/usr/sbin/nologin
games:x:12:100:games:/usr/games:/usr/sbin/nologin
ftp:x:14:50:FTP User:/var/ftp:/usr/sbin/nologin
mockbuild:x:1000:135::/builddir:/bin/bash
nobody:x:65534:65534:Kernel Overflow User:/:/usr/sbin/nologin
EOF
  cat > etc/group <<'EOF'
root:x:0:
bin:x:1:
daemon:x:2:
sys:x:3:
adm:x:4:
tty:x:5:
disk:x:6:
lp:x:7:
mem:x:8:
kmem:x:9:
wheel:x:10:
cdrom:x:11:
mail:x:12:
man:x:15:
dialout:x:18:
floppy:x:19:
games:x:20:
tape:x:33:
video:x:39:
ftp:x:50:
lock:x:54:
audio:x:63:
users:x:100:
mock:x:135:mockbuild
nobody:x:65534:
EOF
  printf 'root:!!:20000::::::\nmockbuild:!!:20000::::::\n' > etc/shadow
  chmod 0400 etc/shadow
  printf '127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4\n::1         localhost localhost.localdomain localhost6 localhost6.localdomain6\n' > etc/hosts
  printf 'passwd: files\nshadow: files\ngroup: files\nhosts: files dns\nservices: files\nnetgroup: files\nautomount: files\naliases: files\n' > etc/nsswitch.conf
  : > etc/resolv.conf
  echo /bin/bash > etc/shells; echo /bin/sh >> etc/shells
  touch etc/fstab
  # empty rpm database
  # (`rpm --initdb` is a popt alias exec'ing /usr/bin/rpmdb: call rpmdb directly)
  RPM_CONFIGDIR=${rpm}/usr/lib/rpm ${rpm}/usr/bin/rpmdb --root $out --initdb
  # the db is closed: an empty WAL and a stale wal-index must not live in a
  # layer (upper layers would otherwise mix with them)
  test ! -s usr/lib/sysimage/rpm/rpmdb.sqlite-wal
  rm -f usr/lib/sysimage/rpm/rpmdb.sqlite-wal usr/lib/sysimage/rpm/rpmdb.sqlite-shm
  ls -la usr/lib/sysimage/rpm
'' + lib.optionalString withToolchain ''
  # dynamic linker cache (the stage0 glibc's static ldconfig)
  usr/sbin/ldconfig -r $out
  # --- sanity ----------------------------------------------------------------
  test -x usr/bin/gcc && test -x usr/bin/ld && test -e usr/lib64/libc.so.6 && test -e lib64/ld-linux-x86-64.so.2
'')
