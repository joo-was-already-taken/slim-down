{ lib, stdenv, zig, callPackage, gitCommit, ... }:

stdenv.mkDerivation {
  pname = "slim-down";
  version = "0.0.1";
  src = lib.cleanSource ./..;

  nativeBuildInputs = [ zig ];

  configurePhase = ''
    export ZIG_GLOBAL_CACHE_DIR=$TEMP/.cache
    PACKAGE_DIR=${callPackage ./deps.nix {}}
  '';

  buildPhase = ''
    zig build install \
      --system $PACKAGE_DIR \
      --prefix $out \
      --release=safe \
      -Dcpu=baseline \
      -Dgit_commit=${gitCommit}
  '';
}
