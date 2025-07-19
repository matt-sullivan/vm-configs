#!/bin/bash

#set -x # debug mode
set -e

# =============================================================================================
# global vars

# force english messages
export LANG=C
export LC_ALL=C

# template vm vars
VMID="104"
VM_NAME="frigate"
VMSTORAGE="local-thin"
VMSTORAGE_TYPE="block"
#VMSTORAGE_TYPE="file"
SNIPPET_STORAGE="local"
VMDISK_SIZE="100G"
VMDISK_OPTIONS=",discard=on"

IGNITION_FILE_NAME="frigate.ign"

# Move the important disk data aside and restore it later if re-creating the VM
CONTAINER_DATA_DISK="vm-${VMID}-disk-1"
CONTAINER_DATA_BACKUP="vm-${VMID}-disk-1-preserved"

NODE=$(hostname)

# fcos version
STREAMS=stable
VERSION=41.20250315.3.0
PLATFORM=qemu
BASEURL=https://builds.coreos.fedoraproject.org

# =============================================================================================

FORCE=false
VM_EXISTS=false

# Check for -f flag
if [[ "$1" == "-f" ]]; then
  FORCE=true
fi

# Abort if VM exists and not forced
if pvesh get /nodes/${NODE}/qemu/${VMID} &>/dev/null; then
  VM_EXISTS=true
fi
if $VM_EXISTS && ! $FORCE; then
  echo "Error: VM with ID ${VMID} already exists. Use -f to override."
  exit 1
fi

if $VM_EXISTS; then
  echo "VM already exists, deleting"
  qm stop $VMID
  lvrename pve ${CONTAINER_DATA_DISK} ${CONTAINER_DATA_BACKUP}
  qm destroy $VMID
  lvrename pve ${CONTAINER_DATA_BACKUP} ${CONTAINER_DATA_DISK}
fi

# pve storage exist ?
echo -n "Check if vm storage ${VMSTORAGE} exist... "
pvesh get /storage/${VMSTORAGE} --noborder --noheader &> /dev/null || {
        echo -e "[failed]"
        exit 1
}
echo "[ok]"

# pve storage snippet ok ?
echo -n "Check if snippet storage ${SNIPPET_STORAGE} exist... "
pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader &> /dev/null || {
        echo -e "[failed]"
        exit 1
}
echo "[ok]"

# pve storage snippet enable
pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader | grep -q snippets || {
	echo "You musr activate content snippet on storage: ${SNIPPET_STORAGE}"
	exit 1
}
SNIPPET_STORAGE_PATH="$(pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader | grep ^path | awk '{print $NF}')"

# copy files
[[ ! -e ${IGNITION_FILE_NAME} ]]&& {
    echo "${IGNITION_FILE_NAME} missing"
    exit 1
}
echo "Copy ignition config to snippet storage..."
cp -av ${IGNITION_FILE_NAME} ${SNIPPET_STORAGE_PATH}/snippets

# download fcos vdisk
[[ ! -e fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2 ]]&& {
    echo "Download fedora coreos..."
    wget -q --show-progress \
        ${BASEURL}/prod/streams/${STREAMS}/builds/${VERSION}/x86_64/fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2.xz
    xz -dv fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2.xz
}

# create a new VM
echo "Create fedora coreos vm ${VMID}"
qm create ${VMID} --name "${VM_NAME}"
qm set ${VMID} --memory 8192 \
			--cpu host \
			--cores 8 \
			--machine q35 \
			--agent enabled=1 \
			--autostart \
			--onboot 1 \
			--ostype l26

qm set ${VMID} --net0 virtio,bridge=vmbr0,tag=3
# A second network for connecting to cameras. ATM it's on the IoT VLAN, but will probably move it later.
qm set ${VMID} --net1 virtio,bridge=vmbr0,tag=3

# add a serial console in case of emergency console and avoid the default serial-getty service failing
qm set ${VMID} -serial0 socket

# import fedora disk
if [[ "x${VMSTORAGE_TYPE}" = "xfile" ]]
then
	vmdisk_name="${VMID}/vm-${VMID}-disk-0.qcow2"
	vmdisk_format="--format qcow2"
else
	vmdisk_name="vm-${VMID}-disk-0"
	vmdisk_format=""
fi
qm importdisk ${VMID} fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2 ${VMSTORAGE} ${vmdisk_format}
qm set ${VMID} --scsihw virtio-scsi-pci --scsi0 ${VMSTORAGE}:${vmdisk_name}${VMDISK_OPTIONS}
qm resize ${VMID} scsi0 ${VMDISK_SIZE}
qm set ${VMID} --boot order=scsi0

# A second disk for container data storage (in two steps to re-use the size variable that has 'G' in it)
if lvs --noheadings -o lv_name | grep -q -w "${CONTAINER_DATA_DISK}"; then
  qm set ${VMID} --scsi1 ${VMSTORAGE}:${CONTAINER_DATA_DISK}${VMDISK_OPTIONS}
else
  qm set ${VMID} --scsi1 ${VMSTORAGE}:1${VMDISK_OPTIONS}
fi
qm resize ${VMID} scsi1 ${VMDISK_SIZE}

# UEFI bios to allow GPU passthrough, and a disk to support uefi bios settings
# after the other disk operations to avoid interferring with disk naming assumptions
qm set ${VMID} --bios ovmf -efidisk0 ${VMSTORAGE}:0,efitype=4m,pre-enrolled-keys=1

# Set fw_cfg to provide ignition config (in qemu image specific way.) 
FW_CFG="-fw_cfg name=opt/com.coreos/config,file=${SNIPPET_STORAGE_PATH}/snippets/${IGNITION_FILE_NAME}"
qm set ${VMID} -args "${FW_CFG}"

# Pass through nvidia GPU (and audio device)
qm set ${VMID} --hostpci0 0000:0f:00.0,pcie=1,rombar=0
qm set ${VMID} --hostpci1 0000:0f:00.1,pcie=1

echo "[done]"