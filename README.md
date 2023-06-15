# UofA's Veeam Integration Scripting, for MariaDB

* Inception: Oct 18, 2022
* This exists because Veeam does NOT integrate with MariaDB (even though it does with MySQL, PostgreSQL, and Oracle)

## Veeam Agent Overview

* Started by Veeam, the pre-scan script makes a snapshot of the DB volume, mounts it, starts a second copy of the DB on it, and dumps .SQL files from that DB.
* Next, it unwinds all that, and stops the replica database service, so /var/lib/mysql/ will be quiesced when Veeam snapshots it.
* Then, Veeam proceeds make the snapshots.
* Next, Veeam runs the post-backup scripts, putting the replica database service back online.
* Finally, Veeam backs up the snapshots, then releases them.

## Recommendations for a Dev environment:

* Choose a server like mariadb-db-dev-secondary-1
* `git clone git@github.com:ualbertalib/UAL-Veeam-MariaDB-Export.git` maybe as root, in root's home dir
* `export DEBUG=1` - Set this variable to have it echo syslog output to STDOUT
* Make sure that you uninstall any previous version of the RPM! 
    * Reminder, the package for CommVault was: MariaDB_Simpana_Backup
    * ... and the new name is: UAL-Veeam-MariaDB-Export
* Note that uninstalling the RPM will rename your config files, so you'll need to rescue them, eg:

```
warning: /etc/snap.cnf saved as /etc/snap.cnf.rpmsave
warning: /etc/logrotate.d/mariadb-snapshot saved as /etc/logrotate.d/mariadb-snapshot.rpmsave
warning: /etc/UAL-Veeam-MariaDB-Export.conf saved as /etc/UAL-Veeam-MariaDB-Export.conf.rpmsave
```

* `export PERL5LIB=/root/UAL-Veeam-MariaDB-Export` Why? Because if the file /usr/local/bin/UALBackups.pm exists, it will be used !first!, ahead of anything found in $PERL5LIB :)  You have been warned!
* If you'd like to try running it from cron, consider: 

```
cd /usr/local/bin
ln -s /root/UAL-Veeam-MariaDB-Export/pre-scan.pl .
ln -s /root/UAL-Veeam-MariaDB-Export/post-backup.pl .
ln -s /root/UAL-Veeam-MariaDB-Export/UALBackups.pm .
```

... but obviously, you'd have to remember to undo that, before attempting to install it from RPM again!!
