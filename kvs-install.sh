#!/bin/bash
#
# [Automatic installation on Linux for Kernel Video Sharing]
#
# GitHub : https://github.com/MaximeMichaud/KVS-install
# URL : https://www.kernel-video-sharing.com
#
# This script is intended for a quick and easy installation :
# curl -O https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/kvs-install.sh
# chmod +x kvs-install.sh
# ./kvs-install.sh
#
# KVS-install Copyright (c) 2020-2021 Maxime Michaud
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
    echo "Looks like you aren't running this script on a Debian, Ubuntu or CentOS system ${normal}"
    exit 1
  fi
}

function script() {
  installQuestions
  aptupdate
  aptinstall
  #aptinstall_"$webserver"
  aptinstall_nginx
  aptinstall_"$database"
  aptinstall_php
  #aptinstall_phpmyadmin
  #install_KVS
  install_ioncube
  install_composer
  autoUpdate
  setupdone

}
function installQuestions() {
  echo "${cyan}Welcome to KVS-install !"
  echo "https://github.com/MaximeMichaud/KVS-install"
  echo "I need to ask some questions before starting the configuration."
  echo "You can leave the default options and just press Enter if that's right for you."
  echo ""
  echo "${cyan}What is your DOMAIN which will be use for KVS ?"
  echo "${cyan}Do you want to create a SSL certs ?"
  echo "${cyan}Which Version of PHP ?"
  echo "${red}Red = End of life ${yellow}| Yellow = Security fixes only ${green}| Green = Active support"
  echo "   1) PHP 7.4 (recommended) ${normal}${cyan}"
  echo "${yellow}   2) PHP 7.3 ${normal}${cyan}"
  until [[ "$PHP_VERSION" =~ ^[1-2]$ ]]; do
    read -rp "Version [1-2]: " -e -i 1 PHP_VERSION
  done
  case $PHP_VERSION in
  #1)
  #PHP="8.0"
  #;;
  1)
    PHP="7.4"
    ;;
  2)
    PHP="7.3"
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
    echo "${green}   1) MariaDB 10.5 (Stable)${normal}"
    echo "${yellow}   2) MariaDB 10.4 (Old Stable)${normal}"
    echo "${yellow}   2) MariaDB 10.3 (Old Stable)${normal}${cyan}"
    until [[ "$DATABASE_VER" =~ ^[1-3]$ ]]; do
      read -rp "Version [1-3]: " -e -i 1 DATABASE_VER
    done
    case $DATABASE_VER in
    1)
      database_ver="10.5"
      ;;
    2)
      database_ver="10.4"
      ;;
    3)
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
    apt-get -y install ca-certificates apt-transport-https dirmngr zip unzip lsb-release gnupg openssl curl imagemagick ffmpeg wget
  elif [[ "$OS" == "centos" ]]; then
    echo "No Support"
  fi
}

function aptinstall_nginx() {
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    echo "Nginx Installation"
    apt-key adv --fetch-keys 'https://nginx.org/keys/nginx_signing.key'
    if [[ "$VERSION_ID" =~ (9|10|16.04|18.04|20.04) ]]; then
      echo "deb https://nginx.org/packages/$nginx_branch/$OS/ $(lsb_release -sc) nginx" >/etc/apt/sources.list.d/nginx.list
      echo "deb-src https://nginx.org/packages/$nginx_branch/$OS/ $(lsb_release -sc) nginx" >>/etc/apt/sources.list.d/nginx.list
      apt-get update && apt-get install nginx -y
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/nginx.conf -O /etc/nginx/nginx.conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/general.conf -O /etc/nginx/globals/general.conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/security.conf -O /etc/nginx/globals/security.conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/php_fastcgi.conf -O /etc/nginx/globals/php_fastcgi.conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/letsencrypt.conf -O /etc/nginx/globals/letsencrypt.conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/cloudflare-ip-list.conf -O /etc/nginx/globals/cloudflare-ip-list.conf
      #update CF IPV4/V6
      #wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/update-cloudflare-ip-list.sh -O /etc/nginx/scripts/update-cloudflare-ip-list.sh
    fi
    if [[ "$VERSION_ID" == "11" ]]; then
      echo "deb https://nginx.org/packages/$nginx_branch/$OS/ $(lsb_release -sc) nginx" >/etc/apt/sources.list.d/nginx.list
      echo "deb-src https://nginx.org/packages/$nginx_branch/$OS/ $(lsb_release -sc) nginx" >>/etc/apt/sources.list.d/nginx.list
      apt-get update && apt-get install nginx -y
    fi
  elif [[ "$OS" == "centos" ]]; then
    echo "No Support"
  fi
}

function aptinstall_mariadb() {
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    echo "MariaDB Installation"
    apt-key adv --fetch-keys 'https://mariadb.org/mariadb_release_signing_key.asc'
    if [[ "$VERSION_ID" =~ (9|10|16.04|18.04|20.04) ]]; then
      echo "deb [arch=amd64] https://ftp.igh.cnrs.fr/pub/mariadb/repo/$database_ver/$ID $(lsb_release -sc) main" >/etc/apt/sources.list.d/mariadb.list
      apt-get update && apt-get install mariadb-server -y
      systemctl enable mariadb && systemctl start mariadb
    fi
    if [[ "$VERSION_ID" == "11" ]]; then
      echo "deb [arch=amd64] https://ftp.igh.cnrs.fr/pub/mariadb/repo/$database_ver/debian buster main" >/etc/apt/sources.list.d/mariadb.list
      apt-get update && apt-get install mariadb-server -y
      systemctl enable mariadb && systemctl start mariadb
    elif [[ "$OS" == "centos" ]]; then
      echo "No Support"
    fi
  fi
}

function aptinstall_mysql() {
  if [[ "$OS" =~ (debian|ubuntu) ]]; then
    echo "MYSQL Installation"
    if [[ "$database_ver" == "8.0" ]]; then
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/master/conf/mysql/default-auth-override.cnf -P /etc/mysql/mysql.conf.d
    fi
    if [[ "$VERSION_ID" =~ (9|10|16.04|18.04|20.04) ]]; then
      echo "deb http://repo.mysql.com/apt/$ID/ $(lsb_release -sc) mysql-$database_ver" >/etc/apt/sources.list.d/mysql.list
      echo "deb-src http://repo.mysql.com/apt/$ID/ $(lsb_release -sc) mysql-$database_ver" >>/etc/apt/sources.list.d/mysql.list
      apt-key adv --keyserver keys.gnupg.net --recv-keys 8C718D3B5072E1F5
      apt-get update && apt-get install mysql-server mysql-client -y
      systemctl enable mysql && systemctl start mysql
    fi
    if [[ "$VERSION_ID" == "11" ]]; then
      echo "deb http://repo.mysql.com/apt/debian/ buster mysql-$database_ver" >/etc/apt/sources.list.d/mysql.list
      echo "deb-src http://repo.mysql.com/apt/debian/ buster mysql-$database_ver" >>/etc/apt/sources.list.d/mysql.list
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
      if [[ "$VERSION_ID" =~ (9|10) ]]; then
        echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list
        apt-get update && apt-get install php$PHP{,-bcmath,-mbstring,-common,-xml,-curl,-gd,-zip,-mysql,-fpm} -y
        sed -i 's|upload_max_filesize = 2M|upload_max_filesize = 2000M|' /etc/php/$PHP/fpm/php.ini
        sed -i 's|post_max_size = 8M|post_max_size = 2000M|' /etc/php/$PHP/fpm/php.ini
	    sed -i 's|memory_limit = 128M|memory_limit = 512M|' /etc/php/$PHP/fpm/php.ini
        apt-get remove apache2 -y
        systemctl restart nginx
      fi
      if [[ "$VERSION_ID" == "11" ]]; then
        echo "deb https://packages.sury.org/php/ buster main" | tee /etc/apt/sources.list.d/php.list
        apt-get update && apt-get install php$PHP{,-bcmath,-mbstring,-common,-xml,-curl,-gd,-zip,-mysql,-fpm} -y
        sed -i 's|upload_max_filesize = 2M|upload_max_filesize = 2000M|' /etc/php/$PHP/fpm/php.ini
        sed -i 's|post_max_size = 8M|post_max_size = 2000M|' /etc/php/$PHP/fpm/php.ini
	    sed -i 's|memory_limit = 128M|memory_limit = 512M|' /etc/php/$PHP/fpm/php.ini
        apt-get remove apache2 -y
        systemctl restart nginx
      fi
      if [[ "$VERSION_ID" =~ (16.04|18.04|20.04) ]]; then
        add-apt-repository -y ppa:ondrej/php
        apt-get update && apt-get install php$PHP{,-bcmath,-mbstring,-common,-xml,-curl,-gd,-zip,-mysql,-fpm} -y
        sed -i 's|upload_max_filesize = 2M|upload_max_filesize = 2000M|' /etc/php/$PHP/fpm/php.ini
        sed -i 's|post_max_size = 8M|post_max_size = 2000M|' /etc/php/$PHP/fpm/php.ini
	    sed -i 's|memory_limit = 128M|memory_limit = 512M|' /etc/php/$PHP/fpm/php.ini
        apt-get remove apache2 -y
        systemctl restart nginx
      fi
    fi
    #if [[ "$webserver" =~ (apache2) ]]; then
      #if [[ "$VERSION_ID" =~ (9|10) ]]; then
        #echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list
        #apt-get update && apt-get install php$PHP{,-bcmath,-mbstring,-common,-xml,-curl,-gd,-zip,-mysql} -y
        #sed -i 's|upload_max_filesize = 2M|upload_max_filesize = 50M|' /etc/php/$PHP/apache2/php.ini
        #sed -i 's|post_max_size = 8M|post_max_size = 50M|' /etc/php/$PHP/apache2/php.ini
        #sed -i 's|;max_input_vars = 1000|max_input_vars = 2000|' /etc/php/$PHP/apache2/php.ini
        #systemctl restart apache2
      #fi
      #if [[ "$VERSION_ID" == "11" ]]; then
        #echo "deb https://packages.sury.org/php/ buster main" | tee /etc/apt/sources.list.d/php.list
        #apt-get update && apt-get install php$PHP{,-bcmath,-mbstring,-common,-xml,-curl,-gd,-zip,-mysql} -y
        #sed -i 's|upload_max_filesize = 2M|upload_max_filesize = 50M|' /etc/php/$PHP/apache2/php.ini
        #sed -i 's|post_max_size = 8M|post_max_size = 50M|' /etc/php/$PHP/apache2/php.ini
        #sed -i 's|;max_input_vars = 1000|max_input_vars = 2000|' /etc/php/$PHP/apache2/php.ini
        #systemctl restart apache2
      #fi
      #if [[ "$VERSION_ID" =~ (16.04|18.04|20.04) ]]; then
        #add-apt-repository -y ppa:ondrej/php
        #apt-get update && apt-get install php$PHP{,-bcmath,-mbstring,-common,-xml,-curl,-gd,-zip,-mysql} -y
        #sed -i 's|upload_max_filesize = 2M|upload_max_filesize = 50M|' /etc/php/$PHP/apache2/php.ini
        #sed -i 's|post_max_size = 8M|post_max_size = 50M|' /etc/php/$PHP/apache2/php.ini
        #sed -i 's|;max_input_vars = 1000|max_input_vars = 2000|' /etc/php/$PHP/apache2/php.ini
        #systemctl restart apache2
      #fi
    #fi
  #fi
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
    randomBlowfishSecret=$(openssl rand -base64 32)
    sed -e "s|cfg\['blowfish_secret'\] = ''|cfg['blowfish_secret'] = '$randomBlowfishSecret'|" /usr/share/phpmyadmin/config.sample.inc.php >/usr/share/phpmyadmin/config.inc.php
    wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/phpmyadmin.conf
    ln -s /usr/share/phpmyadmin /var/www/phpmyadmin
    if [[ "$webserver" =~ (nginx) ]]; then
      apt-get update && apt-get install php7.4{,-bcmath,-mbstring,-common,-xml,-curl,-gd,-zip,-mysql,-fpm} -y
      service nginx restart
    elif [[ "$webserver" =~ (apache2) ]]; then
      wget https://raw.githubusercontent.com/MaximeMichaud/Azuriom-install/master/conf/apache2/phpmyadmin.conf
      mv phpmyadmin.conf /etc/apache2/sites-available/
      a2ensite phpmyadmin
      systemctl restart apache2
    fi
  elif [[ "$OS" == "centos" ]]; then
    echo "No Support"
  fi
}

function install_KVS() {
  if [[ "$OS" =~ (debian|ubuntu|centos) ]]; then
    rm -rf /var/www/html/*
    #mkdir /var/www/html
    mv /var/KVS_* /var/www/"$DOMAIN"
    unzip -o /var/www/"$DOMAIN"/KVS_*
    rm -r /var/www/"$DOMAIN"/KVS_*
    chown -R www-data:www-data /var/www/"$DOMAIN"
    chmod -R 755 /var/www/"$DOMAIN"
    #cd /var/www/html || exit
    #unzip KVSInstaller.zip
    #rm -rf KVSInstaller.zip
    #chmod -R 755 /var/www/html
    #chown -R www-data:www-data /var/www/html
    #chmod for kvs
    chmod 777 tmp
    chmod 777 admin/smarty/cache
    chmod 777 admin/smarty/template-c
    chmod 777 admin/smarty/template-c-site
    find admin/logs -type d | xargs chmod 777
    find admin/logs -type f \( ! -iname ".htaccess" \) | xargs chmod 666
    find contents -type d | xargs chmod 777
    chmod 755 contents
    find template -type d | xargs chmod 777
    find template -type f \( ! -iname ".htaccess" \) | xargs chmod 666
    find admin/data -type d | xargs chmod 777
    chmod 755 admin/data
    find admin/data -type f \( -iname "*.dat" \) | xargs chmod 666
    find admin/data -type f \( -iname "*.tpl" \) | xargs chmod 666
    chmod 777 langs
    find langs -type f \( -iname "*.lang" \) | xargs chmod 666
  fi
}

function install_ioncube() {
  if [[ "$OS" =~ (debian|ubuntu|centos) ]]; then
    wget 'https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz'
    tar -xvzf ioncube_loaders_lin_x86-64.tar.gz
    cd ioncube && cp ioncube_loader_lin_$PHP.so /usr/lib/php/20190902/
    echo "zend_extension=/usr/lib/php/20190902/ioncube_loader_lin_$PHP.so" >>/etc/php/$PHP/apache2/php.ini
    echo "zend_extension=/usr/lib/php/20190902/ioncube_loader_lin_$PHP.so" >>/etc/php/$PHP/cli/php.ini
    systemctl restart apache2
  fi
}

function install_composer() {
  if [[ "$OS" =~ (debian|ubuntu|centos) ]]; then
    curl -sS https://getcomposer.org/installer | php
    mv composer.phar /usr/local/bin/composer
    chmod +x /usr/local/bin/composer
  fi
}

#function install_cron() {
#Disabled for the moment
#if [[ "$OS" =~ (debian|ubuntu) ]]; then
#cd /var/www/html || exit
#apt-get install cron -y
#crontab -l > cron
#wget -O cron 'https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/cron/cron'
#crontab cron
#rm cron
#fi
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
    randomBlowfishSecret=$(openssl rand -base64 32)
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
