# Overrides of the kernel-headers VARIANT of the kernel SRPM (WP8,
# docs/nix-native-design.md §12; fields: packages/README-overrides.md).
#
# rockyBoot.<stage>.kernel-headers = mkRpmPackage over the kernel SRPM with
# this file (mkStage `variants = { kernel-headers = "kernel"; }`): the same
# headers-only recipe as the FHS twin packages/kernel-headers.nix
# (docs/kernel-headers.md) -- every kernel/tools/perf/selftests/doc/UKI
# variant off, configchecks on -- relocated: the headers land in
# <out>/include, out being the kernel-headers subpackage.
#
# Outputs (names rule, §2.12): the prefix subpackage of the SRPM would be
# `kernel`, which this build does not produce, so kernel-headers is the
# prefix subpackage -> `out` (not `dev`: it is not <srpm>-devel; consumers
# use it as `buildInputs = [ kernel-headers ]`, lib.getDev falls back to out).
# The spec's unconditional, empty kernel-modules-extra-matched meta package
# is the second built subpackage -> `modules_extra_matched`.  No debuginfo.
{ lib }:
let
  recipe = import ./headers-only.nix;
in
{
  bconds.without = recipe.withouts;
  prefixSubpackage = "kernel-headers";
  inherit (recipe) builtSubpackages;

  # headers only: nothing in an output runs, so the stage libc (which links
  # the host tools kconfig, fixdep, unifdef, relocs) is build-only
  runtimeLibc = false;

  inputs = {
    # what the headers-only path runs but builddeps.json does not list:
    #   rsync               `make headers_install` (BuildRequires: rsync under
    #                       %if %{with_headers} || %{with_cross_headers}: the
    #                       lock's parse of the SRPM header misses it)
    #   python3-rpm-macros  %py3_shebang_fix in %prep (Rocky's buildroot has it
    #                       through python3-devel's Requires)
    buildRequires = [ "rsync" "python3-rpm-macros" ];
    # BuildRequires only the switched-off parts use (the kernel image and
    # modules, tools, perf, docs, kABI checks); %prep, InitBuildVars and
    # headers_install run none of them
    drop = [
      "asciidoc" "xmlto" "python3-sphinx" "python3-sphinx_rtd_theme"   # with_doc
      "dwarves"            # pahole: BTF of vmlinux/modules
      "elfutils-devel"     # objtool, resolve_btfids
      "kabi-dw" "kmod"     # kABI checks, depmod
      "libkcapi-hmaccalc"  # hmac of vmlinuz
      "net-tools"          # kernel build scripts
      "openssl-devel"      # sign-file, extract-cert
      "perl-Carp" "perl-devel" "perl-generators"   # perf, kernel build scripts
      "python3-pyyaml"     # ynl
      # CONFIG_CC_CAN_LINK_STATIC of the kernel build (the configs are
      # generated with dummy tools and never reach UAPI); also: glibc
      # takes kernel-headers as an input, so glibc-static here would be a cycle
      "glibc-static"
    ];
  };
}
