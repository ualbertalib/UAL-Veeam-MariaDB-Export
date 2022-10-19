# UofA's Veeam Integration Scripting, for MariaDB

* Inception: Oct 18, 2022
* This exists because Veeam does NOT integrate with MariaDB (even though it does with MySQL, PostgreSQL, and Oracle)

## Veeam Agent Overview

* Started by Veeam, the pre-scan script  makes a snapshot of the DB volume, mounts it, starts a second copy of the DB on it, and dumps .SQL files from that DB.
* Next, it unwinds all that, and stops the replica database service, so /var/lib/mysql/ will be quiesced when Veeam snapshots it.
* Then, Veeam proceeds make the snapshots.
* Next, Veeam runs the post-backup scripts, putting the replica database service back online.
* Finally, Veem backs up the snapshots, then releases them.


## Recommendations for a Dev environment:

* Choose a server like mariadb-db-dev-secondary-1
* `git clone git@github.com:ualbertalib/UAL-Veeam-MariaDB-Export.git` maybe as root, in root's home dir
* `export DEBUG=1` - Set this variable to have it echo syslog output to STDOUT
* Make sure that you uninstall any previous version of the RPM, reminder, the package for CommVault was: "MariaDB_Simpana_Backup"
* `export PERL5LIB=/root/UAL-Veeam-MariaDB-Export` Why? Because if the file /usr/local/bin/UALBackups.pm exists, it will be used !first!, ahead of anything found in $PERL5LIB :)  You have been warned!
* If you'd like to try running it from cron, consider: 

```
[root@mariadb-db-tst-secondary-1 UAL-Veeam-MariaDB-Export]# ln -s pre-scan.pl /usr/local/bin
[root@mariadb-db-tst-secondary-1 UAL-Veeam-MariaDB-Export]# ln -s post-backup.pl /usr/local/bin
[root@mariadb-db-tst-secondary-1 UAL-Veeam-MariaDB-Export]# ln -s UALBackups.pm  /usr/local/bin
```

... but obviously, you'd have to remember to undo that, before attempting to install it from cr
