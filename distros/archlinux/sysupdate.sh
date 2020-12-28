#!/bin/sh

set -e

JOURNALD_TARGET="sysupdate"

lxc_update() {
# update lxc containers
  if [ -x /usr/bin/lxc-ls ]; then
    echo "update lxc containers"
    for lxc in $(lxc-ls); do
      lxc-attach -n $lxc -- /bin/su -l -c "/usr/local/bin/sysupdate.sh" || true
      lxc-stop -n $lxc || true
      lxc-start -n $lxc || true
    done
  fi
}

lxc_update | systemd-cat -t $JOURNALD_TARGET
pacman -Syu --noconfirm | systemd-cat -t $JOURNALD_TARGET

# check kernel version
kinst=$(pacman -Q linux | awk '{ print $2 }' | sed 's/\.arch/-arch/')
krun=$(uname -r)
if [ "$kinst" != "$krun" ]; then
  echo "reboot enforced according to kernel update ($krun -> $kinst)" | systemd-cat -t $JOURNALD_TARGET
  reboot
fi

# check missing libs
pids=$(lsof +c 0 | grep 'DEL.*lib' | awk '{ print $2 }' | sort -u)
if [ "x$pids" != "x" ]; then
  systemctl daemon-reload | systemd-cat -t $JOURNALD_TARGET
fi

for pid in $pids; do
  if [ $pid -eq 1 ]; then
    echo "restarting systemd" | systemd-cat -t $JOURNALD_TARGET
    systemctl daemon-reexec | systemd-cat -t $JOURNALD_TARGET
  else
    systemctl restart $pid | systemd-cat -t $JOURNALD_TARGET || true
  fi
done

# still missing libs?
pids=$(lsof +c 0 | grep 'DEL.*lib' | awk '{ print $2 }' | sort -u)
if [ "x$pids" != "x" ]; then
  echo "reboot enforced according to missing libs" | systemd-cat -t $JOURNALD_TARGET
  reboot
fi
