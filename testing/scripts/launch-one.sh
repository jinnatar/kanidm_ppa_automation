#!/bin/bash

set -eu

arch="${1?}"
img="${2?}"
debglob="${2?}"

SSH_PORT="${SSH_PORT:-222}"

>&2 echo "Generating seed.img"
cloud-localds seed.img user-data.yaml

>&2 echo "Generating EFI artifacts"

case "$arch" in
	x86_64)
		MACHINE=q35,accel=kvm
		EFI=/usr/share/OVMF/OVMF_CODE.fd
		VARSTORE=""
		DRIVE="-drive if=virtio,format=qcow2,file=${img}"
		;;
	aarch64)
		MACHINE=virt,gic-version=3
		
		truncate -s 64m "${arch}_varstore.img"
		truncate -s 64m "${arch}_efi.img"
		dd if=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd of="${arch}_efi.img" conv=notrunc
		VARSTORE="-drive if=pflash,format=raw,file=${arch}_varstore.img"
		EFI="${arch}_efi.img"
		DRIVE="-drive if=none,file=${img},id=hd0 -device virtio-blk-device,drive=hd0"
		;;
	*)
		>&2 echo "Unsupported architecture"
		exit 1
		;;
esac

>&2 echo "Booting $arch $MACHINE with $EFI from $img"

"qemu-system-$arch"  \
  -machine type="${MACHINE}" -m 1024 \
  -cpu max \
  -nographic \
  -snapshot \
  -drive if=pflash,format=raw,file=${EFI},readonly=on \
  ${VARSTORE} \
  ${DRIVE} \
  -drive if=virtio,format=raw,file=seed.img \
  -netdev id=net00,type=user,hostfwd=tcp::"${SSH_PORT}"-:22 \
  -device virtio-net-pci,netdev=net00
