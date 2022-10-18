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
use Data::Dumper; 
use JSON;

my $DEBUG = 0;  # disabled by default
$DEBUG = $ENV{"DEBUG"} if defined $ENV{"DEBUG"};  # settable from the environment, if you like

$ENV{"PATH"} = "/sbin:/bin:/usr/sbin:/usr/bin:/root/bin";

# Read my configuration file
my $configPath="/etc/MariaDB_Simpana_Backup.conf";
open(CONFIG,$configPath) or &gone("Cannot open my config file, $configPath"); # does not return
my $JSONconfig=<CONFIG>;   # will only read one line
close CONFIG;
my $cfg=decode_json($JSONconfig);
$DEBUG && print "Results from reading the config file:\n",  Dumper($cfg);
# Input validation: at least these must exist...
defined $cfg->{"mysqlVolumeGroup"} or &gone("Config file $configPath didn't specify 'mysqlVolumeGroup'");
defined $cfg->{"backupDir"} or &gone("Config file $configPath didn't specify 'backupDir'");
defined $cfg->{"daysToRetainBackups"} or &gone("Config file $configPath didn't specify 'daysToRetainBackups'");
defined $cfg->{"killTimeout"} or &gone("Config file $configPath didn't specify 'killTimeout'");
&log ("Read $configPath");

# If the "snapshot" database is running, kill it
`ps -ef | grep snap.cnf | grep mysql | awk -F" " '{ print \$2; }' | xargs kill `;
my $killTimeout = $cfg->{"killTimeout"};
&log("Sleeping for $killTimeout seconds, waiting for a database I might have killed to die");
sleep $killTimeout;

# Unmount the snapshot, if it's mounted
if (-d "/mnt/snapshot/mysql") {  # existence of this directory suggests the snapshot is mounted
	`umount /mnt/snapshot`; 
	if ($? == 0 ) {
		&log ("Successfully unmounted the snapshot");
	} else {
		&log ("Tried and failed to unmount the snapshot!");
	}
}
# remove the snapshot, if it exists
my $LV = "/dev/" . $cfg->{"mysqlVolumeGroup"} . "/snap";
if (-e $LV) {
	`lvremove --force $LV`; 
	if ($? == 0) {
		&log ("Successfully removed the LVM snapshot, $LV");
	} else {
		&log ("Tried to destroy the snapshot, $LV, but failed!");
	}
}

# Clean up files in the backup directory
my $backupDir = $cfg->{"backupDir"}; my $cmd; my $filename;
open ($cmd,  "/usr/bin/find $backupDir -name \"mysql_backup_*.tar\" -ctime +" . $cfg->{"daysToRetainBackups"} . " |") || &gone("Can't run the find command");
while ($filename  = <$cmd>) {
	chomp $filename;
	unlink $filename || &gone("Failed to delete $filename");
	&log("Deleted:$filename\n");
}

# Also silently cleanup the tmpdir, which can result if the pre-scan script fails.
`/bin/rm -rf $backupDir/tmp/*`;
&log("Cleaned up $backupDir/tmp/");

# Start the database service
`systemctl start mariadb.service`;
&gone("Unable to restart the mariadb service, after making the snapshot") unless ($? == 0);  # does not return
&log ("Database re-started");


&log("post-backup.pl finished");

sub log {
	my $string = shift;
	`logger -p local0.info -t post-backup "$string"`; 
}


# Call logger & then exit with input
sub gone {
my $string = shift;
&log("ERROR: $string"); 
die $string;
}
# intended EOF
