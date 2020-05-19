#!/bin/sh

set -e

JOURNALD_TARGET="sysupdate"

export DEBIAN_FRONTEND="noninteractive"

apt-get -y update | systemd-cat -t $JOURNALD_TARGET
apt-get -y upgrade | systemd-cat -t $JOURNALD_TARGET

pids=$(lsof +c 0 | grep 'DEL.*lib' | awk '{ print $2 }' | sort -u)
if [ "x$pids" != "x" ]; then
  systemctl daemon-reload | systemd-cat -t $JOURNALD_TARGET
fi

for pid in $pids; do
  if [ $pid -eq 1 ]; then
    echo "restarting systemd" | systemd-cat -t $JOURNALD_TARGET
    systemctl daemon-reexec | systemd-cat -t $JOURNALD_TARGET
  else
    systemctl restart $pid | systemd-cat -t $JOURNALD_TARGET
  fi
done

# still missing libs?
pids=$(lsof +c 0 | grep 'DEL.*lib' | awk '{ print $2 }' | sort -u)
if [ "x$pids" != "x" ]; then
  echo "reboot enforced according to missing libs" | systemd-cat -t $JOURNALD_TARGET
  reboot
fi
