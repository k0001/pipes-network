{ nixpkgs ? import ./nixpkgs.nix }:

let
pkgs = import nixpkgs {};
ghc841 = pkgs.haskell.packages.ghc841.override {
  packageSetConfig = import ./hs-overlay.nix { inherit pkgs; };
};

in { inherit (ghc841) pipes-network; }
