
# el-nixos cc-wrapper hook, part 2 (lib/rocky/cc/m32-libc.sh): with -m32 the
# i686 libc comes from <libc>/lib (Rocky's layout: /usr/lib; the relocated
# glibc keeps glibc32 merged into out).  gcc tries a -B prefix as given and
# with the multilib suffix "32/" (nixpkgs' glibc_multi layout), never with
# "../lib", so without this -m32 would pick crt1.o and libc.so from
# <libc dev>/lib64/.  These -B dirs go first; gcc also turns them into -L.
rockyM32=0
for rockyP in ${params+"${params[@]}"}; do
    case $rockyP in
        -m32) rockyM32=1 ;;
        -m64 | -mx32) rockyM32=0 ;;
    esac
done
if [ "$rockyM32" = 1 ]; then
    extraBefore=(-B@libcDev@/lib/ @libcOutB@ ${extraBefore+"${extraBefore[@]}"})
fi
unset -v rockyM32 rockyP
