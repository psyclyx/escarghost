{ stdenv
, lib
, zigpkgs
, pkg-config
, wayland-protocols
, wayland-scanner
, autoPatchelfHook
, libGL
, libglvnd
, mesa
, libgbm
, libdrm
, wayland
, libxkbcommon
, fontconfig
, harfbuzz
, libpulseaudio
, libghostty-vt
, snail-src
}:

stdenv.mkDerivation {
  pname = "scrgo";
  version = "0.0.1";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../src
      ../protocol
      ../dist
      ../build.zig
      ../build.zig.zon
    ];
  };

  nativeBuildInputs = [
    zigpkgs."0.16.0"
    pkg-config
    wayland-protocols
    wayland-scanner
    autoPatchelfHook
  ];

  buildInputs = [
    libGL
    libglvnd
    mesa
    libgbm
    libdrm
    stdenv.cc.cc.lib
    wayland
    libxkbcommon
    fontconfig
    harfbuzz
    libpulseaudio
    libghostty-vt.dev
  ];

  buildPhase = ''
    export XDG_CACHE_HOME="$TMPDIR/.cache"
    export GHOSTTY_VT_INCLUDE="${libghostty-vt.dev}/include"
    export GHOSTTY_VT_LIB="${libghostty-vt.dev}/lib/libghostty-vt.a"
    export WAYLAND_PROTOCOLS_DIR="$(pkg-config --variable=pkgdatadir wayland-protocols)"
    export WAYLAND_SCANNER="$(pkg-config --variable=wayland_scanner wayland-scanner)"

    zig build \
      --fork=${snail-src} \
      -Doptimize=ReleaseFast
  '';

  installPhase = ''
    mkdir -p $out/bin $out/share
    cp zig-out/bin/scrgo $out/bin/
    cp -r zig-out/share/. $out/share/
  '';
}
