#!/bin/bash

#set -x # debug mode
set -e

# =============================================================================================
# global vars

# force english messages
export LANG=C
export LC_ALL=C

# template vm vars
TEMPLATE_VMID="900"
TEMPLATE_VM_NAME="fcos_tmplt"
TEMPLATE_VMSTORAGE="local-thin"
TEMPLATE_VMSTORAGE_type="block"
#TEMPLATE_VMSTORAGE_type="file"
SNIPPET_STORAGE="local"
VMDISK_SIZE="100G"
VMDISK_OPTIONS=",discard=on"

TEMPLATE_IGNITION="fcos_tmplt.ign"

# fcos version
STREAMS=stable
VERSION=32.20201018.3.0
PLATFORM=qemu
BASEURL=https://builds.coreos.fedoraproject.org

# =============================================================================================
# main()

# pve storage exist ?
echo -n "Check if vm storage ${TEMPLATE_VMSTORAGE} exist... "
pvesh get /storage/${TEMPLATE_VMSTORAGE} --noborder --noheader &> /dev/null || {
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
[[ ! -e ${TEMPLATE_IGNITION} ]]&& {
    echo "${TEMPLATE_IGNITION} missing"
    exit 1
}
echo "Copy ignition config to snippet storage..."
cp -av ${TEMPLATE_IGNITION} ${SNIPPET_STORAGE_PATH}/snippets

# download fcos vdisk
[[ ! -e fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2 ]]&& {
    echo "Download fedora coreos..."
    wget -q --show-progress \
        ${BASEURL}/prod/streams/${STREAMS}/builds/${VERSION}/x86_64/fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2.xz
    xz -dv fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2.xz
}

# create a new VM
echo "Create fedora coreos vm ${VMID}"
qm create ${TEMPLATE_VMID} --name "${TEMPLATE_VM_NAME}"
qm set ${TEMPLATE_VMID} --memory 4096 \
			--cpu host \
			--cores 4 \
			--agent enabled=1 \
			--autostart \
			--onboot 1 \
			--ostype l26

#template_vmcreated=$(date +%Y-%m-%d)
#qm set ${TEMPLATE_VMID} --description "Fedora CoreOS - Geco-iT Template
#
# - Version             : ${VERSION}
# - Cloud-init          : true
#
#Creation date : ${template_vmcreated}
#"

qm set ${TEMPLATE_VMID} --net0 virtio,bridge=vmbr0
#qm set ${TEMPLATE_VMID} --net1 virtio,bridge=vmbr1

# import fedora disk
if [[ "x${TEMPLATE_VMSTORAGE_type}" = "xfile" ]]
then
	vmdisk_name="${TEMPLATE_VMID}/vm-${TEMPLATE_VMID}-disk-0.qcow2"
	vmdisk_format="--format qcow2"
else
	vmdisk_name="vm-${TEMPLATE_VMID}-disk-0"
        vmdisk_format=""
fi
qm importdisk ${TEMPLATE_VMID} fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2 ${TEMPLATE_VMSTORAGE} ${vmdisk_format}
qm set ${TEMPLATE_VMID} --scsihw virtio-scsi-pci --scsi0 ${TEMPLATE_VMSTORAGE}:${vmdisk_name}${VMDISK_OPTIONS}
qm resize ${TEMPLATE_VMID} scsi0 ${VMDISK_SIZE}

qm set ${TEMPLATE_VMID} --boot order=scsi0

# Set fw_cfg to provide ignition config (in qemu image specific way.) 
FW_CFG="-fw_cfg name=opt/com.coreos/config,file=${SNIPPET_STORAGE_PATH}/snippets/${TEMPLATE_IGNITION}"
qm set ${TEMPLATE_VMID} -args "${FW_CFG}"

# convert vm template
#echo -n "Convert VM ${TEMPLATE_VMID} in proxmox vm template... "
#qm template ${TEMPLATE_VMID} &> /dev/null || true

echo "[done]"