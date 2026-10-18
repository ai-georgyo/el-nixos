# Generic machinery: chroot runner, buildroots, rpmbuild-in-chroot, rpm->tree.
# See docs/stage0.md.
{ pkgs          # nixpkgs: only for tools that run OUTSIDE the chroot
, lock          # parsed srpms.json
, installerRpm  # rpm used outside the chroot for `rpm --root` (bootstrap/rpm.nix)
}:
let
  inherit (pkgs) lib;
  fetch = import ./fetch-srpm-seed.nix { inherit pkgs lock; };

  # tools used outside the chroot by the runner
  runnerTools = with pkgs; [ bubblewrap coreutils findutils gnugrep gnused gawk diffutils attr cpio bash ];

  # rpm invoked outside the chroot: compiled-in configdir is /usr/lib/rpm,
  # which does not exist in the sandbox -> point it at the store copy.
  rpmOutside = ''env RPM_CONFIGDIR=${installerRpm}/usr/lib/rpm ${installerRpm}/usr/bin/rpm'';

  nukeStore = ''sed -E 's|/nix/store/[a-z0-9]{32}-|/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-|g' '';

  # --- rpm sets ---------------------------------------------------------------
  # An "rpm spec" (what to install into a buildroot) is one of
  #   - a path to a single .rpm file
  #   - a buildSrpm result: all of its binary RPMs except -debuginfo/-debugsource
  #   - { from = <buildSrpm result>; names = [ "<%{NAME}>" ... ]; }
  rpmSpecToShell = s:
    if lib.isAttrs s && s ? from then "${s.from}|${lib.concatStringsSep "," s.names}"
    else if lib.isDerivation s && (s.isSrpmBuild or false) then "${s}|"
    else "${s}|=file";

  # shell snippet: expand rpm specs into the list of .rpm paths in $rpmlist
  collectRpms = specs: ''
    rpmlist=()
    for spec in ${lib.escapeShellArgs (map rpmSpecToShell specs)}; do
      src=''${spec%%|*}; names=''${spec#*|}
      if [ "$names" = "=file" ]; then rpmlist+=("$src"); continue; fi
      found=0
      for f in "$src"/RPMS/*/*.rpm; do
        n=$(${rpmOutside} -qp --nosignature --qf '%{NAME}' "$f")
        if [ -z "$names" ]; then
          case $n in *-debuginfo|*-debugsource) continue ;; esac
          rpmlist+=("$f"); found=1
        elif [[ ",$names," == *",$n,"* ]]; then
          rpmlist+=("$f"); found=$((found+1))
        fi
      done
      if [ -n "$names" ] && [ "$found" -ne "$(tr ',' '\n' <<<"$names" | wc -l)" ]; then
        echo "error: not all of [$names] found in $src/RPMS" >&2; exit 1
      fi
    done
  '';

  # install the rpms listed in file $1 into $BUILDROOT with the outside rpm
  installScript = installFlags: extraCommands: pkgs.writeText "install-rpms.sh" ''
    set -euo pipefail
    if [ -s "$1" ]; then
      mapfile -t rpms < "$1"
      ${rpmOutside} --root "$BUILDROOT" -i ${lib.escapeShellArgs installFlags} \
        --nosignature --nodigest --define '_pkgverify_level none' "''${rpms[@]}"
    fi
    ${extraCommands}
  '';

  # --- mkBuildroot --------------------------------------------------------------
  # Compose a buildroot: `base` (a buildroot) + binary RPMs installed with the
  # outside rpm (`rpm --root`).  The result is a *layer* (only what changed);
  # passthru.layers is the full stack used by the runner.
  #   stage0:  installFlags = [ "--nodeps" "--noscripts" ]  (default)
  #   later:   installFlags = [ ]  -> deps checked, scriptlets run chrooted
  mkBuildroot =
    { name
    , base
    , rpms ? [ ]
    , installFlags ? [ "--nodeps" "--noscripts" ]
    , extraCommands ? ""   # runs as ns-root outside the root, $BUILDROOT = the root
    }:
    let
      layer = pkgs.stdenvNoCC.mkDerivation {
        name = "buildroot-${name}";
        nativeBuildInputs = runnerTools;
        buildCommand = ''
          set -euo pipefail
          source ${./chroot.sh}
          ${collectRpms rpms}
          chroot_setup $TMPDIR/st ${lib.escapeShellArgs base.layers}
          : > $TMPDIR/rpmlist
          for r in "''${rpmlist[@]}"; do echo "$r" >> $TMPDIR/rpmlist; done
          chroot_tools --root -- bash ${installScript installFlags extraCommands} $TMPDIR/rpmlist
          chroot_layer_out $TMPDIR/st $out
          mkdir -p $out
        '';
        passthru = {
          inherit (base) stage store;
          layers = base.layers ++ [ layer ];
          isBuildroot = true;
        };
      };
    in layer;

  # --- buildSrpm ----------------------------------------------------------------
  buildSrpm =
    { srpm                       # SRPM name in the lock, or an .src.rpm path
    , buildroot
    , name ? null
    , rpmbuildArgs ? [ ]
    , defines ? { }
    , dist ? (if builtins.isString srpm then fetch.distOf srpm else lock.dist)
    , extraRpms ? [ ]            # installed into the root before building
    , nodeps ? (buildroot.stage == 0)
    , target ? "x86_64"
    , buildhost ? "el-nixos.localdomain"
    , vendor ? null      # Rocky's build system sets "Rocky Enterprise Software Foundation"
    , packager ? null    # ... and "Rocky Linux Build System <releng@rockylinux.org>"; we do not claim those
    , allowStoreReferences ? false
    }:
    let
      srpmFile = if builtins.isString srpm then fetch.fetchSrpm srpm else srpm;
      srpmBase = baseNameOf (toString srpmFile.name or srpmFile);
      e = if builtins.isString srpm then fetch.entry srpm else null;
      pname = if name != null then name else if builtins.isString srpm then srpm else lib.removeSuffix ".src.rpm" srpmBase;
      allDefines = {
        _topdir = "/builddir/build";
        inherit dist;
        _buildhost = buildhost;
        source_date_epoch_from_changelog = "1";
        use_source_date_epoch_as_buildtime = "1";
        clamp_mtime_to_source_date_epoch = "1";
      } // lib.optionalAttrs (vendor != null) { inherit vendor; }
        // lib.optionalAttrs (packager != null) { inherit packager; }
        // defines;
      defineArgs = lib.concatLists (lib.mapAttrsToList (k: v: [ "--define" "${k} ${v}" ]) allDefines);
      common = defineArgs
        ++ [ "--define" "_smp_build_ncpus @NCPUS@" "--target" target ]
        ++ lib.optional nodeps "--nodeps"
        ++ rpmbuildArgs;
    in
    pkgs.stdenvNoCC.mkDerivation {
      name = "srpm-${pname}" + lib.optionalString (e != null) "-${e.version}-${e.release}";
      nativeBuildInputs = runnerTools;
      outputs = [ "out" ];
      buildCommand = ''
        set -euo pipefail
        source ${./chroot.sh}
        ${collectRpms extraRpms}
        chroot_setup $TMPDIR/st ${lib.escapeShellArgs buildroot.layers}
        if [ ''${#rpmlist[@]} -gt 0 ]; then
          printf '%s\n' "''${rpmlist[@]}" > $TMPDIR/rpmlist
          chroot_tools --root -- bash ${installScript (lib.optionals nodeps [ "--nodeps" "--noscripts" ]) ""} $TMPDIR/rpmlist
        fi

        mkdir -p $TMPDIR/builddir/build
        cp ${srpmFile} $TMPDIR/builddir/${srpmBase}
        ncpus=''${NIX_BUILD_CORES:-1}; [ "$ncpus" -ge 1 ] || ncpus=1
        args=()
        for a in ${lib.escapeShellArgs common}; do args+=("''${a//@NCPUS@/$ncpus}"); done

        run() {
          chroot_exec --user 1000 135 ${lib.optionalString buildroot.store "--store"} \
            --bind $TMPDIR/builddir /builddir --hostname ${buildhost} --chdir /builddir \
            --setenv USER mockbuild --setenv LOGNAME mockbuild -- "$@"
        }
        mkdir -p $out/logs
        echo "=== rpmbuild --rebuild ${srpmBase} (dist ${dist}, target ${target}, -j$ncpus)"
        set +e
        run /usr/bin/rpmbuild --rebuild "/builddir/${srpmBase}" "''${args[@]}" 2>&1 | tee $TMPDIR/build.log
        rc=''${PIPESTATUS[0]}
        set -e
        ${nukeStore} < $TMPDIR/build.log > $out/logs/build.log
        if [ $rc -ne 0 ]; then
          echo "=================== rpmbuild FAILED (exit $rc) -- last 80 lines: ===================" >&2
          tail -n 80 $TMPDIR/build.log >&2
          exit 1
        fi
        # source package as rebuilt in this buildroot (rpmbuild -rs)
        run /usr/bin/rpmbuild -rs "/builddir/${srpmBase}" "''${args[@]}" > $TMPDIR/srpm.log 2>&1 \
          || { cat $TMPDIR/srpm.log >&2; exit 1; }
        ${nukeStore} < $TMPDIR/srpm.log > $out/logs/srpm.log
        cp -r $TMPDIR/builddir/build/RPMS $out/RPMS
        cp -r $TMPDIR/builddir/build/SRPMS $out/SRPMS
        (cd $out && find RPMS SRPMS -name '*.rpm' | sort) > $out/logs/files
        cat $out/logs/files
      '';
      allowedReferences = if allowStoreReferences then null else [ ];
      passthru = {
        isSrpmBuild = true;
        srpmName = pname;
        inherit buildroot dist;
        lockEntry = e;
      };
    };

  # --- runInBuildroot -----------------------------------------------------------
  # Run a bash script inside a buildroot (as mockbuild unless root = true).
  # /builddir is the (empty) work dir; whatever the script leaves in
  # /builddir/out becomes $out.  Inputs can be passed with `binds`
  # ({ "/inside/path" = <store path>; }, read-only).
  runInBuildroot =
    { name, buildroot, script, root ? false, binds ? { }, allowStoreReferences ? true }:
    pkgs.stdenvNoCC.mkDerivation {
      inherit name;
      nativeBuildInputs = runnerTools;
      passAsFile = [ "script" ];
      inherit script;
      buildCommand = ''
        set -euo pipefail
        source ${./chroot.sh}
        chroot_setup $TMPDIR/st ${lib.escapeShellArgs buildroot.layers}
        mkdir -p $TMPDIR/builddir/out
        cp $scriptPath $TMPDIR/builddir/script.sh
        chroot_exec ${if root then "--root" else "--user 1000 135"} ${lib.optionalString buildroot.store "--store"} \
          --bind $TMPDIR/builddir /builddir --chdir /builddir \
          ${lib.concatStringsSep " " (lib.mapAttrsToList (dst: src: "--ro-bind ${src} ${dst}") binds)} \
          -- /bin/bash -euo pipefail /builddir/script.sh
        cp -r $TMPDIR/builddir/out $out
      '';
      allowedReferences = if allowStoreReferences then null else [ ];
    };

  # --- rpmTree ------------------------------------------------------------------
  # One binary RPM's payload as an FHS tree.  allowedReferences = [ ] makes any
  # /nix/store reference in the payload a build failure: this is how "the
  # resulting packages do not depend on nixpkgs" is enforced.
  rpmTree =
    { build          # buildSrpm result
    , name           # %{NAME} of the binary rpm
    }:
    pkgs.stdenvNoCC.mkDerivation {
      name = "rpm-${name}";
      nativeBuildInputs = [ pkgs.cpio ];
      buildCommand = ''
        set -euo pipefail
        sel=
        for f in ${build}/RPMS/*/*.rpm; do
          if [ "$(${rpmOutside} -qp --nosignature --qf '%{NAME}' "$f")" = ${lib.escapeShellArg name} ]; then sel=$f; fi
        done
        [ -n "$sel" ] || { echo "no rpm named ${name} in ${build}/RPMS" >&2; exit 1; }
        mkdir -p $out
        echo "extracting $(${rpmOutside} -qp --nosignature --qf '%{NEVRA}' "$sel")"
        RPM_CONFIGDIR=${installerRpm}/usr/lib/rpm ${installerRpm}/usr/bin/rpm2cpio "$sel" \
          | (cd $out && cpio -idm --quiet --no-absolute-filenames)
        chmod -R u+w $out
      '';
      allowedReferences = [ ];
      passthru = { rpmName = name; inherit build; };
    };
in
{
  inherit fetch mkBuildroot buildSrpm rpmTree rpmOutside runInBuildroot;
  inherit (fetch) fetchSrpm unpackSrpm distOf;
  chrootLib = ./chroot.sh;
}
