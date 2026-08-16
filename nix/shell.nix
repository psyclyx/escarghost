{
  mkShell,
  lib,
  zigpkgs,
  pkg-config,
  hyperfine,
  foot,
  alacritty,
  kitty,
  wezterm,
  mesa,
  libdrm,
  stdenv,
  wayland,
  wayland-protocols,
  wayland-scanner,
  libxkbcommon,
  harfbuzz,
  fontconfig,
  libspng,
  libpulseaudio,
  vulkan-headers,
  vulkan-loader,
  vulkan-validation-layers,
  shader-slang,
  wgpu-utils,
  libghostty-vt,
  # dev tooling
  treefmt,
  nixfmt,
  zls,
  nixd,
  deadnix,
  statix,
  shellcheck,
}:
mkShell {
  packages = [
    zigpkgs."0.16.0"
    pkg-config
    hyperfine
    foot
    alacritty
    kitty
    wezterm
    mesa
    libdrm
    stdenv.cc.cc.lib
    wayland
    wayland-protocols
    wayland-scanner
    libxkbcommon
    harfbuzz
    fontconfig
    libspng
    libpulseaudio
    vulkan-headers
    vulkan-loader
    vulkan-validation-layers
    shader-slang
    wgpu-utils
    # dev tooling
    treefmt
    nixfmt
    zls
    nixd
    deadnix
    statix
    shellcheck
  ];

  buildInputs = [
    libghostty-vt.dev
  ];

  LD_LIBRARY_PATH = lib.makeLibraryPath [
    mesa
    libdrm
    stdenv.cc.cc.lib
    wayland
    libxkbcommon
    harfbuzz
    libspng
    libghostty-vt
    libpulseaudio
    vulkan-loader
  ];

  PKG_CONFIG_PATH = "${libghostty-vt.dev}/share/pkgconfig";

  # For zig build to find the static library directly
  GHOSTTY_VT_INCLUDE = "${libghostty-vt.dev}/include";
  GHOSTTY_VT_LIB = "${libghostty-vt.dev}/lib/libghostty-vt.a";

  shellHook = ''
    export WAYLAND_PROTOCOLS_DIR="$(pkg-config --variable=pkgdatadir wayland-protocols)"
    export WAYLAND_SCANNER="$(pkg-config --variable=wayland_scanner wayland-scanner)"
  '';
}
