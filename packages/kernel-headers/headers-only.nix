# The headers-only recipe of the kernel SRPM, shared by the FHS twin
# (packages/kernel-headers.nix, stage0.kernelHeadersBuild) and the relocated
# build (packages/kernel-headers/default.nix, rockyBoot.s1.kernel-headers).
# docs/kernel-headers.md, docs/research/kernel-headers.md §1.1.
{
  # kernel.spec switches (all `%define with_X %{?_without_X: 0} ...`).
  # Everything that would build a kernel, tools, perf, selftests, docs, UKIs or
  # extra packages is off; `headers` stays on (and `configchecks`, as in
  # Rocky's build).
  withouts = [
    "debug" "up" "realtime" "perf" "libperf" "tools" "ynl" "selftests"
    "debuginfo" "kmap" "cross_headers" "doc" "efiuki" "kabichk" "kabidwchk"
    "vdso_install"
  ];

  # What rpmbuild then produces: kernel-headers and the always-emitted, empty
  # kernel-modules-extra-matched meta package (`%files modules-extra-matched`
  # is unconditional on x86_64).  No debuginfo.
  builtSubpackages = [ "kernel-headers" "kernel-modules-extra-matched" ];

  # The official RPM is produced by the full kernel build, in which libperf's
  # `install_headers` and cpupower's `install` write into the same buildroot
  # and `%files headers` is `/usr/include/*`: these 21 paths leak into it
  # (they are owned by libperf-devel / kernel-tools-libs-devel too).  A
  # headers-only build cannot produce them; we do not fake them.
  leakedPaths = [
    "/usr/include/cpuidle.h"
    "/usr/include/internal"
    "/usr/include/internal/cpumap.h"
    "/usr/include/internal/evlist.h"
    "/usr/include/internal/evsel.h"
    "/usr/include/internal/lib.h"
    "/usr/include/internal/mmap.h"
    "/usr/include/internal/rc_check.h"
    "/usr/include/internal/threadmap.h"
    "/usr/include/internal/xyarray.h"
    "/usr/include/perf"
    "/usr/include/perf/bpf_perf.h"
    "/usr/include/perf/core.h"
    "/usr/include/perf/cpumap.h"
    "/usr/include/perf/event.h"
    "/usr/include/perf/evlist.h"
    "/usr/include/perf/evsel.h"
    "/usr/include/perf/mmap.h"
    "/usr/include/perf/perf_dlfilter.h"
    "/usr/include/perf/threadmap.h"
    "/usr/include/powercap.h"
  ];

  # sha256 over `sha256sum` of every file below usr/ of the payload, sorted
  # (docs/research/kernel-headers.md §3): the content oracle
  contentOracle = "3c2cc5570191a364648006ffca5e60e0c5cfea8fe89234aee003ee744297d3f8";
}
