{ lib
, stdenv
, fetchurl
, qmake
, qttools
, qtbase
, qtdeclarative
, qtsvg
, qtwayland
, qtwebsockets
, qt5compat
, makeWrapper
, wrapQtAppsHook
, botan2
, pkg-config
, xvfb-run
, installShellFiles
}:

let
  pname = "qownnotes";
  appname = "QOwnNotes";
  version = "24.6.2";
in
stdenv.mkDerivation {
  inherit pname appname version;

  src = fetchurl {
    url = "https://github.com/pbek/QOwnNotes/releases/download/v${version}/qownnotes-${version}.tar.xz";
    hash = "sha256-7r7HuRN0mo1t0bc4ehGjgwVpHJS8T5psIgmYXLnTj5s=";
  };

  nativeBuildInputs = [
    qmake
    qttools
    wrapQtAppsHook
    pkg-config
    installShellFiles
    xvfb-run
  ] ++ lib.optionals stdenv.isDarwin [ makeWrapper ];

  buildInputs = [
    qtbase
    qtdeclarative
    qtsvg
    qtwebsockets
    qt5compat
    botan2
  ] ++ lib.optionals stdenv.isLinux [ qtwayland ];

  qmakeFlags = [
    "USE_SYSTEM_BOTAN=1"
  ];

  postInstall = ''
    installShellCompletion --cmd ${appname} \
      --bash <(xvfb-run $out/bin/${appname} --completion bash) \
      --fish <(xvfb-run $out/bin/${appname} --completion fish)
    installShellCompletion --cmd ${pname} \
      --bash <(xvfb-run $out/bin/${appname} --completion bash) \
      --fish <(xvfb-run $out/bin/${appname} --completion fish)
  ''
  # Create a lowercase symlink for Linux
  + lib.optionalString stdenv.isLinux ''
    ln -s $out/bin/${appname} $out/bin/${pname}
  ''
  # Wrap application for macOS as lowercase binary
  + lib.optionalString stdenv.isDarwin ''
    mkdir -p $out/Applications
    mv $out/bin/${appname}.app $out/Applications
    makeWrapper $out/Applications/${appname}.app/Contents/MacOS/${appname} $out/bin/${pname}
  '';

  meta = with lib; {
    description = "Plain-text file notepad and todo-list manager with markdown support and Nextcloud/ownCloud integration";
    homepage = "https://www.qownnotes.org/";
    changelog = "https://www.qownnotes.org/changelog.html";
    downloadPage = "https://github.com/pbek/QOwnNotes/releases/tag/v${version}";
    license = licenses.gpl2Only;
    maintainers = with maintainers; [ pbek totoroot ];
    platforms = platforms.unix;
  };
}
