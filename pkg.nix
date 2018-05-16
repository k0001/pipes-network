{ mkDerivation, base, bytestring, exceptions, network
, network-simple, pipes, pipes-safe, stdenv, transformers
}:
mkDerivation {
  pname = "pipes-network";
  version = "0.6.5";
  src = ./.;
  libraryHaskellDepends = [
    base bytestring exceptions network network-simple pipes pipes-safe
    transformers
  ];
  homepage = "https://github.com/k0001/pipes-network";
  description = "Use network sockets together with the pipes library";
  license = stdenv.lib.licenses.bsd3;
}
