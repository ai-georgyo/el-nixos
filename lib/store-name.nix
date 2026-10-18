# RPM file names may contain '^' and '~' (e.g. foo-1.0^20240101git.rpm),
# which are not allowed in Nix store path names. Map them to '_' (the URL is
# unaffected; only the store path name changes).
builtins.replaceStrings [ "^" "~" ] [ "_" "_" ]
