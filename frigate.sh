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

# fcos version
STREAMS=stable
VERSION=41.20250315.3.0
PLATFORM=qemu
BASEURL=https://builds.coreos.fedoraproject.org

# =============================================================================================

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
			--agent enabled=1 \
			--autostart \
			--onboot 1 \
			--ostype l26

qm set ${VMID} --net0 virtio,bridge=vmbr0,tag=3
#qm set ${VMID} --net1 virtio,bridge=vmbr1

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

# A second disk for container data storage (in two steps to re-use the size variable)
qm set ${VMID} --scsi1 ${VMSTORAGE}:1${VMDISK_OPTIONS}
qm resize ${VMID} scsi1 ${VMDISK_SIZE}

# UEFI bios to allow GPU passthrough, and a disk to support uefi bios settings
# after the other disk operations to avoid interferring with disk naming assumptions
qm set ${VMID} --bios ovmf -efidisk0 ${VMSTORAGE}:0,efitype=4m,pre-enrolled-keys=1

# Set fw_cfg to provide ignition config (in qemu image specific way.) 
FW_CFG="-fw_cfg name=opt/com.coreos/config,file=${SNIPPET_STORAGE_PATH}/snippets/${IGNITION_FILE_NAME}"
qm set ${VMID} -args "${FW_CFG}"

echo "[done]"