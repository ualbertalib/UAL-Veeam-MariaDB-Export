package UALBackups; 

use strict; 
use Data::Dumper; 
use JSON;
use Exporter;

our @ISA= qw( Exporter );

# these CAN be exported.
our @EXPORT_OK = qw( readConfigFile killSnapshotDatabase unmountSnapshot removeSnapshot cleanUp startDatabase log gone );
# these are exported by default.
our @EXPORT = qw( readConfigFile killSnapshotDatabase unmountSnapshot removeSnapshot cleanUp startDatabase log gone);

my $DEBUG = 0;  # disabled by default
$DEBUG = $ENV{"DEBUG"} if defined $ENV{"DEBUG"};  # settable from the environment, if you like


sub readConfigFile {
	# Read my configuration file
	my $configPath="/etc/UAL-Veeam-MariaDB-Export.conf";
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
	return $cfg;
}

sub killSnapshotDatabase   {
	my $cfg = $_; 
	# If the "snapshot" database is running, kill it
	`ps -ef | grep snap.cnf | grep mysql | awk -F" " '{ print \$2; }' | xargs kill `;
	my $killTimeout = $cfg->{"killTimeout"};
	&log("Sleeping for $killTimeout seconds, waiting for a database I might have killed to die");
	sleep $killTimeout;
}

sub unmountSnapshot {
	# Unmount the snapshot, if it's mounted
	if (-d "/mnt/snapshot/mysql") {  # existence of this directory suggests the snapshot is mounted
		`umount /mnt/snapshot`; 
		if ($? == 0 ) {
			&log ("Successfully unmounted the snapshot");
		} else {
			&log ("Tried and failed to unmount the snapshot!");
		}
	}
}

sub removeSnapshot {
	# remove the snapshot, if it exists
	my $cfg = $_; 
	my $LV = "/dev/" . $cfg->{"mysqlVolumeGroup"} . "/snap";
	if (-e $LV) {
		`lvremove --force $LV`; 
		if ($? == 0) {
			&log ("Successfully removed the LVM snapshot, $LV");
		} else {
			&log ("Tried to destroy the snapshot, $LV, but failed!");
		}
	}
}

sub cleanUp {
	my $cfg = $_; 
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
}

sub startDatabase {
	# Start the database service
	`systemctl start mariadb.service`;
	&gone("Unable to restart the mariadb service, after making the snapshot") unless ($? == 0);  # does not return
	&log ("Database re-started");

}

sub log {
	my $string = shift;
	$DEBUG && print "$string\n";
	`logger -p local0.info -t post-backup "$string"`; 
}

# Call logger & then exit with input
sub gone {
	my $string = shift;
	&log("ERROR: $string"); 
	die $string;
}

1; 
