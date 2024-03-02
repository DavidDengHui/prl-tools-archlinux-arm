#!/bin/bash
# Copyright (C) 1999-2016 Parallels International GmbH. All rights reserved.
#
# This script restart network inside RedHat like VM.
#

if type nmcli_reset >/dev/null 2>&1; then
	nmcli_reset
elif [[ -x /etc/init.d/network ]]; then
	/etc/init.d/network restart
else
	nmcli network off
	nmcli network on
fi

exit 0
# end of script
