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

## no need to change anything below

# if a config file has been specified with BACKUP_CONFIG=myfile use this one, otherwise default to config
if [[ ! -n "$BACKUP_CONFIG" ]]; then
	BACKUP_CONFIG=config
fi

if [ -e $BACKUP_CONFIG ]; then
	echo "using config from file: $BACKUP_CONFIG"
	source $BACKUP_CONFIG
fi

# check dependencies
if [ ! "$(which encfs)" ]; then
	echo "encfs is not installed"
	exit 1
fi

if [ ! "$(which unionfs-fuse)" ]; then
	echo "unionfs-fuse is not installed"
	exit 1
fi

if [ ! "$(which acd_cli)" ]; then
	echo "acd_cli is not installed"
	echo "https://github.com/yadayada/acd_cli/blob/master/docs/setup.rst"
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

mount_clouddir(){
	#check_mounted $CLOUD_PATH
	if grep -qs $CLOUD_PATH /proc/mounts; then
		echo "already mounted"
		exit 1
	fi
	mkdir -p $CLOUD_PATH
	echo "sync acd metadata"
	acd_cli sync
	echo "mount acd"
	acd_cli mount --allow-other --interval 0 $CLOUD_PATH
	# wait for mount to settle
	sleep 5
}

mount_encfs(){
	until $(mkdir -p $CRYPT_PATH $ENCFS_PATH); do
		sleep 1
	done
	echo "mount encfs dir"
	ENCFS6_CONFIG=$ENCFS_CONFIG encfs -o allow_other --ondemand --idle=5 --extpass="cat $ENCFS_PASSWORD" $CRYPT_PATH $ENCFS_PATH
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
	mount_clouddir
	mount_encfs
	mount_overlay
	;;
umount|unmount)
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
	# optionally --remove-source-files could be used in upload, but this leads to situations where files are
	# removed from $ENCFS_REVERSE_PATH, but not yes listed in $CRYPT_PATH)
	if [ "$(ls -A $ENCFS_REVERSE_PATH)" ]; then
		acd_cli upload --overwrite $ENCFS_REVERSE_PATH/* /$(basename $CRYPT_PATH)/  --max-connections 10
		sleep 3
		acd_cli sync
		# delete files from local cache 14 days after they have been created
		find $OVERLAY_CACHE -type f -mtime +14 -delete
		#sudo mount -t unionfs -o remount,incgen $OVERLAY_PATH
	else
		echo "Nothing to sync"
	fi
	fusermount -u $ENCFS_REVERSE_PATH
	rmdir $ENCFS_REVERSE_PATH

	$0 check-mount
	;;
clean-deleted)
	echo "cleaning locally deleted files from acd, remove empty dirs in cache"
	rsync --recursive --delete --existing --ignore-existing $OVERLAY_PATH/ $ENCFS_PATH/
	if [ -d $OVERLAY_CACHE/.unionfs-fuse ]; then
		rm -rf $OVERLAY_CACHE/.unionfs-fuse
	fi
	# only delete empty dir, if there are files at all
	if [ "$(ls -A $OVERLAY_CACHE)" ]; then
		find $OVERLAY_CACHE -type d -empty -delete
	fi
	#sudo mount -t unionfs -o remount,incgen $OVERLAY_PATH
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
esac
