{
  stdenv,
  lib,
  zigpkgs,
  snail-src,
}:

# Builds the `gen-completions` codegen exe, patches its dynamic-linker
# interpreter so the binary runs in the Nix sandbox, executes it, and
# captures the three shell-completion files as $out.
#
# This derivation exists separately from `scrgo` because the main
# `zig build install` would (a) try to spawn the freshly-built exe
# during build with its hardcoded `/lib/ld-musl-x86_64.so.1` interpreter
# that doesn't exist in the sandbox, and (b) `autoPatchelfHook` only
# patches binaries under $out during the fixup phase — too late to
# satisfy an `addRunArtifact` step. Isolating the exec to its own
# derivation lets the main scrgo build stay declarative compile+install.

stdenv.mkDerivation {
  pname = "scrgo-completions";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../../.;
    fileset = lib.fileset.unions [
      ../../src/cli.zig
      ../../src/gen_completions.zig
      ../../src/log.zig
      ../../build.zig
      ../../build.zig.zon
    ];
  };

  nativeBuildInputs = [
    zigpkgs."0.16.0"
  ];

  buildPhase = ''
    export XDG_CACHE_HOME="$TMPDIR/.cache"

    # Build only the codegen exe (no run, no install of main artifacts).
    # `--fork=snail` is required because zig eagerly resolves every dep
    # declared in build.zig.zon even when the requested step (here,
    # gen-completions) doesn't touch snail. Without --fork the build
    # tries to fetch snail over the network, which the sandbox blocks.
    zig build gen-completions \
      --fork=${snail-src} \
      -Doptimize=ReleaseFast

    # Zig stamps a fixed PT_INTERP (e.g. /lib/ld-musl-x86_64.so.1 in
    # the sandbox); that path doesn't exist, so an unpatched exec
    # returns ENOENT. patchelf with the stdenv-cc's dynamic linker.
    patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
      zig-out/bin/gen-completions

    mkdir -p $out
    ./zig-out/bin/gen-completions $out
  '';

  dontInstall = true;
}
