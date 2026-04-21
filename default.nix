let
  sources = import ./npins;
  flake-compat = import sources.flake-compat;
  zig-flake = (flake-compat { src = sources.zig-overlay; }).defaultNix;
  pkgs = import sources.nixpkgs-unstable {
    overlays = [ zig-flake.overlays.default ];
  };

  zig = pkgs.zigpkgs."0.16.0";

  ghostty-src = sources.ghostty;
  libghostty-vt = pkgs.callPackage "${ghostty-src}/nix/libghostty-vt.nix" {
    optimize = "ReleaseFast";
    revision = builtins.substring 0 7 ghostty-src.revision;
  };

  runtimeLibs = with pkgs; [
    libGL
    libglvnd # EGL
    stdenv.cc.cc.lib
    wayland
    libxkbcommon
    fontconfig
  ];

  allBuildInputs = runtimeLibs ++ (with pkgs; [ wayland-protocols ]) ++ [
    libghostty-vt.dev
  ];

  filteredSrc = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./src
      ./protocol
      ./build.zig
      ./build.zig.zon
    ];
  };

in
pkgs.stdenv.mkDerivation {
  pname = "mollusk";
  version = "0.0.1";
  src = filteredSrc;

  nativeBuildInputs = with pkgs; [
    zig
    pkg-config
    autoPatchelfHook
  ];

  buildInputs = allBuildInputs;

  buildPhase = ''
    export XDG_CACHE_HOME="$TMPDIR/.cache"
    export GHOSTTY_VT_INCLUDE="${libghostty-vt.dev}/include"
    export GHOSTTY_VT_LIB="${libghostty-vt.dev}/lib/libghostty-vt.a"

    zig build \
      --fork=${sources.snail} \
      -Doptimize=ReleaseFast
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp zig-out/bin/mollusk $out/bin/
  '';
}
