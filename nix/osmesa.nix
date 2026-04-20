# Minimal mesa: llvmpipe + OSMesa only. For mollusk's software GL first-frame.
{ pkgs }:

(pkgs.mesa.overrideAttrs (old: {
  pname = "mollusk-osmesa";
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
