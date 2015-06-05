#!/bin/bash
#
# This script is run on every ami change.
#+ This is the place to do things like database initilizations and migrations.
#
#set -x

INSTALL_ROOT='/var/www/mediawiki'
LOGGER_BIN='/usr/bin/logger'

# Set up the logger command if the binary is installed
if [ ! -x $LOGGER_BIN ]; then
    echo "ERROR: 'logger' binary not found - Aborting"
    echo "ERROR: '$BASH_SOURCE' Line: '$LINENO'"
    exit 2
else
    LOGGER="$LOGGER_BIN --stderr --priority local7.info --tag migrate.sh"
fi

# Source the consul connection details from the metadata api
eval `curl -fq http://169.254.169.254/latest/user-data`

# Check to see if NUBIS_MIGRATE was set in userdata. If not we exit quietly.
if [ ${NUBIS_MIGRATE:-0} == '0' ]; then
    exit 0
fi

# Set up the consul url
CONSUL="http://localhost:8500/v1/kv/$NUBIS_PROJECT/$NUBIS_ENVIRONMENT/config"

# We run early, so we need to account for Consul's startup time, unfortunately, magic isn't
# always free
CONSUL_UP=-1
COUNT=0
while [ "$CONSUL_UP" != "0" ]; do
    if [ ${COUNT} == "6" ]; then
        $LOGGER "ERROR: Timeout while attempting to connect to consul."
        exit 1
    fi
    QUERY=`curl -s ${CONSUL}?raw=1`
    CONSUL_UP=$?

    if [ "$QUERY" != "" ]; then
        CONSUL_UP=-2
    fi

    if [ "$CONSUL_UP" != "0" ]; then
      $LOGGER "Consul not ready yet ($CONSUL_UP). Sleeping 10 seconds before retrying..."
      sleep 10
      COUNT=${COUNT}+1
    fi
done

# Generate and set the secrets for the app
wgDBpassword=`curl -s $CONSUL/wgDBpassword?raw=1`
if [ "$wgDBpassword" == "" ]; then
    wgDBpassword=`makepasswd --minchars=12 --maxchars=16`
    curl -s -X PUT -d $wgDBpassword $CONSUL/wgDBpassword
fi
echo " + wgSecretKey=$wgSecretKey"

wgSecretKey=`curl -s $CONSUL/wgSecretKey?raw=1`
if [ "$wgSecretKey" == "" ]; then
    wgSecretKey=`uuidgen`
    curl -s -X PUT -d $wgSecretKey $CONSUL/wgSecretKey
fi
echo " + wgSecretKey=$wgSecretKey"

wgUpgradeKey=`curl -s $CONSUL/wgUpgradeKey?raw=1`
if [ "$wgUpgradeKey" == "" ]; then
    wgUpgradeKey=`uuidgen`
    curl -s -X PUT -d $wgUpgradeKey $CONSUL/wgUpgradeKey
fi
echo " + wgUpgradeKey=$wgUpgradeKey"

# Grab the variables from consul
#+ If this is a new stack we need to wait for the values to be placed in consul
#+ We will test the first and sleep with a timeout
KEYS_UP=-1
COUNT=0
while [ "$KEYS_UP" != "0" ]; do
    # Try for 20 minutes (30 seconds * 20160 attempts = 604800 seconds / 60 seconds / 60 minutes / 12 hours = 7 days)
    if [ ${COUNT} == "20160" ]; then
        $LOGGER "ERROR: Timeout while waiting for keys to be populated in consul."
        exit 1
    fi
    QUERY=`curl -s $CONSUL/wgDBserver?raw=1`

    if [ "$QUERY" == "" ]; then
        $LOGGER "Keys not ready yet. Sleeping 30 seconds before retrying..."
        sleep 30
        COUNT=${COUNT}+1
    else
        KEYS_UP=0
    fi
done

# Now we can safely gather the values
wgDBserver=`curl -s $CONSUL/wgDBserver?raw=1`
wgDBname=`curl -s $CONSUL/wgDBname?raw=1`
wgDBuser=`curl -s $CONSUL/wgDBuser?raw=1`

# Reset the database password on first run
# Create mysql defaults file
echo -e "[client]\npassword=$wgDBpassword\nhost=$wgDBserver\nuser=$wgDBuser" > .DB_DEFAULTS
# Test the current password
TEST_PASS=`mysql --defaults-file=.DB_DEFAULTS $wgDBname -e "show tables" 2>&1`
if [ `echo $TEST_PASS | grep -c 'ERROR 1045'` == 1 ]; then
    # Use the provisioner pasword to cange the password
    echo -e "[client]\npassword=provisioner_password\nhost=$wgDBserver\nuser=$wgDBuser" > .DB_DEFAULTS
    $LOGGER "Detected provisioner passwrod, reseting database password."
    mysql --defaults-file=.DB_DEFAULTS $wgDBname -e "SET PASSWORD FOR '$wgDBuser'@'%' = password('$wgDBpassword')"
    RV=$?
    if [ $RV != 0 ]; then
        $LOGGER "ERROR: Could not access mysql database ($RV), aborting."
        exit $RV
    fi
    # Rewrite defaults file with updated password
    echo -e "[client]\npassword=$wgDBpassword\nhost=$wgDBserver\nuser=$wgDBuser" > .DB_DEFAULTS
fi

# Initilize the database if it is not already done
if [ `mysql --defaults-file=.DB_DEFAULTS $wgDBname -e "show tables" | grep -c ^` == 0 ];then
    $LOGGER "No database tables found, creating tables."
    mysql --defaults-file=.DB_DEFAULTS $wgDBname < $INSTALL_ROOT/maintenance/tables.sql
    RV=$?
    if [ $RV != 0 ]; then
        $LOGGER "ERROR: Could not create database tables ($RV), aborting."
        exit $RV
    fi
fi

# Clean up
rm -f .DB_DEFAULTS

# Run the database migrations
#+ This command is safe to run multiple times
$LOGGER "Running database migrations."
php $INSTALL_ROOT/maintenance/update.php --quick
RV=$?
if [ $RV != 0 ]; then
    $LOGGER "ERROR: Error running database migrations ($RV), aborting."
    exit $RV
fi

# Check to see if /data is mounted
#+ Create directories if they do not exist
while [ ${DONE:-0} -lt '60' ]; do
    MOUNT_TEST=`mountpoint -q /data/wiki.mozilla.org/`
    MOUNT_UP=$?
    if [ $MOUNT_UP == 0 ]; then
        if [ ! -d '/data/wiki.mozilla.org/tmp' ]; then
            mkdir '/data/wiki.mozilla.org/tmp'
            chown ubuntu:ubuntu '/data/wiki.mozilla.org/tmp'
        fi
        if [ ! -d '/data/wiki.mozilla.org/images' ]; then
            mkdir '/data/wiki.mozilla.org/images'
            chown www-data:www-data '/data/wiki.mozilla.org/images'
        fi
        if [ ! -d '/data/wiki.mozilla.org/charts' ]; then
            mkdir '/data/wiki.mozilla.org/charts'
            chown www-data:www-data '/data/wiki.mozilla.org/charts'
        fi
        DONE=255
    else
        echo "Waiting for mount point (sleep 10)"
        sleep 10
        let DONE=$DONE+1
    fi
done
