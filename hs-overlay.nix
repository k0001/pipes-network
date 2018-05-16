{ pkgs }:

let
src-network-simple = builtins.fetchGit {
  url = "https://github.com/k0001/network-simple";
  rev = "14e5517c01286c5f59db6990be8fc3366aa54294";
};

in
# This expression can be used as a Haskell package set `packageSetConfig`:
pkgs.lib.composeExtensions
  (import "${src-network-simple}/hs-overlay.nix")
  (self: super: {
     pipes-network = super.callPackage ./pkg.nix {};
  })
