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

  # Slim harfbuzz: we use the default OpenType shaper, not graphite2 or
  # ICU. Dropping them removes libgraphite2 from scrgo's link graph
  # without forcing the rest of nixpkgs to rebuild against this variant.
  leanHarfbuzz = pkgs.harfbuzz.override {
    withGraphite2 = false;
    withIcu = false;
  };

  scrgo = pkgs.callPackage ./nix/package.nix {
    inherit libghostty-vt;
    snail-src = sources.snail;
    harfbuzz = leanHarfbuzz;
  };

  bench-startup = pkgs.callPackage ./bench-startup.nix {
    inherit scrgo;
  };

  integration-test = pkgs.callPackage ./integration-test.nix {
    inherit scrgo;
  };
in
scrgo // { inherit bench-startup integration-test; }
