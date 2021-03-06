#!/bin/bash

# Make sure we react to these signals by running stop() when we see them - for clean shutdown
# And then exiting
trap "stop; exit 0;" SIGTERM SIGINT

stop()
{
  # We're here because we've seen SIGTERM, likely via a Docker stop command or similar
  # Let's shutdown cleanly
  echo "SIGTERM caught, terminating NFS process(es)..."
  /usr/sbin/exportfs -uav
  /usr/sbin/rpc.nfsd 0
  pid1=`pidof rpc.nfsd`
  pid2=`pidof rpc.mountd`
  # For IPv6 bug:
  pid3=`pidof rpcbind`
  kill -TERM $pid1 $pid2 $pid3 > /dev/null 2>&1
  echo "Terminated."
  exit
}

# Check if the SHARED_DIRECTORY variable is empty
if [ -z "${SHARED_DIRECTORY}" ]; then
  echo "The SHARED_DIRECTORY environment variable is unset or null, exiting..."
  exit 1
else
  echo "Writing SHARED_DIRECTORY to /etc/exports file"
  /bin/sed -i "s@{{SHARED_DIRECTORY}}@${SHARED_DIRECTORY}@g" /etc/exports
fi

# Added multiple shared directories
for fd in "${!SHARED_DIRECTORY_@}"; do
    if [[ ! -z "${fd}" ]]; then
        echo "Writing ${!fd} directory to /etc/exports file"
        echo "{{SHARED_DIRECTORY_REP}} {{PERMITTED}}({{READ_ONLY}},{{SYNC}},no_subtree_check,no_auth_nlm,insecure,no_root_squash)" >> /etc/exports
        /bin/sed -i "s@{{SHARED_DIRECTORY_REP}}@${!fd}@g" /etc/exports
    fi
done

# Cecking if the ownership of the directory needs to be changed
if [ -z "${DIRECTORY_UID}" ]; then
  echo "The UID environment variable is unset or null, doing nothing"
else
  if [ -z "${DIRECTORY_GID}" ]; then
      echo "Changing user ownership of the SHARED_DIRECTORY to $DIRECTORY_UID:$DIRECTORY_UID (found no $DIRECTORY_GID env value)"
      /bin/chown ${DIRECTORY_UID}:${DIRECTORY_UID} ${SHARED_DIRECTORY}
  else
    echo "Changing user ownership of the SHARED_DIRECTORY to $DIRECTORY_UID:$DIRECTORY_GID"
    /bin/chown ${DIRECTORY_UID}:${DIRECTORY_GID} ${SHARED_DIRECTORY}
  fi
fi

# Setting the correct permissions for the shared directory
if [ -z "${DIRECTORY_PERMISSIONS}" ]; then
  echo "The DIRECTORY_PERMISSIONS environment variable is unset or null, doing nothing"
else
  echo "Changing permissions of the SHARED_DIRECTORY"
  /bin/chmod ${DIRECTORY_PERMISSIONS} ${SHARED_DIRECTORY}
fi

# Check if the PERMITTED variable is empty
if [ -z "${PERMITTED}" ]; then
  echo "The PERMITTED environment variable is unset or null, defaulting to '*'."
  echo "This means any client can mount."
  /bin/sed -i "s/{{PERMITTED}}/*/g" /etc/exports
else
  echo "The PERMITTED environment variable is set."
  echo "The permitted clients are: ${PERMITTED}."
  /bin/sed -i "s/{{PERMITTED}}/"${PERMITTED}"/g" /etc/exports
fi

# Check if the READ_ONLY variable is set (rather than a null string) using parameter expansion
if [ -z ${READ_ONLY+y} ]; then
  echo "The READ_ONLY environment variable is unset or null, defaulting to 'rw'."
  echo "Clients have read/write access."
  /bin/sed -i "s/{{READ_ONLY}}/rw/g" /etc/exports
else
  echo "The READ_ONLY environment variable is set."
  echo "Clients will have read-only access."
  /bin/sed -i "s/{{READ_ONLY}}/ro/g" /etc/exports
fi

# Check if the SYNC variable is set (rather than a null string) using parameter expansion
if [ -z "${SYNC+y}" ]; then
  echo "The SYNC environment variable is unset or null, defaulting to 'async' mode".
  echo "Writes will not be immediately written to disk."
  /bin/sed -i "s/{{SYNC}}/async/g" /etc/exports
else
  echo "The SYNC environment variable is set, using 'sync' mode".
  echo "Writes will be immediately written to disk."
  /bin/sed -i "s/{{SYNC}}/sync/g" /etc/exports
fi

# use GRACE_TIME variable if avaliable
if [ -z ${GRACE_TIME+y} ]; then
  echo "GRACE_TIME variable is unset"
  GRACE_TIME_ARG=""
else
  echo "GRACE_TIME variable is set to ${GRACE_TIME}"
  GRACE_TIME_ARG="-G ${GRACE_TIME}"
fi

echo "Grace time argument = ${GRACE_TIME_ARG}"

# use LEASE_TIME variable if avaliable
if [ -z ${LEASE_TIME+y} ]; then
  echo "LEASE_TIME variable is unset"
  LEASE_TIME_ARG=""
else
  echo "LEASE_TIME variable is set to ${GRACE_TIME}"
  LEASE_TIME_ARG="-L ${LEASE_TIME}"
fi

echo "Lease time argument = ${LEASE_TIME_ARG}"

# Partially set 'unofficial Bash Strict Mode' as described here: http://redsymbol.net/articles/unofficial-bash-strict-mode/
# We don't set -e because the pidof command returns an exit code of 1 when the specified process is not found
# We expect this at times and don't want the script to be terminated when it occurs
set -uo pipefail
IFS=$'\n\t'

# This loop runs till until we've started up successfully
while true; do

  # Check if NFS is running by recording it's PID (if it's not running $pid will be null):
  pid=`pidof rpc.mountd`

  # If $pid is null, do this to start or restart NFS:
  while [ -z "$pid" ]; do
    echo "Displaying /etc/exports contents:"
    cat /etc/exports
    echo ""

    # Normally only required if v3 will be used
    # But currently enabled to overcome an NFS bug around opening an IPv6 socket
    echo "Starting rpcbind..."
    /sbin/rpcbind -w
    echo "Displaying rpcbind status..."
    /sbin/rpcinfo

    # Only required if v3 will be used
    # /usr/sbin/rpc.idmapd
    # /usr/sbin/rpc.gssd -v
    # /usr/sbin/rpc.statd

    echo "Starting NFS in the background..."
    /usr/sbin/rpc.nfsd --debug 8 --no-udp --no-nfs-version 2 --no-nfs-version 3 ${GRACE_TIME_ARG} ${LEASE_TIME_ARG}
    echo "Exporting File System..."
    if /usr/sbin/exportfs -rv; then
      /usr/sbin/exportfs
    else
      echo "Export validation failed, exiting..."
      exit 1
    fi
    echo "Starting Mountd in the background..."These
    /usr/sbin/rpc.mountd --debug all --no-udp --no-nfs-version 2 --no-nfs-version 3
# --exports-file /etc/exports

    # Check if NFS is now running by recording it's PID (if it's not running $pid will be null):
    pid=`pidof rpc.mountd`

    # If $pid is null, startup failed; log the fact and sleep for 2s
    # We'll then automatically loop through and try again
    if [ -z "$pid" ]; then
      echo "Startup of NFS failed, sleeping for 2s, then retrying..."
      sleep 2
    fi

  done

  # Break this outer loop once we've started up successfully
  # Otherwise, we'll silently restart and Docker won't know
  echo "Startup successful."
  break

done

while true; do

  # Check if NFS is STILL running by recording it's PID (if it's not running $pid will be null):
  pid=`pidof rpc.mountd`
  # If it is not, lets kill our PID1 process (this script) by breaking out of this while loop:
  # This ensures Docker observes the failure and handles it as necessary
  if [ -z "$pid" ]; then
    echo "NFS has failed, exiting, so Docker can restart the container..."
    break
  fi

  # If it is, give the CPU a rest
  sleep 1

done

sleep 1
exit 1