#!/bin/bash
#
# Parallels Tools for Linux. Shared Folders automounting tool.
#
# Copyright (c) 1999-2015 Parallels International GmbH.
# All rights reserved.
# http://www.parallels.com

MOUNTS=/etc/mtab
SF_LIST=/proc/fs/prl_fs/sf_list
POLL_TIME=5
MNT_OPS=sync,nosuid,nodev,noatime,share
# In addition to MNT_OPS for the Home folder
MNT_OPS_HOME=host_inodes
PRL_LOG=/var/log/parallels.log
ROSETTA_LINUX_SF_NAME=RosettaLinux
ROSETTAD_PID_FILE="/var/run/prlrosettad.pid"
ROSETTAD_SOCK="/var/run/prlrosettad.sock"
BINFMT_CONFIG_COMMAND=prlbinfmtconfig

if [ "$1" = "-f" ]; then
	# Foreground mode: just run remounting once.
	RUN_MODE=f
elif [ "$1" = "-u" ]; then
	# Umount mode: umount everything and exit.
	RUN_MODE=u
else
	# Background mode: do remounting infinitely with POLL_TIME sleep.
	RUN_MODE=b
	PID_FILE=$1
	if test -z "$PID_FILE"; then
		echo "Pid-file must be given as an argument." >&2
		exit 2
	fi

	if ! echo $$ >"$PID_FILE"; then
		echo "Failed to write into pid-file '$PID_FILE'." >&2
		exit 1
	fi
fi

[ -d "/media" ] && MNT_PT=/media/psf || MNT_PT=/mnt/psf

# remove all obsolete mount points in MNT_PT dir
rmdir "$MNT_PT"/* 2>/dev/null

prl_log() {
	level=$1
	shift
	msg=$*
	timestamp=`date '+%m-%d %H:%M:%S    '`
	echo "$timestamp $level SHAREDFOLDERS: $msg" >>"$PRL_LOG"
	echo "$msg"
}

# $1 -- SF name
# $2 -- mount point
do_mount() {
	if [ "$1" = "Home" ]; then
		mnt_ops="$MNT_OPS,$MNT_OPS_HOME"
	else
		mnt_ops=$MNT_OPS
	fi

	se_target_context=$([ "$1" = "RosettaLinux" ] && 
		echo "bin_t" || echo "removable_t")
	type semodule >/dev/null 2>&1 &&
		mnt_ops=$mnt_ops",context=system_u:object_r:$se_target_context:s0"

	if uname -r | grep -q '^[0-2].[0-4]'; then
		mount -t prl_fs -o $mnt_ops,sf="$1" none "$2"
	else
		mount -t prl_fs -o $mnt_ops "$1" "$2"
	fi

	return $?
}

run_with_logging()
{
	local command=$1
  	shift
	
	local command_out
	command_out=$($command $* 2>&1)
	rc=$?

	# TODO comment
	local original_ifs="$IFS"
	IFS=" "
	if [ $rc -eq 0 ]; then
		prl_log I "Successfully executed: '$command $*'" \
			"Output: $command_out"
	else
		prl_log E "Failed to execute:'$command $*'. " \
			"Retcode=$rc Output: $command_out"
	fi

	IFS="$original_ifs"
	return $rc
}
	
check_socket_existence() {
	local socket_path="$1"
	local timeout=10
	
	local start_time=$(date +%s)
	local end_time=$((start_time + timeout))
	
	while [ ! -S "$socket_path" ] && [ $(date +%s) -lt "$end_time" ]; do
		sleep 1
	done
	
	if [ ! -S "$socket_path" ]; then
		echo "Timeout: Socket $socket_path does not exist within $timeout seconds"
		return 1
	fi
}

start_rosettad() {
	path="$1"
	cache_dir="/var/cache/prlrosettad"
	socket_path="$cache_dir/uds/prlrosettad.sock"

	# Remove stale rosettad native socket (to be able monitor the creation of a new socket) 
	if [ -S "$socket_path" ]; then
		rm -f "$socket_path"
	fi

	# Run rosettad as daemon
	"$path" daemon "$cache_dir" > /var/log/parallels-rosettad.log 2>&1 < /dev/null &
	pid=$!
	echo $pid > $ROSETTAD_PID_FILE
	echo "Rosettad daemon started with PID: $pid"

	# Detach backgroud task (rosettad)
	disown

	# Wait untill rosetad create communication socket
	if check_socket_existence "$socket_path"; then
		# Allow connections from NON-root processes
		#rwx--x--x
		chmod 711 "$cache_dir"
		chmod 711 "$cache_dir/uds"
		#rwxrw-rw-
		chmod 766 "$socket_path"

		# Create symlink to the sock in /var/run/
		ln -s "$socket_path" "$ROSETTAD_SOCK"
	fi

	return $?
}

stop_rosettad() {
	if [ -f "$ROSETTAD_PID_FILE" ]; then
		pid=$(cat "$ROSETTAD_PID_FILE")

		echo "Teminating Rosettad daemon started with PID: $pid"

		kill "$pid"

		rm "$ROSETTAD_PID_FILE"
	else
		echo "Rosettad daemon is not running or PID file does not exist"
	fi

	if [ -h "$ROSETTAD_SOCK" ]; then
		rm "$ROSETTAD_SOCK"
	fi
}

on_mount_rosetta_sf() {
	mount_point="$1"
	rosetta_path=$mount_point/rosetta
	rosettad_daemon_path=$mount_point/rosettad
		
	if [ -f "$rosetta_path" ]; then
		run_with_logging $BINFMT_CONFIG_COMMAND register $ROSETTA_LINUX_SF_NAME $rosetta_path

		if [ $? -eq 0 ]; then
			if [ -f "$rosettad_daemon_path" ]; then
					run_with_logging start_rosettad "$rosettad_daemon_path"
			else
					prl_log I "Skip starting Rosetta OAT сaching daemon. executable '$rosettad_daemon_path' is not found"
			fi
		fi
	else
		prl_log W "Skip registring binfmt. Emulator '$rosetta_path' is not found"
	fi

	return $?
}

on_unmount_rosetta_sf() {
	run_with_logging $BINFMT_CONFIG_COMMAND unregister $ROSETTA_LINUX_SF_NAME
	run_with_logging stop_rosettad
}

IFS=$'\n'
while true; do
	# Get list of SFs which are already mounted
	curr_mounts=$(cat "$MOUNTS" | awk '{
		if ($3 == "prl_fs") {
			if ($1 == "none") {
				split($4, ops, ",")
				for (i in ops) {
					if (ops[i] ~ /^sf=/) {
						split(ops[i], sf_op, "=")
						print sf_op[2]
						break
					}
				}
			} else {
				n = split($1, dir, "/")
				print dir[n]
			}
		}}')
	# and list of their mount points.
	curr_mnt_pts=$(cat "$MOUNTS" | awk '{if ($3 == "prl_fs") print $2}' | \
		while read -r f; do printf "${f/\%/\%\%}\n"; done)
	if [ -r "$SF_LIST" -a $RUN_MODE != 'u' ]; then
		sf_list=$(cat "$SF_LIST" | sed '
			1d
			s/^[[:xdigit:]]\+: \(.*\) r[ow]$/\1/')
		# Go through all enabled SFs
		for sf in $sf_list; do
			mnt_pt="$MNT_PT/$sf"
			curr_mnt_pts=`echo "$curr_mnt_pts" | sed "/^${mnt_pt//\//\\\/}$/d"`
			# Check if shared folder ($sf) is not mounted already
			printf "${curr_mounts/\%/\%\%}" | grep -q "^$sf$" && continue
			if [ ! -d "$MNT_PT" ]; then
				mkdir "$MNT_PT"
				chmod 755 "$MNT_PT"
			fi
			mkdir "$mnt_pt"
			run_with_logging do_mount $sf $mnt_pt

			if [ $? -eq 0 ]; then
				if [ "$sf" = "$ROSETTA_LINUX_SF_NAME" ]; then
					on_mount_rosetta_sf $mnt_pt
				fi
			fi
		done
	fi

	# Here in $curr_mnt_pts is the list of SFs which are disabled
	# but still mounted -- umount all them.
	for mnt_pt in $curr_mnt_pts; do
		# Skip all those mounts outside of our automount directory.
		# Seems user has mounted them manually.
		if ! echo "$mnt_pt" | grep -q "^${MNT_PT}"; then
			prl_log I "Skipping shared folder '${mnt_pt}'"
			continue
		fi

		# Unregister binfmt before unmounting, because binfmt_misc
		# might hold open interpretator
		sf=$(echo "$mnt_pt" | sed "s|^$MNT_PT/||")
		if [ "$sf" = "$ROSETTA_LINUX_SF_NAME" ]; then
			on_unmount_rosetta_sf $mnt_pt
		fi

		run_with_logging umount $mnt_pt
		if [ $? -eq 0 ]; then
			rmdir "$mnt_pt"
		fi
	done
	[ $RUN_MODE != 'b' ] && exit $rc
	sleep $POLL_TIME
done
