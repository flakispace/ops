#!/bin/sh

set -e

echo_h1() {
  echo -e "\033[0;32m::\033[0m ${1}\033[0m"
}

echo_h2() {
  echo -e "\033[0;33m->\033[0;37m ${1}\033[0m"
}

echo_h3() {
  echo -e "\t${1}\033[0m"
}

get_branches() {
  BRANCHES=$(git -C $1 branch -r --color=never | grep tbc | sed 's/\*//' | awk '{ print $1 }')
  for b in $BRANCHES; do
    echo $(echo $b | sed 's_origin/__')
  done
}

get_db_version() {
  mysql -h ${1} -u ${2} -p${3} ${4} \
    -s -r -e "show create table ${5};" | \
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
  echo "missing mysql config (/etc/cmangos-update/${FLAVOR}.conf)"
  exit 3
fi
source /etc/cmangos-update/${FLAVOR}.conf

for repo in ${REPOS}; do
  S="/usr/src/${repo}"
  B="${S}/build"

  echo_h1 "update repo in \033[0;34m${S}"
  echo_h2 "fetch master"
  git -C $S checkout master &> /dev/null
  git -C $S pull upstream master
  git -C $S checkout -D ptr/$BUILD &> /dev/null || true
  git -C $S checkout -b ptr/$BUILD &> /dev/null

  for branch in $(get_branches $S); do
    echo_h2 "rebase \033[0;33m${branch}"
    git -C $S branch -D $branch &> /dev/null || true
    git -C $S fetch origin $branch
    git -C $S checkout $branch
    git -C $S rebase master

    echo_h2 "apply feature/bug \033[0;33m${branch}"
    git -C $S checkout ptr/$BUILD &> /dev/null
    git -C $S rebase $branch
  done
done

echo_h1 "build core and client files"
S="/usr/src/cmangos-${FLAVOR}"
D="/opt/cmangos-${FLAVOR}-${BUILD}"
rm -rf $B; install -d $B

echo_h2 "prepare build dir"
pushd $B
cmake .. \
  -DBUILD_PLAYERBOT=1 \
  -DBUILD_EXTRACTORS=1 \
  -DBUILD_GAME_SERVER=1 \
  -DBUILD_LOGIN_SERVER=1 \
  -DBUILD_SCRIPTDEV=1 \
  -DCMAKE_INSTALL_PREFIX=$D | systemd-cat -t ${JOURNALD_TARGET}

echo_h2 "build core"
make -j${CORES} | systemd-cat -t ${JOURNALD_TARGET}

echo_h2 "install core"
make install | systemd-cat -t ${JOURNALD_TARGET}
popd

echo_h2 "extract client files"
pushd $B/bin/tools
chmod u+x ExtractResources.sh MoveMapGen.sh
install -d /usr/share/cmangos/${CVER}-${BUILD}

if [ "${FLAVOR}" = "tbc" ]; then
  ./ExtractResources.sh a \
    /opt/clients/WoW-${CVER}-MultiLoc \
    /usr/share/cmangos/${CVER}-${BUILD} | systemd-cat -t ${JOURNALD_TARGET}
fi

popd

echo_h1 "update world server"
systemctl stop cmangos-${FLAVOR}
DBVER=$(get_db_version ${SQLHOST} ${SQLUSER} ${SQLPW} ${SQLDB} character_db_version)
echo_h2 "update char database from version \033[0;33m${DBVER}"
dbmatch=0

pushd $S/sql/updates/characters
for f in $(ls -1 *.sql | awk -F'.' '{ print $1 }'); do
  if [ $dbmatch -eq 0 ]; then
    if [ "$f" == "${DBVER}" ]; then
      dbmatch=1
    else
      continue
    fi
  else
    echo_h3 "apply char db update \033[0;33m${f}"
    mysql -h ${SQLHOST} -u ${SQLUSER} -p${SQLPW} ${SQLDB} < ${f}.sql
  fi
done
popd

echo_h2 "apply world db updates"
S="/usr/src/cmangos-${FLAVOR}-db"
pushd ${S}
./InstallFullDB.sh | systemd-cat -t ${JOURNALD_TARGET}
popd
