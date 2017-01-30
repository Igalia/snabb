# Run like this:
#   nix-build --argstr name snabb-lwaftr ./tarball.nix
# and the release tarball will be written to ./result/nix-support .
# It will contain both the sources and the executable, patched to run on
# Linux LSB systems.

{ nixpkgs ? <nixpkgs>
, name ? "snabb"
, src ? ./.
}:

let
  pkgs = import nixpkgs {};
in pkgs.stdenv.mkDerivation rec {
  inherit name src;

  buildInputs = with pkgs; [ git makeWrapper patchelf ];

  postUnpack = ''
    export DISTNAME="$out/${name}-`cd snabb; git describe --tags | cut -d '-' -f 1`"
    mkdir -p $DISTNAME
    cp -a $sourceRoot/* $DISTNAME
  '';

  preBuild = ''
    make clean
  '';

  installPhase = ''
    mv src/snabb "$out"
  '';

  fixupPhase = ''
    patchelf --shrink-rpath "$out/snabb"
    patchelf --set-rpath /lib/x86_64-linux-gnu "$out/snabb"
    patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$out/snabb"
  '';

  doDist = true;

  distPhase = ''
    cd "$out"
    # $out will only contain the DISTNAME directory and the "snabb" binary.
    export DISTNAME=`ls -I snabb`
    # Remove a leftover stray binary. FIXME: should not happen.
    rm "$DISTNAME/src/snabb"
    tar Jcf $DISTNAME.tar.xz *
    # Make tarball available through Hydra.
    mkdir -p "$out/nix-support"
    mv $DISTNAME.tar.xz "$out/nix-support"
  '';
}
