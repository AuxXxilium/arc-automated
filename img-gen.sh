#!/usr/bin/env bash

set -e

if [ ! -d .buildroot ]; then
  echo "Downloading buildroot"
  git clone --single-branch -b 2022.02.x https://github.com/buildroot/buildroot.git .buildroot
fi
# Remove old files
rm -rf ".buildroot/output/target/opt/arpl"
rm -rf ".buildroot/board/arpl/overlayfs"
rm -rf ".buildroot/board/arpl/p1"
rm -rf ".buildroot/board/arpl/p3"

# Get latest LKMs
echo "Getting latest LKMs"
echo "  Downloading from github"
TAG=`curl -s https://api.github.com/repos/AuxXxilium/redpill-lkm/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}'`
echo "Version: ${TAG}"
curl -L "https://github.com/AuxXxilium/redpill-lkm/releases/download/${TAG}/rp-lkms.zip" -o /tmp/rp-lkms.zip
rm -rf files/board/arpl/p3/lkms/*
unzip /tmp/rp-lkms.zip -d files/board/arpl/p3/lkms

# Get latest addons and install its
echo "Getting latest Addons"
rm -rf /tmp/addons
mkdir -p /tmp/addons
TAG=`curl -s https://api.github.com/repos/AuxXxilium/arc-addons/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}'`
echo "Version: ${TAG}"
curl -L "https://github.com/AuxXxilium/arc-addons/releases/download/${TAG}/addons.zip" -o /tmp/addons.zip
unzip /tmp/addons.zip -d /tmp/addons
rm -rf files/board/arpl/p3/addons/*
DEST_PATH="files/board/arpl/p3/addons"
echo "Installing addons to ${DEST_PATH}"
for PKG in `ls /tmp/addons/*.addon`; do
  ADDON=`basename ${PKG} | sed 's|.addon||'`
  mkdir -p "${DEST_PATH}/${ADDON}"
  echo "Extracting ${PKG} to ${DEST_PATH}/${ADDON}"
  tar xaf "${PKG}" -C "${DEST_PATH}/${ADDON}"
done

# Get latest modules
echo "Getting latest modules"
rm -rf files/board/arpl/p3/modules/*
MODULES_DIR="${PWD}/files/board/arpl/p3/modules"
TAG=`curl -s https://api.github.com/repos/AuxXxilium/arc-modules/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}'`
echo "Version: ${TAG}"
while read PLATFORM KVER; do
  FILE="${PLATFORM}-${KVER}"
  curl -L "https://github.com/AuxXxilium/arc-modules/releases/download/${TAG}/${FILE}.tgz" -o "${MODULES_DIR}/${FILE}.tgz"
done < PLATFORMS
curl -L "https://github.com/AuxXxilium/arc-modules/releases/download/${TAG}/firmware.tgz" -o "${MODULES_DIR}/firmware.tgz"

# Copy files
echo "Copying files"
VERSION=$(date +'%y.%m.%d')
rm -f files/board/arpl/p1/ARPL-VERSION
rm -f VERSION
echo "${VERSION}" > files/board/arpl/p1/ARPL-VERSION
echo "${VERSION}" > VERSION
sed 's/^ARPL_VERSION=.*/ARPL_VERSION="'${VERSION}'"/' -i files/board/arpl/overlayfs/opt/arpl/include/consts.sh
cp -rf files/* .buildroot/

cd .buildroot
echo "Generating default config"
make BR2_EXTERNAL=../external -j`nproc` arpl_defconfig
echo "Version: ${VERSION}"
echo "Building... Drink a coffee and wait!"
make BR2_EXTERNAL=../external -j`nproc`
cd -
rm -f arc.img
cp -f arpl.img arc.img
qemu-img convert -O vmdk arc.img arc-dyn.vmdk
qemu-img convert -O vmdk -o adapter_type=lsilogic arc.img -o subformat=monolithicFlat arc.vmdk
[ -x test.sh ] && ./test.sh
rm -f *.zip
zip -9 "arc.img.zip" arc.img
zip -9 "arc.vmdk-dyn.zip" arc-dyn.vmdk
zip -9 "arc.vmdk-flat.zip" arc.vmdk arc-flat.vmdk
sha256sum update-list.yml > sha256sum
zip -9j update.zip update-list.yml
while read F; do
  if [ -d "${F}" ]; then
    FTGZ="`basename "${F}"`.tgz"
    tar czf "${FTGZ}" -C "${F}" .
    sha256sum "${FTGZ}" >> sha256sum
    zip -9j update.zip "${FTGZ}"
    rm "${FTGZ}"
  else
    (cd `dirname ${F}` && sha256sum `basename ${F}`) >> sha256sum
    zip -9j update.zip "${F}"
  fi
done < <(yq '.replace | explode(.) | to_entries | map([.key])[] | .[]' update-list.yml)
zip -9j update.zip sha256sum 
rm -f sha256sum
