let
  pkgs = (builtins.getFlake "git+file:///run/host/home/ai-shammas/Code/el-nixos").inputs.nixpkgs.legacyPackages.x86_64-linux;
  names = [ "out" "glibc-devel" "nss_db" "glibc-langpack-en" "compat-libpthread-nonshared" "sysroot-x86_64-el10-glibc" ] ++ builtins.genList (i: "glibc-langpack-x${toString i}") 224;
in derivation {
  name = "glibc-2.39-142.el10_2"; system = "x86_64-linux"; builder = "${pkgs.bash}/bin/bash";
  outputs = names; PATH = "${pkgs.coreutils}/bin";
  args = [ "-c" ''
    for o in $outputs; do p=$(printenv "$o"); echo "$o" > "$p"; done
    echo "$out" >> "$(printenv glibc-devel)"
    ls /bin /usr/bin 2>&1 | head -5 >&2
  '' ];
}
