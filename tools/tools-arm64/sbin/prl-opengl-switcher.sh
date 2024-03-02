#!/bin/bash
#
# Set and unset Parallels OpenGL libraries.
#
# Copyright (c) 1999-2015 Parallels International GmbH.
# All rights reserved.
# http://www.parallels.com

PRL_TOOLS_VARLIB='/var/lib/parallels-tools'
GL_STORAGE_DIR="${PRL_TOOLS_VARLIB}/GL"
PRL_TOOLS_INSTALL_LIST="${PRL_TOOLS_VARLIB}/.backup/.tools.list"
PRL_TOOLS_DIR='/usr/lib/parallels-tools'
PRL_VER_FILE="${PRL_TOOLS_DIR}/version"
DETECT_XSERVER="${PRL_TOOLS_DIR}/installer/detect-xserver.sh"

is_prl_lib() {
	local lib=$1
	if type strings >/dev/null 2>&1; then
		strings "$lib" | grep -q 'Parallels Inc'
		return $?
	fi
	grep -qU 'Parallels Inc' "$lib"
}

install_lib() {
	local src=$1
	local dst=$2
	ln -f "$src" "$dst" 2>/dev/null || cp -aPf "$src" "$dst"
}

install_lib_record() {
	local src=$1
	local dst=$2
	ln -f "$src" "$dst" 2>/dev/null || cp -aPf "$src" "$dst" || return 1
	echo "$dst" >>"$PRL_TOOLS_INSTALL_LIST"
}

store_lib() {
	local lib=$1
	local arch=$2
	local dir=$GL_STORAGE_DIR
	[ -n "$arch" ] && dir="${dir}_${arch}"
	mkdir -p "$dir"  || return 1
	rm -f "${dir}/${lib##*/}"*
	cp -aPf "$lib" "$dir"
}

restore_lib() {
	local lib=$1
	local arch=$2
	local dir=$GL_STORAGE_DIR
	[ -n "$arch" ] && dir="${dir}_${arch}"
	[ -d "$dir" ] || return 1
	rm -f "$lib" && cp -aPf "$dir/${lib##*/}" "$lib"
	# Restore SELinux context
	type restorecon 1>/dev/null 2>&1
	if [ $? -eq 0 ]; then
		restorecon "$lib"
	fi
}

check_stored_lib() {
	local lib=$1
	local arch=$2
	local dir=$GL_STORAGE_DIR
	[ -n "$arch" ] && dir="${dir}_${arch}"
	local stored_lib="${dir}/${lib##*/}"
	[ -L "$stored_lib" -o -f "$stored_lib" ]
}

src_prl_bin_path() {
	local arch=$1
	local bins_dir="$PRL_TOOLS_DIR/tools/tools32"
	[ "$arch" = 'x86_64' ] && bins_dir="$PRL_TOOLS_DIR/tools/tools64"
	echo "$bins_dir"
}

tgt_prl_lib_path() {
	local lib_path=$1
	local prl_ver=`< "$PRL_VER_FILE"`
	local max_lib_path=`ls "$lib_path"* | while read f; do
			is_prl_lib "$f" || echo "$f";
		done | tail -n1`
	echo "${max_lib_path}.${prl_ver}"
}

find_installed_prl_libs() {
	local lib_path=$1
	local prl_ver=`< "$PRL_VER_FILE"`
	ls "$lib_path"*"$prl_ver" 2>/dev/null | while read f; do
		[ -f "$f" -a ! -L "$f" ] || continue
		is_prl_lib "$f" && echo "$f"
	done
}

rm_prl_libs() {
	local lib_path=$1
	find_installed_prl_libs "$lib_path" | while read l; do
		rm -f "$l"
	done
}

get_lib_arch() {
	local ld_entry=$1
	echo "$ld_entry" | grep -q ' \(.*x86-64.*\) =>' &&
		echo 'x86_64' || echo 'i386'
}

get_ld_entries() {
	local lib_name=$1
	ldconfig -p | grep "^[[:space:]]*${lib_name}"
}

get_lib_path() {
	local ld_entry=$1
	echo "$ld_entry" | sed 's/^.*=> \(.*\)$/\1/'
}

skip_ld_entry() {
	local ld_entries=$1
	local lib_arch=$2

	for ld_entry in $ld_entries; do
		local ld_entry_arch=`get_lib_arch "$ld_entry"`
		[ "$ld_entry_arch" = "$lib_arch" ] && return 0
	done
	return 1
}

enable_lib() {
	local lib_name=$1

	local ld_entries=`get_ld_entries "$lib_name"`
	if [ -z "$ld_entries" ]; then
		echo "Warning: ${lib_name} was not found in the system"
		# If we failed to find libGL on the system we should not install libglx
		# as well.
		return 1
	fi

	IFS=$'\n'
	for ld_entry in $ld_entries; do
		local lib_arch=`get_lib_arch "$ld_entry"`
		local lib_echo="${lib_name} (${lib_arch})"

		local lib_path=`get_lib_path "$ld_entry"`
		if is_prl_lib "$lib_path"; then
			echo "${lib_echo} is Parallels-provided. Skipping."
			continue
		fi

		echo "Saving system-provided ${lib_name}..."
		if ! store_lib "$lib_path" "$lib_arch"; then
			echo "Error: failed to store system-provided ${lib_echo}. Aborting."
			return 1
		fi

		local lib_src=`src_prl_bin_path "$lib_arch"`
		if [ -z "$lib_src" ]; then
			echo "Error: not able to set up Parallels-provided ${lib_echo}."
			return 1
		fi
		lib_src="${lib_src}/lib/${lib_name}.0.0"

		echo "Installing Parallels-provided ${lib_echo}..."
		local lib_dst=`tgt_prl_lib_path "$lib_path"`
		install_lib "$lib_src" "$lib_dst" && ln -sf "$lib_dst" "$lib_path"
		if [ $? -ne 0 ]; then
			echo "Error: failed to write Parallels-provided ${lib_echo}"
			return 1
		fi
	done

	return 0
}

install_libgl_dep() {
	local lib_name="$1"
	local ld_entries=`get_ld_entries "$lib_name"`

	local gl_ld_entries=`get_ld_entries 'libGL.so.1'`
	for gl_ld_entry in $gl_ld_entries; do
		local gl_lib_arch=`get_lib_arch "$gl_ld_entry"`

		skip_ld_entry "$ld_entries" "$gl_lib_arch" && continue

		local lib_echo="${lib_name} (${gl_lib_arch})"
		local lib_path=`get_lib_path "$gl_ld_entry"`
		lib_path="${lib_path%/*}/${lib_name}"

		local lib_src=`src_prl_bin_path "$gl_lib_arch"`
		if [ -z "$lib_src" ]; then
			echo "Error: not able to set up ${lib_echo}."
			return 1
		fi
		lib_src="${lib_src}/lib/${lib_name}.0.0"

		echo "Installing ${lib_echo}..."
		install_lib_record "$lib_src" "$lib_path"
		if [ $? -ne 0 ]; then
			echo "Error: failed to write ${lib_echo}"
			return 1
		fi
	done
}

enable_libgbm() {
	local lib_name='libgbm.so.1'
	local gbm_ld_entries=`get_ld_entries "$lib_name"`
	if [ -n "$gbm_ld_entries" ]; then
		enable_lib "$lib_name"
	fi

	local gl_ld_entries=`get_ld_entries 'libGL.so.1'`
	IFS=$'\n'
	for gl_ld_entry in $gl_ld_entries; do
		local gl_lib_arch=`get_lib_arch "$gl_ld_entry"`
		local lib_echo="${lib_name} (${gl_lib_arch})"

		# Check if we've installed libgbm.so.1 for this arch already
		skip_ld_entry "$gbm_ld_entries" "$gl_lib_arch" && continue

		local lib_path=`get_lib_path "$gl_ld_entry"`
		lib_path="${lib_path%/*}/${lib_name}"

		local lib_src=`src_prl_bin_path "$gl_lib_arch"`
		if [ -z "$lib_src" ]; then
			echo "Error: not able to set up Parallels-provided ${lib_echo}."
			return 1
		fi
		lib_src="${lib_src}/lib/${lib_name}.0.0"

		echo "Installing Parallels-provided ${lib_echo}..."
		install_lib "$lib_src" "$lib_path"
		if [ $? -ne 0 ]; then
			echo "Error: failed to write Parallels-provided ${lib_echo}"
			return 1
		fi
	done

	echo 'Running ldconfig...'
	ldconfig
}

disable_lib() {
	local lib_name=$1

	local ld_entries=`get_ld_entries "$lib_name"`
	if [ -z "$ld_entries" ]; then
		echo "Warning: ${lib_name} was not found in the system"
		return 0
	fi

	IFS=$'\n'
	for ld_entry in $ld_entries; do
		local lib_arch=`get_lib_arch "$ld_entry"`
		local lib_echo="${lib_name} (${lib_arch})"

		local lib_path=`get_lib_path "$ld_entry"`
		if ! is_prl_lib "$lib_path"; then
			echo "${lib_echo} is system-provided. Skipping."
			rm_prl_libs "$lib_path"
			continue
		fi

		echo "Restoring system-provided ${lib_echo}..."
		if ! restore_lib "$lib_path" "$lib_arch"; then
			echo "Error: failed to restore system-provided ${lib_echo}." \
				"Aborting."
			return 1
		fi
		rm_prl_libs "$lib_path"
	done

	return 0
}

disable_libgbm() {
	local lib_name='libgbm.so.1'

	local ld_entries=`get_ld_entries "$lib_name"`
	if [ -z "$ld_entries" ]; then
		echo "Warning: ${lib_name} was not found in the system"
		return 0
	fi

	local run_ldconfig=
	IFS=$'\n'
	for ld_entry in $ld_entries; do
		local lib_arch=`get_lib_arch "$ld_entry"`
		local lib_echo="${lib_name} (${lib_arch})"

		local lib_path=`get_lib_path "$ld_entry"`
		if ! is_prl_lib "$lib_path"; then
			echo "${lib_echo} is system-provided. Skipping."
			rm_prl_libs "$lib_path"
			continue
		fi

		if check_stored_lib "$lib_path" "$lib_arch"; then
			echo "Restoring system-provided ${lib_echo}..."
			if ! restore_lib "$lib_path" "$lib_arch"; then
				echo "Error: failed to restore system-provided ${lib_echo}." \
						"Aborting."
				return 1
			fi
			rm_prl_libs "$lib_path"
		else
			echo "System-provided ${lib_name} doesn't exist."
			rm_prl_libs "$lib_path"
			rm -f "$lib_path"
			run_ldconfig=1
		fi
	done

	if [ "$run_ldconfig" = '1' ]; then
		echo 'Running ldconfig...'
		ldconfig
	fi
}

get_elf_arch() {
	local lib_path=$1
	if type readelf >/dev/null 2>&1; then
		LANG=C readelf -h "$lib_path" | grep -q 'Class:[[:space:]]*ELF64' &&
			echo 'x86_64' || echo 'i386'
	elif type file >/dev/null 2>&1; then
		LANG=C file -b "$lib_path" | grep -q '^ELF 64-bit LSB' &&
			echo 'x86_64' || echo i386
	else
		uname -m
	fi
}

enable_glx() {
	local xmods_dir=`"$DETECT_XSERVER" -d 2>/dev/null`
	if [ -z "$xmods_dir" ]; then
		echo 'Error: failed to find out Xorg modules directory'
		return 1
	fi
	local glx_path="${xmods_dir}/extensions/libglx.so"
	if [ ! -f "${glx_path}" ]; then
		echo 'Warning: libglx.so module not found in the system. Skipping.'
		return 0
	fi
	if is_prl_lib "$glx_path"; then
		echo 'libglx.so is already Parallels-provided. Skipping.'
		return 0
	fi

	local glx_arch=`get_elf_arch "$glx_path"`
	local prl_bin_path=`src_prl_bin_path "$glx_arch"`
	if [ -z "$prl_bin_path" ]; then
		echo 'Error: not able to set up Parallels-provided libglx.so.'
		return 1
	fi

	local prl_mods_dir=`"$DETECT_XSERVER" -dsrc "$prl_bin_path" 2>/dev/null`
	local src_glx_path="${prl_mods_dir}/usr/lib/libglx.so.1.0.0"
	if [ -z "$prl_mods_dir" -o ! -f "$src_glx_path" ]; then
		echo 'Error: failed to find Parallels-provided GLX Xorg extension.'
		return 1
	fi

	echo 'Saving system-provided libglx.so...'
	if ! store_lib "$glx_path"; then
		echo 'Error: failed to store system-provided libglx.so. Aborting.'
		return 1
	fi

	echo 'Installing Parallels-provided libglx.so...'
	local glx_dst=`tgt_prl_lib_path "$glx_path"`
	install_lib "$src_glx_path" "$glx_dst" && ln -sf "$glx_dst" "$glx_path"
	if [ $? -ne 0 ]; then
		echo 'Error: failed to write Parallels-provided libglx.so'
		return 1
	fi

	return 0
}

disable_glx() {
	local xmods_dir=`"$DETECT_XSERVER" -d 2>/dev/null`
	if [ -z "$xmods_dir" ]; then
		echo 'Error: failed to find out Xorg modules directory'
		return 1
	fi
	local glx_path="${xmods_dir}/extensions/libglx.so"
	if [ ! -f "$glx_path" ]; then
		echo 'Warning: libglx.so module not found in the system. Skipping.'
		return 0
	fi

	if ! is_prl_lib "$glx_path"; then
		echo 'libglx.so is system-provided. Skipping.'
	else
		echo 'Restoring system-provided libglx.so...'
		if ! restore_lib "$glx_path"; then
			echo 'Error: failed to restore system-provided libglx.so. Aborting.'
			return 1
		fi
	fi
	rm_prl_libs "$glx_path"
}

check_prl_tools() {
	if [ ! -r "$PRL_VER_FILE" -o ! -d "${PRL_TOOLS_DIR}/tools" ]; then
		echo 'Fatal: broken Parallels Tools installation.'
		exit 1
	fi
}

cleanup_broken_switches() {
	local prl_bkp_dir='/var/lib/parallels-tools/.backup'
	local prl_list="${prl_bkp_dir}/.prl.libgl.list"
	local run_ldconfig=
	if [ -r "$prl_list" ]; then
		echo 'Found Parallels files from pervious broken installation...'
		cat "$prl_list" | sort -u | while read f; do
			[ -r "$f" ] && is_prl_lib "$f" &&
				echo "Removing '${f}'" && rm -f "$f"
		done
		rm -f "$prl_list"
		run_ldconfig=1
	fi
	local sys_list="${prl_bkp_dir}/.libgl.list"
	local storage_dir="${prl_bkp_dir}/.libgl"
	if [ -r "$sys_list" -a -d "${storage_dir}" ]; then
		echo 'Found stored system parts from previous broken installation...'
		cat "$sys_list" | sort -u | while read f; do
			echo -n " * '${f}'... "
			local src_path="${storage_dir}/${f##*/}"
			if [ -r "$src_path" ] && ! is_prl_lib "$src_path"; then
				# Previous switcher added '.32' suffix to 32-bit libs on 64-bit
				# systems. Need to restore lib without this suffix.
				if [ "${src_path: -3}" = '.32' ]; then
					[ `get_elf_arch "$src_path"` = 'i386' ] &&
						f=${f:: -3}
				fi

				if [ -f "$f" ]; then
					echo 'skipped'
				else
					echo 'restoring'
					mv -f "$src_path" "$f"
				fi
			else
				echo 'missed'
			fi
		done
		rm -f "$sys_list"
		run_ldconfig=1
	fi

	# Special kludge to restore original name of 32-bit libGL on 64-bit system.
	# Previous buggy versions of switchers may leave '.32' suffix in
	# version of library -- need to remove this suffix.
	if [ `uname -m` = 'x86_64' ]; then
		local gl32_path
		local gl64_path
		local gl_ld_entries=`get_ld_entries 'libGL.so.1'`
		IFS=$'\n'
		for ld_entry in $gl_ld_entries; do
			local gl_path=`get_lib_path "$ld_entry"`
			case `get_lib_arch "$ld_entry"` in
				'x86_64')
					gl64_path=$gl_path
					;;
				'i386')
					gl32_path=$gl_path
					;;
			esac
		done
		if [ -L "$gl32_path" -a -L "$gl64_path" ]; then
			gl32_path=`readlink -f "$gl32_path"`
			gl64_path=`readlink -f "$gl64_path"`
			if [ "${gl32_path: -3}" = '.32' ] && ! is_prl_lib "$gl32_path"; then
				gl32_path_fixed=${gl32_path%.*}
				if [ "${gl32_path_fixed##*/}" = "${gl64_path##*/}" ]; then
					echo "Removing suffix .32 from path '${gl32_path}'..."
					mv "$gl32_path" "$gl32_path_fixed"
					run_ldconfig=1
				fi
			fi
		fi
	fi

	if [ "$run_ldconfig" = '1' ]; then
		echo 'Running ldconfig...'
		ldconfig
	fi
}

enable_prl_gl() {
	check_prl_tools
	cleanup_broken_switches
	enable_lib 'libGL.so.1' &&
		install_libgl_dep 'libPrlDRI.so.1' &&
		install_libgl_dep 'libPrlWl.so.1' &&
		enable_glx &&
		enable_libgbm &&
		if [ "$1" = "--egl" ]; then enable_lib 'libEGL.so.1'; fi
}

disable_prl_gl() {
	check_prl_tools
	cleanup_broken_switches
	disable_glx && disable_lib 'libGL.so.1' &&
		disable_lib 'libEGL.so.1' &&
		disable_libgbm
}

case "$1" in
	--on)
		enable_prl_gl "$2"
		;;

	--off)
		disable_prl_gl
		;;

	*)
		echo "${0##*/} --on|--off [--egl]"
		exit 2
		;;
esac
exit $?
