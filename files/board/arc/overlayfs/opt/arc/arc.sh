#!/usr/bin/env bash

. /opt/arc/include/functions.sh
. /opt/arc/include/addons.sh
. /opt/arc/include/modules.sh
. /opt/arc/include/consts.sh
. /opt/arc/include/hardware.sh

# Check partition 3 space, if < 2GiB is necessary clean cache folder
CLEARCACHE=0
LOADER_DISK="`blkid | grep 'LABEL="ARC3"' | cut -d3 -f1`"
LOADER_DEVICE_NAME=`echo ${LOADER_DISK} | sed 's|/dev/||'`
if [ `cat /sys/block/${LOADER_DEVICE_NAME}/${LOADER_DEVICE_NAME}3/size` -lt 4194304 ]; then
  CLEARCACHE=1
fi

# Get actual IP
IP=`ip route get 1.1.1.1 2>/dev/null | awk '{print$7}'`

# Dirty flag
DIRTY=0

MODEL="`readConfigKey "model" "${USER_CONFIG_FILE}"`"
BUILD="`readConfigKey "build" "${USER_CONFIG_FILE}"`"
LAYOUT="`readConfigKey "layout" "${USER_CONFIG_FILE}"`"
KEYMAP="`readConfigKey "keymap" "${USER_CONFIG_FILE}"`"
LKM="`readConfigKey "lkm" "${USER_CONFIG_FILE}"`"
DIRECTBOOT="`readConfigKey "directboot" "${USER_CONFIG_FILE}"`"
SN="`readConfigKey "sn" "${USER_CONFIG_FILE}"`"

###############################################################################
# Mounts backtitle dynamically
function backtitle() {
  BACKTITLE="Arc Automated v${ARC_VERSION} |"
  if [ -n "${MODEL}" ]; then
    BACKTITLE+=" ${MODEL}"
  else
    BACKTITLE+=" (no model)"
  fi
    BACKTITLE+=" |"
  if [ -n "${BUILD}" ]; then
    BACKTITLE+=" ${BUILD}"
  else
    BACKTITLE+=" (no build)"
  fi
    BACKTITLE+=" |"
  if [ -n "${SN}" ]; then
    BACKTITLE+=" ${SN}"
  else
    BACKTITLE+=" (no SN)"
  fi
    BACKTITLE+=" |"
  if [ -n "${IP}" ]; then
    BACKTITLE+=" ${IP}"
  else
    BACKTITLE+=" (no IP)"
  fi
    BACKTITLE+=" |"
    BACKTITLE+=" ${MACHINE}"
  echo ${BACKTITLE}
}

###############################################################################
# Check for Updates
function automatedupdate() {
dialog --backtitle "`backtitle`" --title "Update Arc" --aspect 18 \
  --infobox "Checking last version" 0 0
ACTUALVERSION="v${ARC_VERSION}"
TAG="`curl --insecure -s https://api.github.com/repos/AuxXxilium/arc-automated/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}'`"
if [ $? -ne 0 -o -z "${TAG}" ]; then
    dialog --backtitle "`backtitle`" --title "Update Arc" --aspect 18 \
      --msgbox "Error checking new version" 0 0
    continue
fi
if [ "$TAG" != "$ACTUALVERSION" ]; then
dialog --backtitle "`backtitle`" --title "Update Arc" --aspect 18 \
  --infobox "Downloading last version ${TAG}" 0 0
# Download update file
STATUS=`curl --insecure -w "%{http_code}" -L \
  "https://github.com/AuxXxilium/arc-automated/releases/download/${TAG}/update.zip" -o /tmp/update.zip`
  if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
      dialog --backtitle "`backtitle`" --title "Update Arc" --aspect 18 \
        --msgbox "Error downloading update file" 0 0
      continue
  fi
  unzip -oq /tmp/update.zip -d /tmp
  if [ $? -ne 0 ]; then
      dialog --backtitle "`backtitle`" --title "Update Arc" --aspect 18 \
        --msgbox "Error extracting update file" 0 0
      continue
  fi
  # Check checksums
  (cd /tmp && sha256sum --status -c sha256sum)
  if [ $? -ne 0 ]; then
      dialog --backtitle "`backtitle`" --title "Update Arc" --aspect 18 \
        --msgbox "Checksum do not match!" 0 0
      continue
  fi
  dialog --backtitle "`backtitle`" --title "Update Arc" --aspect 18 \
      --infobox "Installing new files" 0 0
  # Process update-list.yml
    while IFS="=" read KEY VALUE; do
    mv /tmp/`basename "${KEY}"` "${VALUE}"
    done < <(readConfigMap "replace" "/tmp/update-list.yml")
    while read F; do
      [ -f "${F}" ] && rm -f "${F}"
      [ -d "${F}" ] && rm -Rf "${F}"
    done < <(readConfigArray "remove" "/tmp/update-list.yml")
  arc-reboot.sh config
fi
}

###############################################################################
# Automated ARC Build
function automatedbuild() {
  DIRTY=1
  # Write config
  writeConfigKey "build" "42962" "${USER_CONFIG_FILE}"
  writeConfigKey "model" "DS3622xs+" "${USER_CONFIG_FILE}"
  MODEL="`readConfigKey "model" "${USER_CONFIG_FILE}"`"
  SN="`readModelKey "${MODEL}" "arcserial"`"
  writeConfigKey "sn" "${SN}" "${USER_CONFIG_FILE}"
  # Write Addons and Modules to Config
  PLATFORM="`readModelKey "${MODEL}" "platform"`"
  BUILD="`readConfigKey "build" "${USER_CONFIG_FILE}"`"
  KVER="`readModelKey "${MODEL}" "builds.${BUILD}.kver"`"
  # Delete synoinfo and reload model/build synoinfo  
  writeConfigKey "synoinfo" "{}" "${USER_CONFIG_FILE}"
  while IFS="=" read KEY VALUE; do
    writeConfigKey "synoinfo.${KEY}" "${VALUE}" "${USER_CONFIG_FILE}"
  done < <(readModelMap "${MODEL}" "builds.${BUILD}.synoinfo")
  # Check addons
  while IFS="=" read ADDON PARAM; do
    [ -z "${ADDON}" ] && continue
    if ! checkAddonExist "${ADDON}" "${PLATFORM}" "${KVER}"; then
      deleteConfigKey "addons.${ADDON}" "${USER_CONFIG_FILE}"
    fi
  done < <(readConfigMap "addons" "${USER_CONFIG_FILE}")
    # Rebuild modules
  writeConfigKey "modules" "{}" "${USER_CONFIG_FILE}"
  while read ID DESC; do
    writeConfigKey "modules.${ID}" "" "${USER_CONFIG_FILE}"
  done < <(getAllModules "${PLATFORM}" "${KVER}")
  # Remove old files
  rm -f "${ORI_ZIMAGE_FILE}" "${ORI_RDGZ_FILE}" "${MOD_ZIMAGE_FILE}" "${MOD_RDGZ_FILE}"
  DIRTY=1
  dialog --backtitle "`backtitle`" --title "ARC Automated Config" \
    --infobox "Model Configuration successfull!" 0 0  
}

###############################################################################
# Make Disk Config
function arcdisk() {
  # Check for diskconfig
  if [ "$DT" = "true" ] && [ "$ADRAID" -gt 0 ]; then
    # There is no Raid/SCSI Support for DT Models
    dialog --backtitle "`backtitle`" --title "Arc Disk Config" \
      --infobox "Device Tree Model selected - Raid/SCSI Controller not supported!" 0 0
    sleep 5
    return 1
  else
    dialog --backtitle "`backtitle`" --title "Arc Disk Config" \
      --infobox "ARC Disk configuration started!" 0 0
    deleteConfigKey "cmdline.SataPortMap" "${USER_CONFIG_FILE}"
    deleteConfigKey "cmdline.DiskIdxMap" "${USER_CONFIG_FILE}"
    sleep 3
    # Get Number of Sata Drives
    if [ "$ADSATA" -gt 0 ]; then
      pcis=$(lspci -nnk | grep -ie "\[0106\]" | awk '{print $1}')
      [ ! -z "$pcis" ]
      # loop through non-SATA controllers
      for pci in $pcis; do
      # get attached block devices (exclude CD-ROMs)
      SATADRIVES=$(ls -la /sys/block | fgrep "$pci" | grep -v "sr.$" | wc -l)
      done
    fi
    # Get Number of Raid/SCSI Drives
    if [ "$ADRAID" -gt 0 ]; then
      pcis=$(lspci -nnk | grep -ie "\[0104\]" -ie "\[0107\]" | awk '{print $1}')
      [ ! -z "$pcis" ]
      # loop through non-SATA controllers
      for pci in $pcis; do
      # get attached block devices (exclude CD-ROMs)
      RAIDDRIVES=$(ls -la /sys/block | fgrep "$pci" | grep -v "sr.$" | wc -l)
      done
    fi
    # Maximum Number of Drives per Controller is 8 > So we have to limit it to 8
    if [ "$SATADRIVES" -gt 8 ]; then
    SATADRIVES=8
    fi
    if [ "$RAIDDRIVES" -gt 8 ]; then
    RAIDDRIVES=8
    fi
    # Set SataPortMap for Native and VMWare ESXi
    if [ "$ADSATA" -eq 1 ]; then
    writeConfigKey "cmdline.SataPortMap" "$SATADRIVES" "${USER_CONFIG_FILE}"
    fi
    if [ "$ADSATA" -eq 2 ]; then
    writeConfigKey "cmdline.SataPortMap" "$SATADRIVES$SATADRIVES" "${USER_CONFIG_FILE}"
    fi
    if [ "$ADSATA" -eq 1 ] && [ "$ADRAID" -eq 1 ]; then
    writeConfigKey "cmdline.SataPortMap" "$SATADRIVES" "${USER_CONFIG_FILE}"
    fi
    # Set SataPortMap for Proxmox/Unraid (only 1 Drive per Sata Controller)
    if [ "${MACHINE}" -eq "VIRTUAL" ]; then
      if [ "$ADSATA" -eq 3 ]; then
      writeConfigKey "cmdline.SataPortMap" "111" "${USER_CONFIG_FILE}"
      fi
      if [ "$ADSATA" -eq 4 ]; then
      writeConfigKey "cmdline.SataPortMap" "1111" "${USER_CONFIG_FILE}"
      fi
      if [ "$ADSATA" -eq 5 ]; then
      writeConfigKey "cmdline.SataPortMap" "11111" "${USER_CONFIG_FILE}"
      fi
      if [ "$ADSATA" -eq 6 ]; then
      writeConfigKey "cmdline.SataPortMap" "111111" "${USER_CONFIG_FILE}"
      fi
      if [ "$ADSATA" -eq 7 ]; then
      writeConfigKey "cmdline.SataPortMap" "1111111" "${USER_CONFIG_FILE}"
      fi
      if [ "$ADSATA" -eq 8 ]; then
      writeConfigKey "cmdline.SataPortMap" "11111111" "${USER_CONFIG_FILE}"
      fi
    fi
  dialog --backtitle "`backtitle`" --title "Arc Disk Config" \
    --infobox "Disk configuration successfull!\n\nSata: $SATADRIVES Drives\nRaid/SCSI: $RAIDDRIVES Drives\n" 0 0
  sleep 3
  fi
}

###############################################################################
# Make Network Config
function arcnet() {
  # Export Network Adapter Amount - DSM 
  NETNUM=$(lshw -class network -short | grep -ie "eth" | wc -l)
  # Hardlimit to 4 Mac because of Redpill doesn't more at this time
  if [ "$NETNUM" -gt 4 ]; then
  NETNUM="4"
  fi
  writeConfigKey "cmdline.netif_num" "${NETNUM}"            "${USER_CONFIG_FILE}"
  # Delete old Mac Address from Userconfig
  #deleteConfigKey "cmdline.mac1" "${USER_CONFIG_FILE}"
  deleteConfigKey "cmdline.mac2" "${USER_CONFIG_FILE}"
  deleteConfigKey "cmdline.mac3" "${USER_CONFIG_FILE}"
  deleteConfigKey "cmdline.mac4" "${USER_CONFIG_FILE}"
    # Install with Arc Patch - Check for model config and set custom Mac Address
    MODEL="`readConfigKey "model" "${USER_CONFIG_FILE}"`"
    if [ "$NETNUM" -gt 0 ]; then
      MAC1="`readModelKey "${MODEL}" "mac1"`"
      writeConfigKey "cmdline.mac1"           "$MAC1" "${USER_CONFIG_FILE}"
      MACN1="${MAC1:0:2}:${MAC1:2:2}:${MAC1:4:2}:${MAC1:6:2}:${MAC1:8:2}:${MAC1:10:2}"
      ip link set dev eth0 address ${MACN1} 2>&1
    fi
    if [ "$NETNUM" -gt 1 ]; then
      MAC2="`readModelKey "${MODEL}" "mac2"`"
      writeConfigKey "cmdline.mac2"           "$MAC2" "${USER_CONFIG_FILE}"
      MACN2="${MAC2:0:2}:${MAC2:2:2}:${MAC2:4:2}:${MAC2:6:2}:${MAC2:8:2}:${MAC2:10:2}"
      ip link set dev eth1 address ${MACN2} 2>&1
    fi
    if [ "$NETNUM" -gt 2 ]; then
      MAC3="`readModelKey "${MODEL}" "mac3"`"
      writeConfigKey "cmdline.mac3"           "$MAC3" "${USER_CONFIG_FILE}"
      MACN3="${MAC3:0:2}:${MAC3:2:2}:${MAC3:4:2}:${MAC3:6:2}:${MAC3:8:2}:${MAC3:10:2}"
      ip link set dev eth2 address ${MACN3} 2>&1
    fi
    if [ "$NETNUM" -gt 3 ]; then
      MAC4="`readModelKey "${MODEL}" "mac4"`"
      writeConfigKey "cmdline.mac4"           "$MAC4" "${USER_CONFIG_FILE}"
      MACN4="${MAC4:0:2}:${MAC4:2:2}:${MAC4:4:2}:${MAC4:6:2}:${MAC4:8:2}:${MAC4:10:2}"
      ip link set dev eth3 address ${MACN4} 2>&1
    fi
    dialog --backtitle "`backtitle`" \
            --title "Loading Arc MAC Table" --infobox "Set new MAC for ${NETNUM} Adapter" 0 0
    sleep 3
  /etc/init.d/S41dhcpcd restart 2>&1 | dialog --backtitle "`backtitle`" \
    --title "Restart DHCP" --progressbox "Renewing IP" 20 70
  sleep 5
  IP=`ip route get 1.1.1.1 2>/dev/null | awk '{print$7}'`
  dialog --backtitle "`backtitle`" --title "Arc Config" \
      --infobox "Network configuration successfull!" 0 0
  sleep 3
  writeConfigKey "confdone" "1" "${USER_CONFIG_FILE}"
  dialog --backtitle "`backtitle`" --title "Arc Config" \
      --infobox "ARC configuration successfull!" 0 0
  sleep 3
  CONFDONE="`readConfigKey "confdone" "${USER_CONFIG_FILE}"`"
  dialog --clear --no-items --backtitle "`backtitle`"
}

###
###############################################################################
# Building Loader
function make() {
  clear
  # Read modelconfig for build
  MODEL="`readConfigKey "model" "${USER_CONFIG_FILE}"`"
  BUILD="`readConfigKey "build" "${USER_CONFIG_FILE}"`"
  PLATFORM="`readModelKey "${MODEL}" "platform"`"
  KVER="`readModelKey "${MODEL}" "builds.${BUILD}.kver"`"

  # Check if all addon exists
  while IFS="=" read ADDON PARAM; do
    [ -z "${ADDON}" ] && continue
    if ! checkAddonExist "${ADDON}" "${PLATFORM}" "${KVER}"; then
      dialog --backtitle "`backtitle`" --title "Error" --aspect 18 \
        --msgbox "Addon ${ADDON} not found!" 0 0
      return 1
    fi
  done < <(readConfigMap "addons" "${USER_CONFIG_FILE}")

  [ ! -f "${ORI_ZIMAGE_FILE}" -o ! -f "${ORI_RDGZ_FILE}" ] && extractDsmFiles

  /opt/arc/zimage-patch.sh
  if [ $? -ne 0 ]; then
    dialog --backtitle "`backtitle`" --title "Error" --aspect 18 \
      --msgbox "zImage not patched:\n`<"${LOG_FILE}"`" 0 0
    return 1
  fi

  /opt/arc/ramdisk-patch.sh
  if [ $? -ne 0 ]; then
    dialog --backtitle "`backtitle`" --title "Error" --aspect 18 \
      --msgbox "Ramdisk not patched:\n`<"${LOG_FILE}"`" 0 0
    return 1
  fi

  echo "Cleaning"
  rm -rf "${UNTAR_PAT_PATH}"

  echo "Ready!"
  dialog --backtitle "`backtitle`" --title "Arc Build" \
    --infobox "Arc Build successfull! Arc will boot now." 0 0
  sleep 3
  DIRTY=0
  return 0
}

###############################################################################
# Extracting DSM for building Loader
function extractDsmFiles() {
  PAT_URL="`readModelKey "${MODEL}" "builds.${BUILD}.pat.url"`"
  PAT_HASH="`readModelKey "${MODEL}" "builds.${BUILD}.pat.hash"`"
  RAMDISK_HASH="`readModelKey "${MODEL}" "builds.${BUILD}.pat.ramdisk-hash"`"
  ZIMAGE_HASH="`readModelKey "${MODEL}" "builds.${BUILD}.pat.zimage-hash"`"

  # If we have little disk space, clean cache folder
  if [ ${CLEARCACHE} -eq 1 ]; then
    echo "Cleaning cache"
    rm -rf "${CACHE_PATH}/dl"
  fi
  mkdir -p "${CACHE_PATH}/dl"

  SPACELEFT=`df --block-size=1 | awk '/'${LOADER_DEVICE_NAME}'3/{print$4}'`  # Check disk space left

  PAT_FILE="${MODEL}-${BUILD}.pat"
  PAT_PATH="${CACHE_PATH}/dl/${PAT_FILE}"
  EXTRACTOR_PATH="${CACHE_PATH}/extractor"
  EXTRACTOR_BIN="syno_extract_system_patch"
  OLDPAT_URL="https://global.download.synology.com/download/DSM/release/7.0.1/42218/DSM_DS3622xs%2B_42218.pat"

  if [ -f "${PAT_PATH}" ]; then
    echo "${PAT_FILE} cached."
  else
    echo "Downloading ${PAT_FILE}"
    # Discover remote file size
    FILESIZE=`curl --insecure -sLI "${PAT_URL}" | grep -i Content-Length | awk '{print$2}'`
    if [ 0${FILESIZE} -ge ${SPACELEFT} ]; then
      # No disk space to download, change it to RAMDISK
      PAT_PATH="${TMP_PATH}/${PAT_FILE}"
    fi
    STATUS=`curl --insecure -w "%{http_code}" -L "${PAT_URL}" -o "${PAT_PATH}" --progress-bar`
    if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
      rm "${PAT_PATH}"
      dialog --backtitle "`backtitle`" --title "Error downloading" --aspect 18 \
        --msgbox "Check internet or cache disk space" 0 0
      return 1
    fi
  fi

  echo -n "Checking hash of ${PAT_FILE}: "
  if [ "`sha256sum ${PAT_PATH} | awk '{print$1}'`" != "${PAT_HASH}" ]; then
    dialog --backtitle "`backtitle`" --title "Error" --aspect 18 \
      --msgbox "Hash of pat not match, try again!" 0 0
    rm -f ${PAT_PATH}
    return 1
  fi
  echo "OK"

  rm -rf "${UNTAR_PAT_PATH}"
  mkdir "${UNTAR_PAT_PATH}"
  echo -n "Disassembling ${PAT_FILE}: "

  header="$(od -bcN2 ${PAT_PATH} | head -1 | awk '{print $3}')"
  case ${header} in
    105)
      echo "Uncompressed tar"
      isencrypted="no"
      ;;
    213)
      echo "Compressed tar"
      isencrypted="no"
      ;;
    255)
      echo "Encrypted"
      isencrypted="yes"
      ;;
    *)
      dialog --backtitle "`backtitle`" --title "Error" --aspect 18 \
        --msgbox "Could not determine if pat file is encrypted or not, maybe corrupted, try again!" \
        0 0
      return 1
      ;;
  esac

  SPACELEFT=`df --block-size=1 | awk '/'${LOADER_DEVICE_NAME}'3/{print$4}'`  # Check disk space left

  if [ "${isencrypted}" = "yes" ]; then
    # Check existance of extractor
    if [ -f "${EXTRACTOR_PATH}/${EXTRACTOR_BIN}" ]; then
      echo "Extractor cached."
    else
      # Extractor not exists, get it.
      mkdir -p "${EXTRACTOR_PATH}"
      # Check if old pat already downloaded
      OLDPAT_PATH="${CACHE_PATH}/dl/DS3622xs+-42218.pat"
      if [ ! -f "${OLDPAT_PATH}" ]; then
        echo "Downloading old pat to extract synology .pat extractor..."
        # Discover remote file size
        FILESIZE=`curl --insecure -sLI "${OLDPAT_URL}" | grep -i Content-Length | awk '{print$2}'`
        if [ 0${FILESIZE} -ge ${SPACELEFT} ]; then
          # No disk space to download, change it to RAMDISK
          OLDPAT_PATH="${TMP_PATH}/DS3622xs+-42218.pat"
        fi
        STATUS=`curl --insecure -w "%{http_code}" -L "${OLDPAT_URL}" -o "${OLDPAT_PATH}"  --progress-bar`
        if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
          rm "${OLDPAT_PATH}"
          dialog --backtitle "`backtitle`" --title "Error downloading" --aspect 18 \
            --msgbox "Check internet or cache disk space" 0 0
          return 1
        fi
      fi
      # Extract DSM ramdisk file from PAT
      rm -rf "${RAMDISK_PATH}"
      mkdir -p "${RAMDISK_PATH}"
      tar -xf "${OLDPAT_PATH}" -C "${RAMDISK_PATH}" rd.gz >"${LOG_FILE}" 2>&1
      if [ $? -ne 0 ]; then
        rm -f "${OLDPAT_PATH}"
        rm -rf "${RAMDISK_PATH}"
        dialog --backtitle "`backtitle`" --title "Error extracting" --textbox "${LOG_FILE}" 0 0
        return 1
      fi
      [ ${CLEARCACHE} -eq 1 ] && rm -f "${OLDPAT_PATH}"
      # Extract all files from rd.gz
      (cd "${RAMDISK_PATH}"; xz -dc < rd.gz | cpio -idm) >/dev/null 2>&1 || true
      # Copy only necessary files
      for f in libcurl.so.4 libmbedcrypto.so.5 libmbedtls.so.13 libmbedx509.so.1 libmsgpackc.so.2 libsodium.so libsynocodesign-ng-virtual-junior-wins.so.7; do
        cp "${RAMDISK_PATH}/usr/lib/${f}" "${EXTRACTOR_PATH}"
      done
      cp "${RAMDISK_PATH}/usr/syno/bin/scemd" "${EXTRACTOR_PATH}/${EXTRACTOR_BIN}"
      rm -rf "${RAMDISK_PATH}"
    fi
    # Uses the extractor to untar pat file
    echo "Extracting..."
    LD_LIBRARY_PATH=${EXTRACTOR_PATH} "${EXTRACTOR_PATH}/${EXTRACTOR_BIN}" "${PAT_PATH}" "${UNTAR_PAT_PATH}" || true
  else
    echo "Extracting..."
    tar -xf "${PAT_PATH}" -C "${UNTAR_PAT_PATH}" >"${LOG_FILE}" 2>&1
    if [ $? -ne 0 ]; then
      dialog --backtitle "`backtitle`" --title "Error extracting" --textbox "${LOG_FILE}" 0 0
    fi
  fi

  echo -n "Checking hash of zImage: "
  HASH="`sha256sum ${UNTAR_PAT_PATH}/zImage | awk '{print$1}'`"
  if [ "${HASH}" != "${ZIMAGE_HASH}" ]; then
    sleep 1
    dialog --backtitle "`backtitle`" --title "Error" --aspect 18 \
      --msgbox "Hash of zImage not match, try again!" 0 0
    return 1
  fi
  echo "OK"
  writeConfigKey "zimage-hash" "${ZIMAGE_HASH}" "${USER_CONFIG_FILE}"

  echo -n "Checking hash of ramdisk: "
  HASH="`sha256sum ${UNTAR_PAT_PATH}/rd.gz | awk '{print$1}'`"
  if [ "${HASH}" != "${RAMDISK_HASH}" ]; then
    sleep 1
    dialog --backtitle "`backtitle`" --title "Error" --aspect 18 \
      --msgbox "Hash of ramdisk not match, try again!" 0 0
    return 1
  fi
  echo "OK"
  writeConfigKey "ramdisk-hash" "${RAMDISK_HASH}" "${USER_CONFIG_FILE}"

  echo -n "Copying files: "
  cp "${UNTAR_PAT_PATH}/grub_cksum.syno" "${BOOTLOADER_PATH}"
  cp "${UNTAR_PAT_PATH}/GRUB_VER"        "${BOOTLOADER_PATH}"
  cp "${UNTAR_PAT_PATH}/grub_cksum.syno" "${SLPART_PATH}"
  cp "${UNTAR_PAT_PATH}/GRUB_VER"        "${SLPART_PATH}"
  cp "${UNTAR_PAT_PATH}/zImage"          "${ORI_ZIMAGE_FILE}"
  cp "${UNTAR_PAT_PATH}/rd.gz"           "${ORI_RDGZ_FILE}"
  rm -rf "${UNTAR_PAT_PATH}"
  echo "DSM extract complete" 
}

###############################################################################
# Calls boot.sh to boot into DSM kernel/ramdisk
function boot() {
  [ ${DIRTY} -eq 1 ] && dialog --backtitle "`backtitle`" --title "Alert" \
    --yesno "Config changed, would you like to rebuild the loader?" 0 0
  if [ $? -eq 0 ]; then
    make || return
  fi
  dialog --backtitle "`backtitle`" --title "ARC Boot" \
    --infobox "Booting to DSM - Please stay patient!" 0 0
  boot.sh
}

###############################################################################
###############################################################################

if [ "x$1" = "xb" -a -n "${MODEL}" -a -n "${BUILD}" -a loaderIsConfigured ]; then
  make
  boot
fi
automatedupdate
automatedbuild
arcdisk
arcnet
make
exec reboot