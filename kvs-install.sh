#!/bin/bash
#
# [Automatic installation on Linux for Kernel Video Sharing]
#
# GitHub : https://github.com/MaximeMichaud/KVS-install
# URL : https://www.kernel-video-sharing.com
#
# This script is intended for a quick and easy installation :
# bash <(curl -s https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/kvs-install.sh)
#
# KVS-install Copyright (c) 2020-2022 Maxime Michaud
# Licensed under GNU General Public License v3.0
#################################################################################
#Colors
red=$(tput setaf 1)
green=$(tput setaf 2)
yellow=$(tput setaf 3)
cyan=$(tput setaf 6)
white=$(tput setaf 7)
normal=$(tput sgr0)
alert=${white}${on_red}
on_red=$(tput setab 1)
# Define installation parameters for headless install (fallback if unspecifed)
if [[ $HEADLESS == "y" ]]; then
  # Define options
  PHP=7.4
  webserver=nginx
  nginx_branch=mainline
  database=mariadb
  database_ver=10.6
fi
MYSQL_USER="$DOMAIN"
MYSQL_PASSWORD="password"
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
      if [[ ! $VERSION_ID =~ (10|11) ]]; then
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
      if [[ ! $VERSION_ID =~ (20.04|22.04) ]]; then
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
  else
    echo "Looks like you aren't running this script on a Debian, Ubuntu or CentOS system ${normal}"
    exit 1
  fi
}

function script() {
  installQuestions
  aptupdate
  aptinstall
  install_yt-dlp
  aptinstall_php
  aptinstall_nginx
  aptinstall_"$database"
  aptinstall_phpmyadmin
  install_KVS
  install_ioncube
  insert_cronjob
  autoUpdate
  setupdone

}
function installQuestions() {
  if [[ $HEADLESS != "y" ]]; then
    echo "${cyan}Welcome to KVS-install !"
    echo "https://github.com/MaximeMichaud/KVS-install"
    echo "I need to ask some questions before starting the configuration."
    echo "You can leave the default options and just press Enter if that's right for you."
    echo ""
    echo "${cyan}What is your DOMAIN which will be use for KVS ?"
    read -r DOMAIN
    echo "${cyan}Do you want to create a SSL certs ?"

    echo "${cyan}Which Version of PHP ?"
    echo "${red}Red = End of life ${yellow}| Yellow = Security fixes only ${green}| Green = Active support"
    echo "${yellow}    1) PHP 7.4 (recommended) ${normal}${cyan}"
    echo "${red}    2) PHP 7.3 ${normal}${cyan}"
    until [[ "$PHP_VERSION" =~ ^[1-2]$ ]]; do
      read -rp "Version [1-2]: " -e -i 1 PHP_VERSION
    done
    case $PHP_VERSION in
    #1) PHP 8.0 not supported in KVS
    #PHP="8.0"
    #;;
    1)
      PHP="7.4"
      ;;
    2)
      PHP="7.3"
      ;;
    esac
    echo "Which branch of NGINX ?"
    echo "   1) Mainline"
    echo "   2) Stable"
    until [[ "$NGINX_BRANCH" =~ ^[1-2]$ ]]; do
      read -rp "Version [1-2]: " -e -i 1 NGINX_BRANCH
    done
    case $NGINX_BRANCH in
    1)
      nginx_branch="mainline"
      ;;
    2)
      nginx_branch="stable"
      ;;
    esac
    echo "Which type of database ?"
    echo "   1) MariaDB"
    echo "   2) MySQL"
    until [[ "$DATABASE" =~ ^[1-2]$ ]]; do
      read -rp "Version [1-2]: " -e -i 1 DATABASE
    done
    case $DATABASE in
    1)
      database="mariadb"
      ;;
    2)
      database="mysql"
      ;;
    esac
    if [[ "$database" =~ (mysql) ]]; then
      echo "Which version of MySQL ?"
      echo "${green}   1) MySQL 8.0 ${normal}"
      echo "${red}   2) MySQL 5.7 ${normal}${cyan}"
      until [[ "$DATABASE_VER" =~ ^[1-2]$ ]]; do
        read -rp "Version [1-2]: " -e -i 1 DATABASE_VER
      done
      case $DATABASE_VER in
      1)
        database_ver="8.0"
        ;;
      2)
        database_ver="5.7"
        ;;
      esac
    fi
    if [[ "$database" =~ (mariadb) ]]; then
      echo "Which version of MariaDB ?"
      echo "${green}   1) MariaDB 10.6 (Stable)${normal}"
      echo "${yellow}   2) MariaDB 10.5 (Old Stable)${normal}"
      echo "${yellow}   3) MariaDB 10.4 (Old Stable)${normal}"
      echo "${yellow}   4) MariaDB 10.3 (Old Stable)${normal}${cyan}"
      until [[ "$DATABASE_VER" =~ ^[1-4]$ ]]; do
        read -rp "Version [1-4]: " -e -i 1 DATABASE_VER
      done
      case $DATABASE_VER in
      1)
        database_ver="10.6"
        ;;
      2)
        database_ver="10.5"
        ;;
      3)
        database_ver="10.4"
        ;;
      4)
        database_ver="10.3"
        ;;
      esac
    fi
    echo ""
    echo "We are ready to start the installation !"
    APPROVE_INSTALL=${APPROVE_INSTALL:-n}
    if [[ $APPROVE_INSTALL =~ n ]]; then
      read -n1 -r -p "Press any key to continue..."
    fi
  fi
}

function aptupdate() {
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    apt-get update
  elif [[ "$OS" == "centos" ]]; then
    echo "No Support"
  fi
}
function aptinstall() {
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    apt-get -y install ca-certificates apt-transport-https dirmngr zip unzip lsb-release gnupg openssl curl imagemagick ffmpeg wget sudo
  elif [[ "$OS" == "centos" ]]; then
    echo "No Support"
  fi
}

function install_yt-dlp() {
    sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
    sudo chmod a+rx /usr/local/bin/yt-dlp
}

function aptinstall_nginx() {
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    echo "NGINX Installation"
    apt-key adv --fetch-keys 'https://nginx.org/keys/nginx_signing.key'
    if [[ "$VERSION_ID" =~ (10|11|20.04|22.04) ]]; then
      echo "deb https://nginx.org/packages/$nginx_branch/$OS/ $(lsb_release -sc) nginx" >/etc/apt/sources.list.d/nginx.list
      echo "deb-src https://nginx.org/packages/$nginx_branch/$OS/ $(lsb_release -sc) nginx" >>/etc/apt/sources.list.d/nginx.list
      apt-get update && apt-get install nginx -y
	  mkdir /etc/nginx/globals
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/nginx.conf -O /etc/nginx/nginx.conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/general.conf -O /etc/nginx/globals/general.conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/security.conf -O /etc/nginx/globals/security.conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/php_fastcgi.conf -O /etc/nginx/globals/php_fastcgi.conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/letsencrypt.conf -O /etc/nginx/globals/letsencrypt.conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/cloudflare-ip-list.conf -O /etc/nginx/globals/cloudflare-ip-list.conf
      openssl dhparam -out /etc/nginx/dhparam.pem 2048
      #update CF IPV4/V6
      #wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/update-cloudflare-ip-list.sh -O /etc/nginx/scripts/update-cloudflare-ip-list.sh
    fi
  elif [[ "$OS" == "centos" ]]; then
    echo "No Support"
  fi
}

function aptinstall_mariadb() {
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    echo "MariaDB Installation"
    curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | sudo bash -s -- --mariadb-server-version="mariadb-$database_ver"
	apt-get install mariadb-server -y
    systemctl enable mariadb && systemctl start mariadb
	rm -f /etc/apt/sources.list.d/mariadb.list.old*
    fi
}

function aptinstall_mysql() {
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    echo "MYSQL Installation"
    if [[ "$database_ver" == "8.0" ]]; then
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/master/conf/mysql/default-auth-override.cnf -P /etc/mysql/mysql.conf.d
    fi
    if [[ "$VERSION_ID" =~ (10|11|20.04|22.04) ]]; then
      echo "deb https://repo.mysql.com/apt/$ID/ $(lsb_release -sc) mysql-$database_ver" >/etc/apt/sources.list.d/mysql.list
      echo "deb-src https://repo.mysql.com/apt/$ID/ $(lsb_release -sc) mysql-$database_ver" >>/etc/apt/sources.list.d/mysql.list
      apt-key adv --keyserver keys.gnupg.net --recv-keys 8C718D3B5072E1F5
      apt-get update && apt-get install mysql-server mysql-client -y
      systemctl enable mysql && systemctl start mysql
    elif [[ "$OS" == "centos" ]]; then
      echo "No Support"
    fi
  fi
}

function aptinstall_php() {
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    echo "PHP Installation"
    curl -sSL -o /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
    if [[ "$webserver" =~ (nginx) ]]; then
      if [[ "$VERSION_ID" =~ (10|11) ]]; then
        echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list
      fi
      if [[ "$VERSION_ID" =~ (20.04|22.04) ]]; then
        add-apt-repository -y ppa:ondrej/php
      fi
    fi
    apt-get update && apt-get install php$PHP{,-bcmath,-mbstring,-common,-xml,-curl,-gd,-zip,-mysql,-fpm,-imagick,-memcache} -y
    sed -i 's|upload_max_filesize = 2M|upload_max_filesize = 2048M|' /etc/php/$PHP/fpm/php.ini
    sed -i 's|post_max_size = 8M|post_max_size = 2048M|' /etc/php/$PHP/fpm/php.ini
    sed -i 's|memory_limit = 128M|memory_limit = 512M|' /etc/php/$PHP/fpm/php.ini
    sed -i 's|;max_input_vars = 1000|max_input_vars = 10000|' /etc/php/$PHP/fpm/php.ini
    systemctl restart nginx
  fi
}

function aptinstall_phpmyadmin() {
  echo "phpMyAdmin Installation"
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    PHPMYADMIN_VER=$(curl -s "https://api.github.com/repos/phpmyadmin/phpmyadmin/releases/latest" | grep -m1 '^[[:blank:]]*"name":' | cut -d \" -f 4)
    mkdir -p /usr/share/phpmyadmin/ || exit
    wget https://files.phpmyadmin.net/phpMyAdmin/"$PHPMYADMIN_VER"/phpMyAdmin-"$PHPMYADMIN_VER"-all-languages.tar.gz -O /usr/share/phpmyadmin/phpMyAdmin-"$PHPMYADMIN_VER"-all-languages.tar.gz
    tar xzf /usr/share/phpmyadmin/phpMyAdmin-"$PHPMYADMIN_VER"-all-languages.tar.gz --strip-components=1 --directory /usr/share/phpmyadmin
    rm -f /usr/share/phpmyadmin/phpMyAdmin-"$PHPMYADMIN_VER"-all-languages
    # Create phpMyAdmin TempDir
    mkdir -p /usr/share/phpmyadmin/tmp || exit
    chown www-data:www-data /usr/share/phpmyadmin/tmp
    chmod 700 /usr/share/phpmyadmin/tmp
    randomBlowfishSecret=$(openssl rand -base64 22)
    sed -e "s|cfg\['blowfish_secret'\] = ''|cfg['blowfish_secret'] = '$randomBlowfishSecret'|" /usr/share/phpmyadmin/config.sample.inc.php >/usr/share/phpmyadmin/config.inc.php
    wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/phpmyadmin.conf
    ln -s /usr/share/phpmyadmin /var/www/phpmyadmin
    if [[ "$webserver" =~ (nginx) ]]; then
      apt-get update && apt-get install php7.4{,-bcmath,-mbstring,-common,-xml,-curl,-gd,-zip,-mysql,-fpm} -y
      service nginx restart
    fi
  elif [[ "$OS" == "centos" ]]; then
    echo "No Support"
  fi
}

function install_KVS() {
  if [[ "$OS" =~ (debian|ubuntu|centos) ]]; then
    mkdir -p /var/www/"$DOMAIN"
    mv KVS_* /var/www/"$DOMAIN"
    cd /var/www/"$DOMAIN" && unzip -o /var/www/"$DOMAIN"/KVS_*
    rm -r /var/www/"$DOMAIN"/KVS_*
    chown -R www-data:www-data /var/www/"$DOMAIN"
    chmod -R 755 /var/www/"$DOMAIN"
    sed -i '/xargs chmod 666/d' /var/www/"$DOMAIN"/_INSTALL/install_permissions.sh
    cd _INSTALL && /var/www/"$DOMAIN"/_INSTALL/install_permissions.sh
    sed -i "s|/PATH|/var/www/"$DOMAIN"|" /var/www/"$DOMAIN"/admin/include/setup.php
    sed -i "s|/usr/local/bin/|/usr/bin/|" /var/www/"$DOMAIN"/admin/include/setup.php
    sed -i "s|/usr/bin/php|/usr/bin/php$PHP|" /var/www/$DOMAIN/admin/include/setup.php
    sed -i "s|KVS|$DOMAIN|" /var/www/"$DOMAIN"/admin/include/setup.php
    #CREATE DATABASE $DOMAIN CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
    #CREATE USER '$DOMAIN'@'localhost' IDENTIFIED BY 'password'
    #GRANT ALL PRIVILEGES ON $DOMAIN.* TO '$DOMAIN'@'localhost'
    #FLUSH PRIVILEGES
  fi
}

insert_cronjob() {
  echo "* Installing cronjob.. "

  crontab -l | {
    cat
    echo "#KVS"
    echo "* * * * * cd /var/www/$DOMAIN/admin/include && /usr/bin/php$PHP cron.php > /dev/null 2>&1"
  } | crontab -

  echo "* Cronjob installed!"
}

function install_ioncube() {
  if [[ "$OS" =~ (debian|ubuntu|centos) ]]; then
    wget 'https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz'
    tar -xvzf ioncube_loaders_lin_x86-64.tar.gz
    cd ioncube && cp ioncube_loader_lin_$PHP.so /usr/lib/php/20190902/
    echo "zend_extension=/usr/lib/php/20190902/ioncube_loader_lin_$PHP.so" >>/etc/php/$PHP/fpm/php.ini
    echo "zend_extension=/usr/lib/php/20190902/ioncube_loader_lin_$PHP.so" >>/etc/php/$PHP/cli/php.ini
    systemctl restart php7.4-fpm
  fi
}

function autoUpdate() {
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    echo "Enable Automatic Updates..."
    apt-get install -y unattended-upgrades
  elif [[ "$OS" == "centos" ]]; then
    echo "No Support"
  fi
}

function setupdone() {
  IP=$(curl 'https://api.ipify.org')
  echo "${cyan}It done!"
  echo "${cyan}Configuration Database/User: ${red}http://$IP/"
  echo "${cyan}phpMyAdmin: ${red}http://$IP/phpmyadmin"
  echo "${cyan}For the moment, If you choose to use MariaDB, you will need to execute ${normal}${on_red}${white}mysql_secure_installation${normal}${cyan} for setting the password"
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
    script
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
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    rm -rf /usr/share/phpmyadmin/*
    cd /usr/share/phpmyadmin/ || exit
    PHPMYADMIN_VER=$(curl -s "https://api.github.com/repos/phpmyadmin/phpmyadmin/releases/latest" | grep -m1 '^[[:blank:]]*"name":' | cut -d \" -f 4)
    wget https://files.phpmyadmin.net/phpMyAdmin/"$PHPMYADMIN_VER"/phpMyAdmin-"$PHPMYADMIN_VER"-all-languages.tar.gz -O /usr/share/phpmyadmin/phpMyAdmin-"$PHPMYADMIN_VER"-all-languages.tar.gz
    tar xzf /usr/share/phpmyadmin/phpMyAdmin-"$PHPMYADMIN_VER"-all-languages.tar.gz --strip-components=1 --directory /usr/share/phpmyadmin
    rm -f /usr/share/phpmyadmin/phpMyAdmin-"$PHPMYADMIN_VER"-all-languages.tar.gz
    # Create TempDir
    mkdir /usr/share/phpmyadmin/tmp || exit
    chown www-data:www-data /usr/share/phpmyadmin/tmp
    chmod 700 /var/www/phpmyadmin/tmp
    randomBlowfishSecret=$(openssl rand -base64 22)
    sed -e "s|cfg\['blowfish_secret'\] = ''|cfg['blowfish_secret'] = '$randomBlowfishSecret'|" /usr/share/phpmyadmin/config.sample.inc.php >/usr/share/phpmyadmin/config.inc.php
  elif [[ "$OS" == "centos" ]]; then
    echo "No Support"
  fi
}

initialCheck

if [[ -e /var/www/html/app/ ]]; then
  manageMenu
else
  script
fi
