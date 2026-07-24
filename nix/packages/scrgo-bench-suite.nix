{
  stdenv,
  lib,
  zigpkgs,
  pkg-config,
  wayland-scanner,
  autoPatchelfHook,
  wayland,
  libxkbcommon,
  snail-src,
}:

# Standalone build of the scrgo-bench-suite binary. It drives nested
# terminals over wayland (libwayland + xkbcommon + the three wlroots
# protocols) and does not link libghostty-vt or snail, so its closure
# is much smaller than `scrgo` itself.
stdenv.mkDerivation {
  pname = "scrgo-bench-suite";
  version = "0.0.1";

  src = lib.fileset.toSource {
    root = ../../.;
    fileset = lib.fileset.unions [
      ../../src
      ../../protocol
      ../../build.zig
      ../../build.zig.zon
    ];
  };

  nativeBuildInputs = [
    zigpkgs."0.16.0"
    pkg-config
    wayland-scanner
    autoPatchelfHook
  ];

  buildInputs = [
    stdenv.cc.cc.lib
    wayland
    libxkbcommon
  ];

  buildPhase = ''
    export XDG_CACHE_HOME="$TMPDIR/.cache"
    export WAYLAND_SCANNER="$(pkg-config --variable=wayland_scanner wayland-scanner)"

    # Zig pre-fetches every entry in build.zig.zon before running
    # build.zig, even if the target we ask for never imports it. Pass
    # --fork=${snail-src} so the snail entry resolves to a local path
    # instead of trying to hit github from inside the sandbox.
    zig build bench-suite \
      --fork=${snail-src} \
      -Doptimize=ReleaseFast
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp zig-out/bin/scrgo-bench-suite $out/bin/
  '';
}
