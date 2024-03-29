#!/bin/bash

set -e

SKIP_DEPS="${SKIP_DEPS:-0}"
GIT_COMMIT="$1"

ARCH=$(uname -m)
ARCHDASH=$(echo "$ARCH"|tr '_' '-')
APPIMAGETOOL="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${ARCH}.AppImage"

curl -Ls "$APPIMAGETOOL" > appimagetool
if [ $? -ne 0 ];then
	echo "failed to retrieve appimagetool.  bailing out."
	exit 1
fi
chmod -f +x appimagetool

#unused but must exist
DESKTOP_ENTRY='[Desktop Entry]
Name=ezquake
Exec=ezquake-linux-'$ARCH'
Icon=quake
Type=Application
Categories=Game;'

TESTPROGRAM='
#include "curl/curl.h"
int main(){
  curl_easy_init();
	return 0;
}
'

QUAKE_SCRIPT='#!/usr/bin/env bash
export LD_LIBRARY_PATH="${APPIMAGE_LIBRARY_PATH}:${APPDIR}/usr/lib:${LD_LIBRARY_PATH}"
if [ ! -e "$OWD/id1" ];then
	cd "$(dirname "$APPIMAGE")"
else
	cd "$OWD"
fi

"${APPDIR}/usr/bin/test"  >/dev/null 2>&1 |:
FAIL=${PIPESTATUS[0]}
if [ $FAIL -eq 0 ];then
  echo "executing with native libc"
  "${APPDIR}/usr/bin/ezquake-linux-'$ARCH'" $*
else
  echo "executing with appimage libc"
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:${APPDIR}/usr/lib-override"
  "${APPDIR}/usr/lib-override/ld-linux-'$ARCHDASH'.so.2" "${APPDIR}/usr/bin/ezquake-linux-'$ARCH'" $*
fi
exitstatus=$?

if [ $exitstatus -eq 0 ];then
	#fix qwurl association if set for appimage
	grep -q "^Exec=/tmp/.mount_ezq" "${HOME}/.local/share/applications/qw-url-handler.desktop" && \
		sed -i "s|^Exec=.*|Exec=${APPIMAGE}|g" "${HOME}/.local/share/applications/qw-url-handler.desktop"
else
		exit $exitstatus
fi
'

unset CC
if [ "$ARCH" == "x86_64" ];then
	march="-march=nehalem"
fi
export CFLAGS="$march -pipe -O3 -flto=$(nproc) -flto-partition=balanced -ftree-slp-vectorize -ffp-contract=fast -fno-defer-pop -finline-limit=64 -fmerge-all-constants"
export LDFLAGS="$CFLAGS"

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

if [ -d AppDir ];then
	rm -rf AppDir
fi
mkdir -p "$DIR/build" || exit 1
mkdir -p "$DIR/AppDir/usr/bin" || exit 1
mkdir -p "$DIR/AppDir/usr/lib" || exit 1
mkdir -p "$DIR/AppDir/usr/lib-override" || exit 1

echo "$TESTPROGRAM" > "$DIR/build/test.c"

#ezquake git
fresh=0
cd build && \
gcc test.c -o test -lcurl && \
if [ ! -d ezquake-source ];then
	git clone --recurse-submodules https://github.com/QW-Group/ezquake-source.git
  fresh=1
fi
cd ezquake-source || exit 2
if [ $fresh -ne 1 ];then
  make clean
  git clean -qfdx
  git reset --hard
  git checkout master
  git pull
fi
if [ ! -z $GIT_COMMIT ];then
	git checkout $GIT_COMMIT
fi
if [ $? -ne 0 ];then
	echo "error updating from git"
	exit 2
fi
VERSION=$(sed -n 's/.*VERSION_NUMBER.*"\(.*\)".*/\1/p' src/version.h)
REVISION=$(git log -n 1|head -1|awk '{print $2}'|cut -c1-6)

if [ $SKIP_DEPS -eq 0 ];then
  chmod +x ./build-linux.sh && \
  nice ./build-linux.sh || make -j$(nproc) || exit 3
else
  make -j$(nproc)
fi

cp -f ../test "$DIR/AppDir/usr/bin/." || exit 4
cp -f ezquake-linux-$ARCH "$DIR/AppDir/usr/bin/." || exit 4
rm -f "$DIR/AppDir/AppRun"
echo "$QUAKE_SCRIPT" > "$DIR/AppDir/AppRun" || exit 4
chmod +x "$DIR/AppDir/AppRun" || exit 4
echo "$DESKTOP_ENTRY" > "$DIR/AppDir/ezquake.desktop" || exit 4
cp "$DIR/quake.png" "$DIR/AppDir/."||true #copy over quake png if it exists
mkdir -p "$DIR/AppDir/usr/share/metainfo"
sed 's,EZQUAKE_VERSION,'$VERSION-$REVISION',g;s,EZQUAKE_DATE,'$(date +%F)',g' "$DIR/ezquake.appdata.xml.template" > "$DIR/AppDir/usr/share/metainfo/ezquake.appdata.xml"
ldd "$DIR/AppDir/usr/bin/ezquake-linux-$ARCH" | \
	grep --color=never -v libGL| \
	grep --color=never -v libdrm.so| \
	awk '{print $3}'| \
	xargs -I% cp -Lf "%" "$DIR/AppDir/usr/lib/." || exit 5
strip -s "$DIR/AppDir/usr/lib/"* || exit 5
strip -s "$DIR/AppDir/usr/bin/"* || exit 5
mv -f "$DIR/AppDir/usr/lib/libc.so.6" "$DIR/AppDir/usr/lib-override/."
mv -f "$DIR/AppDir/usr/lib/libm.so.6" "$DIR/AppDir/usr/lib-override/."
cp -f "$(ldconfig -Np|grep --color=never libpthread.so.0$|grep --color=never $(uname -m)|awk '{print $NF}')" "$DIR/AppDir/usr/lib-override/."
cp -Lf "/lib64/ld-linux-${ARCHDASH}.so.2" "$DIR/AppDir/usr/lib-override/." || exit 6

cd "$DIR" || exit 5
./appimagetool AppDir ezquake-$VERSION-$REVISION-$ARCH.AppImage
