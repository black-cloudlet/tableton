#!/bin/bash
VM_NAME="windows-vm"
DISK_PATH="/var/lib/libvirt/images/windows10.qcow2"

# 1. Wait for Libvirt to be active
if ! systemctl is-active --quiet libvirtd; then
    echo "Libvirt is not ready. Exiting."
    exit 1
fi

# 2. Check if VM is already defined to prevent re-running
if virsh list --all --name | grep -q "^${VM_NAME}$"; then
    echo "VM '${VM_NAME}' already exists. Skipping import."
    exit 0
fi

# 3. Ensure the Default Network is active (NAT)
virsh net-start default || true
virsh net-autostart default || true

# 4. Import the VM (Generates XML and registers the VM)
echo "Importing Windows VM..."
virt-install \
  --name "${VM_NAME}" \
  --memory 4096 \
  --vcpus 2 \
  --disk path="${DISK_PATH}",bus=sata,cache=none \
  --os-variant win10 \
  --network network=default,model=e1000e \
  --graphics vnc,listen=0.0.0.0 \
  --import \
  --noautoconsole \
  --autostart

echo "Windows VM imported and started successfully."
