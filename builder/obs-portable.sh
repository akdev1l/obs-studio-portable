#!/usr/bin/env bash
set -ex
LC_ALL=C

# https://obsproject.com/wiki/Build-Instructions-For-Linux

# Plugins to consider:
# - https://git.vrsal.xyz/alex/Durchblick
# - https://github.com/norihiro/obs-async-audio-filter
# - https://github.com/norihiro/obs-source-record-async
# - https://github.com/norihiro/obs-color-monitor
# - https://github.com/norihiro/obs-output-filter
# - https://github.com/norihiro/obs-face-tracker
# - https://github.com/norihiro/obs-main-view-source
# - https://github.com/norihiro/obs-vnc
# - https://github.com/nowrep/obs-vkcapture

OBS_MAJ_VER=""
if [ -n "${1}" ]; then
    OBS_MAJ_VER="${1}"
fi

BASE_DIR="${HOME}/obs-${OBS_MAJ_VER}"
BUILD_DIR="${BASE_DIR}/build"
BUILD_PORTABLE="${BASE_DIR}/build_portable"
BUILD_SYSTEM="${BASE_DIR}/build_system"
PLUGIN_DIR="${BASE_DIR}/plugins"
SOURCE_DIR="${BASE_DIR}/source"
TARBALL_DIR="${BASE_DIR}/tarballs"

case ${OBS_MAJ_VER} in
  clean)
      rm -rf "${BASE_DIR}/"{build,build_portable,build_system,plugins}
      rm -rf "${SOURCE_DIR}/ntv2/build/"
      exit 0
      ;;
  veryclean)
      rm -rf "${BASE_DIR}/"{build,build_portable,build_system,plugins,source}
      rm -rf "${SOURCE_DIR}/ntv2/build/"
      exit 0
      ;;
  28)
      AJA_VER="v16.2-bugfix5"
      OBS_VER="28.0.2"
      CEF_VER="5060"
      ;;
  27)
      AJA_VER="v16.2-bugfix5"
      OBS_VER="27.2.4"
      CEF_VER="4638"
      ;;
  *)
      echo "ERROR! Unsupported version: ${OBS_MAJ_VER}"
      exit 1
      ;;
esac

if [ -e /etc/os-release ] && grep --quiet UBUNTU_CODENAME /etc/os-release; then
    DISTRO_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d'=' -f2 | sed 's/"//g')
    DISTRO_VERSION=$(grep VERSION_ID /etc/os-release | cut -d'=' -f2 | sed 's/"//g')
    DISTRO_MAJ_VER=$(echo "${DISTRO_VERSION}" | cut -d'.' -f1)
    DISTRO_CMP_VER=$(echo "${DISTRO_VERSION}" | sed 's/\.//g')
    if [ "${DISTRO_MAJ_VER}" -lt 20 ]; then
        echo "Unsupported Ubuntu version: ${DISTRO_VERSION}"
        exit 1
    fi
else
    echo "Unsupported Linux distribution."
    exit 1
fi

# Make the directories
mkdir -p "${BASE_DIR}"/{build,build_portable,build_system,plugins,source,tarballs}
STAMP=$(date +%y%j)
INSTALL_DIR="obs-portable-${OBS_VER}-r${STAMP}-ubuntu-${DISTRO_VERSION}"

function download_file() {
    local URL="${1}"
    local FILE="${URL##*/}"
    local PROJECT=""

    if [[ "${URL}" == *"github"* ]]; then
      PROJECT=$(echo "${URL}" | cut -d'/' -f5)
      FILE="${PROJECT}-${FILE}"
    fi

    # Check the file passes decompression test
    if [ -e "${TARBALL_DIR}/${FILE}" ]; then
        EXT="${FILE##*.}"
        case "${EXT}" in
            bzip2|bz2) FILE_TEST="bzip2 -t";;
            gzip|gz) FILE_TEST="gzip -t";;
            xz) FILE_TEST="xz -t";;
            zip) FILE_TEST="unzip -qq -t";;
            *) FILE_TEST="";;
        esac
        if [ -n "${FILE_TEST}" ]; then
            if ! ${FILE_TEST} "${TARBALL_DIR}/${FILE}"; then
                echo "Testing ${TARBALL_DIR}/${FILE} integrity failed. Deleting it."
                rm "${TARBALL_DIR}/${FILE}" 2>/dev/null
                exit 1
            fi
        fi
    elif ! wget --quiet --show-progress --progress=bar:force:noscroll "${URL}" -O "${TARBALL_DIR}/${FILE}"; then
        echo "Failed to download ${URL}. Deleting ${TARBALL_DIR}/${FILE}..."
        rm "${TARBALL_DIR}/${FILE}" 2>/dev/null
        exit 1
    fi
}

function download_tarball() {
    local URL="${1}"
    local DIR="${2}"
    local FILE="${URL##*/}"
    local PROJECT=""

    if [[ "${URL}" == *"github"* ]]; then
        PROJECT=$(echo "${URL}" | cut -d'/' -f5)
        FILE="${PROJECT}-${FILE}"
    fi

    if [ ! -d "${DIR}" ]; then
        mkdir -p "${DIR}"
    fi

    # Only download and extract if the directory is empty
    if [ -d "${DIR}" ] && [ -z "$(ls -A "${DIR}")" ]; then
        download_file "${URL}"
        bsdtar --strip-components=1 -xf "${TARBALL_DIR}/${FILE}" -C "${DIR}"
    else
        echo " - ${DIR} already exists. Skipping..."
    fi
    echo " - ${URL}" >> "${BUILD_DIR}/obs-manifest.txt"
}

function clone_source() {
    local REPO="${1}"
    local BRANCH="${2}"
    local DIR="${3}"

    if [ ! -d "${DIR}/.git" ]; then
        git clone "${REPO}" --depth=1 --recurse-submodules --shallow-submodules --branch "${BRANCH}" "${DIR}"
    fi
    echo " - ${REPO} (${BRANCH})" >> "${BUILD_DIR}/obs-manifest.txt"
}

function stage_01_get_apt() {
    echo -e "\nBuild dependencies\n" >> "${BUILD_DIR}/obs-manifest.txt"

    apt-get -y update
    apt-get -y upgrade

    if [ "${DISTRO_MAJ_VER}" -ge 22 ]; then
        COMPILERS="gcc g++ golang-go"
    elif [ "${DISTRO_MAJ_VER}" -eq 20 ]; then
        COMPILERS="gcc-10 g++-10 golang-1.16-go"
    fi

    PKG_TOOLCHAIN="bzip2 clang-format clang-tidy cmake curl ${COMPILERS} file git libarchive-tools libc6-dev make meson ninja-build pkg-config unzip wget"
    echo " - Toolchain   : ${PKG_TOOLCHAIN}" >> "${BUILD_DIR}/obs-manifest.txt"
    apt-get -y install ${PKG_TOOLCHAIN}

    if [ "${DISTRO_MAJ_VER}" -eq 20 ]; then
        update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-10 800 --slave /usr/bin/g++ g++ /usr/bin/g++-10
        update-alternatives --install /usr/bin/go go /usr/lib/go-1.16/bin/go 10
    fi

    if [ "${OBS_MAJ_VER}" -ge 28 ] && [ "${DISTRO_MAJ_VER}" -ge 22 ]; then
        PKG_OBS_QT="qt6-base-dev qt6-base-private-dev qt6-wayland libqt6svg6-dev"
    else
        PKG_OBS_QT="qtbase5-dev qtbase5-private-dev qtwayland5 libqt5svg5-dev libqt5x11extras5-dev"
    fi
    echo " - Qt          : ${PKG_OBS_QT}" >> "${BUILD_DIR}/obs-manifest.txt"
    apt-get -y install ${PKG_OBS_QT}

    PKG_OBS_CORE="libavcodec-dev libavdevice-dev libavfilter-dev libavformat-dev \
libavutil-dev libswresample-dev libswscale-dev libcmocka-dev libcurl4-openssl-dev \
libgl1-mesa-dev libgles2-mesa-dev libglvnd-dev libjansson-dev libluajit-5.1-dev \
libmbedtls-dev libpci-dev libvulkan-dev libwayland-dev libx11-dev libx11-xcb-dev \
libx264-dev libxcb-composite0-dev libxcb-randr0-dev libxcb-shm0-dev libxcb-xfixes0-dev \
libxcb-xinerama0-dev libxcb1-dev libxcomposite-dev libxinerama-dev libxss-dev \
python3-dev swig"
    if [ "${OBS_MAJ_VER}" -ge 28 ] && [ "${DISTRO_CMP_VER}" -ge 2210 ]; then
        PKG_OBS_CORE+=" librist-dev libsrt-openssl-dev"
    fi
    echo " - OBS Core    : ${PKG_OBS_CORE}" >> "${BUILD_DIR}/obs-manifest.txt"
    apt-get -y install ${PKG_OBS_CORE}

    PKG_OBS_PLUGINS="libasound2-dev libdrm-dev libfdk-aac-dev libfontconfig-dev \
libfreetype6-dev libjack-jackd2-dev libpulse-dev libsndio-dev libspeexdsp-dev \
libudev-dev libv4l-dev libva-dev libvlc-dev"

    if [ "${DISTRO_MAJ_VER}" -ge 22 ]; then
        PKG_OBS_PLUGINS+=" libpipewire-0.3-dev"
    else
        PKG_OBS_PLUGINS+=" libpipewire-0.2-dev"
    fi

    echo " - OBS Plugins : ${PKG_OBS_PLUGINS}" >> "${BUILD_DIR}/obs-manifest.txt"
    apt-get -y install ${PKG_OBS_PLUGINS}

    echo " - 3rd Party Plugins" >> "${BUILD_DIR}/obs-manifest.txt"
    # 3rd party plugin dependencies:
    PKG_OBS_SCENESWITCHER="libopencv-dev libprocps-dev libxss-dev libxtst-dev"
    echo "   - SceneSwitcher  : ${PKG_OBS_SCENESWITCHER}" >> "${BUILD_DIR}/obs-manifest.txt"
    apt-get -y install ${PKG_OBS_SCENESWITCHER}

    PKG_OBS_WAVEFORM="libfftw3-dev"
    echo "   - Waveform       : ${PKG_OBS_WAVEFORM}" >> "${BUILD_DIR}/obs-manifest.txt"
    apt-get -y install ${PKG_OBS_WAVEFORM}

    PKG_OBS_TEXT="libcairo2-dev libpango1.0-dev libpng-dev"
    echo "   - Pango/PThread  : ${PKG_OBS_TEXT}" >> "${BUILD_DIR}/obs-manifest.txt"
    apt-get -y install ${PKG_OBS_TEXT}

    PKG_OBS_GSTREAMER="libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgstreamer-plugins-good1.0-dev"
    echo "   - GStreamer      : ${PKG_OBS_GSTREAMER}" >> "${BUILD_DIR}/obs-manifest.txt"
    apt-get -y install ${PKG_OBS_GSTREAMER}

    if [ "${DISTRO_MAJ_VER}" -ge 22 ]; then
        PKG_OBS_STREAMFX="libaom-dev"
        echo "   - StreamFX       : ${PKG_OBS_STREAMFX}" >> "${BUILD_DIR}/obs-manifest.txt"
        apt-get -y install ${PKG_OBS_STREAMFX}
    fi
}

function stage_02_get_obs() {
    echo -e "\nOBS Studio\n" >> "${BUILD_DIR}/obs-manifest.txt"
    clone_source "https://github.com/obsproject/obs-studio.git" "${OBS_VER}" "${SOURCE_DIR}"
}

function stage_03_get_cef() {
    download_tarball "https://cdn-fastly.obsproject.com/downloads/cef_binary_${CEF_VER}_linux64.tar.bz2" "${BUILD_DIR}/cef"
    mkdir -p "${BASE_DIR}/${INSTALL_DIR}/cef"
    cp -a "${BUILD_DIR}/cef/Release/"* "${BASE_DIR}/${INSTALL_DIR}/cef/"
    cp -a "${BUILD_DIR}/cef/Resources/"* "${BASE_DIR}/${INSTALL_DIR}/cef/"
    cp "${BUILD_DIR}/cef/"{LICENSE.txt,README.txt} "${BASE_DIR}/${INSTALL_DIR}/cef/"
    chmod 755 "${BASE_DIR}/${INSTALL_DIR}/cef/locales"
}

function stage_04_get_aja() {
    download_tarball "https://github.com/aja-video/ntv2/archive/refs/tags/${AJA_VER}.tar.gz" "${SOURCE_DIR}/ntv2"
    cmake -S "${SOURCE_DIR}/ntv2/" -B "${SOURCE_DIR}/ntv2/build/" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DAJA_BUILD_OPENSOURCE=ON \
      -DAJA_BUILD_APPS=OFF \
      -DAJA_INSTALL_HEADERS=ON
    cmake --build "${SOURCE_DIR}/ntv2/build/"
    cmake --install "${SOURCE_DIR}/ntv2/build/" --prefix "${BUILD_DIR}/aja"
}

function stage_05_build_obs() {
    if [ "${DISTRO_MAJ_VER}" -ge 22 ]; then
        PIPEWIRE_OPTIONS="-DENABLE_PIPEWIRE=ON"
    else
        PIPEWIRE_OPTIONS="-DENABLE_PIPEWIRE=OFF"
    fi

    if [ "${OBS_MAJ_VER}" -ge 28 ]; then
        RTMPS_OPTIONS="-DENABLE_RTMPS=ON"
        BROWSER_OPTIONS="-DENABLE_BROWSER=ON"
        PORTABLE_OPTIONS="-DLINUX_PORTABLE=ON"
        VST_OPTIONS="-DENABLE_VST=ON"
        if [ "${DISTRO_CMP_VER}" -ge 2210 ]; then
            RTMPS_OPTIONS+=" -DENABLE_NEW_MPEGTS_OUTPUT=ON"
        else
            RTMPS_OPTIONS+=" -DENABLE_NEW_MPEGTS_OUTPUT=OFF"
        fi
        if [ "${DISTRO_CMP_VER}" -ge 2204 ]; then
            QT_OPTIONS="-DQT_VERSION=6"
        else
            QT_OPTIONS="-DQT_VERSION=5"
        fi
    else
        RTMPS_OPTIONS="-DWITH_RTMPS=ON"
        BROWSER_OPTIONS="-DBUILD_BROWSER=ON"
        PORTABLE_OPTIONS="-DUNIX_STRUCTURE=OFF"
        QT_OPTIONS="-DQT_VERSION=5"
        VST_OPTIONS="-DBUILD_VST=ON"
    fi

    case ${1} in
      portable)
        BUILD_TO="${BUILD_PORTABLE}"
        INSTALL_TO="${BASE_DIR}/${INSTALL_DIR}"
        if [ "${OBS_MAJ_VER}" -ge 28 ]; then
          PORTABLE_OPTIONS="-DLINUX_PORTABLE=ON"
        else
          PORTABLE_OPTIONS="-DUNIX_STRUCTURE=OFF"
        fi
        STREAMFX_OPTIONS="-DStreamFX_ENABLE_CLANG=OFF -DStreamFX_ENABLE_FRONTEND=OFF -DStreamFX_ENABLE_UPDATER=OFF"
        ;;
      system)
        BUILD_TO="${BUILD_SYSTEM}"
        INSTALL_TO="/usr"
        if [ "${OBS_MAJ_VER}" -ge 28 ]; then
          PORTABLE_OPTIONS="-DLINUX_PORTABLE=OFF"
        else
          PORTABLE_OPTIONS="-DUNIX_STRUCTURE=ON"
        fi
        ;;
    esac

    if [ -e ./obs-options.sh ]; then
        source ./obs-options.sh
        if [ -n "${RESTREAM_CLIENTID}" ] && [ -n "${RESTREAM_HASH}" ]; then
            RESTREAM_OPTIONS="-DRESTREAM_CLIENTID='${RESTREAM_CLIENTID}' -DRESTREAM_HASH='${RESTREAM_HASH}'"
        fi
        if [ -n "${TWITCH_CLIENTID}" ] && [ -n "${TWITCH_HASH}" ]; then
            TWITCH_OPTIONS="-DTWITCH_CLIENTID='${TWITCH_CLIENTID}' -DTWITCH_HASH='${TWITCH_HASH}'"
        fi
        if [ -n "${YOUTUBE_CLIENTID}" ] && [ -n "${YOUTUBE_CLIENTID_HASH}" ] && [ -n "${YOUTUBE_SECRET}" ] &&  [ -n "${YOUTUBE_SECRET_HASH}" ]; then
            YOUTUBE_OPTIONS="-DYOUTUBE_CLIENTID='${YOUTUBE_CLIENTID}' -DYOUTUBE_CLIENTID_HASH='${YOUTUBE_CLIENTID_HASH}' -DYOUTUBE_SECRET='${YOUTUBE_SECRET}' -DYOUTUBE_SECRET_HASH='${YOUTUBE_SECRET_HASH}'"
        fi
    fi

    cmake -S "${SOURCE_DIR}/" -B "${BUILD_TO}/" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="${INSTALL_TO}" \
      -DENABLE_AJA=ON \
      -DAJA_LIBRARIES_INCLUDE_DIR="${BUILD_DIR}"/aja/include/ \
      -DAJA_NTV2_LIB="${BUILD_DIR}"/aja/lib/libajantv2.a \
      ${BROWSER_OPTIONS} \
      -DCEF_ROOT_DIR="${BUILD_DIR}/cef" \
      -DENABLE_ALSA=OFF \
      -DENABLE_SNDIO=OFF \
      -DENABLE_JACK=ON \
      -DENABLE_LIBFDK=ON \
      ${PIPEWIRE_OPTIONS} \
      -DENABLE_PULSEAUDIO=ON \
      -DENABLE_VLC=ON \
      ${VST_OPTIONS} \
      -DENABLE_WAYLAND=ON \
      ${RTMPS_OPTIONS} \
      ${STREAMFX_OPTIONS} \
      ${QT_OPTIONS} \
      ${YOUTUBE_OPTIONS} \
      ${TWITCH_OPTIONS} \
      ${RESTREAM_OPTIONS} \
      ${PORTABLE_OPTIONS}

    cmake --build "${BUILD_TO}/"
    cmake --install "${BUILD_TO}/" --prefix "${INSTALL_TO}"
}

function stage_06_plugins_in_tree() {
    echo -e "\nPlugins (in tree)\n" >> "${BUILD_DIR}/obs-manifest.txt"
    local AUTHOR=""
    local BRANCH=""
    local DIRECTORY=""
    local PLUGIN=""

    if [ "${OBS_MAJ_VER}" -eq 27 ]; then
        REPOS="exeldro:obs-device-switcher:07112a8951bc57deffa3c79f7177281ef5b81420:UI/frontend-plugins \
        exeldro:obs-dir-watch-media:270d9137c650cb419d7a57aa9e81a8e0433217df:plugins \
        exeldro:obs-downstream-keyer:51b59b486e3c037477e0e1bac877bb75db69277d:UI/frontend-plugins \
        exeldro:obs-dynamic-delay:33456a177f830fe63f3bc618ed606465920d072c:plugins \
        exeldro:obs-freeze-filter:e1a8400b9f55f27e00dd9fe2ff8274ee00b39abf:plugins \
        exeldro:obs-gradient-source:ff6c915204d31a45f576f1f43875bfef18c71f04:plugins \
        exeldro:obs-media-controls:8d0ac3ba402e6b535bbb6781b4456a06bf415272:UI/frontend-plugins \
        exeldro:obs-move-transition:2.6.1:plugins \
        exeldro:obs-recursion-effect:f114388665d30a78cf907a1f167c05aa64543a90:plugins \
        exeldro:obs-replay-source:1.6.10:plugins \
        exeldro:obs-scene-notes-dock:9c17ffdf7b15eb3f688b893e35a5aff247d94a78:UI/frontend-plugins \
        exeldro:obs-scene-collection-manager:f7884826996b751c44e26a35d3a8a885274fa97e:UI/frontend-plugins \
        exeldro:obs-setting-docks:978c409c80e44151ee446f6eb18910be44cb6d83:UI/frontend-plugins \
        exeldro:obs-source-copy:25801007d205dabcb16e3a6824727126c1695548:UI/frontend-plugins \
        exeldro:obs-source-dock:0.3.2:UI/frontend-plugins \
        exeldro:obs-source-record:10a9b15c6fd83ba56ffd0e2f5e44b6fba23d772c:plugins \
        exeldro:obs-source-switcher:c83d7d2a497a4c7629e47508309a399a8b83aa06:plugins \
        exeldro:obs-time-shift:6c93ecf1cf74647214f078e6da9178663c45bf3b:plugins \
        exeldro:obs-time-warp-scan:630637ea3a5768e99dd43c772fb0e6766406717b:plugins \
        exeldro:obs-transition-table:d37284703ae0b09673274124addb052600440e5e:UI/frontend-plugins \
        exeldro:obs-virtual-cam-filter:4af4d50d25cb6afa18b29b84a6b1f795e486f4a1:plugins \
        Qufyy:obs-scale-to-sound:1.2.2:plugins \
        WarmUpTill:SceneSwitcher:1.17.7:UI/frontend-plugins \
        Xaymar:obs-StreamFX:0.11.1:UI/frontend-plugins"
    else
        REPOS="exeldro:obs-device-switcher:d8f2c590a9c3da91ff5125d9f01b6797568b02e4:UI/frontend-plugins \
        exeldro:obs-dir-watch-media:270d9137c650cb419d7a57aa9e81a8e0433217df:plugins \
        exeldro:obs-downstream-keyer:0.2.5:UI/frontend-plugins \
        exeldro:obs-dynamic-delay:33456a177f830fe63f3bc618ed606465920d072c:plugins \
        exeldro:obs-freeze-filter:e1a8400b9f55f27e00dd9fe2ff8274ee00b39abf:plugins \
        exeldro:obs-gradient-source:ff6c915204d31a45f576f1f43875bfef18c71f04:plugins \
        exeldro:obs-media-controls:b37f7ab24dcf40701e1f538c14f608a5a0db868b:UI/frontend-plugins \
        exeldro:obs-move-transition:2.6.1:plugins \
        exeldro:obs-recursion-effect:f114388665d30a78cf907a1f167c05aa64543a90:plugins \
        exeldro:obs-replay-source:1.6.11:plugins \
        exeldro:obs-scene-notes-dock:0.1.1:UI/frontend-plugins \
        exeldro:obs-scene-collection-manager:0.0.8:UI/frontend-plugins \
        exeldro:obs-setting-docks:388fb92d253968b797c80d0a5544f49c1d2715f7:UI/frontend-plugins \
        exeldro:obs-source-copy:c88b3c997439247749a5bffc70a69eee8929742a:UI/frontend-plugins \
        exeldro:obs-source-dock:0.3.3:UI/frontend-plugins \
        exeldro:obs-source-record:10a9b15c6fd83ba56ffd0e2f5e44b6fba23d772c:plugins \
        exeldro:obs-source-switcher:c83d7d2a497a4c7629e47508309a399a8b83aa06:plugins \
        exeldro:obs-time-shift:6c93ecf1cf74647214f078e6da9178663c45bf3b:plugins \
        exeldro:obs-time-warp-scan:630637ea3a5768e99dd43c772fb0e6766406717b:plugins \
        exeldro:obs-transition-table:0.2.5:UI/frontend-plugins \
        exeldro:obs-virtual-cam-filter:4af4d50d25cb6afa18b29b84a6b1f795e486f4a1:plugins \
        Qufyy:obs-scale-to-sound:1.2.2:plugins \
        WarmUpTill:SceneSwitcher:1.18.0:plugins \
        Xaymar:obs-StreamFX:0.12.0a134:UI/frontend-plugins"
  fi

  for REPO in ${REPOS}; do
      AUTHOR="$(echo "${REPO}" | cut -d':' -f1)"
      PLUGIN="$(echo "${REPO}" | cut -d':' -f2)"
      BRANCH="$(echo "${REPO}" | cut -d':' -f3)"
      DIRECTORY="$(echo "${REPO}" | cut -d':' -f4)"
      case "${PLUGIN}" in
        obs-StreamFX|SceneSwitcher)
            clone_source "https://github.com/${AUTHOR}/${PLUGIN}.git" "${BRANCH}" "${SOURCE_DIR}/${DIRECTORY}/${PLUGIN}";;
        *)
            BRANCH_LEN=$(echo -n "${BRANCH}" | wc -m);
            if [ "${BRANCH_LEN}" -ge 40 ]; then
                download_tarball "https://github.com/${AUTHOR}/${PLUGIN}/archive/${BRANCH}.zip" "${SOURCE_DIR}/${DIRECTORY}/${PLUGIN}"
            else
                download_tarball "https://github.com/${AUTHOR}/${PLUGIN}/archive/refs/tags/${BRANCH}.zip" "${SOURCE_DIR}/${DIRECTORY}/${PLUGIN}"
            fi
            ;;
      esac
      grep -qxF "add_subdirectory(${PLUGIN})" "${SOURCE_DIR}/${DIRECTORY}/CMakeLists.txt" || echo "add_subdirectory(${PLUGIN})" >> "${SOURCE_DIR}/${DIRECTORY}/CMakeLists.txt"
  done

  # Monkey patch cmake VERSION for Ubuntu 20.04
  if [ "${DISTRO_CMP_VER}" -eq 2004 ]; then
      if [ "${OBS_MAJ_VER}" -eq 28 ]; then
          sed -i 's/VERSION 3\.21/VERSION 3\.16/' "${SOURCE_DIR}/plugins/SceneSwitcher/CMakeLists.txt"
      fi
      if [ "${OBS_MAJ_VER}" -eq 27 ]; then
          for PLUGIN in obs-device-switcher obs-downstream-keyer obs-scene-notes-dock \
          obs-scene-collection-manager obs-source-copy obs-transition-table; do
              sed -i 's/VERSION 3\.18/VERSION 3\.16/' "${SOURCE_DIR}/UI/frontend-plugins/${PLUGIN}/CMakeLists.txt"
          done
      fi
  fi
}

function stage_07_plugins_out_tree() {
    echo -e "\nPlugins (out of tree)\n" >> "${BUILD_DIR}/obs-manifest.txt"
    local AUTHOR=""
    local BRANCH=""
    local DIRECTORY=""
    local PLUGIN=""

    if [ "${OBS_MAJ_VER}" -eq 27 ]; then
        REPOS="cg2121:obs-soundboard:1.0.3: \
        kkartaltepe:obs-text-pango:8f4775d629624ea450474e39a4e7143166d8aeba: \
        norihiro:obs-audio-pan-filter:0.1.2: \
        norihiro:obs-command-source:0.2.1: \
        norihiro:obs-multisource-effect:0.1.7: \
        norihiro:obs-mute-filter:0.1.0: \
        norihiro:obs-text-pthread:1.0.3: \
        obsproject:obs-websocket:4.9.1: \
        phandasm:waveform:v1.4.1:"
    else
        REPOS="cg2121:obs-soundboard:1.1.1: \
        kkartaltepe:obs-text-pango:8f4775d629624ea450474e39a4e7143166d8aeba: \
        norihiro:obs-async-source-duplication:0.4.0: \
        norihiro:obs-audio-pan-filter:0.2.2: \
        norihiro:obs-command-source:0.3.0: \
        norihiro:obs-multisource-effect:0.2.1: \
        norihiro:obs-mute-filter:0.2.1: \
        norihiro:obs-text-pthread:2.0.2: \
        obsproject:obs-websocket:4.9.1-compat: \
        phandasm:waveform:v1.5.0:"
    fi

    if [ "${DISTRO_MAJ_VER}" -ge 22 ] && [ "${OBS_MAJ_VER}" -ge 28 ]; then
        REPOS+=" dimtpap:obs-pipewire-audio-capture:dd0cfa9581481c862cddd725e23423cd975265d9: "
    fi

    for REPO in ${REPOS}; do
        AUTHOR="$(echo "${REPO}" | cut -d':' -f1)"
        PLUGIN="$(echo "${REPO}" | cut -d':' -f2)"
        BRANCH="$(echo "${REPO}" | cut -d':' -f3)"

        case "${PLUGIN}" in
            obs-websocket|waveform)
                clone_source "https://github.com/${AUTHOR}/${PLUGIN}.git" "${BRANCH}" "${PLUGIN_DIR}/${PLUGIN}"
                # Patch obs-websocket 4.9.1 (not the compat release) so it builds against OBS 27.2.4
                # https://github.com/obsproject/obs-websocket/issues/916#issuecomment-1193399097
                if [ "${PLUGIN}" == "obs-websocket" ] && [ "${BRANCH}" == "4.9.1" ]; then
                    sed -r -i 's/OBS(.+?)AutoRelease/OBS\1AutoRelease_OBSWS/g' \
                    "${PLUGIN_DIR}/${PLUGIN}"/src/*.h \
                    "${PLUGIN_DIR}/${PLUGIN}"/src/*/*.h \
                    "${PLUGIN_DIR}/${PLUGIN}"/src/*.cpp \
                    "${PLUGIN_DIR}/${PLUGIN}"/src/*/*.cpp
                fi
                ;;
            *)  BRANCH_LEN=$(echo -n "${BRANCH}" | wc -m);
                if [ "${BRANCH_LEN}" -ge 40 ]; then
                    download_tarball "https://github.com/${AUTHOR}/${PLUGIN}/archive/${BRANCH}.zip" "${PLUGIN_DIR}/${PLUGIN}"
                else
                    download_tarball "https://github.com/${AUTHOR}/${PLUGIN}/archive/refs/tags/${BRANCH}.zip" "${PLUGIN_DIR}/${PLUGIN}"
                fi
                ;;
        esac

        if [ "${OBS_MAJ_VER}" -eq 27 ] && [ "${PLUGIN}" != "obs-soundboard" ]; then
            cd "${PLUGIN_DIR}/${PLUGIN}"
            cmake -S "${PLUGIN_DIR}/${PLUGIN}" -B "${PLUGIN_DIR}/${PLUGIN}/build" \
              -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_INSTALL_PREFIX="${BASE_DIR}/${INSTALL_DIR}"
            make -C "${PLUGIN_DIR}/${PLUGIN}/build"
            make -C "${PLUGIN_DIR}/${PLUGIN}/build" install
        else
            cmake -S "${PLUGIN_DIR}/${PLUGIN}" -B "${PLUGIN_DIR}/${PLUGIN}/build" -G Ninja \
              -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_INSTALL_PREFIX="${BASE_DIR}/${INSTALL_DIR}"
            cmake --build "${PLUGIN_DIR}/${PLUGIN}/build"
            cmake --install "${PLUGIN_DIR}/${PLUGIN}/build" --prefix "${BASE_DIR}/${INSTALL_DIR}/"
        fi

        # Reorgansise some misplaced plugins
        case ${PLUGIN} in
            obs-pipewire-audio-capture)
                mv -v "${BASE_DIR}/${INSTALL_DIR}/lib/obs-plugins/linux-pipewire-audio.so" "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/64bit/" || true
                rm -rf "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/linux-pipewire-audio/locale/"
                mkdir -p "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/linux-pipewire-audio"
                mv -v "${BASE_DIR}/${INSTALL_DIR}/share/obs/obs-plugins/linux-pipewire-audio/locale/" "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/linux-pipewire-audio/" || true
                ;;
            obs-text-pango)
                mv -v "${BASE_DIR}/${INSTALL_DIR}/bin/libtext-pango.so" "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/64bit/" || true
                ;;
            waveform)
                mv -v "${BASE_DIR}/${INSTALL_DIR}"/waveform/bin/64bit/*waveform.so "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/64bit/" || true
                rm -rf "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/waveform"
                mkdir -p "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/waveform"
                mv -v "${BASE_DIR}/${INSTALL_DIR}/waveform/data/"* "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/waveform/" || true
                ;;
        esac

        if [ -e "${BASE_DIR}/${INSTALL_DIR}/lib/obs-plugins/${PLUGIN}.so" ]; then
            mv -v "${BASE_DIR}/${INSTALL_DIR}/lib/obs-plugins/${PLUGIN}.so" "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/64bit/" || true
        fi
        if [ -d "${BASE_DIR}/${INSTALL_DIR}/share/obs/obs-plugins/${PLUGIN}" ]; then
            rm -rf "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/${PLUGIN}"
            mkdir -p "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/${PLUGIN}"
            mv -v "${BASE_DIR}/${INSTALL_DIR}/share/obs/obs-plugins/${PLUGIN}"/* "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/${PLUGIN}/" || true
        fi
    done

    for REPO in fzwoch:obs-gstreamer:v0.3.5: fzwoch:obs-vaapi:0.1.0:; do
        AUTHOR="$(echo "${REPO}" | cut -d':' -f1)"
        PLUGIN="$(echo "${REPO}" | cut -d':' -f2)"
        BRANCH="$(echo "${REPO}" | cut -d':' -f3)"
        download_tarball "https://github.com/${AUTHOR}/${PLUGIN}/archive/refs/tags/${BRANCH}.zip" "${PLUGIN_DIR}/${PLUGIN}"
        meson --buildtype=release --prefix="${BASE_DIR}/${INSTALL_DIR}/" --libdir="${BASE_DIR}/${INSTALL_DIR}/" "${PLUGIN_DIR}/${PLUGIN}" "${PLUGIN_DIR}/${PLUGIN}/build"
        ninja -C "${PLUGIN_DIR}/${PLUGIN}/build"
        ninja -C "${PLUGIN_DIR}/${PLUGIN}/build" install
        mv "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/${PLUGIN}.so" "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/64bit/${PLUGIN}.so"
        chmod 644 "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/64bit/${PLUGIN}.so"
    done

    # Requires Go 1.17, which is not available in Ubuntu 20.04
    if [ "${DISTRO_MAJ_VER}" -ge 22 ]; then
        download_tarball "https://github.com/fzwoch/obs-teleport/archive/refs/tags/0.5.0.zip" "${PLUGIN_DIR}/obs-teleport"
        export CGO_CPPFLAGS="${CPPFLAGS}"
        export CGO_CFLAGS="${CFLAGS} -I/usr/include/obs"
        export CGO_CXXFLAGS="${CXXFLAGS}"
        export CGO_LDFLAGS="${LDFLAGS} -ljpeg -lobs -lobs-frontend-api"
        export GOFLAGS="-buildmode=c-shared -trimpath -mod=readonly -modcacherw"
        cd "${PLUGIN_DIR}/obs-teleport"
        go build -ldflags "-linkmode external -X main.version=0.5.0" -v -o "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/64bit/obs-teleport.so" .
        mv "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/64bit/obs-teleport.h" "${BASE_DIR}/${INSTALL_DIR}/include/"
    fi
}

function stage_08_plugins_prebuilt() {
    echo -e "\nPlugins (pre-built)\n" >> "${BUILD_DIR}/obs-manifest.txt"
    local URL=""
    local ZIP=""

    URLS="https://github.com/univrsal/dvds3/releases/download/v1.1/dvd-screensaver.v1.1.linux.x64.zip \
    https://obsproject.com/forum/resources/rgb-levels.967/download"

    for URL in ${URLS}; do
        ZIP="${URL##*/}"
        if [ "${ZIP}" == "download" ]; then
            ZIP="rgb-levels.zip"
        fi
        echo " - ${URL}" >> "${BUILD_DIR}/obs-manifest.txt"
        wget --quiet --show-progress --progress=bar:force:noscroll "${URL}" -O "${TARBALL_DIR}/${ZIP}"
        unzip -o -qq "${TARBALL_DIR}/${ZIP}" -d "${PLUGIN_DIR}/$(basename "${ZIP}" .zip)"
    done

    # Reorgansise plugins
    mv -v "${PLUGIN_DIR}/dvd-screensaver.v1.1.linux.x64/dvd-screensaver/bin/64bit/dvd-screensaver.so" "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/64bit/"
    rm -rf "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/dvd-screensaver"
    mkdir -p "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/dvd-screensaver"
    mv -v "${PLUGIN_DIR}/dvd-screensaver.v1.1.linux.x64/dvd-screensaver/data/"* "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/dvd-screensaver/"

    mv -v "${PLUGIN_DIR}/rgb-levels/usr/lib/obs-plugins/obs-rgb-levels-filter.so" "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/64bit/"
    mkdir -p "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/obs-rgb-levels-filter/"
    mv -v "${PLUGIN_DIR}/rgb-levels/usr/share/obs/obs-plugins/obs-rgb-levels-filter/"*.effect "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/obs-rgb-levels-filter/"
}

function stage_09_finalise() {
    # Remove CEF files that are lumped in with obs-plugins
    # Prevents OBS from enumating the .so files to determine if they can be loaded as a plugin
    rm -rf "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/64bit/locales" || true
    rm -rf "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/64bit/swiftshader" || true
    for CEF_FILE in chrome-sandbox chrome_100_percent.pak chrome_200_percent.pak \
        icudtl.dat libcef.so libEGL.so libGLESv2.so libvk_swiftshader.so \
        libvulkan.so.1 resources.pak snapshot_blob.bin v8_context_snapshot.bin \
        vk_swiftshader_icd.json; do
        rm -f "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/64bit/${CEF_FILE}" || true
    done

    # The StreamFX log entries show it tries to load libaom.so from data/obs-plugins/StreamFX
    #09:20:39.424: [StreamFX] <encoder::aom::av1> Loading of '../../data/obs-plugins/StreamFX/libaom.so' failed.
    #09:20:39.424: [StreamFX] <encoder::aom::av1> Loading of 'libaom' failed.
    if [ -d "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/StreamFX" ]; then
        case "${DISTRO_CMP_VER}" in
            2204) AOM_VER="3.3.0";;
            2210) AOM_VER="3.4.0";;
        esac
        cp /usr/lib/x86_64-linux-gnu/libaom.so."${AOM_VER}" "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/StreamFX/libaom.so" || true
    fi

    # Remove empty directories
    find "${BASE_DIR}/${INSTALL_DIR}" -type d -empty -delete

    # Strip binaries and correct permissions
    for DIR in "${BASE_DIR}/${INSTALL_DIR}/cef" "${BASE_DIR}/${INSTALL_DIR}/bin/64bit" "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/64bit" "${BASE_DIR}/${INSTALL_DIR}/data/obs-scripting/64bit" "${BASE_DIR}/${INSTALL_DIR}/data/obs-plugins/StreamFX/"; do
        for FILE in $(find "${DIR}" -type f); do
            TYPE=$(file "${FILE}" | cut -d':' -f2 | awk '{print $1}')
            if [ "${TYPE}" == "ELF" ]; then
                strip --strip-unneeded "${FILE}" || true
                if [[ "${FILE}" == *.so* ]]; then
                  chmod 644 "${FILE}"
                fi
            else
                chmod 644 "${FILE}"
            fi
        done
    done

    # Build a list of all the linked libraries
    echo -n "" > obs-libs.txt
    for DIR in "${BASE_DIR}/${INSTALL_DIR}/cef" "${BASE_DIR}/${INSTALL_DIR}/bin/64bit" "${BASE_DIR}/${INSTALL_DIR}/obs-plugins/64bit" "${BASE_DIR}/${INSTALL_DIR}/data/obs-scripting/64bit"; do
        for FILE in $(find "${DIR}" -type f); do
            ldd "${FILE}" | awk '{print $1}' | grep -Fv -e 'advanced-scene-switcher' -e 'libobs' -e 'ld-linux' -e 'libc.so' -e 'libm.so' -e 'linux-vdso' >> obs-libs.txt || true
        done
    done

    # Map linked libraries to their package
    echo -n "" > obs-pkgs.txt
    for LIB in $(sort -u obs-libs.txt); do
        dpkg -S "${LIB}" | grep -Fv -e 'i386' -e '-dev' | cut -d ':' -f1 | sort -u >> obs-pkgs.txt || true
    done

    # Create runtime dependencies installer
    cat << 'EOF' > "${BASE_DIR}/${INSTALL_DIR}/obs-dependencies"
#!/usr/bin/env bash
# Portable OBS Studio launcher dependency installer

sudo apt-get -y update
EOF
    echo "sudo apt-get install \\" >> "${BASE_DIR}/${INSTALL_DIR}/obs-dependencies"
    for PKG in $(sort -u obs-pkgs.txt); do
        echo -e "\t${PKG} \\" >> "${BASE_DIR}/${INSTALL_DIR}/obs-dependencies"
    done

    # Provide additional runtime requirements
    if [ "${OBS_MAJ_VER}" -ge 28 ] && [ "${DISTRO_MAJ_VER}" -ge 22 ]; then
        echo -e "\tqt6-qpa-plugins qt6-wayland \\" >> "${BASE_DIR}/${INSTALL_DIR}/obs-dependencies"
    else
        echo -e "\tqtwayland5 \\" >> "${BASE_DIR}/${INSTALL_DIR}/obs-dependencies"
    fi
    echo -e "\tlibvlc5 vlc-plugin-base v4l2loopback-dkms v4l2loopback-utils" >> "${BASE_DIR}/${INSTALL_DIR}/obs-dependencies"
    chmod 755 "${BASE_DIR}/${INSTALL_DIR}/obs-dependencies"

    # Create launcher script
    cat << 'EOF' > "${BASE_DIR}/${INSTALL_DIR}/obs-portable"
#!/usr/bin/env bash
# Portable OBS Studio launcher

PORTABLE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
export LD_LIBRARY_PATH="${PORTABLE_DIR}/bin/64bit:${PORTABLE_DIR}/obs-plugins/64bit:${PORTABLE_DIR}/data/obs-scripting/64bit:${PORTABLE_DIR}/cef:${LD_LIBRARY_PATH}"

cd "${PORTABLE_DIR}/bin/64bit"
exec ./obs --portable ${@}
EOF
    chmod 755 "${BASE_DIR}/${INSTALL_DIR}/obs-portable"
}

function stage_10_make_tarball() {
    cd "${BASE_DIR}"
    cp "${BUILD_DIR}/obs-manifest.txt" "${BASE_DIR}/${INSTALL_DIR}/manifest.txt"
    tar cjf "${INSTALL_DIR}.tar.bz2" --exclude cmake --exclude include --exclude lib "${INSTALL_DIR}"
    sha256sum "${INSTALL_DIR}.tar.bz2" > "${BASE_DIR}/${INSTALL_DIR}.tar.bz2.sha256"
    sed -i -r "s/ .*\/(.+)/  \1/g" "${BASE_DIR}/${INSTALL_DIR}.tar.bz2.sha256"
    cp "${BUILD_DIR}/obs-manifest.txt" "${BASE_DIR}/${INSTALL_DIR}.txt"
}

echo -e "Portable OBS Studio ${OBS_VER} for Ubuntu ${DISTRO_VERSION} manifest (r${STAMP})\n\n" > "${BUILD_DIR}/obs-manifest.txt"
echo -e "  - https://github.com/wimpysworld/obs-portable/\n"                                   >> "${BUILD_DIR}/obs-manifest.txt"
stage_01_get_apt
stage_02_get_obs
stage_03_get_cef
stage_04_get_aja
stage_05_build_obs system
stage_06_plugins_in_tree
stage_05_build_obs portable
stage_07_plugins_out_tree
stage_08_plugins_prebuilt
stage_09_finalise
stage_10_make_tarball