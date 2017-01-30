# Run like this:
#   nix-build /path/to/this/directory/tarball.nix
# ... and the files are produced in ./result/

{ pkgs ? (import <nixpkgs> {})
, name ? "snabb"
, src ? ./.
}:

pkgs.stdenv.mkDerivation rec {
  inherit name src;

  buildInputs = with pkgs; [ git makeWrapper patchelf ];

  postUnpack = ''
    export DISTDIR="$out/${name}-`cd snabb; git describe --tags`"
    mkdir -p $DISTDIR
    cp -a $sourceRoot/* $DISTDIR
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
    # The tarball will only contain the DISTDIR and the "snabb" binary.
    export DISTDIR=`ls -I snabb`
    # Remove a leftover stray binary. FIXME: should not happen.
    rm "$DISTDIR/src/snabb"
    tar Jcf $DISTDIR.tar.xz *
    # Make tarball available through Hydra.
    cp -av $DISTDIR.tar.xz "$out/nix-support/hydra-build-products"
  '';
}
