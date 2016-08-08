prefix=/usr/local

install:
	install -m 0755 mount-encfs-cloud.sh $(prefix)/bin
	install -m 0755 cron.upload-changes /etc/cron.daily/encfs-cloud-upload

uninstall:
	rm $(prefix)/bin/mount-encfs-cloud.sh
	rm /etc/cron.daily/encfs-cloud-upload

.PHONY: install uninstall
