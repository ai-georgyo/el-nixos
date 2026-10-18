# Union search paths (docs/nix-native-design.md §4.1): a compiled-in directory
# names one output, so directories that Rocky shares between packages (or
# between subpackages of one SRPM) become environment search paths, exported
# by generated setup hooks at build time and by profiles at run time.
#
# table.<VAR> = {
#   dirs     = [ "<rel>" ... ];   # output-relative, in search order
#   kind     = "list"             # VAR = <o1>/<d1>:<o1>/<d2>:<o2>/<d1>...   (sep-joined)
#            | "single";          # VAR = the first provider of dirs (a file or one dir)
#   sep      = ":";
#   when     = [ "build" "run" ]; # build: setup hook of every output having one of
#                                 # `dirs`; run: profiles (rocky.lib.mkProfile) and wrappers
#   provider = null | "<glob>";   # a dir provides VAR only if "<dir>/<glob>" matches
#                                 # something (LOCPATH: "*/LC_CTYPE", directory-format
#                                 # locales; a lib/locale holding only locale-archive
#                                 # is not a LOCPATH entry)
#   yieldsTo = [ "<VAR2>" ... ];  # VAR must stay unset where VAR2 is provided (glibc
#                                 # ignores LOCALE_ARCHIVE whenever LOCPATH is set, and
#                                 # the archive of all_langpacks holds every locale);
#                                 # VAR2 has provider = null
#   doc      = "...";
# }
#
# Consumers:
#   * the partitioner's hook generator (tools/rocky-partition hooks.py) reads
#     `json` from plan.json and, per output o and VAR with "build" in `when`, for
#     each `rel` in `dirs` that exists in o (and, with a provider, has a match for
#     "o/rel/<provider>"), in order, writes to $o/nix-support/setup-hook
#       list:   addToSearchPath VAR "$o/rel"
#               (with yieldsTo Y...: [ -n "${Y-}" ] || addToSearchPath VAR "$o/rel")
#       single: export VAR="${VAR:-$o/rel}"
#               followed by `unset V` for every V whose yieldsTo names VAR
#     so whichever order the hooks run in, a provided VAR2 leaves VAR unset.
#     `hookScript "<o>"` is the same as one sh fragment with the existence tests
#     done when it is sourced (reference implementation, run by checks.nn-names);
#   * profiles: `profileScript root` (sh, run-time variables of a buildEnv root;
#     where root provides VAR2, every VAR yielding to it is unset);
#   * overrides: `runtimeSearchPaths` values must be variables of this table
#     (lib/rocky/overrides.nix), so every compiled-in default that is allowed
#     to dangle has a variable some hook or profile actually sets.
#
# nixpkgs' own hooks cover `lib/pkgconfig` etc. of build inputs; the entries here
# add the Rocky `lib64` spellings (lib64/pkgconfig, lib64/girepository-1.0, ...).
# PYTHONPATH covers the Rocky 10.2 system python (python3.12) only: modules of
# the alternative python3.14 (lib{,64}/python3.14/site-packages, also in the
# lock) are not on it, and must not be (a python3.12 would import 3.14 extension
# modules); they need a python3.14 wrapper or profile of their own.
{ lib }:
let
  mk = kind: dirs: when: doc: {
    inherit kind dirs when doc;
    sep = ":";
    provider = null;
    yieldsTo = [ ];
  };
  list = mk "list";
  single = mk "single";
  both = [ "build" "run" ];

  table = {
    PKG_CONFIG_PATH = list [ "lib64/pkgconfig" "lib/pkgconfig" "share/pkgconfig" ] [ "build" ]
      "pkg-config .pc files (Rocky puts arch ones in lib64)";
    ACLOCAL_PATH = list [ "share/aclocal" ] [ "build" ]
      "autoconf m4 macros";
    XDG_DATA_DIRS = list [ "share" ] both
      "freedesktop data (mime, icons, applications, glib schemas)";
    GI_TYPELIB_PATH = list [ "lib64/girepository-1.0" "lib/girepository-1.0" ] both
      "GObject introspection typelibs";
    PERL5LIB = list [ "share/perl5/vendor_perl" "lib64/perl5/vendor_perl" "share/perl5" "lib64/perl5" ] both
      "perl modules (Rocky vendorlib, vendorarch, privlib, archlib)";
    PYTHONPATH = list [ "lib/python3.12/site-packages" "lib64/python3.12/site-packages" ] both
      "python3.12 modules (purelib, platlib); .pth files are processed only in site dirs; not python3.14";
    MANPATH = list [ "share/man" ] [ "run" ]
      "man pages";
    INFOPATH = list [ "share/info" ] [ "run" ]
      "info pages";
    TERMINFO_DIRS = list [ "share/terminfo" ] [ "run" ]
      "terminfo database (ncurses-base, ncurses-term)";
    GCONV_PATH = list [ "lib64/gconv" ] both
      "glibc iconv modules (glibc-gconv-extra; glibc's own dir is compiled in)";
    LOCPATH = list [ "lib/locale" ] both
      "glibc directory-format locales (langpacks, minimal-langpack, C.utf8 in common); never set where an archive is provided, since glibc then ignores LOCALE_ARCHIVE"
      // { provider = "*/LC_CTYPE"; yieldsTo = [ "LOCALE_ARCHIVE" ]; };
    LOCALE_ARCHIVE = single [ "lib/locale/locale-archive" ] both
      "glibc locale archive (all-langpacks: every locale), via the P2 patch; unsets LOCPATH";
    I18NPATH = list [ "share/i18n" ] both
      "locale sources for localedef (glibc-locale-source; glibc's compiled-in share/i18n dangles)";
    TZDIR = single [ "share/zoneinfo" ] [ "run" ]
      "time zone database (tzdata); glibc's compiled-in default dangles";
    NIX_DEBUG_INFO_DIRS = list [ "lib/debug" ] [ "run" ]
      "separate debuginfo (debug outputs: lib/debug/.build-id) for gdb";
  };

  vars = lib.attrNames table;

  # variables whose dirs contain `rel` (exact)
  forRel = rel: lib.filter (v: lib.elem rel table.${v}.dirs) vars;

  # variables that must stay unset where `v` is provided
  yielders = v: lib.filter (w: lib.elem v table.${w}.yieldsTo) vars;

  # sh: run `body` if "<path>" provides (exists; with a provider glob, has a match)
  ifProvides = path: provider: body:
    if provider == null then ''
      if [ -e "${path}" ]; then
      ${body}fi
    '' else ''
      for _rocky_f in "${path}"/${provider}; do
        if [ -e "$_rocky_f" ]; then
      ${body}  fi; break
      done; unset _rocky_f
    '';

  # sh condition: does "<root>" provide `v` (only for provider-less variables)
  provides = root: v:
    lib.concatMapStringsSep " || " (d: ''[ -e "${root}/${d}" ]'') table.${v}.dirs;

  # sh fragment exporting the run-time variables of a profile rooted at `root`
  # (a store path or a shell expression such as "$out"); existing paths only.
  profileScript = root:
    let
      runVars = lib.filter (v: lib.elem "run" table.${v}.when) vars;
      block = v:
        let
          e = table.${v};
          lines =
            if e.kind == "single" then
              lib.concatMapStrings (d: ifProvides "${root}/${d}" e.provider ''
                [ -n "''${${v}-}" ] || export ${v}="${root}/${d}"
              '') e.dirs
            else
              # prepend in reverse so that the first dir ends up first
              lib.concatMapStrings (d: ifProvides "${root}/${d}" e.provider ''
                export ${v}="${root}/${d}''${${v}:+${e.sep}''$${v}}"
              '') (lib.reverseList e.dirs);
        in
        if e.yieldsTo == [ ] then lines
        else ''
          if ${lib.concatMapStringsSep " || " (provides root) e.yieldsTo}; then
          unset ${v}
          else
          ${lines}fi
        '';
    in
    "# generated from lib/rocky/unions.nix\n" + lib.concatMapStrings block runVars;

  # sh fragment for the setup hook of output `o` (a path or "$out"-like
  # expression): the build-time variables, by the contract above.  Needs
  # setup.sh's addToSearchPath.
  hookScript = o:
    let
      buildVars = lib.filter (v: lib.elem "build" table.${v}.when) vars;
      line = v: d:
        let e = table.${v}; in
        if e.kind == "single" then
          "export ${v}=\"\${${v}:-${o}/${d}}\"\n"
          + lib.concatMapStrings (w: "unset ${w}\n") (yielders v)
        else
          lib.concatMapStrings (y: "[ -n \"\${${y}-}\" ] || ") e.yieldsTo
          + "addToSearchPath ${v} \"${o}/${d}\"\n";
    in
    "# generated from lib/rocky/unions.nix\n"
    + lib.concatMapStrings (v: lib.concatMapStrings (d:
        ifProvides "${o}/${d}" table.${v}.provider (line v d)) table.${v}.dirs) buildVars;
in
{
  inherit table vars forRel yielders profileScript hookScript;
  json = builtins.toJSON table;
}
