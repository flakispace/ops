#!/bin/bash

set -e

clean_db() {
  TABLES=$(mysql -h ${1} -u ${2} -p${3} ${4} -s -r -e "show tables;" 2> /dev/null)
  for t in ${TABLES}; do
    mysql -h ${1} -u ${2} -p${3} ${4} -s -r -e "drop table ${t};" 2>&1
  done
}

echo_h1() {
  echo -e "\033[0;32m::\033[0m ${1}\033[0m"
}

echo_h2() {
  echo -e "\033[0;33m ->\033[0;37m ${1}\033[0m"
}

echo_h3() {
  echo -e "\t${1}\033[0m"
}

get_branches() {
  BRANCHES=$(git -C $1 branch -r --color=never | grep $2 | sed 's/\*//' | awk '{ print $1 }')
  for b in $BRANCHES; do
    echo $(echo $b | sed 's_origin/__')
  done
}

get_db_version() {
  mysql -h ${1} -u ${2} -p${3} ${4} \
    -s -r -e "show create table ${5};" 2> /dev/null | \
    grep required | \
    awk '{ print $1 }' | \
    sed 's/`required_\(.*\)`/\1/'
}

usage() {
  echo "USAGE: $0 <flavor> [<cores>]"
  echo
  echo "flavor:		either vanilla, tbc or wotlk"
}

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  usage
  exit 1
fi

if [ "$1" != "vanilla" ] && [ "$1" != "tbc" ] && [ "$1" != "wotlk" ]; then
  usage
  exit 2
fi

JOURNALD_TARGET="cmangos-update"

FLAVOR="$1"
CORES="${2:-2}"
REPOS="cmangos-${FLAVOR} cmangos-${FLAVOR}-db cmangos-${FLAVOR}-db-localized"
BUILD=$(date +"%Y%m%d")

case $FLAVOR in
  "vanilla")
    CVER="1.12.1"
    ;;
  "tbc")
    CVER="2.4.3"
    ;;
  "wotlk")
    CVER="3.3.5a"
    ;;
esac

if [ ! -f /etc/cmangos-update/${FLAVOR}.conf ]; then
  echo "missing config (/etc/cmangos-update/${FLAVOR}.conf)"
  exit 3
fi
. /etc/cmangos-update/${FLAVOR}.conf

for repo in ${REPOS}; do
  S="/usr/src/${repo}"

  echo_h1 "update repo in \033[0;34m${S}"
  echo_h2 "fetch master"
  git -C $S checkout master &> /dev/null
  git -C $S pull upstream master | systemd-cat -t ${JOURNALD_TARGET}
  git -C $S branch -D ptr/$BUILD &> /dev/null || true
  git -C $S checkout -b ptr/$BUILD &> /dev/null

  for branch in $(get_branches $S ${FLAVOR}); do
    # workaround
    if [ "${branch}" = "tbc/bugfix/cmake_install_path" ]; then
      continue
    fi
    echo_h2 "rebase \033[0;33m${branch}"
    git -C $S branch -D $branch &> /dev/null || true
    git -C $S fetch origin $branch | systemd-cat -t ${JOURNALD_TARGET}
    git -C $S checkout $branch | systemd-cat -t ${JOURNALD_TARGET}
    git -C $S rebase master | systemd-cat -t ${JOURNALD_TARGET}

    echo_h2 "apply feature/bug \033[0;33m${branch}"
    git -C $S checkout ptr/$BUILD &> /dev/null
    git -C $S rebase $branch | systemd-cat -t ${JOURNALD_TARGET}
  done
done

echo_h1 "build core and client files"
S="/usr/src/cmangos-${FLAVOR}"
B="${S}/build"
D="/opt/cmangos-${FLAVOR}-${BUILD}"
rm -rf $B; install -d $B

echo_h2 "prepare build dir"
pushd $B &> /dev/null
cmake .. \
  -DBUILD_PLAYERBOT=${CMAKE_PLAYERBOT:-1} \
  -DBUILD_EXTRACTORS=${CMAKE_EXTRACTORS:-1} \
  -DBUILD_GAME_SERVER=${CMAKE_GAME_SERVER:-1} \
  -DBUILD_LOGIN_SERVER=${CMAKE_LOGIN_SERVER:-1} \
  -DBUILD_SCRIPTDEV=${CMAKE_SCRIPTDEV:-1} \
  -DDEBUG=${CMAKE_DEBUG:-1} \
  -DWARNINGS=${CMAKE_WARNINGS:-1}
  -DCMAKE_INSTALL_PREFIX=$D | systemd-cat -t ${JOURNALD_TARGET}

echo_h2 "build core"
make -j${CORES} | systemd-cat -t ${JOURNALD_TARGET}

echo_h2 "install core"
make install | systemd-cat -t ${JOURNALD_TARGET}
popd &> /dev/null

echo_h2 "extract client files"
pushd $D/bin/tools &> /dev/null
chmod u+x ExtractResources.sh MoveMapGen.sh
install -d /usr/share/cmangos/${CVER}-${BUILD}

if [ "${FLAVOR}" = "tbc" ]; then
  ./ExtractResources.sh a \
    /opt/clients/WoW-${CVER}-MultiLoc \
    /usr/share/cmangos/${CVER}-${BUILD} <<EOF | systemd-cat -t ${JOURNALD_TARGET}
${CORES}
y
y
EOF
fi

popd &> /dev/null

echo_h1 "update world server"
systemctl stop cmangos-${FLAVOR} || true
sleep 60

if [ "$SQLSYNC" = "1" ]; then
  echo_h2 "clone template database"
  clean_db ${SQLHOST} ${SQLUSER} ${SQLPW} ${SQLDBWORLD} | systemd-cat -t ${JOURNALD_TARGET}
  clean_db ${SQLHOST} ${SQLUSER} ${SQLPW} ${SQLDBCHARS} | systemd-cat -t ${JOURNALD_TARGET}
  mysqldump -h ${SYNCHOST} -u ${SYNCUSER} -p${SYNCPW} ${SYNCDBWORLD} 2> /dev/null | \
    mysql -h ${SQLHOST} -u ${SQLUSER} -p${SQLPW} ${SQLDBWORLD} 2>&1 | systemd-cat -t ${JOURNALD_TARGET}
  mysqldump -h ${SYNCHOST} -u ${SYNCUSER} -p${SYNCPW} ${SYNCDBCHARS} 2> /dev/null | \
    mysql -h ${SQLHOST} -u ${SQLUSER} -p${SQLPW} ${SQLDBCHARS} 2>&1 | systemd-cat -t ${JOURNALD_TARGET}
fi

DBVER=$(get_db_version ${SQLHOST} ${SQLUSER} ${SQLPW} ${SQLDBCHARS} character_db_version)
echo_h2 "update char database from version \033[0;33m${DBVER}"
dbmatch=0

pushd $S/sql/updates/characters &> /dev/null
for f in $(ls -1 *.sql | awk -F'.' '{ print $1 }'); do
  if [ $dbmatch -eq 0 ]; then
    if [ "$f" == "${DBVER}" ]; then
      dbmatch=1
    else
      continue
    fi
  else
    echo_h3 "apply char db update \033[0;33m${f}"
    mysql -h ${SQLHOST} -u ${SQLUSER} -p${SQLPW} ${SQLDB} < ${f}.sql 2>&1 | systemd-cat -t ${JOURNALD_TARGET}
  fi
done
popd &> /dev/null

echo_h2 "apply world db updates"
S="/usr/src/cmangos-${FLAVOR}-db"
pushd ${S} &> /dev/null
./InstallFullDB.sh | systemd-cat -t ${JOURNALD_TARGET}
popd &> /dev/null

cp /opt/cmangos-${FLAVOR}/etc/{ahbot.conf,playerbot.conf} /opt/cmangos-${FLAVOR}-${BUILD}/etc

ln -snf /opt/cmangos-${FLAVOR}-${BUILD} /opt/cmangos-${FLAVOR}
ln -snf /usr/share/cmangos/${CVER}-${BUILD} /usr/share/cmangos/${CVER}
systemctl start cmangos-${FLAVOR}

echo_h1 "cleanup old data"
echo_h2 "remove old client data"
pushd /usr/share/cmangos &> /dev/null
for v in $(ls -1 -d -r ${CVER}-* | tail -n +2); do
  echo_h3 "remove ${v}"
  rm -rf ${v}
done
popd &> /dev/null

echo_h2 "remove old server data"
pushd /opt &> /dev/null
for v in $(ls -1 -d -r cmangos-${FLAVOR}-* | tail -n +2); do
  echo_h3 "remove ${v}"
  rm -rf ${v}
done
popd &> /dev/null
