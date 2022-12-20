
# Check for Network Adapter
lshw -class network -short > "${TMP_PATH}/netconf"

# Check for Hypervisor
if grep -q ^flags.*\ hypervisor\  /proc/cpuinfo; then
    MACHINE="VIRTUAL"
    HYPERVISOR=$(lscpu | grep Hypervisor | awk '{print $3}')
fi

# Check for Raid/SCSI
if [ $(lspci -nn | grep -ie "\[0100\]" grep -ie "\[0104\]" -ie "\[0107\]" | wc -l) -gt 0 ]; then
  if [ "${MASHINE}" = "VIRTUAL" ]; then
    writeConfigKey "cmdline.SataPortMap" "1" "${USER_CONFIG_FILE}"
  else
    deleteConfigKey "cmdline.SataPortMap" "${USER_CONFIG_FILE}"
  fi
elif [ $(lspci -nn | grep -ie "\[0101\]" grep -ie "\[0106\]" | wc -l) -gt 0 ]; then
  deleteConfigKey "cmdline.SataPortMap" "${USER_CONFIG_FILE}"
fi