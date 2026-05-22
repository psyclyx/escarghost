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

  scrgo = pkgs.callPackage ./nix/scrgo.nix {
    inherit libghostty-vt;
    snail-src = sources.snail;
  };

  scrgo-bench-suite = pkgs.callPackage ./nix/scrgo-bench-suite.nix {
    snail-src = sources.snail;
  };
  scrgo-integration-test = pkgs.callPackage ./nix/scrgo-integration-test.nix {
    snail-src = sources.snail;
  };

  bench = pkgs.callPackage ./bench.nix {
    inherit scrgo scrgo-bench-suite;
  };

  integration-test = pkgs.callPackage ./integration-test.nix {
    inherit scrgo scrgo-integration-test;
  };
in
scrgo // {
  inherit scrgo-bench-suite scrgo-integration-test bench integration-test;
}
