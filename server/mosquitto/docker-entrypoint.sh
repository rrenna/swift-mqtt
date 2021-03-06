#!/bin/ash
set -e

MOSQUITTO_PASSWORDFILE="password.txt"

if [ ! -f "${MOSQUITTO_PASSWORDFILE}" ]
then
  echo "$0: File '${MOSQUITTO_PASSWORDFILE}' not found."
  exit 1
fi

# Convert the password file.
mosquitto_passwd -U $MOSQUITTO_PASSWORDFILE

exec "$@"
