package UALBackups; 

use strict; 
use Data::Dumper; 
use JSON;
use Exporter;

our @ISA= qw( Exporter );

# these CAN be exported.
our @EXPORT_OK = qw( readConfigFile killSnapshotDatabase unmountSnapshot removeSnapshot cleanUp startDatabase stopDatabase log gone sizeof diskRemaining diskVol);
# these are exported by default.
our @EXPORT = qw( readConfigFile killSnapshotDatabase unmountSnapshot removeSnapshot cleanUp startDatabase stopDatabase log gone sizeof diskRemaining diskVol);

my $DEBUG = 0;  # disabled by default
$DEBUG = $ENV{"DEBUG"} if defined $ENV{"DEBUG"};  # settable from the environment, if you like

our $operation; 

sub readConfigFile {
	# Read my configuration file
	my $configPath="/etc/UAL-Veeam-MariaDB-Export.conf";
	open(CONFIG,$configPath) or &gone("Cannot open my config file, $configPath"); # does not return
	my $JSONconfig=<CONFIG>;   # will only read one line
	close CONFIG;
	my $cfg=decode_json($JSONconfig);
	$DEBUG && print "Results from reading the config file:\n",  Dumper($cfg);
	# Input validation: at least these must exist...
	defined $cfg->{"backupDir"} or &gone("Config file $configPath didn't specify 'backupDir'");
	(mkdir $cfg->{"backupDir"}  or &gone("Config directory " . $cfg->{"backupDir"} . " did not exist, cannot create it") ) unless -d $cfg->{"backupDir"};
	#.. based on backupDir..
	my $tempDir=$cfg->{"backupDir"} . "/tmp";
	(mkdir $tempDir or  &gone("Temp directory $tempDir did not exist, cannot create it")) unless -d  $tempDir;
	defined $cfg->{"binDir"} or &gone("Config file $configPath didn't specify 'binDir'");
	&gone($cfg->{"binDir"} . " does not contain post-backup.pl") unless -e ($cfg->{"binDir"} . "/post-backup.pl") ;
	defined $cfg->{"mysqlVolumeGroup"} or &gone("Config file $configPath didn't specify 'mysqlVolumeGroup'");
	defined $cfg->{"minimumTarballSize"} or &gone("Config file $configPath didn't specify 'minimumTarballSize'");
	defined $cfg->{"snapshotSize"} or &gone("Config file $configPath didn't specify 'snapshotSize'");
	defined $cfg->{"killTimeout"} or &gone("Config file $configPath didn't specify 'killTimeout'");
	defined $cfg->{"daysToRetainBackups"} or &gone("Config file $configPath didn't specify 'daysToRetainBackups'");
	&log ("Read $configPath");
	return $cfg;
}

sub killSnapshotDatabase   {
	my $cfg = $_[0]; 
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
	my $cfg = $_[0]; 
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
	my $cfg = $_[0]; 
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
	&log ("Replica database re-started");

}

sub stopDatabase {
	`systemctl stop mariadb.service `;
	&gone ("Failed shutting down the primary mysqld on this system") unless ($? == 0);  # checking return code ; does not return
	&log ("Replica database shut down");
}

sub log {
	my $string = shift;
	$DEBUG && print "$string\n";
	`logger -p local0.info -t $operation "$string"`; 
}

# Call logger & then exit with input
sub gone {
	my $string = shift;
	&log("ERROR: $string"); 
	die $string;
}

sub sizeof {
	my $string = shift; 
	my %vol = &diskVol($string); 
	&log ("Found $string is of size: " . $vol{'used'}); 
	return $vol{'used'};
};

sub diskRemaining {
	my $string = shift; 
	my %vol = &diskVol($string); 
	&log ("Found $string has " . $vol{'available'} . " available");
	return $vol{'available'};
}

sub diskVol {
	my $string = shift; 
	my $df; my $line; 
	&log ("Interrogating filesystem $string");
	open ($df, "df -Pk $string |") || &gone ("Cannot run the df command");   # -P means posix - all the output on one line; easier to parse
	$line = <$df>; 
	&gone ("Cannot find filesystem size, no Filesystem") unless (defined $line && $line =~ m/^Filesystem/) ; 
	$line = <$df>; 
	close $df;
	&gone ("Cannot find filesystem size, no device, $line") unless (defined $line && $line =~ m!^/dev/mapper/!) ;
	my ($device, $size, $used, $available, $perc, $mount);
	($device, $size, $used, $available, $perc, $mount) = split /\s+/, $line; 
	&gone ("Coding error trying to read filesystem size, '$size'") 	unless (defined $size && $size =~ m/^\d+$/); 
	&gone ("Coding error trying to read filesystem used, $used") 		unless (defined $used && $used =~ m/^\d+$/); 
	&gone ("Coding error trying to read filesystem avail, $available") 	unless (defined $available && $available =~ m/^\d+$/); 
	&gone ("Coding error trying to read filesystem perc, $perc") 		unless (defined $perc && $perc =~ m/^\d+%$/); 

	my %s = (
		size => 	$size,
		used =>		$used,
		available =>	$available,
		percent =>	$perc, 
		mountpt =>	$mount
	);

	return %s;
} # end of sub diskVol()

1;   # This MUST be the last line in the file
