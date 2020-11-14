#!/bin/bash
#
# [Automatic installation on Linux for Kernel Video Sharing]
#
# GitHub : https://github.com/MaximeMichaud/KVS-install
# URL : https://www.kernel-video-sharing.com
#
# This script is intended for a quick and easy installation :
# wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/kvs-install.sh
# chmod +x kvs-install.sh
# ./kvs-install.sh
#
# KVS-install Copyright (c) 2020 Maxime Michaud
# Licensed under GNU General Public License v3.0
#################################################################################
#Colors
red=$(tput setaf 1)
green=$(tput setaf 2)
yellow=$(tput setaf 3)
cyan=$(tput setaf 6)
normal=$(tput sgr0)
alert=${white}${on_red}
#################################################################################
function isRoot() {
  if [ "$EUID" -ne 0 ]; then
    return 1
  fi
}

function initialCheck() {
  if ! isRoot; then
    echo "Sorry, you need to run this as root"
    exit 1
  fi
  checkOS
}

function checkOS() {
  if [[ -e /etc/debian_version ]]; then
    OS="debian"
    source /etc/os-release

    if [[ "$ID" == "debian" || "$ID" == "raspbian" ]]; then
      if [[ ! $VERSION_ID =~ (9|10|11) ]]; then
        echo "⚠️ ${alert}Your version of Debian is not supported.${normal}"
        echo ""
        echo "However, if you're using Debian >= 9 or unstable/testing then you can continue."
        echo "Keep in mind they are not supported, though.${normal}"
        echo ""
        until [[ $CONTINUE =~ (y|n) ]]; do
          read -rp "Continue? [y/n] : " -e CONTINUE
        done
        if [[ "$CONTINUE" == "n" ]]; then
          exit 1
        fi
      fi
    elif [[ "$ID" == "ubuntu" ]]; then
      OS="ubuntu"
      if [[ ! $VERSION_ID =~ (16.04|18.04|20.04) ]]; then
        echo "⚠️ ${alert}Your version of Ubuntu is not supported.${normal}"
        echo ""
        echo "However, if you're using Ubuntu > 17 or beta, then you can continue."
        echo "Keep in mind they are not supported, though.${normal}"
        echo ""
        until [[ $CONTINUE =~ (y|n) ]]; do
          read -rp "Continue? [y/n]: " -e CONTINUE
        done
        if [[ "$CONTINUE" == "n" ]]; then
          exit 1
        fi
      fi
    fi
  elif [[ -e /etc/fedora-release ]]; then
    OS=fedora
  elif [[ -e /etc/centos-release ]]; then
    if ! grep -qs "^CentOS Linux release 7" /etc/centos-release; then
      echo "${alert}Your version of CentOS is not supported.${normal}"
      echo "${red}Keep in mind they are not supported, though.${normal}"
      echo ""
      unset CONTINUE
      until [[ $CONTINUE =~ (y|n) ]]; do
        read -rp "Continue? [y/n] : " -e CONTINUE
      done
      if [[ "$CONTINUE" == "n" ]]; then
        exit 1
      fi
    fi
  else
    echo "Looks like you aren't running this script on a Debian, Ubuntu, Fedora or CentOS system ${normal}"
    exit 1
  fi
}

function script() {
  installQuestions
  aptupdate
  aptinstall
  aptinstall_nginx
  aptinstall_$database
  aptinstall_php
  #aptinstall_phpmyadmin
  #install_KVS
  install_ioncube
  setupdone

}
function installQuestions() {
  echo "${cyan}Welcome to KVS-install !"
  echo "https://github.com/MaximeMichaud/KVS-install"
  echo "I need to ask some questions before starting the configuration."
  echo "You can leave the default options and just press Enter if that's right for you."
  echo ""
  echo "${cyan}Which Version of PHP ?"
  echo "${red}Red = End of life ${yellow}| Yellow = Security fixes only ${green}| Green = Active support"
  echo "${green}   1) PHP 7.3 "
  echo "   2) PHP 7.4 (recommended) ${normal}${cyan}"
  until [[ "$PHP_VERSION" =~ ^[1-2]$ ]]; do
    read -rp "Version [1-2]: " -e -i 2 PHP_VERSION
  done
  case $PHP_VERSION in
  1)
    PHP="7.3"
    ;;
  2)
    PHP="7.4"
    ;;
  esac
  echo "Which type of database ?"
  echo "   1) MySQL"
  echo "   2) MariaDB"
  echo "   3) SQLite"
  until [[ "$DATABASE" =~ ^[1-3]$ ]]; do
    read -rp "Version [1-3]: " -e -i 1 DATABASE
  done
  case $DATABASE in
  1)
    database="mysql"
    ;;
  2)
    database="mariadb"
    ;;
  3)
    database="sqlite"
    ;;
  esac
  if [[ "$database" =~ (mysql) ]]; then
    echo "Which version of MySQL ?"
    echo "   1) MySQL 5.7"
    echo "   2) MySQL 8.0"
    until [[ "$DATABASE_VER" =~ ^[1-2]$ ]]; do
      read -rp "Version [1-2]: " -e -i 2 DATABASE_VER
    done
    case $DATABASE_VER in
    1)
      database_ver="5.7"
      ;;
    2)
      database_ver="8.0"
      ;;
    esac
  fi
  if [[ "$database" =~ (mariadb) ]]; then
    echo "Which version of MySQL ?"
    echo "${yellow}   1) MariaDB 10.3 (Old Stable)${normal}"
    echo "${yellow}   2) MariaDB 10.4 (Old Stable)${normal}"
    echo "${green}   3) MariaDB 10.5 (Stable)${normal}"
    until [[ "$DATABASE_VER" =~ ^[1-3]$ ]]; do
      read -rp "Version [1-3]: " -e -i 3 DATABASE_VER
    done
    case $DATABASE_VER in
    1)
      database_ver="10.3"
      ;;
    2)
      database_ver="10.4"
      ;;
    3)
      database_ver="10.5"
      ;;
    esac
  fi
  echo ""
  echo "We are ready to start the installation !"
  APPROVE_INSTALL=${APPROVE_INSTALL:-n}
  if [[ $APPROVE_INSTALL =~ n ]]; then
    read -n1 -r -p "Press any key to continue..."
  fi
}

function aptupdate() {
  apt-get update
}
function aptinstall() {
  apt-get -y install ca-certificates apt-transport-https dirmngr zip unzip lsb-release gnupg openssl curl wget memcached zlib1g-dev ffmpeg imagemagick
}

function aptinstall_nginx() {
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    echo "Nginx Installation"
    apt-key adv --fetch-keys 'https://nginx.org/keys/nginx_signing.key'
    if [[ "$VERSION_ID" == "9" ]]; then
      echo "deb https://nginx.org/packages/mainline/debian/ stretch nginx" >/etc/apt/sources.list.d/nginx.list
      echo "deb-src https://nginx.org/packages/mainline/debian/ stretch nginx" >>/etc/apt/sources.list.d/nginx.list
      apt-get update
      apt-get install nginx -y
    fi
    if [[ "$VERSION_ID" == "10" ]]; then
      echo "deb https://nginx.org/packages/mainline/debian/ buster nginx" >/etc/apt/sources.list.d/nginx.list
      echo "deb-src https://nginx.org/packages/mainline/debian/ buster nginx" >>/etc/apt/sources.list.d/nginx.list
      apt-get update
      apt-get install nginx -y
    fi
    if [[ "$VERSION_ID" == "11" ]]; then
      echo "deb https://nginx.org/packages/mainline/debian/ buster nginx" >/etc/apt/sources.list.d/nginx.list
      echo "deb-src https://nginx.org/packages/mainline/debian/ buster nginx" >>/etc/apt/sources.list.d/nginx.list
      apt-get update
      apt-get install nginx -y
    fi
    if [[ "$VERSION_ID" == "16.04" ]]; then
      echo "deb https://nginx.org/packages/mainline/ubuntu/ xenial nginx" >/etc/apt/sources.list.d/nginx.list
      echo "deb-src https://nginx.org/packages/mainline/ubuntu/ xenial nginx" >>/etc/apt/sources.list.d/nginx.list
      apt-get update
      apt-get install nginx -y
    fi
    if [[ "$VERSION_ID" == "18.04" ]]; then
      echo "deb https://nginx.org/packages/mainline/ubuntu/ bionic nginx" >/etc/apt/sources.list.d/nginx.list
      echo "deb-src https://nginx.org/packages/mainline/ubuntu/ bionic nginx" >>/etc/apt/sources.list.d/nginx.list
      apt-get update
      apt-get install nginx -y
    fi
    if [[ "$VERSION_ID" == "20.04" ]]; then
      echo "deb https://nginx.org/packages/mainline/ubuntu/ focal nginx" >/etc/apt/sources.list.d/nginx.list
      echo "deb-src https://nginx.org/packages/mainline/ubuntu/ focal nginx" >>/etc/apt/sources.list.d/nginx.list
      apt-get update
      apt-get install nginx -y
    fi
  fi
}

function aptinstall_mariadb() {
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    echo "MariaDB Installation"
    apt-key adv --fetch-keys 'https://mariadb.org/mariadb_release_signing_key.asc'
    if [[ "$VERSION_ID" == "9" ]]; then
      echo "deb [arch=amd64] https://ftp.igh.cnrs.fr/pub/mariadb/repo/$database_ver/debian stretch main" >/etc/apt/sources.list.d/mariadb.list
      apt-get update
      apt-get install mariadb-server -y
      systemctl enable mariadb && systemctl start mariadb
    fi
    if [[ "$VERSION_ID" == "10" ]]; then
      echo "deb [arch=amd64] https://ftp.igh.cnrs.fr/pub/mariadb/repo/$database_ver/debian buster main" >/etc/apt/sources.list.d/mariadb.list
      apt-get update
      apt-get install mariadb-server -y
      systemctl enable mariadb && systemctl start mariadb
    fi
    if [[ "$VERSION_ID" == "11" ]]; then
      echo "deb [arch=amd64] https://ftp.igh.cnrs.fr/pub/mariadb/repo/$database_ver/debian buster main" >/etc/apt/sources.list.d/mariadb.list
      apt-get update
      apt-get install mariadb-server -y
      systemctl enable mariadb && systemctl start mariadb
    fi
    if [[ "$VERSION_ID" == "16.04" ]]; then
      echo "deb [arch=amd64] https://ftp.igh.cnrs.fr/pub/mariadb/repo/$database_ver/debian xenial main" >/etc/apt/sources.list.d/mariadb.list
      apt-get update
      apt-get install mariadb-server -y
      systemctl enable mariadb && systemctl start mariadb
    fi
    if [[ "$VERSION_ID" == "18.04" ]]; then
      echo "deb [arch=amd64] https://ftp.igh.cnrs.fr/pub/mariadb/repo/$database_ver/debian bionic main" >/etc/apt/sources.list.d/mariadb.list
      apt-get update
      apt-get install mariadb-server -y
      systemctl enable mariadb && systemctl start mariadb
    fi
    if [[ "$VERSION_ID" == "20.04" ]]; then
      echo "deb [arch=amd64] https://ftp.igh.cnrs.fr/pub/mariadb/repo/$database_ver/debian focal main" >/etc/apt/sources.list.d/mariadb.list
      apt-get update
      apt-get install mariadb-server -y
      systemctl enable mariadb && systemctl start mariadb
    fi
  fi
}

function aptinstall_mysql() {
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    echo "MYSQL Installation"
    if [[ "$database_ver" == "8.0" ]]; then
      wget 'https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/mysql/default-auth-override.cnf' -P /etc/mysql/mysql.conf.d
    fi
    if [[ "$VERSION_ID" == "9" ]]; then
      echo "deb http://repo.mysql.com/apt/debian/ stretch mysql-$database_ver" >/etc/apt/sources.list.d/mysql.list
      echo "deb-src http://repo.mysql.com/apt/debian/ stretch mysql-$database_ver" >>/etc/apt/sources.list.d/mysql.list
      apt-key adv --keyserver keys.gnupg.net --recv-keys 8C718D3B5072E1F5
      apt-get update
      apt-get install mysql-server mysql-client -y
      systemctl enable mysql && systemctl start mysql
    fi
    if [[ "$VERSION_ID" == "10" ]]; then
      echo "deb http://repo.mysql.com/apt/debian/ buster mysql-$database_ver" >/etc/apt/sources.list.d/mysql.list
      echo "deb-src http://repo.mysql.com/apt/debian/ buster mysql-$database_ver" >>/etc/apt/sources.list.d/mysql.list
      apt-key adv --keyserver keys.gnupg.net --recv-keys 8C718D3B5072E1F5
      apt-get update
      apt-get install mysql-server mysql-client -y
      systemctl enable mysql && systemctl start mysql
    fi
    if [[ "$VERSION_ID" == "11" ]]; then
      echo "deb http://repo.mysql.com/apt/debian/ buster mysql-$database_ver" >/etc/apt/sources.list.d/mysql.list
      echo "deb-src http://repo.mysql.com/apt/debian/ buster mysql-$database_ver" >>/etc/apt/sources.list.d/mysql.list
      apt-key adv --keyserver keys.gnupg.net --recv-keys 8C718D3B5072E1F5
      apt-get update
      apt-get install mysql-server mysql-client -y
      systemctl enable mysql && systemctl start mysql
    fi
    if [[ "$VERSION_ID" == "16.04" ]]; then
      echo "deb http://repo.mysql.com/apt/ubuntu/ xenial mysql-$database_ver" >/etc/apt/sources.list.d/mysql.list
      echo "deb-src http://repo.mysql.com/apt/ubuntu/ xenial mysql-$database_ver" >>/etc/apt/sources.list.d/mysql.list
      apt-key adv --keyserver keys.gnupg.net --recv-keys 8C718D3B5072E1F5
      apt-get update
      apt-get install mysql-server mysql-client -y
      systemctl enable mysql && systemctl start mysql
    fi
    if [[ "$VERSION_ID" == "18.04" ]]; then
      echo "deb http://repo.mysql.com/apt/ubuntu/ bionic mysql-$database_ver" >/etc/apt/sources.list.d/mysql.list
      echo "deb-src http://repo.mysql.com/apt/ubuntu/ bionic mysql-$database_ver" >>/etc/apt/sources.list.d/mysql.list
      apt-key adv --keyserver keys.gnupg.net --recv-keys 8C718D3B5072E1F5
      apt-get update
      apt-get install mysql-server mysql-client -y
      systemctl enable mysql && systemctl start mysql
    fi
    if [[ "$VERSION_ID" == "20.04" ]]; then
      echo "deb http://repo.mysql.com/apt/ubuntu/ focal mysql-$database_ver" >/etc/apt/sources.list.d/mysql.list
      echo "deb-src http://repo.mysql.com/apt/ubuntu/ focal mysql-$database_ver" >>/etc/apt/sources.list.d/mysql.list
      apt-key adv --keyserver keys.gnupg.net --recv-keys 8C718D3B5072E1F5
      apt-get update
      apt-get install mysql-server mysql-client -y
      systemctl enable mysql && systemctl start mysql
    fi
  fi
}

function aptinstall_php() {
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    echo "PHP Installation"
    wget -q 'https://packages.sury.org/php/apt.gpg' -O- | apt-key add -
    if [[ "$VERSION_ID" == "9" ]]; then
      echo "deb https://packages.sury.org/php/ stretch main" | tee /etc/apt/sources.list.d/php.list
      apt-get update >/dev/null
      apt-get install php$PHP php$PHP-bcmath php$PHP-json php$PHP-mbstring php$PHP-common php$PHP-xml php$PHP-curl php$PHP-gd php$PHP-zip php$PHP-mysql php$PHP-sqlite php$PHP-fpm -y
      sed -i 's|upload_max_filesize = 2M|upload_max_filesize = 2000M|' /etc/php/$PHP/fpm/php.ini
      sed -i 's|post_max_size = 8M|post_max_size = 2000M|' /etc/php/$PHP/fpm/php.ini
      sed -i 's|memory_limit = 128M|memory_limit = 512M|' /etc/php/$PHP/fpm/php.ini
      systemctl restart nginx
    fi
    if [[ "$VERSION_ID" == "10" ]]; then
      echo "deb https://packages.sury.org/php/ buster main" | tee /etc/apt/sources.list.d/php.list
      apt-get update >/dev/null
      apt-get install php$PHP php$PHP-bcmath php$PHP-json php$PHP-mbstring php$PHP-common php$PHP-xml php$PHP-curl php$PHP-gd php$PHP-zip php$PHP-mysql php$PHP-sqlite php$PHP-fpm php$PHP-memcached -y
      sed -i 's|upload_max_filesize = 2M|upload_max_filesize = 2000M|' /etc/php/$PHP/fpm/php.ini
      sed -i 's|post_max_size = 8M|post_max_size = 2000M|' /etc/php/$PHP/fpm/php.ini
      sed -i 's|memory_limit = 128M|memory_limit = 512M|' /etc/php/$PHP/fpm/php.ini
      systemctl restart nginx
    fi
    if [[ "$VERSION_ID" == "11" ]]; then
      echo "deb https://packages.sury.org/php/ buster main" | tee /etc/apt/sources.list.d/php.list
      apt-get update >/dev/null
      apt-get install php$PHP php$PHP-bcmath php$PHP-json php$PHP-mbstring php$PHP-common php$PHP-xml php$PHP-curl php$PHP-gd php$PHP-zip php$PHP-mysql php$PHP-sqlite php$PHP-fpm -y
      sed -i 's|upload_max_filesize = 2M|upload_max_filesize = 2000M|' /etc/php/$PHP/fpm/php.ini
      sed -i 's|post_max_size = 8M|post_max_size = 2000M|' /etc/php/$PHP/fpm/php.ini
      sed -i 's|memory_limit = 128M|memory_limit = 512M|' /etc/php/$PHP/fpm/php.ini
      systemctl restart nginx
    fi
    if [[ "$VERSION_ID" == "16.04" ]]; then
      add-apt-repository -y ppa:ondrej/php
      apt-get update >/dev/null
      apt-get install php$PHP php$PHP-bcmath php$PHP-json php$PHP-mbstring php$PHP-common php$PHP-xml php$PHP-curl php$PHP-gd php$PHP-zip php$PHP-mysql php$PHP-sqlite php$PHP-fpm -y
      sed -i 's|upload_max_filesize = 2M|upload_max_filesize = 2000M|' /etc/php/$PHP/fpm/php.ini
      sed -i 's|post_max_size = 8M|post_max_size = 2000M|' /etc/php/$PHP/fpm/php.ini
      sed -i 's|memory_limit = 128M|memory_limit = 512M|' /etc/php/$PHP/fpm/php.ini
      systemctl restart nginx
    fi
    if [[ "$VERSION_ID" == "18.04" ]]; then
      add-apt-repository -y ppa:ondrej/php
      apt-get update >/dev/null
      apt-get install php$PHP php$PHP-bcmath php$PHP-json php$PHP-mbstring php$PHP-common php$PHP-xml php$PHP-curl php$PHP-gd php$PHP-zip php$PHP-mysql php$PHP-sqlite php$PHP-fpm -y
      sed -i 's|upload_max_filesize = 2M|upload_max_filesize = 2000M|' /etc/php/$PHP/fpm/php.ini
      sed -i 's|post_max_size = 8M|post_max_size = 2000M|' /etc/php/$PHP/fpm/php.ini
      sed -i 's|memory_limit = 128M|memory_limit = 512M|' /etc/php/$PHP/fpm/php.ini
      systemctl restart nginx
    fi
    if [[ "$VERSION_ID" == "20.04" ]]; then
      add-apt-repository -y ppa:ondrej/php
      apt-get update >/dev/null
      apt-get install php$PHP php$PHP-bcmath php$PHP-json php$PHP-mbstring php$PHP-common php$PHP-xml php$PHP-curl php$PHP-gd php$PHP-zip php$PHP-mysql php$PHP-sqlite php$PHP-fpm -y
      sed -i 's|upload_max_filesize = 2M|upload_max_filesize = 2000M|' /etc/php/$PHP/fpm/php.ini
      sed -i 's|post_max_size = 8M|post_max_size = 2000M|' /etc/php/$PHP/fpm/php.ini
      sed -i 's|memory_limit = 128M|memory_limit = 512M|' /etc/php/$PHP/fpm/php.ini
      systemctl restart nginx
    fi
  fi
}

function aptinstall_phpmyadmin() {
  echo "phpMyAdmin Installation"
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    mkdir /usr/share/phpmyadmin/ || exit
    cd /usr/share/phpmyadmin/ || exit
    PHPMYADMIN_VER=$(curl -s "https://api.github.com/repos/phpmyadmin/phpmyadmin/releases/latest" | grep -m1 '^[[:blank:]]*"name":' | cut -d \" -f 4)
    wget 'https://files.phpmyadmin.net/phpMyAdmin/$PHPMYADMIN_VER/phpMyAdmin-$PHPMYADMIN_VER-all-languages.tar.gz'
    tar xzf phpMyAdmin-$PHPMYADMIN_VER-all-languages.tar.gz
    mv phpMyAdmin-$PHPMYADMIN_VER-all-languages/* /usr/share/phpmyadmin
    rm /usr/share/phpmyadmin/phpMyAdmin-$PHPMYADMIN_VER-all-languages.tar.gz
    rm -rf /usr/share/phpmyadmin/phpMyAdmin-$PHPMYADMIN_VER-all-languages
    # Create TempDir
    mkdir /usr/share/phpmyadmin/tmp || exit
    chown www-data:www-data /usr/share/phpmyadmin/tmp
    chmod 700 /usr/share/phpmyadmin/tmp
    randomBlowfishSecret=$(openssl rand -base64 32)
    sed -e "s|cfg\['blowfish_secret'\] = ''|cfg['blowfish_secret'] = '$randomBlowfishSecret'|" config.sample.inc.php >config.inc.php
    wget 'https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/phpmyadmin.conf'
    ln -s /usr/share/phpmyadmin /var/www/phpmyadmin
    mv phpmyadmin.conf /etc/apache2/sites-available/
    a2ensite phpmyadmin
    systemctl restart apache2
  elif [[ "$OS" =~ (centos|amzn) ]]; then
    echo "No Support"
  elif [[ "$OS" == "fedora" ]]; then
    echo "No Support"
  fi
}

function install_KVS() {
  rm -rf /var/www/html/
  mkdir /var/www/html
  cd /var/www/html || exit
  unzip KVSInstaller.zip
  rm -rf KVSInstaller.zip
  chmod -R 755 /var/www/html
  chown -R www-data:www-data /var/www/html
}

function install_ioncube() {
  wget 'https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz'
  tar -xvzf ioncube_loaders_lin_x86-64.tar.gz
  cd ioncube && cp ioncube_loader_lin_$PHP.so /usr/lib/php/20190902/
  echo "zend_extension=/usr/lib/php/20190902/ioncube_loader_lin_$PHP.so" >>/etc/php/$PHP/apache2/php.ini
  echo "zend_extension=/usr/lib/php/20190902/ioncube_loader_lin_$PHP.so" >>/etc/php/$PHP/cli/php.ini
  systemctl restart apache2
}

#function install_cron() {
#Disabled for the moment
#cd /var/www/html || exit
#apt-get install cron -y
#crontab -l > cron
#wget -O cron 'https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/cron/cron'
#crontab cron
#rm cron
#}

#function mod_cloudflare() {
#Disabled for the moment
#a2enmod remoteip
#cd /etc/apache2 || exit
#wget 'https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/cloudflare/apache2.conf'
#wget 'https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/cloudflare/000-default.conf'
#cd /etc/apache2/conf-available || exit
#wget 'https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/cloudflare/remoteip.conf'
#systemctl restart apache2
#}

#function autoUpdate() {
#Disable for the moment
#echo "Enable Automatic Updates..."
#apt-get install -y unattended-upgrades
#}

function setupdone() {
  IP=$(curl 'https://api.ipify.org')
  echo "It done!"
  echo "Configuration Database/User: http://$IP/"
  echo "phpMyAdmin: http://$IP/phpmyadmin"
  echo "For the moment, If you choose to use MariaDB, you will need to execute ${cyan}mysql_secure_installation${normal} for setting the password"
}
function manageMenu() {
  clear
  echo "Welcome to KVS-install !"
  echo "https://github.com/MaximeMichaud/KVS-install"
  echo ""
  echo "It seems that the Script has already been used in the past."
  echo ""
  echo "What do you want to do ?"
  echo "   1) Restart the installation"
  echo "   2) Update phpMyAdmin"
  echo "   3) Update the Script"
  echo "   4) Quit"
  until [[ "$MENU_OPTION" =~ ^[1-4]$ ]]; do
    read -rp "Select an option [1-4] : " MENU_OPTION
  done
  case $MENU_OPTION in
  1)
    install_KVS
    ;;
  2)
    updatephpMyAdmin
    ;;
  3)
    update
    ;;
  5)
    exit 0
    ;;
  esac
}

function update() {
  wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/kvs-install.sh -O kvs-install.sh
  chmod +x kvs-install.sh
  echo ""
  echo "Update Done."
  sleep 2
  ./kvs-install.sh
  exit
}

function updatephpMyAdmin() {
  rm -rf /usr/share/phpmyadmin/
  mkdir /usr/share/phpmyadmin/
  cd /usr/share/phpmyadmin/ || exit
  wget https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip
  unzip phpMyAdmin-latest-all-languages.zip
  PHPMYADMIN_VER=$(curl -s "https://api.github.com/repos/phpmyadmin/phpmyadmin/releases/latest" | grep -m1 '^[[:blank:]]*"name":' | cut -d \" -f 4)
  mv phpMyAdmin-$PHPMYADMIN_VER-all-languages/* /usr/share/phpmyadmin
  rm /usr/share/phpmyadmin/phpMyAdmin-latest-all-languages.zip
  rm -rf /usr/share/phpmyadmin/phpMyAdmin-$PHPMYADMIN_VER-all-languages
  # Create TempDir
  mkdir /usr/share/phpmyadmin/tmp || exit
  chown www-data:www-data /usr/share/phpmyadmin/tmp
  chmod 700 /var/www/phpmyadmin/tmp
  randomBlowfishSecret=$(openssl rand -base64 32)
  sed -e "s|cfg\['blowfish_secret'\] = ''|cfg['blowfish_secret'] = '$randomBlowfishSecret'|" config.sample.inc.php >config.inc.php
}

initialCheck

if [[ -e /var/www/html/app/ ]]; then
  manageMenu
else
  script
fi
