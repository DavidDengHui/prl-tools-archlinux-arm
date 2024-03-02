#!/bin/bash
#
# Installation, deinstallation or upgrade of Parallels Guest Tools for Linux.
# Copyright (c) 1999-2017 Parallels International GmbH.
# All rights reserved.
# http://www.parallels.com

PATH=/sbin:/bin:/usr/sbin:/usr/bin${PATH:+:$PATH}
export LANG=C

TOOLS_NAME='Parallels Guest Tools'
BASE_DIR=$(readlink -f "$(dirname "$(readlink -f "$0")")/..")

# Installation package files
INSTALLER_DIR="$BASE_DIR/installer"
KMODS_DIR="$BASE_DIR/kmods"
TOOLS_DIR="$BASE_DIR/tools"
INSTALL="$BASE_DIR/install"
INSTALL_GUI="$BASE_DIR/install-gui"

PMANAGER="$INSTALLER_DIR/pm.sh"

# Target installation files
# The IBACKUP folder is the backupfolder in /var/lib
# the BACKUP folder is the old one in /usr/lib we save it
# in order not to broke the upgrade procedure of the old
# version of parallels-tools

IBACKUP_DIR="/var/lib/parallels-tools"
INSTALL_DIR="/usr/lib/parallels-tools"
MODPROBED_DIR="/etc/modprobe.d"
MODPROBE_CONF="/etc/modprobe.conf"
# Legacy command for blacklisting (prl_eth). Should be removed during deinstallation
ALIAS_NE2K_OFF="install ne2k-pci /bin/true"
# Legacy command for conditional blacklisting (prl_eth). Should be removed during deinstallation
ALIAS_NE2K_OVERRIDE="install ne2k-pci modprobe -q prl_eth || modprobe -i ne2k-pci"
# Legacy conf file for blacklisting (prl_eth). Should be removed during deinstallation
MODPROBE_PRL_ETH_CONF="$MODPROBED_DIR/prl_eth.conf"

INSTALL_DIR_KMODS="$INSTALL_DIR/kmods"
INSTALL_DIR_TOOLS="$INSTALL_DIR/tools"

if [ -z "$FLAG_CHECK_GUI" ]; then
	FLAG_CHECK_GUI=""
fi

# Kernel modules installation/removal
KVER=$(uname -r)
KDIR="/lib/modules/$KVER/extra"

XORG_CONF_D=(
	'/usr/share/X11/xorg.conf.d'
	'/usr/lib/X11/xorg.conf.d'
	'/usr/lib64/X11/xorg.conf.d'
	'/etc/X11/xorg.conf.d'
)

if [ -r "$INSTALL_DIR/version" ]; then
	FULL_PRODUCT_VERSION=$(cat "$INSTALL_DIR/version")
fi
INSTALL_FULL_PRODUCT_VERSION=$(cat "$BASE_DIR/version")

ARCH=$(uname -m)

# Kernel modules to be installed
KMODS_PATHS=(
	'prl_tg/Toolgate/Guest/Linux/prl_tg'
	'prl_fs/SharedFolders/Guest/Linux/prl_fs'
	'prl_fs_freeze/Snapshot/Guest/Linux/prl_freeze'
	)
if [ "$ARCH" = "aarch64" ]; then
	KMODS_PATHS+=(
		'prl_notifier/Installation/lnx/prl_notifier'
		)
else
	KMODS_PATHS+=(
		'prl_vid/Video/Guest/Linux/kmod'
		)
fi

if [ "$ARCH" != "aarch64" ]; then
	REMOVE_ONLY_KMODS_PATHS=(
		'prl_eth/pvmnet'
		)
fi

UPDATE_MODE=0
RESTORE_ON_FAIL=0
REBOOT_REQUIRED=0

# Tools locations and helper scripts and files
DETECT_X_SERVER="$INSTALLER_DIR/detect-xserver.sh"
REGISTER_SERVICE="$INSTALLER_DIR/install-service.sh"

BACKUP_DIR="${IBACKUP_DIR}/.backup"
TOOLS_BACKUP="${BACKUP_DIR}/.tools.list"
VIDEO_BACKUP="${BACKUP_DIR}/.video.list"
PSF_BACKUP="${BACKUP_DIR}/.psf"
SLP_BACKUP="${BACKUP_DIR}/.${SLP_NAME}.selinux"

TOOLS_BIN_DIR_ARM64="$INSTALL_DIR_TOOLS/tools-arm64"
TOOLS_BIN_DIR_64="$INSTALL_DIR_TOOLS/tools64"
TOOLS_BIN_DIR_32="$INSTALL_DIR_TOOLS/tools32"
if [ "$ARCH" = "x86_64" ]; then
	TOOLS_BIN_DIR="$TOOLS_BIN_DIR_64"
elif [ "$ARCH" = "aarch64" ]; then
	TOOLS_BIN_DIR="$TOOLS_BIN_DIR_ARM64"
else
	TOOLS_BIN_DIR="$TOOLS_BIN_DIR_32"
fi

# System directories
BIN_DIR="/usr/bin"
SBIN_DIR="/usr/sbin"
INITD_DIR="/etc/init.d"
INIT_DIR="/etc/init"
ICONS_DIR="/usr/share/icons/hicolor"
KERNEL_CONFIG="/boot/config-$KVER"

# X server configuration variables
XVERSION=""
XMODULES_SRC_DIR=""
XMODULES_DIR=""
USE_PRL_VIDEO=

# User space modules
TOOLSD="prltoolsd"
TOOLSD_ISERVICE="$INITD_DIR/$TOOLSD"
TOOLSD_SD_SERVICE="$TOOLSD.service"        # systemd service file

OPENGL_SWITCHER="prl-opengl-switcher.sh"

# Error codes
E_NOERROR=0
E_NOLINUX=101
E_NOPERM=102
E_NOARGS=103
E_WARG=104
E_NOTOOLS=106
E_PMLOCKED=123 # defined in pm.sh
E_NOPM=124   # defined in pm.sh
E_BFAIL=143
E_NOPKG=149
E_CHKFAIL=150
E_NOXSERV=163
E_NOXMODIR=164
E_BFAIL=167
E_IFAIL=168

# Logging routines
LOG="/var/log/parallels-tools-install.log"
VERBOSE=0

start_logging() {
	if [[ $VERBOSE -eq 1 ]]; then
		# Both errors and other output goes to both terminal and log file
		exec &> >(tee -a "$LOG")
	else
		# Only errors are reported to the user, other output goes to the log
		# We still need to tell user some things sometimes,
		# so save original stdout
		exec 3>&1
		exec 2> >(tee -a "$LOG") >> "$LOG"
	fi
}

# Uncondional console output, regardless of VERBOSE state
# For example, we want to tell user to reboot the VM after
# tools installation, even if it was installed in silent mode
tell_user() {
	echo $@
	if [[ $VERBOSE -eq 0 ]]; then
		# original stdout is in 4th descriptor so
		# we ensure that user recieved our message
		echo $@ >&3
	fi
}

# Show error
# Error message should always go to the log and to console
perror() {
	echo "$1" >&2
}

# Report installation progress for ptiagent-gui
PROGR_TOTAL=10
PROGR_CURR=0
SHOW_PROGRESS=0
echo_progress() {
	[ $SHOW_PROGRESS -eq 0 ] && return
	p=$(awk -v a=$PROGR_TOTAL -v b=$PROGR_CURR  \
		'BEGIN {printf("%f", (100 / a * b))}')
	tell_user "installer:%$p"
	let PROGR_CURR+=1
}

# Help message
usage() {
	cat << EOF
Perform installation, deinstallation or upgrade of Parallels Guest Tools for Linux
Usage: $0 [option] [--skip-rclocal-restore] [--progress] [--restore-on-fail]
         -i, --install                    install or upgrade Parallels tools in Guest OS
         --install-unattended             perform unattended installation or upgrade of Parallels tools
         --install-unattended-with-deps   perform unattended installation or upgrade of Parallels tools
                                          with downloading required packages
         --install-ptiagent               install Parallels Tools Installation Agent only
         -r, --remove                     remove Parallels tools from Guest OS
         -v, --version                    output version information
         -h, --help                       display this help message
         --skip-rclocal-restore           flag to disable restoring /etc/rc.local broken by unsuccessful
                                          express installation (for Ubuntu systems)
         --progress                       show installation progress in terminal
         --verbose                        report installation process also to stdout
         --restore-on-fail                try to restore previous Parallels Guest Tools installation
                                          (if it exists) in case of this one is failed
EOF
}

init_x_server_version() {
	XVERSION=$("$DETECT_X_SERVER" -v 2>/dev/null)
	return $?
}

check_x_server_supported() {
	init_x_server_version
	local rc=$?
	if [ $rc -eq $E_NOXSERV ]; then
		echo 'Xorg not found in the system'
		return 0
	fi
	if [ $rc -ne 0 -o $rc -eq 0 -a -z "$XVERSION" ]; then
		perror 'Warning: failed to determine Xorg version'
		return 0
	fi

	local tools_bin_dir="${TOOLS_DIR}/tools32"
	[ "$ARCH" = "x86_64" ] && tools_bin_dir="${TOOLS_DIR}/tools64"
	"$DETECT_X_SERVER" -dsrc "$tools_bin_dir" >/dev/null 2>&1
	rc=$?
	[ $rc -ne 0 ] && perror "Error: Xorg version $XVERSION not supported"
	return $rc
}

# Check requirements to run this script
check_requirements() {
	if [ "x$(uname -s)" != "xLinux" ]; then
		perror "Error: these $TOOLS_NAME can be installed on Linux guest OS only."
		exit $E_NOLINUX
	fi

	if [ "x$(id -u)" != "x0" ]; then
		perror "Error: you do not have permissions to run this script."
		exit $E_NOPERM
	fi

	local kver=$(uname -r |
		sed 's/^\([0-9]\+\)\.\([0-9]\+\)\.\([0-9]\+\)[^0-9].*/\1 \2 \3/')
	kver=$(printf '%02d%02d%02d' $kver)
	if [[ $kver < 031000 ]]; then
		perror "Error: current Linux kernel version '$(uname -r)' is outdated and not supported"
		exit $E_NOLINUX
	fi

	if use_prl_video; then
		check_x_server_supported || exit $?
	fi
}

check_required_packages() {
	# Check... are there required package manager and packages?
	local packages retcode
	packages=$("$PMANAGER" --check gtools)
	retcode=$?
	packages=$(echo "$packages" | grep '^[mo] ')
	[[ -z "$packages" && $retcode -eq 0 ]] && return $E_NOERROR

	for i in {1..10}; do
		"$PMANAGER" --install gtools
		local result_pm=$?
		# pm.sh retcode E_PMLOCKED (123) means package manager is locked at the
		# moment. It is highly probale if PTfL are updated after VM resume. So
		# let's retry installation attempt after 10 seconds pause.
		[ $result_pm -ne $E_PMLOCKED ] && break
		[ $i -ne 10 ] &&
			echo 'Package manager is locked. Trying once again.' && sleep 10
	done

	[ $result_pm -eq 0 ] && return $E_NOERROR
	[ $result_pm -eq $E_NOPM ] &&
		perror "Error: none of supported package managers found in system." ||
		perror "Error: failed to install mandatory packages."
	return $E_CHKFAIL
}

check_restrictions() {
	# Do not check restrictions if and only if
	# we are installing tools from GUI application
	if [ -z "$FLAG_CHECK_GUI" ]; then
		# Perform basic checks
		check_requirements
		check_required_packages
		result=$?
		[ $result -ne $E_NOERROR ] && return $result
	fi

	return $E_NOERROR
}

# Remove kernel modules

remove_weak_updates() {
	# On CentOS and RHEL there's mechanism called weak-updates,
	# which creates symlinks for all modules in
	# /lib/modules/$(uname -r)/weak-updates/ directory
	# It's nice to clean that symlinks from that dir also.
	local mod="${1##*/}"
	for kver in /lib/modules/*; do
		rm -f "${kver}/weak-updates/${mod}"
	done
}

remove_kernel_modules() {
	# Removing dkms modules. Should be done first cause dkms is too smart: it
	# may restore removed modules by original path.
	if type dkms > /dev/null 2>&1; then
		# Previously we registered our kmods under different name.
		# So need to support removing them as well.
		for mod_name in parallels-tools-kernel-modules parallels-tools; do
			# Unfortunately we cannot relay on dkms status retcode. So need to
			# grep it's output. If there's nothing - there was no such modules
			# registered.
			if dkms status -m $mod_name -v "$FULL_PRODUCT_VERSION" |
					grep -q $mod_name; then
				dkms remove -m $mod_name -v "$FULL_PRODUCT_VERSION" --all &&
					tell_user "DKMS modules were removed successfully"
			fi
			rm -rvf "/usr/src/${mod_name}-${FULL_PRODUCT_VERSION}"
		done
	fi

	local KMODS_PATHS_TO_REMOVE=("${KMODS_PATHS[@]}" "${REMOVE_ONLY_KMODS_PATHS[@]}")
	for kmod_path in "${KMODS_PATHS_TO_REMOVE[@]}"; do
		local kmod="${kmod_path%%/*}"
		local kmod_dir="$INSTALL_DIR_KMODS/$kmod"
		local fmod="$KDIR/$kmod.ko"

		tell_user "Start removal of $kmod kernel module"

		# Unload kernel module
		if lsmod | grep -q "^$kmod\s"; then
			if rmmod "$kmod" > /dev/null 2>&1; then
				tell_user "Kernel module $kmod was unloaded"
			else
				perror "Error: could not unload $kmod kernel module"
			fi
		fi

		# Remove kernel module from directory
		[ -f "$fmod" ] && rm -f "$fmod"

		# Remove directory if it exists
		[ -d "$kmod_dir" ] && rm -rf "$kmod_dir"
	done

	depmod -a
	update_initramfs --remove
}

remove_kernel_modules_backup() {
	local backup="$BACKUP_DIR/.kmods.list"
	tell_user "Remove kernel modules according to $backup file"
	while read -r line; do
		rm -f "$line"
		remove_weak_updates "$line"
	done < "$backup"
	rm -f "$backup"
}

# Install kernel modules

install_kmods_src() {
	local backup="$BACKUP_DIR/.kmods.list"

	cp -Rf "$KMODS_DIR" "$INSTALL_DIR"
	tar -xzf "$INSTALL_DIR_KMODS/prl_mod.tar.gz" -C "$INSTALL_DIR_KMODS"

	make -C "$INSTALL_DIR_KMODS" -f Makefile.kmods
	local result=$?
	if [ $result -ne 0 ]; then
		perror "Error: could not build kernel modules"
		return $E_BFAIL
	fi

	mkdir -p "$KDIR"
	for kmod_path in "${KMODS_PATHS[@]}"; do
		local kernel_module_name="${kmod_path%%/*}"

		if [ "$kernel_module_name" = 'prl_vid' ]; then
			use_prl_video || continue
		fi

		local kernel_dir="$INSTALL_DIR_KMODS/$kmod_path"
		tell_user "Start installation of $kernel_module_name kernel module"
		local found_module="$kernel_dir/$kernel_module_name.ko"
		if [ ! -e "$found_module" ]; then
			perror "Error: could not find $kernel_module_name kernel module"
			return $E_BFAIL
		fi
		cp -f "$found_module" "$KDIR"
		echo "$KDIR/$kernel_module_name.ko" >> "$backup"
	done

	depmod -a
}

install_kmods_dkms() {
	if type dkms > /dev/null 2>&1; then
		# Starting from version 2.2 dkms broke options compatibility:
		# option "ldtarball" will refuse to get our kmods archive. But at the
		# same time "add" option will eat our kmods sources.
		if dkms --version | sed 's/dkms: \([0-9]\+\.[0-9]\+\)\..*/\1/' |
			awk '{if ($1 < 2.2) exit 1}'
		then
			dkms add "$INSTALL_DIR_KMODS"
		else
			dkms ldtarball --archive="$INSTALL_DIR_KMODS/prl_mod.tar.gz"
		fi
		if [ $? -eq 0 ]; then
			tell_user "DKMS modules were added successfully"
		else
			tell_user "DKMS modules were not added"
		fi
		for mod_path in /lib/modules/*; do
			local _kver=${mod_path##*/}
			local tools_modules_name=parallels-tools
			if dkms build -m $tools_modules_name \
					-v "$INSTALL_FULL_PRODUCT_VERSION" \
					-k "$_kver" > /dev/null 2>&1; then
				tell_user "DKMS modules for kernel $_kver were built successfully"
			else
				perror "DKMS modules for kernel $_kver building failed"
			fi
			if dkms install -m $tools_modules_name \
					-v "$INSTALL_FULL_PRODUCT_VERSION" \
					-k "$_kver" --force > /dev/null 2>&1; then
				tell_user "DKMS modules for kernel $_kver were installed successfully"
			else
				perror "DKMS modules for kernel $_kver installation failed"
			fi
		done
	fi
}

install_kernel_modules() {
	install_kmods_src || return $?
	install_kmods_dkms

	modprobe prl_tg || return $?
	[ $REBOOT_REQUIRED -eq 0 ] && [ ! -f /proc/driver/prl_tg ] && REBOOT_REQUIRED=1
	if [ "$ARCH" = "aarch64" ]; then
		modprobe prl_notifier
	fi
}

# Tools modules installation

update_icon_cache()
{
	# mech is taken from host Linux installers
	if type gtk-update-icon-cache > /dev/null 2>&1; then
		local ignore_th_index=
		[ -f "$ICONS_DIR/index.theme" ] || ignore_th_index=--ignore-theme-index
		gtk-update-icon-cache $ignore_th_index -fq "$ICONS_DIR" > /dev/null 2>&1
	fi
}

# Init system related helper functions

# Check for systemd being main init system.
# Official systemd man suggests this as a reliable check.
# See `sd_booted` documentation on freedesktop.org.
systemd_enabled() {
	[ -d "/run/systemd/system" ]
}

# Check underlying operaion system.for being RHEL/Centos 6.x.
# 6.x have old upstart as init manager, and actually this
# function is an indirect check for this case.
not_rhel6() {
	local major=$(rev /etc/redhat-release | cut -d" " -f2 | cut -d. -f2)
	[ "$major" != "6" ]
}

# Check if system has upstart of correct version and all
# necessary directories to install our job files into.
# Old versions and certain OSes are known to have issues,
# and it's safer to fallback on sysv init scripts on such
# systems.
upstart_enabled() {
	/sbin/init --version 2>/dev/null | grep -q upstart &&
		not_rhel6 &&
		[ -d "/etc/init/" ]
}

# Remove user space tools' modules

remove_orphaned_files() {
	# In previous versions these files may not be put into TOOLS_BACK
	# log-file correctly. So need to remove them explicitely.
	local prl_x11_conf="${INIT_DIR}/prl-x11.conf"
	local prltools_updater_conf="${INIT_DIR}/prltools_updater.conf"
	if [ -e "$prltools_updater_conf" ] || [ -e "$prl_x11_conf" ]; then
		rm -f "$prltools_updater_conf" "$prl_x11_conf"
		type initctl >/dev/null 2>&1 && initctl reload-configuration
	fi

	# In previous versions init.d scripts were installed even from systemd-based
	# systemds.
	rm -f "${INITD_DIR}/prl-x11"

	rm -f "$BIN_DIR/prlfsmountd"

	# Some systemd units also might have missed the TOOLS_BACK file,
	# so we need to check for them too.
	rm -f '/usr/lib/systemd/user/prltools_updater.service'

	# On PDFM 11 K20prltoolsd remained in
	# /etc/rc.d/* dirs on systems with systemd,
	# since prtloosd used init compatibility mode,
	# and used to be started by corresponding service
	for rc_level in /etc/rc.d/*; do
		rm -f "${rc_level}/K20prltoolsd"
	done

	rm -vf "${IBACKUP_DIR}/.xconf.info"
	for xcd in "${XORG_CONF_D[@]}"; do
		rm -vf "${xcd}/40-prltools.conf"
	done
}

remove_by_list() {
	local file_list=$1

	tell_user "Removing files according to '${file_list}'"
	while read line; do
		# Kludge to fix previous buggy backup files on Fedora 19.
		[ -f "$line" ] || line=$(echo $line | sed 's/^‘\(.*\)’$/\1/')
		# Kludge to support case when 64-bit Ubuntu 11.04
		# was updated to 11.10: symlink /usr/lib64 was removed.
		[ -f "$line" ] || line=${line/usr\/lib64/usr\/lib}
		echo " rm $line"
		rm -f "$line"
	done < "$file_list"
}

remove_tools_modules() {
	if systemd_enabled; then
		for s in \
				"$TOOLSD_SD_SERVICE" \
				'prltools_updater' \
				'prl-x11' \
				'prltools-reconfig'; do
			systemctl stop "$s"
			systemctl disable "$s" 2>&1
		done
	elif upstart_enabled; then
		# nothing to do, jobs are installed via install_file
		# function and will be removed automatically
		:
	else
		"$REGISTER_SERVICE" --remove 'prltools_updater'
		"$REGISTER_SERVICE" --remove 'prl-x11'
		"$REGISTER_SERVICE" --remove 'prltools-reconfig'
	fi
	if ! use_prl_video; then
		suspend_control unmask
	fi

	if [ -e "$TOOLSD_ISERVICE" ]; then
		"$TOOLSD_ISERVICE" stop
		local pidfile="/var/run/$TOOLSD.pid"
		if [ -r "$pidfile" ]; then
			# in some versions of tools service there was bug
			# which preveted correct stopping
			# so here is kludge for this situation
			local svc_pid=$(< "$pidfile")
			kill "$svc_pid"
		fi
		"$REGISTER_SERVICE" --remove "$TOOLSD"
		rm -f "$TOOLSD_ISERVICE"
	fi

	# kill control all center processes
	for prlcc_pid in $(ps -A -opid,command | grep -v grep | grep "prlcc\>" | awk '{print $1}'); do
		kill "$prlcc_pid"
	done

	# unload selinux policy
	if [ -e "$SLP_BACKUP" ]; then
		IFS=$'\n'
		while read mod; do semodule -r "$mod"; done < "$SLP_BACKUP"
		unset IFS
	fi

	#remove shared folder
	local mpoint=$(head -n1 $PSF_BACKUP)
	IFS=$'\n'
	awk '{if ($3 == "prl_fs") print $2}' /proc/mounts |
		while read -r f; do
			local mnt_pt=$(printf "%s\n" "$f")
			umount "$mnt_pt"
			rmdir "$mnt_pt"
		done
	unset IFS
	umount -at prl_fs
	rmdir "$mpoint"

	# delete created links on psf on users desktop
	grep 'Desktop' $PSF_BACKUP | sed 's/\ /\\\ /g' | xargs rm -f

	remove_prl_video
	if [ -e "$TOOLS_BACKUP" ]; then
		remove_by_list "$TOOLS_BACKUP"
		rm -f "$TOOLS_BACKUP"
	fi

	echo 'Running ldconfig...'
	ldconfig

	# Files from previous versions, which have been forgotten
	# to be added to backup files, and thus remained after
	# tools removal. They are all special cases, and are
	# needed to be removed
	remove_orphaned_files

	# Parallels Tools icon was removed
	# So need to update icon cache
	update_icon_cache

	rmdir '/etc/prltools'

	# Attempt to remove INITD_DIR, as it may have been
	# created by our installer (in case of Arch/Manjaro)
	rmdir "$INITD_DIR" --ignore-fail-on-non-empty

	# Per-user cleanup actions:
	for d in $(awk -F: '{print $6}' /etc/passwd); do
		# Restore configuration of users directories after
		# Shared Profile changes.
		for f in user-dirs.dirs gtk-bookmarks; do
			local cfg=${d}/.parallels/${f}
			local bkp=${cfg}.orig
			if [ -r "$bkp" ] && [ -L "$cfg" ]; then
				cp -f "$bkp" "$cfg"
				rm -f "$cfg" "$bkp"
			fi
		done

		# Cleanup custom monitors configs of dynamic resolution tool.
		rm -f "${d}/.config/monitors.xml"
	done
}


# Install user space tools' modules

get_x_server_version_num() {
	local vmajor=$(echo "$1" | awk -F . '{ printf "%s", $1 }')
	local vminor=$(echo "$1" | awk -F . '{ printf "%s", $2 }')
	local vpatch=$(echo "$1" | awk -F . '{ printf "%s", $3 }')

	if [ $vmajor -ge 6 ]; then
	# Must discount major version,
	# because XOrg changes versioning logic since 7.3 (7.3 -> 1.3)
		vmajor=$((vmajor - 6))
	fi

	local v=$((vmajor*1000000 + vminor*1000))
	if [ -n "$vpatch" ]; then
		v=$((v + vpatch))
	fi
	echo $v
}

cmp_xorg_ver() {
	local op=$1
	local rv=$(get_x_server_version_num $2)
	local lv=$(get_x_server_version_num $XVERSION)
	[ $lv $op $rv ]
}

install_file() {
	local src=$1
	local dst=$2
	[ -d "$dst" ] && dst="${dst}/${src##*/}"
	cp -vf "$src" "$dst" && echo "$dst" >>"$TOOLS_BACKUP"
}

install_symlink() {
	local src=$1
	local lnk=$2
	[ -d "$lnk" ] && lnk="${lnk}/${src##*/}"
	ln -svf "$src" "$lnk" && echo "$lnk" >>"$TOOLS_BACKUP"
}

suspend_control() {
	local act=$1
	local systemd_config_dir='/etc/systemd/sleep.conf.d'
	local systemd_config_file='prl-nosuspend.conf'
	local pm_config_dir='/etc/pm/sleep.d'
	local pm_config_file="99prl-nosuspend"

	if [ "$act" = "mask" ]; then
		if systemd_enabled; then
			mkdir -p ${systemd_config_dir}
			install_file "${INSTALL_DIR_TOOLS}/${systemd_config_file}" "${systemd_config_dir}/${systemd_config_file}"
		fi
		if [[ -d /etc/pm/sleep.d/ ]]; then
			install_file "${INSTALL_DIR_TOOLS}/${pm_config_file}" "${pm_config_dir}/${pm_config_file}"
			chmod 755 "${pm_config_dir}/${pm_config_file}"
		fi
	elif [ "$act" = "unmask" ]; then
		if systemd_enabled; then
			rm -f "${systemd_config_dir}/${systemd_config_file}"
		fi
		if [[ -d /etc/pm/sleep.d/ ]]; then
			rm -f "${pm_config_dir}/${pm_config_file}"
		fi
	fi
}

configure_x_server() {
	for xcd in "${XORG_CONF_D[@]}"; do
		[ -d "$xcd" ] || continue
		install_file "${INSTALL_DIR_TOOLS}/prlmouse.conf" \
				"${xcd}/90-prlmouse.conf"
		install_file "${INSTALL_DIR_TOOLS}/parallels-tools.conf" \
				"${xcd}/40-parallels-tools.conf"
		break
	done
}

install_x_modules() {
	local xmod="$1/x-server/modules"
	for f in 'input/prlmouse_drv.so' 'drivers/prlvidel_drv.so'; do
		install_file "${xmod}/${f}" "${XMODULES_DIR}/${f}"
	done

	if cmp_xorg_ver -ge 1.17; then
		local f='drivers/prlvidex_drv.so'
		install_file "${xmod}/${f}" "${XMODULES_DIR}/${f}"
	fi

	local vid_drv='drivers/prlvideo_drv.so'
	install_file "${TOOLS_BIN_DIR}/x-server/modules/${vid_drv}" \
			"${XMODULES_DIR}/${vid_drv}"

	local udev_dir="/etc/udev/rules.d"
	local xorgprlmouse="xorg-prlmouse.rules"
	local level=69
	install_file "$INSTALL_DIR_TOOLS/$xorgprlmouse" "$udev_dir/$level-$xorgprlmouse"
}

# Setup launcher into users's session in all available DEs
# $1 - path to launcher .desktop-file
setup_session_launcher() {

	local autostart_paths="/etc/xdg/autostart
/usr/share/autostart
/usr/share/gnome/autostart
/usr/local/share/autostart
/usr/local/share/gnome/autostart
/opt/gnome/share/autostart
/opt/kde/share/autostart
/opt/kde3/share/autostart
/opt/kde4/share/autostart"

	# Try to use kde-config for KDE if available
	if type kde-config >/dev/null 2>&1; then
		local kde_autostart_paths="$(kde-config --prefix)/share/autostart"
		if ! echo "$autostart_paths" | grep -q "\<$kde_autostart_paths\>"; then
			autostart_paths="$autostart_paths
$kde_autostart_paths"
		fi
	fi

	local symlink_name="${1##*/}"
	for autostart_path in $autostart_paths; do
		if [ -d "$autostart_path" ]; then
			install_symlink "$1" "${autostart_path}/${symlink_name}"
		fi
	done
}

install_video_rules()
{
	local video_rule="parallels-video.rules"
	local dst_video_rule="/etc/udev/rules.d/99-$video_rule"
	install_file "$INSTALL_DIR_TOOLS/$video_rule" "$dst_video_rule"
}

install_selinux_module_make() {
	local makefile="/usr/share/selinux/devel/Makefile"
	local policy=$1
	local bin_path="$2"
	local mod_name=${policy##*/}; mod_name=${mod_name%.*}

	[ ! -f $makefile ] && return 1

	local tempdir=$(mktemp -d /tmp/XXXXXX-parallels-tools-selinux)
	[ -z "$tempdir" ] || [ ! -d "$tempdir" ] && return 1

	cp "$policy" "$tempdir"
	cp "${policy%.*}.fc" "$tempdir"
	pushd "$tempdir"
	make -f "$makefile" "${mod_name}.pp"
	popd
	local mod_pkg="$tempdir/${mod_name}.pp"
	[ -e "$mod_pkg" ] &&
		semodule -i "$mod_pkg" &&
		restorecon "$bin_path" &&
		echo "$mod_name" >>"$SLP_BACKUP"
	local ret_code=$?
	rm -rf "$tempdir"
	return $ret_code
}

install_selinux_module() {
	local policy=$1
	local mod_name=${policy##*/}; mod_name=${mod_name%.*}
	local bin_policy="$TOOLS_BIN_DIR/${mod_name}.mod"
	local mod_pkg="$TOOLS_BIN_DIR/${mod_name}.pp"

	# Check if SELinux stuff is available
	type checkmodule >/dev/null 2>&1 || return 1

	# Build and install module package
	checkmodule -m -M "$policy" -o "$bin_policy"
	[ -e "$bin_policy" ] && semodule_package -m "$bin_policy" -o "$mod_pkg"
	[ -e "$mod_pkg" ] && semodule -i "$mod_pkg" &&
		echo "$mod_name" >>"$SLP_BACKUP" && return 0
	return 1
}

src_prl_bin_path() {
	local arch=$1

	if [ "$ARCH" = 'aarch64' ]; then
		[ "$arch" = 'aarch64' ] && echo "$TOOLS_BIN_DIR_ARM64"
		return $?
	else
		if [ "$arch" = 'x86_64' ]; then
			echo "$TOOLS_BIN_DIR_64"
			return 0
		elif [[ "$arch" =~ ^i.86$ ]]; then
			echo "$TOOLS_BIN_DIR_32"
			return 0
		fi
	fi

	return 1
}

get_lib_path() {
	local ld_entry=$1
	echo "$ld_entry" | sed 's/^.*=> \(.*\)$/\1/'
}

get_lib_arch() {
	local ld_entry=$1
	echo "$ld_entry" | grep -q ' \(.*x86-64.*\) =>'
	if [ $? -eq 0 ]; then
		echo 'x86_64'
		return
	fi
	echo "$ld_entry" | grep -q ' \(.*AArch64.*\) =>'
	if [ $? -eq 0 ]; then
		echo 'aarch64'
		return
	fi
	echo 'i386'
}

get_ld_entries() {
	local lib_name=$1
	ldconfig -p | grep "^[[:space:]]*${lib_name}"
}

install_gl_libs() {
	local lib_name=$1
	local ld_entries=`get_ld_entries 'libGL.so.1'`
	if [ -z "$ld_entries" ]; then
		echo 'Warning: libGL.so.1 has not found in the system'
		return 0
	fi

	IFS=$'\n'
	for ld_entry in $ld_entries; do
		local gl_path=`get_lib_path "$ld_entry"`
		local gl_arch=`get_lib_arch "$ld_entry"`

		local lib_echo="${lib_name} (${gl_arch})"

		local lib_src
		lib_src=`src_prl_bin_path "$gl_arch"`
		if [ $? -ne 0 ]; then
			echo "Warning: skipping ${lib_echo} - arch unsupported"
			continue
		fi
		if [ -z "$lib_src" ]; then
			echo "Error: not able to install ${lib_echo}."
			return 1
		fi
		lib_src="${lib_src}/lib/${lib_name}.0.0"

		echo "Installing ${lib_echo} ..."
		local lib_dst="${gl_path%/*}/${lib_name}"
		install_file "$lib_src" "$lib_dst"
		if [ $? -ne 0 ]; then
			perror "Error: failed to install ${lib_echo}"
			return 1
		fi
	done
	unset IFS

	echo 'Running ldconfig...'
	ldconfig
	return 0
}

init_x_server_info() {
	init_x_server_version || return $rc

	echo "X server version: $XVERSION"
	XMODULES_SRC_DIR=$("$DETECT_X_SERVER" -dsrc "$TOOLS_BIN_DIR")
	if [ $? -eq $E_NOERROR ]; then
		echo "System X modules are installing from $XMODULES_SRC_DIR"
	else
		return $E_NOXMODIR
	fi

	XMODULES_DIR=$("$DETECT_X_SERVER" -d)
	if [ $? -eq $E_NOERROR ]; then
		echo "System X modules are placed in $XMODULES_DIR"
	else
		return $E_NOXMODIR
	fi
	return $E_NOERROR
}

use_prl_video() {
	[ "$ARCH" = 'aarch64' ] && return 1

	if [ -z "$USE_PRL_VIDEO" ]; then
		local kver=$(uname -r |
			sed 's/^\([0-9]\+\)\.\([0-9]\+\)\.\([0-9]\+\)[^0-9].*/\1 \2 \3/')
		kver=$(printf '%02d%02d%02d' $kver)
		[[ $kver < 051000 ]] && USE_PRL_VIDEO=1 || USE_PRL_VIDEO=0
	fi
	[ $USE_PRL_VIDEO -eq 1 ]
}

prl_video_installed() {
	[ -r "$VIDEO_BACKUP" ]
}

reload_udev() {
	# we need to force reloading of the udev rules and
	# reinitialization of devices in order to make X server
	# able to use correct driver for our mouse
	if type udevadm >/dev/null 2>&1; then
		udevadm control --reload-rules && udevadm trigger
		echo "udevadm exited with status $?"
	fi
}

save_xorg_version() {
	local xorg_ver

	xorg_ver=$("$INSTALLER_DIR/detect-xserver.sh" --xver)
	if [ $? -ne 0 ]; then
		perror 'Failed to detect Xorg version'
		return 1
	fi

	echo "$xorg_ver" >"$IBACKUP_DIR/xorg.version"
}

install_prl_video() {
	local tools_backup_saved=$TOOLS_BACKUP
	trap "TOOLS_BACKUP=$tools_backup_saved" RETURN
	TOOLS_BACKUP=$VIDEO_BACKUP

	init_x_server_info
	local rc=$?
	if [ $rc -eq $E_NOXSERV ]; then
		tell_user "Skip X server configuration and installation of X modules"
		return 0
	fi
	[ $rc -ne 0 ] && return $rc

	configure_x_server
	local result=$?
	if [ $result -ne $E_NOERROR ]; then
		perror "Error: could not configure X server"
		return $result
	fi

	install_x_modules "$XMODULES_SRC_DIR"
	local result=$?
	if [ $result -ne $E_NOERROR ]; then
		perror "Error: could not install X modules"
		return $result
	fi

	if ! install_gl_libs 'libPrlDRI.so.1'; then
		perror 'Error: could not install common GL libraries'
		return 1
	fi

	install_selinux_module "$INSTALLER_DIR/prlvtg.te"
	reload_udev
	save_xorg_version

	return 0
}

remove_prl_video() {
	'/usr/sbin/prl-opengl-switcher.sh' --off

	[ -r "$VIDEO_BACKUP" ] || return 0

	tell_user 'Uninstalling Parallels video stack'

	remove_by_list "$VIDEO_BACKUP"
	rm -f "$VIDEO_BACKUP"
	reload_udev
}

install_tools_service() {
	local svc="$1"

	if systemd_enabled; then
		local systemd_svc="${svc}.service"
		install_file "$INSTALLER_DIR/${systemd_svc}" '/etc/systemd/system/' &&
			systemctl enable "$systemd_svc" 2>&1
		return $?
	fi

	mkdir -p '/etc/init.d'
	install_file "${INSTALLER_DIR}/${svc}.sh" "/etc/init.d/${svc}"
	if upstart_enabled && grep -q -r "filesystem" '/etc/init'; then
		local upstart_job="${svc}.conf"
		install_file "${INSTALLER_DIR}/${upstart_job}" '/etc/init' &&
			initctl reload-configuration
		return $?
	fi

	"$REGISTER_SERVICE" --install "$svc"
}

install_tools_modules() {
	if ! install_gl_libs 'libPrlWl.so.1'; then
		perror 'Error: could not install common libraries'
		return 1
	fi

	if use_prl_video; then
		install_prl_video
		result=$?
		if [ $result -ne $E_NOERROR ]; then
			return $result
		fi
	fi

	#prepare for shared folders features using
	if [ -d /media ]; then
		local mpoint="/media/psf"
	else
		local mpoint="/mnt/psf"
	fi

	echo "$mpoint" > "$PSF_BACKUP"

	mkdir -p "$mpoint"
	if [ -d "$mpoint" ]; then
		chmod 0555 "$mpoint"
		install_selinux_module "$INSTALLER_DIR/prlfs.te"

		# add shared mount point to fstab
		for i in $(awk -F: '{print $6}' /etc/passwd); do
			if [ -d "$i"/Desktop ]; then
				local link_name="$i/Desktop/Parallels Shared Folders"
				install_symlink "$mpoint" "$link_name"
			fi
		done
	fi

	# Install time sync tool
	local timesync="$TOOLS_BIN_DIR/bin/prltimesync"
	install_file "$timesync" "$BIN_DIR/prltimesync"
	# prltoolsd's SELinux module will need types defined for prltimesync, so
	# we must install timesync SELinux module before prltoolsd's one
	install_selinux_module_make "$INSTALLER_DIR/prltimesync.te" "$BIN_DIR/prltimesync"

	# Install Parallels Tools services
	install_file "$TOOLS_BIN_DIR/bin/$TOOLSD" "$BIN_DIR/$TOOLSD"
	(
		for svc in "$TOOLSD" 'prltools-reconfig'; do
			install_tools_service "$svc" || exit $?
		done
	)
	result=$?
	[ $result -ne $E_NOERROR ] && return $result

	# Install Parallels Shared Folders automount daemon
	install_file "$INSTALL_DIR_TOOLS/prlfsmountd.sh" "$BIN_DIR/prlfsmountd"
	if [ "$ARCH" = "aarch64" ]; then
		install_file "$INSTALL_DIR_TOOLS/prlbinfmtconfig.sh" "$BIN_DIR/prlbinfmtconfig"
	fi
	
	install_selinux_module_make "$INSTALLER_DIR/prltoolsd.te" "$BIN_DIR/$TOOLSD"
	# prltoolsd accesses this directory during startup
	# and this should be permitted by SELinux
	local installer_dir="${INSTALL_DIR_TOOLS}/../installer"
	if type semanage > /dev/null 2>&1; then
		semanage fcontext -a -t lib_t "${installer_dir}(/.*)?"
		restorecon -RFv "$installer_dir"
	else
		echo "Warning: no semanage found in system"
		echo "Not changing type for ${installer_dir}."
	fi

	# Install Parallels Control Center
	local ctlcenter="$TOOLS_BIN_DIR/bin/prlcc"
	install_file "$ctlcenter" "$BIN_DIR/prlcc"

	# and just the same for DnD tool
	local dndtool="$TOOLS_BIN_DIR/bin/prldnd"
	install_file "$dndtool" "$BIN_DIR/prldnd"

	# and CP tool as well
	local cptool="$TOOLS_BIN_DIR/bin/prlcp"
	install_file "$cptool" "$BIN_DIR/prlcp"

	# and don't forget brand new SGA
	local sgatool="$TOOLS_BIN_DIR/bin/prlsga"
	install_file "$sgatool" "$BIN_DIR/prlsga"

	# Install host time utility
	local hostime="$TOOLS_BIN_DIR/bin/prlhosttime"
	install_file "$hostime" "$BIN_DIR/prlhosttime"

	# Install istatus utility
	local show_vm_cfg="$TOOLS_BIN_DIR/bin/prl_showvmcfg"
	install_file "$show_vm_cfg" "$BIN_DIR/prl_showvmcfg"

	# Install network tool utility
	local nettool="$TOOLS_BIN_DIR/sbin/prl_nettool"
	install_file "$nettool" "$SBIN_DIR/prl_nettool"

	# Install utility for smoof filesystems backup
	local snap_tool="$TOOLS_BIN_DIR/sbin/prl_snapshot"
	install_file "$snap_tool" "$SBIN_DIR/prl_snapshot"

	# Install shared profile tool
	local shprof="$TOOLS_BIN_DIR/bin/prlshprof"
	install_file "$shprof" "$BIN_DIR/prlshprof"

	# Install shared printers tool
	local shprint="$TOOLS_BIN_DIR/bin/prlshprint"
	install_file "$shprint" "$BIN_DIR/prlshprint"

	# Install user session manager tool
	if [ "$ARCH" != "aarch64" ]; then
		local usmd="$TOOLS_BIN_DIR/bin/prlusmd"
		install_file "$usmd" "$BIN_DIR/prlusmd"
	fi

	setup_session_launcher "${INSTALL_DIR_TOOLS}/prlcc.desktop"

	# Install OpenGL switcher
	local openglsw="$TOOLS_BIN_DIR/sbin/$OPENGL_SWITCHER"
	install_file "$openglsw" "$SBIN_DIR/$OPENGL_SWITCHER"

	# Man-page for prl_fs
	local manpage_name='mount.prl_fs.8'
	local manpage="$INSTALL_DIR_TOOLS/$manpage_name"
	local man_dir='/usr/share/man/man8'
	if [ -d "$man_dir" ]; then
		install_file "$manpage" "$man_dir/$manpage_name"
	fi

	if [[ -d /etc/pm/sleep.d/ ]]; then
		local toolsd_hibernate="$INSTALL_DIR_TOOLS/99prltoolsd-hibernate"
		install_file "$toolsd_hibernate" "/etc/pm/sleep.d/99prltoolsd-hibernate"
	fi

	if [ "$ARCH" != "aarch64" ]; then
		install_video_rules
	fi

	install_ptiagent_starters

	if [ -d "$ICONS_DIR" ]; then
		local tools_icon="parallels-tools.png"
		local icon="$INSTALL_DIR_TOOLS/$tools_icon"
		local icon_target="$ICONS_DIR/48x48/apps/$tools_icon"
		if [ -e "$icon" ]; then
			install_file "$icon" "$icon_target"
		fi
		update_icon_cache
	fi

	return $E_NOERROR
}

remove_gt() {
	result=$E_NOTOOLS
	n=0

	if [ "$ARCH" != "aarch64" ]; then
		rm -f "$MODPROBED_DIR/blacklist-parallels.conf"
		rm -f "$MODPROBED_DIR/blacklist-parallels"
	fi
	
	# Remove legacy conf file for blacklisting (prl_eth)
	rm -f "$MODPROBE_PRL_ETH_CONF"

	# Remove from global conf legacy blacklisting (prl_eth)
	if [ -f "$MODPROBE_CONF" ]; then
		cmds="$ALIAS_NE2K_OFF:$ALIAS_NE2K_OVERRIDE"
		IFS=':'
		for cmd in $cmds; do
			esc_cmd=$(echo "$cmd" | sed 's/\//\\\//g')
			grep -q "^\W*$cmd" "$MODPROBE_CONF" && sed -i "/^\W*$esc_cmd/d" "$MODPROBE_CONF"
		done
		unset IFS
	fi

	# Find directory with installed Guest Tools
	if [ ! -d "$INSTALL_DIR" ]; then
		echo "Installed Guest Tools were not found"
		UPDATE_MODE=0
		return $E_NOERROR
	fi
	echo "Found Guest Tools directory: $INSTALL_DIR"

	remove_tools_modules

	# Check... should we completely remove Guest Tools?
	if ([ "$1" = "-f" ] || [ "$BASE_DIR" != "$INSTALL_DIR" ]); then
		# Remove kernel modules
		remove_kernel_modules
		remove_kernel_modules_backup

		# Backups will be removed only if we are in non-update or force-remove mode
		if [ "$1" = "-f" ] || [ $UPDATE_MODE -ne 1 ]; then
			# Remove backup directory
			rm -rf "$BACKUP_DIR"
		fi
		# Finally remove installation directory
		echo "Remove $INSTALL_DIR directory"
		rm -rf "$INSTALL_DIR"
	else
		# Remove kernel modules
		remove_kernel_modules

		echo "Skip removal of $INSTALL_DIR directory"
	fi
	return $E_NOERROR
}

istatus() {
	local argument=$1
	local version=$2
	local error_msg=$3

	local istatus_dir=$INSTALLER_DIR
	[ -n "$ISTATUS_DIR" ] && istatus_dir=$ISTATUS_DIR
	local arch_suffix=32
	[ "$ARCH" = 'x86_64' ] && arch_suffix=64
	[ "$ARCH" = 'aarch64' ] && arch_suffix='-arm64'
	local istatus_cmd=$istatus_dir/prl_istatus$arch_suffix

	"$istatus_cmd" "$argument" "$version" ||
		perror "Error during report about ${error_msg}."
}

remove_guest_tools() {
	tell_user
	tell_user $(date)
	tell_user "Start removal of Guest Tools"

	# Special kludge to store prl_istatus binary temporarily if we are calling
	# uninstaller "in place".
	local tmp_istatus=$(mktemp -d -t prlistatus-XXXXXX)
	cp "$INSTALLER_DIR"/prl_istatus{32,64,'-arm64'} "$tmp_istatus"

	remove_gt -f
	result=$?
	if [ $result -ne $E_NOERROR ]; then
		rm -rf "$tmp_istatus"
		return $result
	fi

	ISTATUS_DIR=$tmp_istatus istatus uninstalled "$FULL_PRODUCT_VERSION" \
		"uninstalled tools version"
	rm -rf "$tmp_istatus"
	return $E_NOERROR
}

restore_rclocal() {
	rclocal=/etc/rc.local
	rclocal_backup=/etc/rc.local.backup

	[[ -f "$rclocal" ]] || [[ -f "$rclocal_backup" ]] || return

	# Try criterias of damaged express installation
	grep -q 'HOME_DIR' "$rclocal" || return
	grep -q '^mv /etc/rc.local.backup /etc/rc.local$' "$rclocal" || return
	grep -q '^reboot$' "$rclocal" || return

	tell_user "Failed express installation is detected!"
	tell_user "Trying to restore /etc/rc.local and other stuff"

	# Here are the commands which were not executed during the end
	# of express installation. See Ubuntu's part of UnattendedCd lib.
	mv -f "$rclocal_backup" "$rclocal"
	mv -f /opt/prl-tools-installer/S*gdm /etc/rc2.d/
	mv -f /opt/prl-tools-installer/S*kdm /etc/rc2.d/
	rm -rf /opt/prl-tools-installer
	mv -f /etc/issue.backup /etc/issue
}

update_initramfs() {
	# Add prl_tg/vid/eth modules to initramfs and exclude others
	# $1: --install/--remove

	# RHEL, CentOS, Fedora...
	local dracut_conf_dir='/etc/dracut.conf.d'
	if type dracut >/dev/null 2>&1 && [ -d "$dracut_conf_dir" ]; then
		local dracut_conf_file="${dracut_conf_dir}/parallels-tools.conf"
		if [ "$1" = '--install' ]; then
			rm -vf "$dracut_conf_file"
			dracut -f --regenerate-all
		else
			rm -f "$dracut_conf_file"
			local omited_drvs='prl_fs prl_fs_freeze prl_tg'
			if [ "$ARCH" != "aarch64" ]; then
				omited_drvs="prl_eth prl_vid ${omited_drvs}"
			fi
			dracut -f --regenerate-all --omit-drivers "$omited_drvs"
		fi

	# Debian-based
	elif type update-initramfs > /dev/null 2>&1; then
		local hooks_dir='/usr/share/initramfs-tools/hooks'
		local hooks_file="${hooks_dir}/parallels_tools"

		if [ "$1" = '--install' ]; then
			[ -d "$hooks_dir" ] &&
				install_file "$INSTALLER_DIR/parallels_tools.initramfs-hook" \
						"$hooks_file"
		else
			rm -f "$hooks_file"
		fi

		update-initramfs -u -k all

	# Arch, Manjaro...
	elif type mkinitcpio > /dev/null 2>&1; then
		mkinitcpio -P
	fi
}

# Install Guest Tools

install_guest_tools() {

	echo_progress
	istatus install_started "$INSTALL_FULL_PRODUCT_VERSION" \
		"start installation of parallels tools"

	tell_user
	tell_user $(date)
	tell_user "Start installation or upgrade of Guest Tools"

	echo_progress
	if [ -z "$SKIP_RCLOCAL_RESTORE" ]; then
		restore_rclocal
	else
		echo "Restoring rc.local is skipped"
	fi

	# Switching to update mode
	# If guest tools are not installed really remove_gt() will set UPDATE_MODE=0
	echo_progress
	UPDATE_MODE=1
	remove_gt

	result=$?
	if [ $result -eq $E_NOERROR ]; then
		echo "Register service to install new Guest Tools"
		# TODO register service
	fi

	echo_progress
	echo "Perform installation into the $INSTALL_DIR directory"
	# Create installation directory and copy files
	mkdir -p "$INSTALL_DIR"
	# Create directory for backup files
	mkdir -p "$BACKUP_DIR"

	echo_progress
	install_kernel_modules
	result=$?
	if [ $result -ne $E_NOERROR ]; then
		# Compilation of kernel modules is failed so do clean up
		rm -rf "$INSTALL_DIR"
		istatus install_failed "$INSTALL_FULL_PRODUCT_VERSION" \
			"failed installation of parallels tools"
		return $result
	fi

	echo_progress
	# Special procedure to update installer stuff
	# because PTIAgent may be running there.
	local TMP_INSTALLER_DIR="$(mktemp -d -t prlinstallerXXXXXX)"
	cp -Rf "$INSTALLER_DIR" "$TMP_INSTALLER_DIR"
	mv -f "$TMP_INSTALLER_DIR/installer" "$INSTALL_DIR"
	chmod 755 "$INSTALL_DIR/installer"
	rm -rf "$TMP_INSTALLER_DIR"

	echo_progress
	cp -Rf "$TOOLS_DIR" "$INSTALL_DIR"
	cp -Rf "$INSTALL" "$INSTALL_DIR"
	cp -Rf "$INSTALL_GUI" "$INSTALL_DIR"
	cp -Rf "$BASE_DIR/version" "$INSTALL_DIR"

	# Install blacklist for prl_vid
	if [ "$ARCH" != "aarch64" ]; then
		if [ -d "$MODPROBED_DIR" ]; then
			cp -f "$INSTALLER_DIR/blacklist-parallels.conf" "$MODPROBED_DIR"
		else
			echo "Skip installing of blacklist-parallels.conf. $MODPROBED_DIR is missing"
		fi
	fi

	echo_progress
	install_tools_modules
	result=$?
	if [ $result -ne $E_NOERROR ]; then
		istatus install_failed "$INSTALL_FULL_PRODUCT_VERSION" \
			"failed installation of parallels tools"
		return $result
	fi

	echo "Perform initramfs update."
	update_initramfs --install

	echo_progress
	echo "Send installed Parallels Tools version to dispatcher."
	istatus installed "$INSTALL_FULL_PRODUCT_VERSION" "installed tools version"
	echo_progress
	return $E_NOERROR
}

install_ptiagent_starters() {
	local ptiagent_starter="${INSTALL_DIR}/installer/ptiagent-wrapper.sh"
	local ptiagent_symlink="${BIN_DIR}/ptiagent"
	install_symlink "$ptiagent_starter" "$ptiagent_symlink"

	local ptiagent_cmd_starter="${INSTALL_DIR}/installer/ptiagent-cmd"
	local ptiagent_cmd_symlink="${BIN_DIR}/ptiagent-cmd"
	install_symlink "$ptiagent_cmd_starter" "$ptiagent_cmd_symlink"

	setup_session_launcher "${INSTALL_DIR_TOOLS}/ptiagent.desktop"
}

install_ptiagent() {
	TOOLS_BACKUP="$IBACKUP_DIR/.backup/.tools.list"
	mkdir -p "${TOOLS_BACKUP%/*}"

	local tgt_installer_dir="${INSTALL_DIR}/installer"
	mkdir -p "$tgt_installer_dir"
	if [ "$ARCH" != "aarch64" ]; then
		cp -fR "${INSTALLER_DIR}/ptiagent32" "$tgt_installer_dir"
		cp -fR "${INSTALLER_DIR}/ptiagent64" "$tgt_installer_dir"
		cp -fR "${INSTALLER_DIR}/ptiagent32-cmd" "$tgt_installer_dir"
		cp -fR "${INSTALLER_DIR}/ptiagent64-cmd" "$tgt_installer_dir"
		cp -fR "${INSTALLER_DIR}/iagent32" "$tgt_installer_dir"
		cp -fR "${INSTALLER_DIR}/iagent64" "$tgt_installer_dir"
	else
		cp -fR "${INSTALLER_DIR}/ptiagent-arm64" "$tgt_installer_dir"
		cp -fR "${INSTALLER_DIR}/ptiagent-arm64-cmd" "$tgt_installer_dir"
		cp -fR "${INSTALLER_DIR}/iagent-arm64" "$tgt_installer_dir"
	fi
	cp -f "${INSTALLER_DIR}/ptiagent-cmd" "$tgt_installer_dir"
	cp -f "${INSTALLER_DIR}/ptiagent-wrapper.sh" "$tgt_installer_dir"

	mkdir -p "$INSTALL_DIR_TOOLS"
	cp -f "${TOOLS_DIR}/ptiagent.desktop" "$INSTALL_DIR_TOOLS"

	cp -f "$INSTALL_GUI" "$INSTALL_DIR"
	cp -f "${BASE_DIR}/version" "$INSTALL_DIR"

	install_ptiagent_starters
	install_kmods_src
}

is_xserver_detected() {
	"$INSTALLER_DIR/detect-xserver.sh" -v >/dev/null 2>&1
	[ $? -eq $E_NOERROR ]
}

post_install() {
	echo ">>> Postinstall"
	echo "Writing OS version and Xorg version"
	"$PMANAGER" --os-ver > "$IBACKUP_DIR/os.version"
	if systemd_enabled; then
		echo "Enabling PRL_GL"
		systemctl start 'prltools-reconfig'
		echo "Starting prltoolsd service:"
		systemctl start prltoolsd
	else
		echo "Enabling PRL_GL"
		/etc/init.d/prltools-reconfig start
		echo "Starting prltoolsd service:"
		/etc/init.d/prltoolsd start
	fi
	if ! use_prl_video; then
		echo "Mask suspend service unit (since virtio-gpu doesn't support suspend/resume):"
		suspend_control mask
	fi
	echo_progress
}

RESTORE_BACKUP=
backup_old_version() {
	if [ ! -d "$INSTALL_DIR" ]; then
		echo "Previous version was not found. Nothing to backup."
		return 1
	fi

	echo "Installation of $TOOLS_NAME version '$FULL_PRODUCT_VERSION' was found."

	RESTORE_BACKUP=$(mktemp -t prltools-backup-XXXXXX.tar.gz)
	tar cz -C "$INSTALL_DIR" . >"$RESTORE_BACKUP" &&
		echo "Created previous version backup in '$RESTORE_BACKUP'" ||
		echo "Failed to create backup of previous version."
}

restore_old_version() {
	[ -r "$RESTORE_BACKUP" ] || return 1
	echo
	echo "Reinstalling previous version '$FULL_PRODUCT_VERSION'" \
		"from backup '$RESTORE_BACKUP'"
	echo '--------------------------------------------------------'
	tmp_installer=$(mktemp -d -t prl-tools-lin-XXXXXX)
	tar xzf "$RESTORE_BACKUP" -C "$tmp_installer" || return 1
	rm -f "$RESTORE_BACKUP"
	"$tmp_installer/install" --install-unattended-with-deps
	rc=$?
	echo '--------------------------------------------------------'
	[ $rc -eq 0 ] &&
		tell_user "Previous version '$FULL_PRODUCT_VERSION' was" \
			"reinstalled successfully" ||
		perror "Failed to restore previous version '$FULL_PRODUCT_VERSION'" \
			"(retcode $rc)"
	rm -rf "$tmp_installer"
	return $rc
}

show_installer_error() {
	if [ $result -ne $E_NOPKG -a -z "$FLAG_CHECK_GUI" ]; then
		# Log is not created if installer failed with error $E_NOPKG
		perror "Error: failed to $2 $TOOLS_NAME!"
		[ -f "$LOG" ] && [ -z $VERBOSE ] &&
			perror "Please, look at $LOG file for more information."
	fi
}

show_installer_ok() {
	if [ "$1" = 'install' ]; then
		msg0='installed'
		msg1='installation'
	elif [ "$1" = 'upgrade' ]; then
		msg0='upgraded'
		msg1='upgrade'
	elif [ "$1" = 'remove' ]; then
		msg0='removed'
		msg1='removal'
	elif [ "$1" = 'restore' ]; then
		msg0='restored'
		msg1='recovery'
	fi

	tell_user "$TOOLS_NAME were $msg0 successfully!"
	[ $REBOOT_REQUIRED -eq 1 ] &&
		tell_user "Please, reboot your OS to finish $msg1 of $TOOLS_NAME."
}

install_proc() {
	tell_user "Started installation of $TOOLS_NAME version '$INSTALL_FULL_PRODUCT_VERSION'"
	check_restrictions
	result=$?
	[ $result -ne $E_NOERROR ] &&
		{ show_installer_error $result "install or upgrade"; return $result; }

	[ $RESTORE_ON_FAIL -eq 1 ] && backup_old_version
	install_guest_tools
	result=$?
	# UPDATE_MODE is set only in install_guest_tools
	[ $UPDATE_MODE -eq 1 ] && type_msg='upgrade' || type_msg='install'
	if [ $result -ne $E_NOERROR ]; then
		show_installer_error $result "$type_msg"
		if [ $RESTORE_ON_FAIL -eq 1 ]; then
			tell_user "Trying to restore previous $TOOLS_NAME installation..."
			type_msg='restore'
			restore_old_version || return $?
		else
			return $result
		fi
	fi
	post_install
	result=$?
	show_installer_ok "$type_msg"
	return $result
}

remove_proc() {
	check_requirements
	remove_guest_tools
	result=$?
	msg='remove'
	if [ $result -eq $E_NOERROR ]; then
		show_installer_ok "$msg"
	else
		show_installer_error $result "$msg"
	fi
	if ( type lsb_release && type dpkg-reconfigure ) > /dev/null 2>&1; then
		distro=$(lsb_release -i | awk -F " " '{print $3}')
		if [ "$distro" = "Ubuntu" ]; then
			dpkg-reconfigure xserver-xorg
		fi
	fi
	return $result
}

install_x_tools_modules() {
	tell_user $(date)
	tell_user "Starting installation of Parallels Tools for Linux X modules"
	check_x_server_supported || return $?
	install_prl_video
	local result=$?
	if [ $result -eq 0 ]; then
		tell_user "PTfL X modules installation finished successfully"
	else
		tell_user "PTfL X modules installation failed"
	fi
	return $result
}

check_xorg_changed() {
	[ -r "$IBACKUP_DIR/xorg.version" ] || return 1
	init_x_server_version || return 1

	local xorg_saved_version=$(< "$IBACKUP_DIR/xorg.version")
	[ -z "$xorg_saved_version" ] && return 1

	cmp_xorg_ver -ne "$xorg_saved_version"
}

setup_gl_libs() {
	local show_vm_cfg='/usr/bin/prl_showvmcfg'
	local opengl_switcher='/usr/sbin/prl-opengl-switcher.sh'

	echo 'Setting up GL libs'

	if [ ! -x "$show_vm_cfg" ]; then
		perror "'${show_vm_cfg}' is missing"
		return 1
	fi

	if "$show_vm_cfg" | grep -q 'opengl-support:[[:space:]]*1$'; then
		tell_user "Found OpenGL support in host; set up OpenGL libs in guest"
		"$opengl_switcher" --on --egl
	else
		tell_user "No OpenGL support in host; skip set up OpenGL libs in guest"
		"$opengl_switcher" --off
	fi
}

reconfig() {
	if use_prl_video; then
		if ! prl_video_installed || check_xorg_changed; then
			install_x_tools_modules || return 1
			suspend_control unmask
		fi
		setup_gl_libs
	elif prl_video_installed; then
		remove_prl_video
		suspend_control mask
	fi
}

# Install, upgrade or remove Guest Tools

is_xserver_detected && REBOOT_REQUIRED=1

if [ $# -eq 0 ]; then
	perror "Error: wrong number of input parameters [$#]"
	perror
	usage
	exit $E_NOARGS
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
		--install-ptiagent)
			action="install_ptiagent"
			;;

		-i | --install | --install-unattended \
				| --force-install | --install-unattended-with-deps)
			action="install_proc"
			;;

		-r | --remove)
			action="remove_proc"
			;;

		-v | --version)
			echo "$INSTALL_FULL_PRODUCT_VERSION"
			exit $E_NOERROR
			;;

		-h | --help)
			usage
			exit $E_NOERROR
			;;

		--verbose)
			VERBOSE=1
			;;

		--progress)
			SHOW_PROGRESS=1
			;;

		--restore-on-fail)
			RESTORE_ON_FAIL=1
			;;

		--skip-rclocal-restore)
			SKIP_RCLOCAL_RESTORE=1
			;;

		--check)
			action='check_requirements'
			;;

		--reconfig)
			action='reconfig'
			;;

		*)
			perror "Error: wrong input parameter [$1]"
			perror
			usage
			exit $E_WARG
			;;
	esac
	shift
done

umask 022
start_logging
$action
exit $?
