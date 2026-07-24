let
  npins = import ./npins;
  flake-compat = import npins.flake-compat;
  zig-flake = (flake-compat { src = npins.zig-overlay; }).defaultNix;

  mkPackages =
    lib: callPackage:
    if builtins.pathExists ./nix/packages then
      lib.packagesFromDirectoryRecursive {
        inherit callPackage;
        directory = ./nix/packages;
      }
    else
      { };

  # Packages are scoped against `final` (not `prev`) so that packages in
  # nix/packages/ can reference each other. This cannot infinitely recurse:
  # the fixpoint is lazy, and an attribute is only demanded when something
  # actually depends on it.
  #
  # `lib` comes from `_prev` (it is identical across layers) to avoid
  # the recursion that would occur if `final.lib` were demanded before
  # the overlay's own attribute names are known.
  overlay =
    final: _prev:
    let
      ghostty-src = npins.ghostty;
    in
    mkPackages _prev.lib final.callPackage
    // {
      # Non-nixpkgs inputs that packages in nix/packages/ take as
      # callPackage arguments. Scoped against `final` so packages can
      # reference siblings (e.g. scrgo depends on scrgo-completions).
      libghostty-vt = final.callPackage "${ghostty-src}/nix/libghostty-vt.nix" {
        optimize = "ReleaseFast";
        revision = builtins.substring 0 7 ghostty-src.revision;
      };
      snail-src = npins.snail;
    };
in
{
  nixpkgs ? npins.nixpkgs-unstable,
  pkgs ? import nixpkgs { overlays = [ zig-flake.overlays.default ]; },
}:
let
  finalPkgs = pkgs.extend overlay;
in
rec {
  packages = mkPackages finalPkgs.lib finalPkgs.callPackage;
  inherit overlay;
  shell = finalPkgs.callPackage ./nix/shell.nix { };
  default = packages.scrgo;
}
