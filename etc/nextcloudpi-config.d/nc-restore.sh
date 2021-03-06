#!/bin/bash

#!/bin/bash
# Nextcloud restore backup
#
# Copyleft 2017 by Ignacio Nunez Hernanz <nacho _a_t_ ownyourbits _d_o_t_ com>
# GPL licensed (see end of file) * Use at your own risk!
#
# Usage:
# 
#   ./installer.sh nc-restore.sh <IP> (<img>)
#
# See installer.sh instructions for details
#
# More at https://ownyourbits.com/2017/02/13/nextcloud-ready-raspberry-pi-image/
#


BACKUPFILE_=/media/USBdrive/nextcloud-bkp_xxxxxxxx.tar
DBADMIN=ncadmin
DESCRIPTION="Restore a previously backuped NC instance"

INFOTITLE="Restore NextCloud backup"
INFO="This new installation will cleanup current
NextCloud instance, including files and database.

** perform backup before proceding **

You can use nc-backup"

configure()
{ 
  local DBPASSWD=$( grep password /root/.my.cnf | sed 's|password=||' )

  [ -f $BACKUPFILE_       ] || { echo "$BACKUPFILE_ not found"; return 1; }
  [ -d /var/www/nextcloud ] && { echo "INFO: overwriting old instance"  ; }

  local TMPDIR="$( dirname $BACKUPFILE_ )/$( basename ${BACKUPFILE_}-tmp )"
  rm -rf "$TMPDIR" && mkdir -p "$TMPDIR"

  # EXTRACT FILES
  [[ "$BACKUPFILE_" =~ ".tar.gz" ]] && local COMPRESSED=1 || local COMPRESSED=0
  [[ "$COMPRESSED" == "1" ]] && {
    echo "decompressing backup file $BACKUPFILE_..."
    tar -xzf "$BACKUPFILE_" -C "$TMPDIR" || return 1
    BACKUPFILE_="$( ls "$TMPDIR"/*.tar 2>/dev/null )"
    [[ -f "$BACKUPFILE_" ]] || { echo "$BACKUPFILE_ not found"; return 1; }
  }

  echo "extracting backup file $BACKUPFILE_..."
  tar -xf "$BACKUPFILE_" -C "$TMPDIR" || return 1

  ## SANITY CHECKS
  [[ -d "$TMPDIR"/nextcloud ]] && [[ -f "$( ls "$TMPDIR"/nextcloud-sqlbkp_*.bak 2>/dev/null )" ]] || {
    echo "invalid backup file. Abort"
    return 1
  }

  ## RESTORE FILES

  echo "restore files..."
  rm -rf /var/www/nextcloud
  mv "$TMPDIR"/nextcloud /var/www || { echo "Error restoring base files"; return 1; }

  # update NC database password to this instance
  sed -i "s|'dbpassword' =>.*|'dbpassword' => '$DBPASSWD',|" /var/www/nextcloud/config/config.php

  # update redis credentials
  local REDISPASS="$( grep "^requirepass" /etc/redis/redis.conf | cut -f2 -d' ' )"
  [[ "$REDISPASS" != "" ]] && \
    sed -i "s|'password'.*|'password' => '$REDISPASS',|" /var/www/nextcloud/config/config.php
  service redis restart

  ## RE-CREATE DATABASE TABLE

  echo "restore database..."
  mysql -u root <<EOF
DROP DATABASE IF EXISTS nextcloud;
CREATE DATABASE nextcloud;
GRANT USAGE ON *.* TO '$DBADMIN'@'localhost' IDENTIFIED BY '$DBPASSWD';
DROP USER '$DBADMIN'@'localhost';
CREATE USER '$DBADMIN'@'localhost' IDENTIFIED BY '$DBPASSWD';
GRANT ALL PRIVILEGES ON nextcloud.* TO $DBADMIN@localhost;
EXIT
EOF
  [ $? -ne 0 ] && { echo "Error configuring nextcloud database"; return 1; }

  mysql -u root nextcloud <  "$TMPDIR"/nextcloud-sqlbkp_*.bak || { echo "Error restoring nextcloud database"; return 1; }

  ## RESTORE DATADIR

  cd /var/www/nextcloud

  ### INCLUDEDATA=yes situation

  local NUMFILES=$(( 2 + COMPRESSED ))
  if [[ $( ls "$TMPDIR" | wc -l ) -eq $NUMFILES ]]; then

    local DATADIR=$( grep datadirectory /var/www/nextcloud/config/config.php | awk '{ print $3 }' | grep -oP "[^']*[^']" | head -1 ) 
    [[ "$DATADIR" == "" ]] && { echo "Error reading data directory"; return 1; }

    echo "restore datadir to $DATADIR..."

    [[ -e "$DATADIR" ]] && { 
      echo "backing up existing $DATADIR"
      mv "$DATADIR" "$DATADIR-$( date "+%m-%d-%y" )" || return 1
    }

    mkdir -p "$DATADIR"
    [[ "$( stat -fc%T "$DATADIR" )" == "btrfs" ]] && {
      rmdir "$DATADIR"                  || return 1
      btrfs subvolume create "$DATADIR" || return 1
    }
    chown www-data:www-data "$DATADIR"
    local TMPDATA="$TMPDIR/$( basename "$DATADIR" )"
    mv "$TMPDATA"/* "$TMPDATA"/.[!.]* "$DATADIR" || return 1
    rmdir "$TMPDATA"                             || return 1

    sudo -u www-data php occ maintenance:mode --off

  ### INCLUDEDATA=no situation

  else      
    echo "no datadir found in backup"
    local DATADIR=/var/www/nextcloud/data

    sudo -u www-data php occ maintenance:mode --off
    sudo -u www-data php occ files:scan --all

    # Just in case we moved the opcache dir
    sed -i "s|^opcache.file_cache=.*|opcache.file_cache=$DATADIR/.opcache|" /etc/php/7.0/mods-available/opcache.ini

    # cache needs to be cleaned as of NC 12
    bash -c " sleep 3
              systemctl stop php7.0-fpm
              systemctl stop mysqld
              sleep 0.5
              systemctl start php7.0-fpm
              systemctl start mysqld
              " &>/dev/null &
  fi

  # Just in case we moved the opcache dir
  sed -i "s|^opcache.file_cache=.*|opcache.file_cache=$DATADIR/.opcache|" /etc/php/7.0/mods-available/opcache.ini

  # update fail2ban logpath
  sed -i "s|logpath  =.*|logpath  = $DATADIR/nextcloud.log|" /etc/fail2ban/jail.conf
  pgrep fail2ban &>/dev/null && service fail2ban restart

  # refresh nextcloud trusted domains
  bash /usr/local/bin/nextcloud-domain.sh

  rm -r "$TMPDIR"
}

install() { :; }

# License
#
# This script is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This script is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this script; if not, write to the
# Free Software Foundation, Inc., 59 Temple Place, Suite 330,
# Boston, MA  02111-1307  USA

