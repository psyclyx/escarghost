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
in
pkgs.mkShell {
  packages = with pkgs; [
    zigpkgs."0.16.0"
    pkg-config
    libGL
    libglvnd # EGL
    stdenv.cc.cc.lib
    wayland
    wayland-protocols
    wayland-scanner
    libxkbcommon
    harfbuzz
    fontconfig
  ];

  buildInputs = [
    libghostty-vt.dev
  ];

  LD_LIBRARY_PATH = with pkgs; pkgs.lib.makeLibraryPath [
    libGL
    libglvnd
    stdenv.cc.cc.lib
    wayland
    libxkbcommon
    harfbuzz
    libghostty-vt
  ];

  PKG_CONFIG_PATH = "${libghostty-vt.dev}/share/pkgconfig";

  # For zig build to find the static library directly
  GHOSTTY_VT_INCLUDE = "${libghostty-vt.dev}/include";
  GHOSTTY_VT_LIB = "${libghostty-vt.dev}/lib/libghostty-vt.a";
}
