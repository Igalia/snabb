# Run like this:
#   nix-build --argstr hydraName snabb-lwaftr --arg hydraSrc \
#     '{ uri = ./. ; gitTag = "1.0.0"; }' ./tarball.nix
# and the release tarball will be written to ./result/nix-support .
# It will contain both the sources and the executable, patched to run on
# Linux LSB systems.
#
# FIXME: currently Hydra doesn't use the --tags parameter in the "git
# describe" command, so lightweight (non-annotated) tags are not found.
# See https://github.com/NixOS/hydra/blob/master/src/lib/Hydra/Plugin/GitInput.pm#L148
# Always need to use one of -a, -s or -u with the "git tag" command.

{ nixpkgs ? <nixpkgs>
, hydraName ? "snabb"
, hydraSrc ? { uri = ./. ; gitTag = "1.0.0"; }
}:

let
  pkgs = import nixpkgs {};
  # Massage output of "git describe": "v3.1.7-7-g89747a1" -> "v3.1.7"
  # version = (builtins.parseDrvName hydraSrc.gitTag).name;
  # name = "${hydraName}-${version}";
  # TODO: don't massage gitTag for now, re-evaluate later.
  # Possibly add policy to only generate the tarball when there's a new tag.
  name = "${hydraName}-${hydraSrc.gitTag}";
  src = hydraSrc.uri;
in {
  tarball = pkgs.stdenv.mkDerivation rec {
    inherit name src;

    buildInputs = with pkgs; [ makeWrapper patchelf ];

    postUnpack = ''
      mkdir -p $out/$name
      cp -a $sourceRoot/* $out/$name
    '';

    # preBuild = ''
    #   make clean
    # '';

    installPhase = ''
      mv src/snabb $out
    '';

    fixupPhase = ''
      patchelf --shrink-rpath $out/snabb
      patchelf --set-rpath /lib/x86_64-linux-gnu $out/snabb
      patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 $out/snabb
    '';

    doDist = true;

    distPhase = ''
      cd $out
      tar Jcf $name.tar.xz *
      # Make the tarball available for download through Hydra.
      mkdir -p $out/nix-support
      echo "file tarball $out/$name.tar.xz" >> $out/nix-support/hydra-build-products
    '';
  };
}
