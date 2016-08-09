# Mounting of encrypted cloud storage with Encfs and UnisonFS

## Theorie
Cloud Speicher wird immer günstiger und ist mittlerweise (z.B. über [OVH/Hubic](https://hubic.com/home/new/?referral=TQHECA); Reflnk) für fünf Euro im Monat/50 Euro im Jahr zu haben. Und gerade erst kürzlich hat Amazon sein [Unlimited Cloud Drive Angebot auch in Deutschland gestarten](http://stadt-bremerhaven.de/amazon-unendlicher-speicher-fuer-70-euro/). Für den Fall das ein Anwender seine Daten nicht unverschlüsselt zu einem solchen Anbieter hochladen möchte gibt es die Anwendung [EncFS](https://de.wikipedia.org/wiki/EncFS) welche es erlaubt diese Daten zu verschlüssel, bevor diese zum Anbieter hochgeladen werden. Um einen schnellen Zugriff auf neu hinzugefügt Elemente zu haben soll der Cloudspeicher über ein UnionFS Overlay eingebunden werden.

```
/media/cloud                  <- Startpunkt
/media/cloud/source           <- unverschlüsselter Mountpunkt des Cloudanbieters
/media/cloud/source/.private  <- Speicherort der verschlüsselten Daten innerhalb der Cloudspeichers
/media/cloud/.decrypted       <- Mountpunkt für EncFS (zeigt verschlüsselte Daten unverschlüsselt an)
/media/cloud/.cache           <- Zwischenspeicher und R/W Speicherort für UnionFS
/media/cloud/.cache-encrypted <- Temporärer Mount (verschlüsselte Daten) welcher während des Updloads eingehangen ist
/media/cloud/local            <- Speicherort der vom Nutzer genutzt wird (von UnionFS bereitgestellt)
```

**HINWEIS:** EncFS gilt als potentiell unsicher, da ein Angreifer der in Besitz mehrere Versionen einer Datei ist den verwendeten Schlüssel errechnen kann. Mehr dazu unter https://defuse.ca/audits/encfs.htm.

## Installation

Vor der ersten Ausführung müssen sowohl encfs als auch unionfs-fuse installiert sein. Ohne diese beiden Abhängigkeiten wird das Skript den Start abbrechen.
```
apt install encfs unionfs-fuse
```
To simplify the installation of the script itself you can call ```make install``` to install the script, the example configuration and the cron job (and ```make uninstall``` to remove them again).

### Konfiguration
If a personalised configuration should be used the ```config-example``` file has to be renamed to ```config``` and adapted. The default settings should be fine for most environments.

## Usage
The script ```mount-encfs-cloud.sh``` accepts some parameters: 
- if called **without arguments** or with the argument **mount** it mounts the storage.
- if called with the argument **unmount** or **umount** it unmounts the storage.
- if called with the argument **sync** it copies files from the cache dir to the cloud
- if called with the argument **clean-deleted** it removes files from the cloud, that have been deleted from the unionfs mount.
- acd_cli has the habit of destroying the mount when calling **acd_cli sync**. To detect such a case the script can be called with the argument **check-mount** (which will remount the storage).

Have a look at [rclone-encfs-wrapper](https://github.com/fbartels/rclone-encfs-wrapper) for an alternate way of copying files to the cloud storage.

## Inspiration
- https://amc.ovh/2015/08/13/infinite-media-server.html
- https://amc.ovh/2015/08/15/uniting-encrypted-encfs-filesystems.html
- https://amc.ovh/2015/08/14/mounting-uploading-amazon-cloud-drive-encrypted.html
-  https://www.reddit.com/r/DataHoarder/comments/3uj5v4/experienced_amazon_cloud_drive_users_tips_useful/
- https://unix.stackexchange.com/questions/289522/automount-with-autofs-encfs-and-keyring-access
- https://ufie.de/encfs-verschluesseltes-laufwerk-mit-autofs-vom-hostingpackungserver-ueber-cifs-mounten/
- https://news.ycombinator.com/item?id=12043712

## Anbieter
- https://www.amazon.com/clouddrive/unlimited
- https://hubic.com/en/offers/
