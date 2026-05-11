let
  sources = import ./npins;
  flake-compat = import sources.flake-compat;
  zig-flake = (flake-compat { src = sources.zig-overlay; }).defaultNix;
  pkgs = import sources.nixpkgs-unstable {
    overlays = [ zig-flake.overlays.default ];
  };

  ghostty-src = sources.ghostty;
  libghostty-vt = pkgs.callPackage "${ghostty-src}/nix/libghostty-vt.nix" {
    optimize = "ReleaseFast";
    revision = builtins.substring 0 7 ghostty-src.revision;
  };

  scrgo = pkgs.callPackage ./nix/package.nix {
    inherit libghostty-vt;
    snail-src = sources.snail;
  };

  bench-startup = pkgs.callPackage ./bench-startup.nix {
    inherit scrgo;
  };
in
scrgo // { inherit bench-startup; }
