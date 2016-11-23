#!/usr/bin/env bash
set -e
set -u

## Defaults

MOUNT_ROOT="/media/cloud"
CLOUD_PATH="$MOUNT_ROOT/source"
CRYPT_PATH="$CLOUD_PATH/.private"
ENCFS_PATH="$MOUNT_ROOT/.decrypted"
ENCFS_REVERSE_PATH="$MOUNT_ROOT/.cache-encrypted"
OVERLAY_CACHE="$MOUNT_ROOT/.cache"
OVERLAY_PATH="$MOUNT_ROOT/local"
ENCFS_PASSWORD=$HOME/.config/encfs-password
ENCFS_CONFIG=$HOME/.config/encfs-cloud.xml
# Rclone settings
RCLONE_REMOTE="acd"                             # name of the remote configured in rclone
RCLONE_PATH=$(basename $CRYPT_PATH)             # directory at cloud provider, will be created if it does not exist
# Mount settings
USER=$(whoami)
GROUP=users
MOUNT_ENGINE=acdcli	# TODO can be acdcli or rclone

## no need to change anything below

# if a config file has been specified with BACKUP_CONFIG=myfile use this one, otherwise default to config
set +u
BASE_PATH="$(dirname "$(readlink -f "$0")")"
if [[ ! -n "$BACKUP_CONFIG" ]]; then
	BACKUP_CONFIG="$BASE_PATH/config"
fi

if [ -e $BACKUP_CONFIG ]; then
	echo "using config from file: $BACKUP_CONFIG"
	source "$BACKUP_CONFIG"
fi
set -u

# check dependencies
if [ ! "$(which encfs)" ]; then
	echo "encfs is not installed"
	exit 1
fi

if [ ! "$(which unionfs-fuse)" ]; then
	echo "unionfs-fuse is not installed"
	exit 1
fi

if [ ! "$(which acd_cli)" ] || [ ! "$(which rclone)" ]; then
	echo "Neither acd_cli nor rclone is not installed"
	echo "https://github.com/yadayada/acd_cli/blob/master/docs/setup.rst"
	echo "http://rclone.org/install/"
	exit 1
fi


# script logic begins here
# if CLOUD_PATH does not exist, check if folder is writeable, if not create and chown it with sudo
if [ ! -d $MOUNT_ROOT ] && [ ! -w $MOUNT_ROOT ]; then
	echo "MOUNT_ROOT does not yet exist, but MOUNT_ROOT is not writeable. Calling sudo for help."
	sudo mkdir -p $MOUNT_ROOT
	sudo chown $(id -un):$(id -gn) $MOUNT_ROOT
else
	mkdir -p $MOUNT_ROOT
fi

# test if user_allow_other is set in /etc/fuse.conf
test_fuse(){
	set +e
	grep '^user_allow_other' /etc/fuse.conf > /dev/null
	if [ $? -ne 0 ]; then
		echo "either /etc/fuse.conf is not readable, or the option 'user_allow_other' is not set".
		exit 1
	fi
}

mount_clouddir_acdcli(){
	#check_mounted $CLOUD_PATH
	if grep -qs $CLOUD_PATH /proc/mounts; then
		echo "already mounted"
		exit 1
	fi
	mkdir -p $CLOUD_PATH
	echo "sync acd_cli metadata"
	acd_cli sync
	echo "mount acd_cli"
	acd_cli mount --allow-other --interval 0 $CLOUD_PATH
	# wait for mount to settle
	sleep 5
}

mount_clouddir_rclone(){
	#check_mounted $CLOUD_PATH
	if grep -qs $CLOUD_PATH /proc/mounts; then
		echo "already mounted"
		exit 1
	fi
	mkdir -p $CLOUD_PATH
	echo "mount rclone"
	rclone mount "$RCLONE_REMOTE":/ $CLOUD_PATH &
	sleep 5
}

mount_encfs(){
	until $(mkdir -p $CRYPT_PATH $ENCFS_PATH); do
		sleep 1
	done
	echo "mount encfs dir"
	UMASK=007
	uid=$(id -u $USER)
	gid=$(getent group $GROUP | cut -d: -f 3)
	ENCFS6_CONFIG=$ENCFS_CONFIG encfs -o allow_other -o umask=$UMASK,gid=$gid,uid=$uid --ondemand --idle=5 --extpass="cat $ENCFS_PASSWORD" $CRYPT_PATH $ENCFS_PATH
}

mount_reverse_encfs(){
	mkdir -p $ENCFS_REVERSE_PATH
	echo "mount reverse encfs dir"
	ENCFS6_CONFIG=$ENCFS_CONFIG encfs -o allow_other --reverse --extpass="cat $ENCFS_PASSWORD" $OVERLAY_CACHE $ENCFS_REVERSE_PATH
}

mount_overlay(){
	test_fuse
	mkdir -p $OVERLAY_CACHE $OVERLAY_PATH
	echo "mount overlay"
	unionfs-fuse -o cow -o allow_other $OVERLAY_CACHE=RW:$ENCFS_PATH=RO $OVERLAY_PATH
}

create_encfs(){
	mkdir -p $OVERLAY_CACHE $ENCFS_REVERSE_PATH
	encfs --standard --reverse --extpass="cat $ENCFS_PASSWORD" $OVERLAY_CACHE $ENCFS_REVERSE_PATH

	# waiting for mount to settle
	sleep 3
	fusermount -u $ENCFS_REVERSE_PATH

	echo "moving xml"
	mv $OVERLAY_CACHE/.encfs6.xml $ENCFS_CONFIG
}

if [ ! -e $HOME/.cache/acd_cli ]; then
	echo "no oauth data for acd_cli found found. running 'acd_cli init'"
	acd_cli init
	exit
fi

if [ ! -e $ENCFS_PASSWORD ]; then
	echo "generating encfs password"
	PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 100 | head -n 1)
	echo $PASSWORD > $ENCFS_PASSWORD
fi

if [ ! -e $ENCFS_CONFIG ]; then
	echo "no encfs config xml found. Assuming new setup and creating new mount."
	create_encfs
fi

# default to $0 mount, if not specified otherwise
runoption=${1:-mount}

case $runoption in
mount)
	case $MOUNT_ENGINE in
		acdcli) mount_clouddir_acdcli;;
		rclone) mount_clouddir_rclone;;
		*) echo "unknown engine"; exit 1;;
	esac
	mount_encfs
	mount_overlay
	;;
umount|unmount)
	# TODO create function for unmounting which checks if programs are still accessing the mount and retrying later on
	# https://github.com/scriptzteam/rclone-re-mount/blob/master/rclone_remount.sh
	set +e
	echo "unmounting everything"
	fusermount -u $OVERLAY_PATH
	sleep 3
	fusermount -u $ENCFS_PATH
	sleep 3
	fusermount -u $CLOUD_PATH
	;;
sync)
	if [ ! -d $OVERLAY_CACHE ]; then
		echo "OVERLAY_CACHE_PATH does not exist"
		exit 1
	fi
	mount_reverse_encfs
	if [ "$(ls -A $ENCFS_REVERSE_PATH)" ]; then
		if [ $(which rclone) ]; then
			rclone --verbose --transfers=1 copy $ENCFS_REVERSE_PATH "$RCLONE_REMOTE":/"$RCLONE_PATH"
		else
			acd_cli upload --overwrite $ENCFS_REVERSE_PATH/* /$(basename $CRYPT_PATH)/  --max-connections 10
		fi
		sleep 3
		#refresh mount
		case $MOUNT_ENGINE in
			acdcli) acd_cli sync;;
			rclone) $0 umount && $0 mount;;
			*) echo "unknown engine"; exit 1;;
		esac
	else
		echo "Nothing to sync"
	fi
	fusermount -u $ENCFS_REVERSE_PATH
	rmdir $ENCFS_REVERSE_PATH

	$0 check-mount
	;;
clean-deleted)
	echo "cleaning locally deleted files from acd, remove empty dirs in cache"
	rsync --verbose --recursive --delete --existing --ignore-existing $OVERLAY_PATH/ $ENCFS_PATH/
	if [ -d $OVERLAY_CACHE/.unionfs-fuse ]; then
		rm -rf $OVERLAY_CACHE/.unionfs-fuse
	fi
	# only delete empty dir, if there are files at all
	if [ "$(ls -A $OVERLAY_CACHE)" ]; then
		find $OVERLAY_CACHE -type d -empty -delete
	fi
	sudo sudo mount -t unionfs -o remount,incgen unionfs $OVERLAY_PATH
	;;
clean-old-files)
	days=730
	echo "deleting files older than $days days"
	find $OVERLAY_CACHE -type f -mtime +$days -delete
	find $OVERLAY_CACHE -type d -empty -delete
	;;
check-mount)
	set +e
	ls $CLOUD_PATH > /dev/null
	if [ $? -ne 0 ]; then
		echo "Error: there seems to be a problem with the mount. Remounting.."
		$0 umount > /dev/null
		$0 mount > /dev/null
	fi
	;;
*)
	echo "unknown command"
	echo "Available options are: mount, unmount, sync, clean-deleted, check-mount"
	;;
esac
