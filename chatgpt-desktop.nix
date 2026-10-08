{ pkgs }:
let
  inherit (pkgs) lib;
in
pkgs.stdenv.mkDerivation rec {
  pname = "chatgpt-desktop";
  version = "26.1002.52244";

  # Official Linux app (includes Codex). Use the immutable APT pool URL,
  # not deb/latest, so a future upstream release cannot change this build.
  src = pkgs.fetchurl {
    url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_${version}_amd64.deb";
    hash = "sha256-lJjkFxMaJ4vONb//YnXSUsDTMvF6/AMT4LeCdJ9NNIo=";
  };

  nativeBuildInputs = with pkgs; [
    dpkg
    autoPatchelfHook
    makeWrapper
    wrapGAppsHook3
  ];

  buildInputs = with pkgs; [
    alsa-lib
    at-spi2-core
    cairo
    cups
    dbus
    expat
    gdk-pixbuf
    glib
    gtk3
    libgbm
    libusb1
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    nspr
    nss
    openssl
    pango
    qt6.qtbase
    stdenv.cc.cc.lib
    systemdLibs
    tpm2-tss
  ];

  # Chromium loads these with dlopen rather than ELF DT_NEEDED entries.
  runtimeDependencies = with pkgs; [
    libGL
    libnotify
    libpulseaudio
    libsecret
    vulkan-loader
  ];

  dontBuild = true;
  dontStrip = true;
  dontWrapGApps = true;
  dontWrapQtApps = true;

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --fsys-tarfile "$src" | tar -x
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib" "$out/bin" "$out/share"
    cp -a usr/lib/chatgpt "$out/lib/"
    cp -a usr/share/{applications,pixmaps,metainfo,swcatalog} "$out/share/"

    # Keep Chromium's GTK and Qt 6 backends; Qt 5 cannot share Nix's Qt hook.
    rm "$out/lib/chatgpt/libqt5_shim.so"

    # Bundled node addons include musl builds; this package targets glibc.
    find "$out/lib/chatgpt" -type f -name '*musl*' -delete
    find "$out/lib/chatgpt" -type d -name '*musl*' -prune -exec rm -rf {} +

    substituteInPlace "$out/share/applications/chatgpt.desktop" \
      --replace-fail 'Exec=chatgpt %U' "Exec=$out/bin/chatgpt %U"
    runHook postInstall
  '';

  preFixup = ''
    makeWrapper "$out/lib/chatgpt/ChatGPT" "$out/bin/chatgpt" \
      "''${gappsWrapperArgs[@]}" \
      --suffix PATH : ${lib.makeBinPath (with pkgs; [ xdg-utils glib git xz ])}
  '';

  meta = {
    description = "Official ChatGPT desktop app with Codex";
    homepage = "https://learn.chatgpt.com/docs/linux/linux-app";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "chatgpt";
  };
}
