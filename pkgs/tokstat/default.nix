{
  lib,
  fetchFromGitHub,
  rustPlatform,
  pkg-config,
  openssl,
  installShellFiles,
  stdenv,
  dbus, # Linux only - keyring backend; macOS uses Security.framework
}:

rustPlatform.buildRustPackage rec {
  pname = "tokstat";
  version = "0.7.0";

  src = fetchFromGitHub {
    owner = "pbek";
    repo = "tokstat";
    rev = "v${version}";
    hash = "sha256-JXjQiPhkkSJh4oWVqTq3lJdVYaknPDCnZ7L+K1vVb/4=";
  };

  cargoLock = {
    lockFile = "${src}/Cargo.lock";
  };

  nativeBuildInputs = [
    pkg-config
    installShellFiles
  ];

  buildInputs = [ openssl ] ++ lib.optionals stdenv.isLinux [ dbus ];

  postInstall = ''
    installShellCompletion --cmd tokstat \
      --bash <($out/bin/tokstat --generate bash 2>/dev/null || true) \
      --fish <($out/bin/tokstat --generate fish 2>/dev/null || true) \
      --zsh <($out/bin/tokstat --generate zsh 2>/dev/null || true)
  '';

  meta = with lib; {
    description = "Monitor token quotas across multiple AI providers";
    homepage = "https://github.com/pbek/tokstat";
    changelog = "https://github.com/pbek/tokstat/releases/tag/v${version}";
    license = licenses.mit;
    mainProgram = "tokstat";
    platforms = platforms.unix;
  };
}
