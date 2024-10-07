#!/bin/bash
scripts/get-images.sh 
scripts/install-deps.sh

export SSH_PORT=2222

function prompt(){
  read -p "Happy? ^C to stop full run, enter to continue to next target."
}

function run(){
	distro=$1
	shift
	debs=("$@")
	sudo -E scripts/launch-one.sh "$target" images/${distro}-*-${arch}.* ${debs[@]} || exit 1
	prompt
	sleep 2s  # Wait for qemu to release ports
}

### Sequencing of permutations. The defaults only test current stable

target=x86_64
arch=amd64
run debian-12 debs/stable/stable-debian-12-${target}-unknown-linux-gnu/kanidm*
run jammy debs/stable/stable-ubuntu-22.04-${target}-unknown-linux-gnu/kanidm*
run noble debs/stable/stable-ubuntu-24.04-${target}-unknown-linux-gnu/kanidm*


target=aarch64
arch=arm64
run debian-12 debs/stable/stable-debian-12-${target}-unknown-linux-gnu/kanidm*
run jammy debs/stable/stable-ubuntu-22.04-${target}-unknown-linux-gnu/kanidm*
run noble debs/stable/stable-ubuntu-24.04-${target}-unknown-linux-gnu/kanidm*
