#!/bin/bash
set -x

main() {
    gitdir=$(pwd)
    clang_root=$(pwd)/clang_root
    buildroot=$(pwd)
    srcdir=$(pwd)/src_packages
    local target=$1
    compiler=$2
    simple_package=$3

    prepare
    if [ "$target" == "64-v3" ]; then
        package "64-v3"
    elif [ "$target" == "aarch64" ]; then
        package "aarch64"
    elif [ "$target" == "all" ]; then
        package "64-v3"
        package "aarch64"
    fi
    rm -rf ./release/mpv-packaging-master
}

package() {
    local bit=$1
    if [ $bit == "64-v3" ]; then
        local arch="x86_64"
        local gcc_arch="-DMARCH=skylake"
        local x86_64_level="-v3"
    elif [ $bit == "aarch64" ]; then
        local arch="aarch64"
    fi

    build $bit $arch $gcc_arch $x86_64_level
    zip $bit $arch $x86_64_level
    sudo rm -rf $buildroot/build$bit/mpv-*
    sudo chmod -R a+rwx $buildroot/build$bit
}

build() {
    local bit=$1
    local arch=$2
    local gcc_arch=$3
    local x86_64_level=$4

    export PATH="/usr/local/fuchsia-clang/bin:$PATH"
    wget https://github.com/Andarwinux/mpv-winbuild/releases/download/pgo/pgo.profdata
    wget https://github.com/Andarwinux/mimalloc/raw/refs/heads/dev2/bin/minject.exe

    if [ "$compiler" == "clang" ]; then
        clang_option=(-DCMAKE_INSTALL_PREFIX=$clang_root -DMINGW_INSTALL_PREFIX=$buildroot/build$bit/install/$arch-w64-mingw32)
        pgo_option=(-DCLANG_PACKAGES_PGO=USE -DCLANG_PACKAGES_PROFDATA_FILE="./pgo.profdata")
    fi

    if [ "$arch" == "x86_64" ]; then
        if [ "$x86_64_level" == "-v3" ]; then
            arch_option=(-DMARCH_NAME=-v3)
        fi
    fi

    cmake --fresh -DTARGET_ARCH=$arch-w64-mingw32 $gcc_arch -DCOMPILER_TOOLCHAIN=$compiler "${clang_option[@]}" "${pgo_option[@]}" "${arch_option[@]}" $extra_option -DENABLE_LEGACY_MPV=ON -DENABLE_CCACHE=ON -DQT_DISABLE_CCACHE=ON -DSINGLE_SOURCE_LOCATION=$srcdir -G Ninja -H$gitdir -B$buildroot/build$bit

    ninja -C $buildroot/build$bit download || true
    ninja -C $buildroot/build$bit update || true
    ninja -C $buildroot/build$bit update
    ninja -C $buildroot/build$bit mpv-fullclean
    ninja -C $buildroot/build$bit download
    ninja -C $buildroot/build$bit patch

    ninja -C $buildroot/build$bit qbittorrent
    ninja -C $buildroot/build$bit curl aria2 mediainfo svtav1-psy mimalloc
    ninja -C $buildroot/build$bit mpv mpv-menu-plugin mpv-debug-plugin mpc-qt

    sudo wine ./minject.exe $buildroot/build$bit/mpv-*/mpv.exe --inplace -y
    sudo wine ./minject.exe $buildroot/build$bit/mpv-*/mpv-legacy.exe --inplace -y
    sudo wine ./minject.exe $buildroot/build$bit/install/$arch-w64-mingw32/bin/ffmpeg.exe --inplace -y
    sudo wine ./minject.exe $buildroot/build$bit/install/$arch-w64-mingw32/bin/curl.exe --inplace -y
    sudo wine ./minject.exe $buildroot/build$bit/install/$arch-w64-mingw32/bin/mujs.exe --inplace -y
    sudo wine ./minject.exe $buildroot/build$bit/install/$arch-w64-mingw32/bin/aria2c.exe --inplace -y
    sudo wine ./minject.exe $buildroot/build$bit/install/$arch-w64-mingw32/bin/mediainfo.exe --inplace -y
    sudo wine ./minject.exe $buildroot/build$bit/install/$arch-w64-mingw32/bin/SvtAv1EncApp-PSY.exe --inplace -y
    sudo wine ./minject.exe $buildroot/build$bit/install/$arch-w64-mingw32/bin/qbittorrent.exe --inplace -y
    sudo wine ./minject.exe $buildroot/build$bit/install/$arch-w64-mingw32/bin/mpc-qt.exe --inplace -y

    if [ "$arch" == "x86_64" ]; then
        cp $buildroot/build$bit/install/$arch-w64-mingw32/bin/mimalloc{-redirect,}.dll $buildroot/build$bit/mpv-$arch$x86_64_level*/
        cp $buildroot/build$bit/install/$arch-w64-mingw32/bin/vulkan-1.dll $buildroot/build$bit/mpv-$arch$x86_64_level*/
        bin-cpuflags-x86 -d $buildroot/build$bit/mpv-*/mpv.exe > instrinfo.txt
        cp instrinfo.txt $buildroot/build$bit/mpv-$arch$x86_64_level*/
    elif [ "$arch" == "aarch64" ]; then
        cp $buildroot/build$bit/install/$arch-w64-mingw32/bin/mimalloc{-redirect-arm64,}.dll $buildroot/build$bit/mpv-$arch*/
        cp $buildroot/build$bit/install/$arch-w64-mingw32/bin/vulkan-1.dll $buildroot/build$bit/mpv-$arch*/
    fi

    if [ -n "$(find $buildroot/build$bit -maxdepth 1 -type d -name "mpv*$arch*" -print -quit)" ] ; then
        echo "Successfully compiled $bit-bit. Continue"
    else
        echo "Failed compiled $bit-bit. Stop"
        exit 1
    fi

    ninja -C $buildroot/build$bit ccache-recomp
}

zip() {
    local bit=$1
    local arch=$2
    local x86_64_level=$3

    mv $buildroot/build$bit/mpv-* $gitdir/release
    if [ "$simple_package" != "true" ]; then
        cd $gitdir/release/mpv-packaging-master
        cp -r ./mpv-root/* ../mpv-$arch$x86_64_level*
    fi
    cd $gitdir/release
    for dir in ./mpv*$arch$x86_64_level*; do
        if [ -d $dir ]; then
            7z a -m0=lzma2 -mx=9 -ms=on $dir.7z $dir/* -x!*.7z
            rm -rf $dir
        fi
    done
    cd ..
}

download_mpv_package() {
    local package_url="https://codeload.github.com/Andarwinux/mpv-packaging/zip/master"
    if [ -e mpv-packaging.zip ]; then
        echo "Package exists. Check if it is newer.."
        remote_commit=$(git ls-remote https://github.com/Andarwinux/mpv-packaging.git master | awk '{print $1;}')
        local_commit=$(unzip -z mpv-packaging.zip | tail +2)
        if [ "$remote_commit" != "$local_commit" ]; then
            wget -qO mpv-packaging.zip $package_url
        fi
    else
        wget -qO mpv-packaging.zip $package_url
    fi
    unzip -o mpv-packaging.zip
}

prepare() {
    mkdir -p ./release
    if [ "$simple_package" != "true" ]; then
        cd ./release
        download_mpv_package
        cd ./mpv-packaging-master
        cd ../..
    fi
}

while getopts t:c:s:e: flag
do
    case "${flag}" in
        t) target=${OPTARG};;
        c) compiler=${OPTARG};;
        s) simple_package=${OPTARG};;
        e) extra_option=${OPTARG};;
    esac
done

main "${target:-all-64}" "${compiler:-gcc}" "${simple_package:-false}"
