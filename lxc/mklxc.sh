#!/bin/sh

set -e

if [ $# -ne 4 ]; then
  echo "USAGE: $0 <distro> <hostname> <ip> <gw>"
  exit 1
fi

BASEDIR="/var/lib/lxc/${2}"

# choose distro
if [ "$1" = "archlinux" ]; then
  opts="-d archlinux -r current -a amd64"
elif [ "$1" = "debian" ]; then
  opts="-d debian -r buster -a amd64"
elif [ "$1" = "ubuntu" ]; then
  opts="-d ubuntu -r focal -a amd64"
elif [ "$1" = "opensuse" ]; then
  opts="-d opensuse -r 15.1 -a amd64"
else
  echo "no such distro"
  exit 1
fi


lxc-create -n $2 -t download -- ${opts}
cat >> ${BASEDIR}/config <<EOF
lxc.net.0.ipv4.address = ${3}
lxc.net.0.ipv4.gateway = ${4}

lxc.start.auto = 1
EOF

install -d -m 0700 ${BASEDIR}/rootfs/root/.ssh
install -m 0600 /root/.ssh/authorized_keys ${BASEDIR}/rootfs/root/.ssh/authorized_keys

install -m 0644 /etc/resolv.conf ${BASEDIR}/rootfs/etc/resolv.conf

if [ "$1" = "archlinux" ] || [ "$1" = "ubuntu" ]; then
  ln -s /dev/null ${BASEDIR}/rootfs/etc/systemd/system/systemd-networkd.service || true
  systemctl disable systemd-resolved || true
  systemctl stop systemd-resolved || true
fi

lxc-start -n $2
if [ "$1" = "archlinux" ]; then
  lxc-attach -n $2 --clear-env -- /bin/su -l -c "pacman -Sy --noconfirm openssh"
  lxc-attach -n $2 --clear-env -- /bin/su -l -c "systemctl enable sshd"
  lxc-attach -n $2 --clear-env -- /bin/su -l -c "systemctl start sshd"
elif [ "$1" = "ubuntu" ] || [ "$1" = "debian" ]; then
  lxc-attach -n $2 --clear-env -- /bin/su -l -c "apt-get -y install openssh-server less"
elif [ "$1" = "opensuse" ]; then
  lxc-attach -n $2 --clear-env -- /bin/su -l -c "zypper -n install openssh less vim"
  lxc-attach -n $2 --clear-env -- /bin/su -l -c "systemctl enable sshd"
  lxc-attach -n $2 --clear-env -- /bin/su -l -c "systemctl start sshd"
fi
