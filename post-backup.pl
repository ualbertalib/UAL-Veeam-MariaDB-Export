#!/usr/bin/perl -w 
# Author:	Neil MacGregor
# Date: 	Oct 18, 2022
# Provenance:	This came from a similar script written for CommVault Simpana, ref: https://code.library.ualberta.ca/gitweb/?p=MariaDB_Simpana_Backup;a=summary, ca. 2013
# Version: 
# Purpose:	* This script will be called from the Veeam Agent, after it has completed either
# 		  a Full or Incremental backup.  In normal operation, it unmounts the snapshot created by 
# 		  the pre-scan.pl script, before removing the snapshot and restarting the MariaDB service.
# 		* It is also designed to kill the 'snapshot' database on port 3307 (although it should 
# 		not have been left running), as this would prevent the unmount!
# 		* It also deletes older tarballs, left behind in the backupdir
# Reference: 
use strict; 
use UALBackups;

my $DEBUG = 0;  # disabled by default
$DEBUG = $ENV{"DEBUG"} if defined $ENV{"DEBUG"};  # settable from the environment, if you like

$ENV{"PATH"} = "/sbin:/bin:/usr/sbin:/usr/bin:/root/bin";

# Read my configuration file
$UALBackups::operation="post-backup";
my $cfg=readConfigFile();

# If the "snapshot" database is running, kill it
killSnapshotDatabase($cfg);

# Unmount the snapshot, if it's mounted
unmountSnapshot();

# remove the snapshot, if it exists
removeSnapshot($cfg); 

# Clean up files in the backup directory
cleanUp($cfg); 

# Start the database service
startDatabase();

&log("post-backup.pl finished");

# intended EOF
