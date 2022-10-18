# UofA's Veeam Integration Scripting, for MariaDB

* Inception: Oct 18, 2022
* This exists because Veeam does NOT integrate with MariaDB (even though it does with MySQL, PostgreSQL, and Oracle)

## Veeam Agent Overview

* Started by Veeam, the pre-scan script  makes a snapshot of the DB volume, mounts it, starts a second copy of the DB on it, and dumps .SQL files from that DB.
* Next, it unwinds all that, and stops the replica database service, so /var/lib/mysql/ will be quiesced when Veeam snapshots it.
* Then, Veeam proceeds make the snapshots.
* Next, Veeam runs the post-backup scripts, putting the replica database service back online.
* Finally, Veem backs up the snapshots, then releases them.

