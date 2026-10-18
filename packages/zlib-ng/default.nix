# Per-package overrides for the relocated zlib-ng (docs/nix-native-design.md
# §8.1; fields: packages/README-overrides.md).
#
# S1: test/CMakeLists.txt is configured even with --nocheck and, without
# cmake(GTest) (Rocky's gtest-devel, not built in S1; unresolved in
# builddeps.json), tries to git-clone googletest at configure time.  The
# googletest-based test programs are never installed, so turning them off
# changes no output: WITH_GTEST=OFF, appended to %_cmake_lib_suffix64
# (macros.cmake puts it into every %cmake call on lib64 targets, and nothing
# else uses it; the spec's %cmake_param is a %global a --define cannot extend,
# and %__cmake is also used by `%cmake_build` = `%__cmake --build ...`, where a
# leading -D breaks the argument parsing).  From the stage that has gtest the
# spec runs unmodified.
{ lib, stage }:
{
  # the lock cannot resolve cmake(GTest) (builddeps.json `unresolved`; Rocky's
  # gtest-devel is not in S1): named here, as mkStage requires, and turned off
  # below (S1 only; from the stage with gtest it is a normal input again)
  inputs.drop = lib.optionals (stage.name == "s1") [ "cmake(GTest)" ];
  defines = lib.optionalAttrs (stage.name == "s1") {
    _cmake_lib_suffix64 = "-DLIB_SUFFIX=64 -DWITH_GTEST=OFF";
  };
}
