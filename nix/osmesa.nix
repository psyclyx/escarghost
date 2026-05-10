# Minimal mesa: llvmpipe + OSMesa only. For scrgo's software GL first-frame.
{ pkgs }:

(pkgs.mesa.overrideAttrs (old: {
  pname = "scrgo-osmesa";
  outputs = [ "out" ];
  outputDev = "out";

  mesonFlags = [
    "-Dgallium-drivers=llvmpipe"
    "-Dvulkan-drivers="
    "-Dvulkan-layers="
    "-Degl=disabled"
    "-Dglx=disabled"
    "-Dgbm=disabled"
    "-Dplatforms="
    "-Dglvnd=disabled"
    "-Dgallium-rusticl=false"
    "-Dtools="
    "-Dauto_features=disabled"
    "-Dvalgrind=disabled"
    "-Dvideo-codecs="
    "-Dllvm=enabled"
  ];

  postInstall = pkgs.lib.mkForce "";
  postFixup = pkgs.lib.mkForce "";
}))
