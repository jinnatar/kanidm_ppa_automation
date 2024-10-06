#!/bin/bash

set -eu

arch="${1?}"
img="${2?}"
debglob="${2?}"

SSH_PORT="${SSH_PORT:-222}"

cloud-localds seed.img user-data.yaml

case "$arch" in
	x86_64)
		MACHINE=q35,accel=kvm
		EFI=/usr/share/OVMF/OVMF_CODE.fd
		;;
	aarch64)
		MACHINE=virt,gic-version=3
		
		# Make a bespoke EFI img
		#truncate -s 64m "${arch}_varstore.img"
		truncate -s 64m "${arch}_efi.img"
		dd if=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd of="${arch}_efi.img" conv=notrunc
		EFI="${arch}_efi.img"
		#VARSTORE="${arch}_varstore.img"
		;;
	*)
		machine=virt
		EFI=efi.img # :shrug: .. you figure it out.
		;;
esac

>&2 echo "Booting $arch $MACHINE with $EFI from $img"

"qemu-system-$arch"  \
  -machine type="${MACHINE}" -m 1024 \
  -boot d \
  -nographic \
  -snapshot \
  -netdev id=net00,type=user,hostfwd=tcp::"${SSH_PORT}"-:22 \
  -device virtio-net-pci,netdev=net00 \
  -drive if=pflash,format=raw,file=${EFI},readonly=on \
  -drive if=virtio,format=qcow2,file="${img}" \
  -drive if=virtio,unit=2,format=raw,file=seed.img
  #-drive if=pflash,format=raw,file=${VARSTORE} \
