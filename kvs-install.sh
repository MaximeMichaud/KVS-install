#!/bin/bash
# [Automatic installation on Linux for Kernel Video Sharing]
#
# GitHub : https://github.com/MaximeMichaud/KVS-install
# URL : https://www.kernel-video-sharing.com
#
# This script is intended for a quick and easy installation :
# bash <(curl -s https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/kvs-install.sh)
#
# KVS-install Copyright (c) 2020-2023 Maxime Michaud
# Licensed under GNU General Public License v3.0
#################################################################
# shellcheck disable=SC1091
#################################################################
#Logs
exec 3<&1
coproc mytee { tee /root/kvs-install.log >&3; }
exec >&"${mytee[1]}" 2>&1
#Colors
red=$(tput setaf 1)
green=$(tput setaf 2)
#yellow=$(tput setaf 3)
cyan=$(tput setaf 6)
white=$(tput setaf 7)
normal=$(tput sgr0)
alert=${white}${on_red}
on_red=$(tput setab 1)
# Variables Shell
export DEBIAN_FRONTEND=noninteractive
# Variables Services
webserver=nginx
# Define installation parameters for headless install (fallback if unspecified)
if [[ $HEADLESS == "y" ]]; then
  # Define options
  database_ver=11.4
  IONCUBE=YES
  AUTOPACKAGEUPDATE=YES
fi
#################################################################
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

    if [[ ! $VERSION_ID =~ (11|12) ]]; then
      echo "⚠️ ${alert}Your version of Debian is not supported.${normal}"
      echo ""
      until [[ $CONTINUE =~ (y|n) ]]; do
        read -rp "Continue? [y/n] : " -e CONTINUE
      done
      if [[ "$CONTINUE" == "n" ]]; then
        exit 1
      fi
    fi
  else
    echo "Looks like you aren't running this script on a Debian system ${normal}"
    exit 1
  fi
}


function script() {
  installQuestions
  aptupdate
  aptinstall
  whatisdomain
  install_yt-dlp
  aptinstall_php
  aptinstall_memcached
  aptinstall_nginx
  aptinstall_mariadb
  aptinstall_phpmyadmin
  install_KVS
  install_ioncube
  insert_cronjob
  install_acme.sh
  configure_dynamic_php_fpm
  autoUpdate
  setupdone

}
function installQuestions() {
  if [[ $HEADLESS != "y" ]]; then
    yes '' | sed 20q
    echo "${cyan}Welcome to KVS-install !"
    echo "https://github.com/MaximeMichaud/KVS-install"
    echo "I need to ask some questions before starting the configuration."
    echo "You can leave the default options and just press Enter if that's right for you."
    echo ""
    echo "Note: This script should be run on a fresh installation of a tested distribution."
    echo "Otherwise, it may not function correctly."
    echo ""
    echo "Do you want to enable automatic updates (All Packages) (Recommended) ?"
    echo "   1) Yes"
    echo "   2) No"
    until [[ "$AUTOPACKAGEUPDATE" =~ ^[1-2]$ ]]; do
      read -rp "[1-2]: " -e -i 1 AUTOPACKAGEUPDATE
    done
    case $AUTOPACKAGEUPDATE in
    1)
      AUTOPACKAGEUPDATE="YES"
      ;;
    2)
      AUTOPACKAGEUPDATE="NO"
      ;;
    esac
    echo "Do you want to install and enable IonCube? (Recommended)"
    echo "No, only if you have a license with the source code."
    echo "If unsure, choose Yes."
    echo "If some files are encoded with IonCube along with open-source code, it may result in unknown behavior (Really bad)."
    echo "   1) Yes"
    echo "   2) No"
    until [[ "$IONCUBE" =~ ^[1-2]$ ]]; do
      read -rp "[1-2]: " -e -i 1 IONCUBE
    done
    case $IONCUBE in
    1)
      IONCUBE="YES"
      ;;
    2)
      IONCUBE="NO"
      ;;
    esac
    #    echo "Which branch of NGINX ?"
    #    echo "   1) Mainline"
    #    echo "   2) Stable"
    #    until [[ "$NGINX_BRANCH" =~ ^[1-2]$ ]]; do
    #      read -rp "Version [1-2]: " -e -i 1 NGINX_BRANCH
    #    done
    #    case $NGINX_BRANCH in
    #    1)
    #      nginx_branch="mainline"
    #      ;;
    #    2)
    #      nginx_branch="stable"
    #      ;;
    #    esac
    echo "Which version of MariaDB ? https://endoflife.date/mariadb"
    echo "${green}   1) MariaDB 11.4 (Stable) (LTS) (Default)${normal}"
    echo "${green}   2) MariaDB 10.11 (Old Stable) (LTS)${normal}"
    echo "${green}   2) MariaDB 10.6 (Old Stable) (LTS)${normal}"
    echo "Please note: We only recommend LTS versions, despite other versions being available."
    echo "Regardless of the version, KVS has a specific way of storing MYSQL data."
    echo "As long as the MYISAM engine is not removed from MariaDB, you should always choose the latest LTS version recommended by the script."
    echo "Even if this was the case, tables can be migrated from MYISAM to InnoDB."
    echo "Some have done so, but the end result was never studied thoroughly."
    echo "The risk taken is probably not worth the performance difference if the case."
    until [[ "$DATABASE_VER" =~ ^[1-3]$ ]]; do
      read -rp "Version [1-3]: " -e -i 1 DATABASE_VER
    done
    case $DATABASE_VER in
    1)
      database_ver="11.4"
      ;;
    2)
      database_ver="10.11"
      ;;
    3)
      database_ver="10.6"
      ;;
    esac
    echo "Mail for SSL"
    echo "Email address is required for notifications (e.g., certificate expiration if script doesn't renew automatically)."
    echo "Required by acme.sh as a security measure for SSL."
    echo "Currently, acme.sh utilizes ZeroSSL for SSL certificates."
    echo "The certificate will be ECDSA 256-bit, valid for 3 months (standard)."
    while true; do
      read -rp "Email: " EMAIL
      if [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        break
      else
        echo "Please enter a valid email address."
      fi
    done
    echo "Upload KVS Archive File in /root"
    echo "Ex : KVS_X.X.X_[domain.tld].zip"
    # shellcheck disable=SC2144
    while [ ! -f /root/KVS_*.zip ]; do
      sleep 2
      echo "Waiting for KVS .ZIP file in /root"
      echo "Press CTRL + C for exiting"
    done
    file=$(ls /root/KVS_*.zip)
    ls -l "$file"
    version=$(echo "$file" | grep -oP 'KVS_\K[0-9]+\.[0-9]+\.[0-9]+')

    # KVS Version comparison
    ver_compare() {
      [ "$1" = "$(echo -e "$1\n$2" | sort -V | head -n1)" ]
    }

    # Determining PHP version and PHP path
    PHP="7.4"
    php_path="/usr/lib/php/20190902"
    if ver_compare "6.2" "$version"; then
      PHP="8.1"
      php_path="/usr/lib/php/20210902"
    fi

    echo "We are ready to start the installation !"
    APPROVE_INSTALL=${APPROVE_INSTALL:-n}
    if [[ $APPROVE_INSTALL =~ n ]]; then
      read -n1 -r -p "Press any key to continue..."
    fi
  fi
}

function aptupdate() {
apt-get update
}

function aptinstall() {
    packages=(
      ca-certificates
      apt-transport-https
      dirmngr
      zip
      unzip
      lsb-release
      gnupg
      openssl
      curl
      imagemagick
      ffmpeg
      wget
      sudo
      git
    )
    apt-get -y install "${packages[@]}"
}

function install_yt-dlp() {
  curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
  chmod a+rx /usr/local/bin/yt-dlp
  ln -s /usr/local/bin/yt-dlp /usr/local/bin/youtube-dl
}

function whatisdomain() {
  mkdir -p /root/tmp
  cp KVS_* tmp
  cd /root/tmp && unzip -o KVS_*
  # shellcheck disable=SC2016
  DOMAIN=$(grep -P -i '\$config\['"'"'project_licence_domain'"'"']="[a-zA-Z]+\.[a-zA-Z]+"' /root/tmp/admin/include/setup.php)
  DOMAIN=$(echo "$DOMAIN" | cut -d'"' -f 2)
  # shellcheck disable=SC2016
  URL=$(grep -P -i -m1 '\$config\['"'"'project_url'"'"']=' /root/tmp/admin/include/setup.php)
  URL=$(echo "$URL" | cut -d'"' -f 2)
  # shellcheck disable=SC2001
  URL=$(echo "$URL" | sed 's~http[s]*://~~g')
  rm -rf /root/tmp && cd /root || exit
}

function aptinstall_nginx() {
    echo "NGINX Installation"
    apt-key adv --fetch-keys 'https://nginx.org/keys/nginx_signing.key'
    if [[ "$VERSION_ID" =~ (11|12|20.04|22.04) ]]; then
      echo "deb https://nginx.org/packages/mainline/$OS/ $(lsb_release -sc) nginx" >/etc/apt/sources.list.d/nginx.list
      echo "deb-src https://nginx.org/packages/mainline/$OS/ $(lsb_release -sc) nginx" >>/etc/apt/sources.list.d/nginx.list
      apt-get update && apt-get install nginx -y
      rm -rf conf.d && mkdir -p /etc/nginx/globals
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/nginx.conf -O /etc/nginx/nginx.conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/globals/general.conf -O /etc/nginx/globals/general.conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/globals/security.conf -O /etc/nginx/globals/security.conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/globals/php_fastcgi.conf -O /etc/nginx/globals/php_fastcgi.conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/globals/letsencrypt.conf -O /etc/nginx/globals/letsencrypt.conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/globals/cloudflare-ip-list.conf -O /etc/nginx/globals/cloudflare-ip-list.conf
	  # Custom KVS NGINX conf
      #wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/kvs.conf -O /etc/nginx/globals/kvs.conf
      openssl dhparam -out /etc/nginx/dhparam.pem 2048
      mkdir /etc/nginx/sites-available /etc/nginx/sites-enabled
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/conf.d/domain.conf -O /etc/nginx/sites-available/"$DOMAIN".conf
      sed -i "s/domain.tld/$DOMAIN/g" /etc/nginx/sites-available/"$DOMAIN".conf
      sed -i "s/project_url/$URL/g" /etc/nginx/sites-available/"$DOMAIN".conf
      # wget sslgen conf
      wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/conf.d/sslgen.conf -O /etc/nginx/sites-enabled/sslgen.conf
      sed -i "s/domain.tld/$DOMAIN/g" /etc/nginx/sites-enabled/sslgen.conf
      sed -i "s/project_url/$URL/g" /etc/nginx/sites-enabled/sslgen.conf
      ##
      sed -i "s|fastcgi_pass unix:/var/run/php/phpX.X-fpm.sock;|fastcgi_pass unix:/var/run/php/php$PHP-fpm.sock;|" /etc/nginx/sites-available/"$DOMAIN".conf
      rm -rf /etc/nginx/conf.d
      service nginx restart
      #update CF IPV4/V6 if CF is used
      #wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/update-cloudflare-ip-list.sh -O /usr/bin/update-cloudflare-ip-list.sh
    fi
}

function aptinstall_mariadb() {
  echo "MariaDB Installation"
    apt-key adv --fetch-keys 'https://mariadb.org/mariadb_release_signing_key.asc'
    echo "deb [arch=amd64] https://dlm.mariadb.com/repo/mariadb-server/$database_ver/repo/$ID $(lsb_release -sc) main" >/etc/apt/sources.list.d/mariadb.list
    apt-get update && apt-get install mariadb-server -y
    systemctl enable mariadb && systemctl start mariadb
}

function aptinstall_php() {
    echo "PHP Installation"
    curl -sSL -o /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
    if [[ "$webserver" =~ (nginx) ]]; then
      if [[ "$VERSION_ID" =~ (11|12) ]]; then
        echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list
      fi
      if [[ "$VERSION_ID" =~ (20.04|22.04) ]]; then
        add-apt-repository -y ppa:ondrej/php
      fi
    fi
    apt-get update && apt-get install php"$PHP"{,-bcmath,-mbstring,-common,-xml,-curl,-gd,-zip,-mysql,-fpm,-imagick,-memcached} -y
    sed -i "s|upload_max_filesize = 2M|upload_max_filesize = 2048M|
                s|post_max_size = 8M|post_max_size = 2048M|
                s|memory_limit = 128M|memory_limit = 512M|
                s|;max_input_vars = 1000|max_input_vars = 10000|
                s|;max_execution_time = 30|max_execution_time = 300|
                s|;max_input_time = 30|max_input_time = 360|" /etc/php/"$PHP"/fpm/php.ini
    systemctl restart php"$PHP"
}

function aptinstall_phpmyadmin() {
  echo "phpMyAdmin Installation"
    INSTALL_DIR="/usr/share/phpmyadmin"
    PHPMYADMIN_DOWNLOAD_PAGE="https://www.phpmyadmin.net/downloads/"
    PHPMYADMIN_URL=$(curl -s "${PHPMYADMIN_DOWNLOAD_PAGE}" | grep -oP 'https://files.phpmyadmin.net/phpMyAdmin/[^"]+-all-languages.tar.gz' | head -n 1)
    wget -O phpmyadmin.tar.gz "${PHPMYADMIN_URL}"
    mkdir -p "${INSTALL_DIR}"
    tar xzf phpmyadmin.tar.gz --strip-components=1 -C "${INSTALL_DIR}"
    rm phpmyadmin.tar.gz
    mkdir -p /usr/share/phpmyadmin/tmp || exit
    chown www-data:www-data /usr/share/phpmyadmin/tmp
    chmod 700 /usr/share/phpmyadmin/tmp
    randomBlowfishSecret=$(openssl rand -base64 22)
    sed -e "s|cfg\['blowfish_secret'\] = ''|cfg['blowfish_secret'] = '$randomBlowfishSecret'|" /usr/share/phpmyadmin/config.sample.inc.php >/usr/share/phpmyadmin/config.inc.php
    # 404
	#wget https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/phpmyadmin.conf
    ln -s /usr/share/phpmyadmin /var/www/phpmyadmin
    if [[ "$webserver" =~ (nginx) ]]; then
      apt-get update && apt-get install php"$PHP"{,-bcmath,-mbstring,-common,-xml,-curl,-gd,-zip,-mysql,-fpm} -y
      service nginx restart
    fi
}

function install_KVS() {
    KVS_PATH="/var/www/$DOMAIN"
    mkdir -p "$KVS_PATH"
    mv /root/KVS_* "$KVS_PATH"
    unzip -o "$KVS_PATH"/KVS_* -d "$KVS_PATH"
    rm -r "$KVS_PATH"/KVS_*
    chown -R www-data:www-data "$KVS_PATH"
    chmod -R 755 "$KVS_PATH"

    sed -i '/xargs chmod 666/d' "$KVS_PATH"/_INSTALL/install_permissions.sh
    "$KVS_PATH"/_INSTALL/install_permissions.sh
    cat "$KVS_PATH"/_INSTALL/nginx_config.txt > /etc/nginx/globals/kvs.conf
    sed -i "s|/PATH|$KVS_PATH|
             s|/usr/local/bin/|/usr/bin/|
             s|/usr/bin/php|/usr/bin/php$PHP|" "$KVS_PATH"/admin/include/setup.php
    sed -i "/\$config\[.project_title.\]=/s/KVS/${DOMAIN}/" "$KVS_PATH"/admin/include/setup.php
    databasepassword="$(openssl rand -base64 12)"
    mysql -e "CREATE DATABASE \`$DOMAIN\`;"
    mysql -e "CREATE USER \`$DOMAIN\`@localhost IDENTIFIED BY '${databasepassword}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`$DOMAIN\`.* TO \`$DOMAIN\`@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    mysql -u "$DOMAIN" -p"$databasepassword" "$DOMAIN" <"$KVS_PATH"/_INSTALL/install_db.sql
    # Remove anonymous user
    mysql -e "DELETE FROM mysql.user WHERE User='';"
    rm -rf "$KVS_PATH"/_INSTALL/
    sed -i "s|login|$DOMAIN|
             s|pass|$databasepassword|
             s|'DB_DEVICE','base'|'DB_DEVICE','$DOMAIN'|" "$KVS_PATH"/admin/include/setup_db.php
}

function aptinstall_memcached() {
    echo "Installing Memcached..."
    apt-get install -y memcached
    echo "Configuring Memcached to use 256 MB of RAM..."
    sed -i 's/-m 64/-m 256/' /etc/memcached.conf
    systemctl restart memcached

  echo "Memcached installation and configuration complete."
}

function install_acme.sh() {
    cd /root || exit
    git clone https://github.com/acmesh-official/acme.sh.git
    cd ./acme.sh || exit
    ./acme.sh --install -m "$EMAIL"
    mkdir -p /var/www/_letsencrypt && chown www-data /var/www/_letsencrypt
    #sed -i -r 's/(listen .*443)/\1; #/g; s/(ssl_(certificate|certificate_key|trusted_certificate) )/#;#\1/g; s/(server \{)/\1\n    ssl off;/g' /etc/nginx/sites-available/"$DOMAIN".conf
    service nginx restart
    /root/.acme.sh/acme.sh --issue -d "$DOMAIN" -d www."$DOMAIN" -w /var/www/_letsencrypt --keylength ec-256
    mkdir -p /etc/nginx/ssl /etc/nginx/ssl/"$DOMAIN"
    /root/.acme.sh/acme.sh --install-cert --ecc -d "$DOMAIN" -d www."$DOMAIN" \
      --key-file /etc/nginx/ssl/"$DOMAIN"/key.pem \
      --fullchain-file /etc/nginx/ssl/"$DOMAIN"/cert.pem \
      --reloadcmd "service nginx force-reload"
    mv /etc/nginx/sites-enabled/sslgen.conf /etc/nginx/sites-available/sslgen.conf
    mv /etc/nginx/sites-available/"$DOMAIN".conf /etc/nginx/sites-enabled/"$DOMAIN".conf
    #sed -i -r -z 's/#?; ?#//g; s/(server \{)\n    ssl off;/\1/g' /etc/nginx/sites-available/"$DOMAIN".conf
    service nginx restart
}

configure_dynamic_php_fpm() {
  # Retrieve the total memory in KB and convert it to MB
  total_memory_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  total_memory_mb=$((total_memory_kb / 1024))

  # Use half of the total memory for PHP-FPM
  allocated_memory_mb=$((total_memory_mb / 2))

  # Average memory per PHP script (adjust as needed)
  average_memory_per_script=64

  # Calculate FPM settings
  max_children=$((allocated_memory_mb / average_memory_per_script))
  start_servers=$((max_children / 4))
  min_spare_servers=$((start_servers / 2))
  max_spare_servers=$((start_servers * 2))

  # Path to PHP-FPM configuration file for www pool
  php_fpm_conf="/etc/php/$PHP/fpm/pool.d/www.conf"

  # Backup the original configuration file
  cp "$php_fpm_conf" "${php_fpm_conf}.bak"

  # Update PHP-FPM configuration with new calculated values
  sed -i "s/pm.max_children =.*/pm.max_children = $max_children/" "$php_fpm_conf"
  sed -i "s/pm.start_servers =.*/pm.start_servers = $start_servers/" "$php_fpm_conf"
  sed -i "s/pm.min_spare_servers =.*/pm.min_spare_servers = $min_spare_servers/" "$php_fpm_conf"
  sed -i "s/pm.max_spare_s_servers =.*/pm.max_spare_servers = $max_spare_servers/" "$php_fpm_conf"

  # Restart PHP-FPM to apply changes
  systemctl restart php"$PHP"-fpm

  # Optionally, display the new settings for confirmation/debugging purposes
  # echo "PHP-FPM has been configured with the following settings:"
  # echo "Max Children: $max_children"
  # echo "Start Servers: $start_servers"
  # echo "Min Spare Servers: $min_spare_servers"
  # echo "Max Spare Servers: $max_spare_servers"
}

insert_cronjob() {
  echo "* Installing cronjob.. "

  crontab -l | {
    cat
    echo "#KVS"
    echo "* * * * * cd /var/www/$DOMAIN/admin/include && /usr/bin/php$PHP cron.php > /dev/null 2>&1"
    echo "#yt-dlp Automatic Update"
    echo "0 0 * * * /bin/bash -c 'curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp && chmod a+rx /usr/local/bin/yt-dlp' > /dev/null 2>&1"
} | crontab -

  echo "* Cronjob installed!"
}

function install_ioncube() {
  if [[ "$IONCUBE" =~ (YES) ]]; then
      cd /root || exit
      wget 'https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz'
      tar -xvzf ioncube_loaders_lin_x86-64.tar.gz
      cd ioncube && cp ioncube_loader_lin_"$PHP".so "$php_path"/
      echo "zend_extension=$php_path/ioncube_loader_lin_$PHP.so" >>/etc/php/"$PHP"/fpm/php.ini
      echo "zend_extension=$php_path/ioncube_loader_lin_$PHP.so" >>/etc/php/"$PHP"/cli/php.ini
      systemctl restart php"$PHP"-fpm
      rm -rf /root/ioncube_loaders_lin_x86-64.tar.gz /root/ioncube
  fi
}

function autoUpdate() {
  if [[ "$AUTOPACKAGEUPDATE" =~ (YES) ]]; then
    apt-get install -y unattended-upgrades
    sed -i 's|APT::Periodic::Update-Package-Lists "0";|APT::Periodic::Update-Package-Lists "1";|' /etc/apt/apt.conf.d/20auto-upgrades
    sed -i 's|APT::Periodic::Unattended-Upgrade "0";|APT::Periodic::Unattended-Upgrade "1";|' /etc/apt/apt.conf.d/20auto-upgrades
  fi
}

function setupdone() {
  IPV4=$(curl 'https://api.ipify.org')
  IPV6=$(curl 'https://api64.ipify.org')
  echo "${cyan}It done!"
  echo "IPV4 : $IPV4"
  if [[ "$IPV4" == "$IPV6" ]]; then
    echo "${red}IPV6 : None${normal}"
  else
    echo "IPV6 : $IPV6"
  fi
  echo "${cyan}Website: ${green}https://$URL"
  echo "${cyan}phpMyAdmin: ${green}http://$IP/phpmyadmin"
  echo "${cyan}Database: ${green}$DOMAIN"
  echo "${cyan}User: ${green}$DOMAIN"
  echo "${cyan}Password: ${green}$databasepassword"
  echo "${cyan}You will need to execute ${normal}${on_red}${white}mysql_secure_installation${normal}${cyan} for setting the root password."
  echo "${cyan}IPV6 is not ENABLED on the webserver configuration, KVS doesn't support IPV6 at 100%"
  echo "${cyan}If you wish to analyze the logs later, you can execute the following command : cat /root/kvs-install.log"
  if [[ "$AUTOPACKAGEUPDATE" =~ (YES) ]]; then
    echo "${green}Automatic updates enabled${normal}"
  fi
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
  echo "   2) Add another KVS website (work in progress, not working)"
  echo "   3) Update phpMyAdmin"
  echo "   4) Update the Script"
  echo "   5) Quit"
  until [[ "$MENU_OPTION" =~ ^[1-5]$ ]]; do
    read -rp "Select an option [1-5] : " MENU_OPTION
  done
  case $MENU_OPTION in
  1)
    script
    ;;
  2)
    whatisdomain
    install_KVS
    ;;
  3)
    updatephpMyAdmin
    ;;
  4)
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
    rm -rf /usr/share/phpmyadmin/*
    INSTALL_DIR="/usr/share/phpmyadmin"
    PHPMYADMIN_DOWNLOAD_PAGE="https://www.phpmyadmin.net/downloads/"
    PHPMYADMIN_URL=$(curl -s "${PHPMYADMIN_DOWNLOAD_PAGE}" | grep -oP 'https://files.phpmyadmin.net/phpMyAdmin/[^"]+-all-languages.tar.gz' | head -n 1)
    wget -O phpmyadmin.tar.gz "${PHPMYADMIN_URL}"
    mkdir -p "${INSTALL_DIR}"
    tar xzf phpmyadmin.tar.gz --strip-components=1 -C "${INSTALL_DIR}"
    rm phpmyadmin.tar.gz
    mkdir /usr/share/phpmyadmin/tmp || exit
    chown www-data:www-data /usr/share/phpmyadmin/tmp
    chmod 700 /var/www/phpmyadmin/tmp
    randomBlowfishSecret=$(openssl rand -base64 22)
    sed -e "s|cfg\['blowfish_secret'\] = ''|cfg['blowfish_secret'] = '$randomBlowfishSecret'|" /usr/share/phpmyadmin/config.sample.inc.php >/usr/share/phpmyadmin/config.inc.php
}

initialCheck

if [[ -e /var/www ]]; then
  manageMenu
else
  script
fi
