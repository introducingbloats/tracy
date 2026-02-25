{
  lib,
  stdenv,
  fetchgit,
  fetchFromGitHub,
  cmake,
  pkg-config,

  # System dependencies (used via pkg-config instead of CPM download)
  freetype,
  glfw,
  curl,
  pugixml,

  # Build/runtime dependencies
  dbus,
  libglvnd,
  libffi,
  wayland,
  wayland-protocols,
  wayland-scanner,
  libxkbcommon,
  libdecor,
  xorg,
  libgcc,
  autoPatchelfHook,
  makeWrapper,
}:
let
  currentVersion = lib.importJSON ./version.json;
  shortRev = builtins.substring 0 7 currentVersion.rev;
  version = "${currentVersion.version}-unstable-${shortRev}";

  # Helper to fetch a CPM dependency listed in version.json
  fetchDep = name: fetchFromGitHub {
    inherit (currentVersion.deps.${name}) owner repo rev hash;
  };

  # CPM dependencies built from source
  # Packages WITH patches (need writable copies for CPM to patch)
  imgui-src = fetchDep "imgui";
  ppqsort-src = fetchDep "ppqsort";
  tidy-src = fetchDep "tidy";

  # Packages WITHOUT patches (read-only Nix store paths are fine)
  nfd-src = fetchDep "nfd";
  json-src = fetchDep "json";
  md4c-src = fetchDep "md4c";
  base64-src = fetchDep "base64";
  usearch-src = fetchDep "usearch";
  capstone-src = fetchDep "capstone";
  zstd-src = fetchDep "zstd";

  # Transitive CPM dependency (required by PPQSort)
  packageproject-src = fetchDep "packageproject";
in
stdenv.mkDerivation {
  pname = "tracy";
  inherit version;

  src = fetchgit {
    url = "https://github.com/wolfpld/tracy.git";
    rev = currentVersion.rev;
    hash = currentVersion.gitHash;
  };

  nativeBuildInputs = [
    cmake
    pkg-config
    wayland-scanner
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = [
    # System packages that Tracy can find via pkg-config
    freetype
    glfw
    curl
    pugixml

    # Graphics / windowing
    libglvnd
    dbus
    wayland
    wayland-protocols
    libxkbcommon
    libdecor
    libffi

    # X11 (needed by GLFW's X11 backend with LEGACY=ON)
    xorg.libX11
    xorg.libXext
    xorg.libXrandr
    xorg.libXinerama
    xorg.libXcursor
    xorg.libXi

    libgcc
    libgcc.lib
  ];

  # Build all Tracy tools from their respective subdirectories
  dontUseCmakeConfigure = true;

  buildPhase =
    let
      # Helper to create fresh writable copies of patched CPM sources.
      # Each tool build applies patches, so copies must be recreated per-tool.
      setupWritableSources = ''
        rm -rf imgui-writable ppqsort-writable tidy-writable

        cp -r ${imgui-src} imgui-writable
        chmod -R u+w imgui-writable

        cp -r ${ppqsort-src} ppqsort-writable
        chmod -R u+w ppqsort-writable
        # PPQSort bundles a CPM bootstrap that tries to download from GitHub.
        # Tracy's CPM.cmake is already loaded at this point, so just empty it.
        echo "" > ppqsort-writable/cmake/CPM.cmake

        cp -r ${tidy-src} tidy-writable
        chmod -R u+w tidy-writable
      '';
      cpmFlags = lib.concatStringsSep " " [
        # Use system packages for these (found via pkg-config)
        "-DDOWNLOAD_GLFW=OFF"
        "-DDOWNLOAD_FREETYPE=OFF"
        "-DDOWNLOAD_LIBCURL=OFF"
        "-DDOWNLOAD_PUGIXML=OFF"

        # CPM source overrides — packages WITH patches (writable copies)
        "-DCPM_ImGui_SOURCE=$PWD/imgui-writable"
        "-DCPM_PPQSort_SOURCE=$PWD/ppqsort-writable"
        "-DCPM_tidy_SOURCE=$PWD/tidy-writable"

        # CPM source overrides — packages WITHOUT patches (read-only store paths)
        "-DCPM_nfd_SOURCE=${nfd-src}"
        "-DCPM_json_SOURCE=${json-src}"
        "-DCPM_md4c_SOURCE=${md4c-src}"
        "-DCPM_base64_SOURCE=${base64-src}"
        "-DCPM_usearch_SOURCE=${usearch-src}"
        "-DCPM_capstone_SOURCE=${capstone-src}"
        "-DCPM_zstd_SOURCE=${zstd-src}"

        # Transitive CPM dependency (required by PPQSort)
        "-DCPM_PackageProject.cmake_SOURCE=${packageproject-src}"

        # usearch's fp16 submodule isn't fetched; disable software FP16 emulation
        "-DUSEARCH_USE_FP16LIB=OFF"

        "-DCMAKE_BUILD_TYPE=Release"
        "-DLEGACY=ON"
        "-DNO_ISA_EXTENSIONS=ON"
      ];
      tools = [
        "profiler"
        "capture"
        "csvexport"
        "update"
        "import"
      ];
      buildTool = tool: ''
        echo "=== Building ${tool} ==="
        ${setupWritableSources}
        cmake -B build-${tool} -S ${tool} ${cpmFlags} \
          -DCMAKE_INSTALL_PREFIX=$out
        cmake --build build-${tool} --config Release --parallel $NIX_BUILD_CORES
      '';
    in
    ''
      runHook preBuild
      ${lib.concatMapStringsSep "\n" buildTool tools}
      runHook postBuild
    '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin

    install -m755 build-profiler/tracy-profiler $out/bin/tracy
    install -m755 build-capture/tracy-capture $out/bin/tracy-capture
    install -m755 build-csvexport/tracy-csvexport $out/bin/tracy-csvexport
    install -m755 build-update/tracy-update $out/bin/tracy-update

    for f in build-import/tracy-import-*; do
      install -m755 "$f" $out/bin/
    done

    for bin in $out/bin/*; do
      wrapProgram "$bin" \
        --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [
          libglvnd
          wayland
          libxkbcommon
          libdecor
          dbus
          xorg.libX11
          xorg.libXext
          xorg.libXrandr
          xorg.libXinerama
          xorg.libXcursor
          xorg.libXi
        ]}
    done

    runHook postInstall
  '';

  meta = {
    description = "A real time, nanosecond resolution, remote telemetry, hybrid frame and sampling profiler";
    homepage = "https://github.com/wolfpld/tracy";
    license = lib.licenses.bsd3;
    sourceProvenance = with lib.sourceTypes; [ fromSource ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "tracy";
  };
}
