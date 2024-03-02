#!/bin/bash

### BEGIN INIT INFO
# Provides: prltools-reconfig
# Required-Start:
# Required-Stop:
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: Parallels Tools Reconfiguration
# Description: Autostart script for Parallels Tools to adjust its configuration
### END INIT INFO

###########################################################################
# Autostart script for Parallels service that configure X server in guest.
#
# Copyright (c) 1999-2016 Parallels International GmbH.
# All rights reserved.
# http://www.parallels.com
###########################################################################


###
# chkconfig: 345 06 20
# description: Autostart script for Parallels service that configure X server in guest.
###

. "/usr/lib/parallels-tools/installer/prl-functions.sh"

PATH=${PATH:+$PATH:}/sbin:/bin:/usr/sbin:/usr/bin
pidfile="/var/run/prltools-reconfig.pid"
log="/var/log/parallels.log"

TOOLS_DIR="/usr/lib/parallels-tools"

[ ! -f $log ] && touch $log && chmod go+rw $log

start() {
	echo "Xorg processes:" >> "$log"
	ps -eo comm,args | grep Xorg | grep -v grep >> "$log"
	echo "End of Xorg processes" >> "$log"

	"$TOOLS_DIR/install" --reconfig ||
		echo "Error: Paralels Tools reconfiguration failed" >&2
}

# See how we were called.
case "$1" in
  start)
	echo "$$" > "$pidfile"
	start
	rm "$pidfile"
		;;
  stop)
	# Do nothing
		;;
  status)
	status "prltools-reconfig" "$pidfile"
		;;
  *)
		echo $"Usage: $0 {start|status|stop}"
		exit 1
esac

exit 0
