{ stdenv
, lib
, zigpkgs
, pkg-config
, wayland-scanner
, autoPatchelfHook
, wayland
, libxkbcommon
, snail-src
}:

# Standalone build of the scrgo-integration-test binary. Same closure
# as scrgo-bench-suite: drives a nested compositor + scrgo as a child
# via wlroots protocols; doesn't link libghostty-vt or snail.
stdenv.mkDerivation {
  pname = "scrgo-integration-test";
  version = "0.0.1";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../src
      ../protocol
      ../build.zig
      ../build.zig.zon
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
    zig build integration-test \
      --fork=${snail-src} \
      -Doptimize=ReleaseFast
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp zig-out/bin/scrgo-integration-test $out/bin/
  '';
}
