{ pkgs }:

let
src-network-simple = builtins.fetchGit {
  url = "https://github.com/k0001/network-simple";
  rev = "2c3ab6e7aa2a86be692c55bf6081161d83d50c34";
};

in
# This expression can be used as a Haskell package set `packageSetConfig`:
pkgs.lib.composeExtensions
  (import "${src-network-simple}/hs-overlay.nix" { inherit pkgs; })
  (self: super: {
     pipes-network = super.callPackage ./pkg.nix {};
  })
