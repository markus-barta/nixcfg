{ lib
, rustPlatform
, fetchFromGitHub
, stdenv
, cmake
, pkg-config
, openssl
, hyperscan
, python3
}:

rustPlatform.buildRustPackage rec {
  pname = "noseyparker";
  version = "0.13.0";
#   version = "0.12.0";

  src = fetchFromGitHub {
    owner = "praetorian-inc";
    repo = "noseyparker";
    rev = "v${version}";
   hash = "sha256-ApL9wqTktxOjLD7IVoaVStvkccJNnpxntNTNBGGxl+M=";
    # hash = "sha256-qop6KjTFPQ5o1kPEVPP0AfDfr8w/JP3YmC+sb5OUbDY=";
  };

  cargoHash = "sha256-Om9uaCL+hC9r82fbEykCwtsdF1OTW0WE108Yv5g677Y=";
#   cargoHash = "sha256-ZtoJO/R11qTFYAE6G7AVCpnYZ3JGrxtVSXvCm0W8DAA=";

  postPatch = ''
    # disabledTests (network, failing)
    rm tests/* -Rf
  '';

  nativeBuildInputs = [
    cmake
    pkg-config
    python3
  ];
  buildInputs = [
    openssl
    hyperscan
  ];

  OPENSSL_NO_VENDOR = 1;

  meta = with lib; {
    description = "Find secrets and sensitive information in textual data";
    homepage = "https://github.com/praetorian-inc/noseyparker";
    changelog = "https://github.com/praetorian-inc/noseyparker/blob/v${version}/CHANGELOG.md";
    license = licenses.asl20;
    maintainers = with maintainers; [ _0x4A6F ];
    # limited by hyperscan
    platforms = [ "x86_64-linux" ];
  };
}