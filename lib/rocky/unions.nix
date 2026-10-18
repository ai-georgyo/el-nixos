# Union search paths (docs/nix-native-design.md §4.1): a compiled-in directory
# names one output, so directories that Rocky shares between packages (or
# between subpackages of one SRPM) become environment search paths, exported
# by generated setup hooks at build time and by profiles at run time.
#
# table.<VAR> = {
#   dirs  = [ "<rel>" ... ];   # output-relative, in search order
#   kind  = "list"             # VAR = <o1>/<d1>:<o1>/<d2>:<o2>/<d1>...   (sep-joined)
#         | "single";          # VAR = the first provider of dirs (a file or one dir)
#   sep   = ":";
#   when  = [ "build" "run" ]; # build: setup hook of every output having one of
#                              # `dirs`; run: profiles (rocky.lib.mkProfile) and wrappers
#   doc   = "...";
# }
#
# Consumers:
#   * the partitioner's hook generator (tools/rocky-partition hooks.py) reads
#     `json` from plan.json and, per output o and VAR with "build" in `when`, for
#     each `rel` in `dirs` that exists in o (in order), writes to
#     $o/nix-support/setup-hook
#       list:   addToSearchPath VAR "$o/rel"
#       single: export VAR="${VAR:-$o/rel}"
#   * profiles: `profileScript root` (sh, run-time variables of a buildEnv root);
#   * overrides: `runtimeSearchPaths` values must be variables of this table
#     (lib/rocky/overrides.nix), so every compiled-in default that is allowed
#     to dangle has a variable some hook or profile actually sets.
#
# nixpkgs' own hooks cover `lib/pkgconfig` etc. of build inputs; the entries here
# add the Rocky `lib64` spellings (lib64/pkgconfig, lib64/girepository-1.0, ...).
# Python's version is the one of Rocky 10.2 (python3.12).
{ lib }:
let
  list = dirs: when: doc: { inherit dirs when doc; kind = "list"; sep = ":"; };
  single = dirs: when: doc: { inherit dirs when doc; kind = "single"; sep = ":"; };
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
      "python modules (purelib, platlib); .pth files are processed only in site dirs";
    MANPATH = list [ "share/man" ] [ "run" ]
      "man pages";
    INFOPATH = list [ "share/info" ] [ "run" ]
      "info pages";
    TERMINFO_DIRS = list [ "share/terminfo" ] [ "run" ]
      "terminfo database (ncurses-base, ncurses-term)";
    GCONV_PATH = list [ "lib64/gconv" ] both
      "glibc iconv modules (glibc-gconv-extra; glibc's own dir is compiled in)";
    LOCPATH = list [ "lib/locale" ] both
      "glibc locale directories (langpacks, minimal-langpack, C.utf8 in common)";
    LOCALE_ARCHIVE = single [ "lib/locale/locale-archive" ] both
      "glibc locale archive (all-langpacks), via the P2 patch";
    I18NPATH = list [ "share/i18n" ] [ "build" ]
      "locale sources for localedef (glibc-locale-source)";
    TZDIR = single [ "share/zoneinfo" ] [ "run" ]
      "time zone database (tzdata); glibc's compiled-in default dangles";
    NIX_DEBUG_INFO_DIRS = list [ "lib/debug" ] [ "run" ]
      "separate debuginfo (debug outputs: lib/debug/.build-id) for gdb";
  };

  vars = lib.attrNames table;

  # variables whose dirs contain `rel` (exact)
  forRel = rel: lib.filter (v: lib.elem rel table.${v}.dirs) vars;

  # sh fragment exporting the run-time variables of a profile rooted at `root`
  # (a store path or a shell expression such as "$out"); existing paths only.
  profileScript = root:
    let
      runVars = lib.filter (v: lib.elem "run" table.${v}.when) vars;
      line = v:
        let e = table.${v}; in
        if e.kind == "single" then
          lib.concatMapStrings (d: ''
            [ -n "''${${v}-}" ] || [ ! -e "${root}/${d}" ] || export ${v}="${root}/${d}"
          '') e.dirs
        else
          # prepend in reverse so that the first dir ends up first
          lib.concatMapStrings (d: ''
            [ ! -e "${root}/${d}" ] || export ${v}="${root}/${d}''${${v}:+${e.sep}''$${v}}"
          '') (lib.reverseList e.dirs);
    in
    "# generated from lib/rocky/unions.nix\n" + lib.concatMapStrings line runVars;
in
{
  inherit table vars forRel profileScript;
  json = builtins.toJSON table;
}
