#!/bin/bash
#
# Parallels Tools for Linux. Binfmt Miscelanious configurator.
#
# Copyright (c) 1999-2023 Parallels International GmbH.
# All rights reserved.
# http://www.parallels.com

SYSTEMDDIR="/etc/binfmt.d"
DEBIANDIR="/usr/share/binfmts"
X86_X64_MAGIC="\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00"
X86_X64_MASK="\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff"

check_binfmt_support() {
	dpkg --status binfmt-support > /dev/null 2>&1
}

check_binfmt_systemd() {
	systemctl -q is-enabled systemd-binfmt.service 
}

# $1 -- Emulator name
# $2 -- Emulator path
register_binfmt_systemd() {
	echo ":$1:M::$X86_X64_MAGIC:$X86_X64_MASK:$2:OCF" > "$SYSTEMDDIR/$1.conf"
	systemctl --system restart systemd-binfmt.service
}

# $1 -- Emulator name
# $2 -- Emulator path
register_binfmt_support() {
	cat > "$DEBIANDIR/$1" <<EOF
package $1
interpreter $2 
magic $X86_X64_MAGIC
mask $X86_X64_MASK
credentials yes
preserve no
fix_binary yes
EOF
	update-binfmts "--import" "$1"
}

# $1 -- Emulator name
unregister_binfmt_systemd() {
	rm -f "$SYSTEMDDIR/$1.conf"
	systemctl "--system" "try-restart" "systemd-binfmt.service"
}

# $1 -- Emulator name
unregister_binfmt_support() {
	update-binfmts "--unimport" "$1"
	rm -f "$DEBIANDIR/$1"
}

setup_binfmt() {
	local action=$1
	local name=$2
	local path=$3
	local impl

	# Chose tool to set up binfmt_misc
	if [ -f "/etc/debian_version" ]; then
		# Use binfmt_support package for Debian
		impl=binfmt_support
	elif [ -d "/run/systemd/system" ]; then
		# Use systemd.binfmt.d if systemd avalable
		impl=binfmt_systemd
	else
		echo "Error: Setting up binfmt is not supported!" 1>&2
		return 1
	fi

	echo "Setting up binfmt via '$impl', action: '$action'..."

	if [ -z "$name" ]; then
		echo "Error: Emulator name argument is empty" 1>&2
		return 2
	fi

	# Do registering/unregistering binfmt
	if [ "$action" = "register" ]; then
		karch=$(uname -m)
		if [ ! "$karch" = 'aarch64' ]; then
			# The custom binfmt handler must never be set for 
			# native binaries (it might crash the system)
			echo "Platform $karch is not supported"
			return 3
		fi

		if [ -z "$path" ]; then
			echo "Error: Emulator path argument is empty" 1>&2
			return 4
		fi

		check_$impl

		if [ $? -eq 0 ]; then
			register_$impl "$name" "$path" 
		fi

	elif [ "$action" = "unregister" ]; then
		unregister_$impl "$name"

	else
		echo "Error: Unsupported action: '$action'" 1>&2
		return 5
	fi
}

setup_binfmt $1 $2 $3
