#!/bin/bash
#
# Parallels Guest Tools for Linux
#
# Copyright (C) 2020 Parallels International GmbH
# http://www.parallels.com

if type systemctl >/dev/null 2>&1; then
	if systemctl --user is-enabled gsd-xsettings >/dev/null 2>&1; then
		for i in {1..10}; do
			systemctl --user is-active gsd-xsettings >/dev/null 2>&1 && break
			sleep 1
		done
	fi
fi
real_exec=$(readlink -f "$0")
exec "${real_exec%/*}/../install-gui" "$@"
