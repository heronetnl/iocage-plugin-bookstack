#!/bin/bash

echo "This script installs a new BookStack instance on a fresh Freenas."
echo "This script does not ensure system security."
echo ""

# Get the current user running the script
SCRIPT_USER="${SUDO_USER:-$USER}"

echo "$SCRIPT_USER"

# The directory to install BookStack into
BOOKSTACK_DIR="/usr/local/www/bookstack"

# Generate a password for the database
DB_PASS=$(openssl rand -base64 16)

Hostname=book.local

# Echo out an information message to both the command line and log file
info_msg(){
  echo "$1"
}

# set hostname
set_hostname(){
  hostname $Hostname
}

# Enable autostart for php, nginx and mysql
run_autostart(){
  sysrc -f /etc/rc.conf nginx_enable="YES"
  sysrc -f /etc/rc.conf mysql_enable="YES"
  sysrc -f /etc/rc.conf php_fpm_enable="YES"
}

# Setup php-fpm 
setup_php-fpm(){
  cp /usr/local/etc/php.ini-production /usr/local/etc/php.ini
  sed -i '' 's|listen = 127.0.0.1:9000|listen = /var/run/php-fpm.sock|' /usr/local/etc/php-fpm.d/www.conf
  sed -i '' 's/;listen.owner = www/listen.owner = www/' /usr/local/etc/php-fpm.d/www.conf
  sed -i '' 's/;listen.group = www/listen.group = www/' /usr/local/etc/php-fpm.d/www.conf
  sed -i '' 's/;listen.mode = 0660/listen.mode = 0660/' /usr/local/etc/php-fpm.d/www.conf
  sed -i '' 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' /usr/local/etc/php.ini
}

# Start the service
start_service(){
  service nginx start
  service php-fpm start
  service mysql-server start
}

# Set up database
run_database_setup(){
  mysql -u root -e "CREATE DATABASE bookstack;"
  mysql -u root -e "CREATE USER 'bookstack'@'localhost' IDENTIFIED BY '$DB_PASS';"
  mysql -u root -e "GRANT ALL ON bookstack.* TO 'bookstack'@'localhost';"
  mysql -u root -e "FLUSH PRIVILEGES;"
}

# Install composer
run_install_composer(){
  EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

  if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]
  then
    >&2 echo 'ERROR: Invalid composer installer checksum'
    rm composer-setup.php
    exit 1
  fi

  php composer-setup.php --quiet
  rm composer-setup.php

  # Move composer to global installation
  mv composer.phar /usr/local/bin/composer
}

# Download BookStack
run_bookstack_download(){
  cd /usr/local/www || exit
  git clone https://github.com/BookStackApp/BookStack.git --branch release --single-branch bookstack
}

# Install BookStack composer dependencies
run_install_bookstack_composer_deps(){
  cd "$BOOKSTACK_DIR" || exit
  php /usr/local/bin/composer install --no-dev --no-plugins
}

# Run the BookStack database migrations for the first time
run_bookstack_database_migrations(){
  cd "$BOOKSTACK_DIR" || exit
  php artisan migrate --no-interaction --force
}

# Copy and update BookStack environment variables
run_update_bookstack_env(){
  cd "$BOOKSTACK_DIR" || exit
  cp .env.example .env
  sed -i.bak "s@APP_URL=.*\$@APP_URL=http://$Hostname@" .env
  sed -i.bak 's/DB_DATABASE=.*$/DB_DATABASE=bookstack/' .env
  sed -i.bak 's/DB_USERNAME=.*$/DB_USERNAME=bookstack/' .env
  sed -i.bak "s/DB_PASSWORD=.*\$/DB_PASSWORD=$DB_PASS/" .env
  # Generate the application key
  php artisan key:generate --no-interaction --force
}

# Set file and folder permissions
# Sets current user as owner user and www-data as owner group then
# provides group write access only to required directories.
# Hides the `.env` file so it's not visible to other users on the system.
run_set_application_file_permissions(){
  cd "$BOOKSTACK_DIR" || exit
  chown -R www:www ./
  chmod -R 755 ./
  chmod -R 775 bootstrap/cache public/uploads storage
  chmod 740 .env

  # Tell git to ignore permission changes
  git config core.fileMode false
}

# Reload configs
reload_config(){
service php-fpm restart
service nginx reload
}

sleep 1

info_msg "[1/12] Set hostname"
set_hostname

info_msg "[2/12] Enable autostart for php, nginx and mysql"
run_autostart

info_msg "[3/12] Setup php-fpm"
setup_php-fpm

info_msg "[4/12] Start the service"
start_service

info_msg "[5/12] Set up database"
run_database_setup

info_msg "[6/12] Install composer"
run_install_composer

info_msg "[7/12] Download BookStack"
run_bookstack_download

info_msg "[8/12] Install BookStack composer dependencies"
run_install_bookstack_composer_deps

info_msg "[9/12] Run the BookStack database migrations for the first time"
run_bookstack_database_migrations

info_msg "[10/12] Copy and update BookStack environment variables"
run_update_bookstack_env

info_msg "[11/12] Set file and folder permissions"
run_set_application_file_permissions

info_msg "[12/12] Reload configs"
reload_config

touch /root/PLUGIN_INFO
echo "DATABASE_NAME=bookstack" >> /root/PLUGIN_INFO
echo "DB_USERNAME=bookstack" >> /root/PLUGIN_INFO
echo "DB_PASSWORD=$DB_PASS" >> /root/PLUGIN_INFO
