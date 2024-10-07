#!/bin/bash

set -eu

aarch64=(
	https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2
	https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img
	https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img
)

x86_64=(
	https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2
	https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
	https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
	
)

mkdir -p images && cd images

for image in ${aarch64[@]} ${x86_64[@]}; do
	if [[ ! -f $(basename $image) ]]; then
		wget "$image"
	fi
done
