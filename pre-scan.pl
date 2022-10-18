#!/usr/bin/perl -w
# Author:	Neil MacGregor
# Versions:	-- fix mee!!!! -------------------------------
# Provenance: 	From my earlier work on CommVault: ssh://root@code.library.ualberta.ca/var/lib/git/MariaDB_Simpana_Backup, ca. 2013
# Date:		Oct 18, 2022
# Purpose:	pre-scan.pl is designed to be called from CommVault BEFORE it scans the filesystem.
# 		It is designed to run ONLY on the replica - if you try to run it on the Master
# 		it will fail (when it tries to stop slave!). 
# 		Overview of the process:
# 		0.1.0 Read configuration file, import variables found there
# 		0.1.1 Acquire a lock file (ensure only one copy of this process is running).  If we steal the lock, run the 
# 		  post-backup.pl script to clean up a previous run.
# 		0.2 Check for sufficient disk space -- don't bother to start, if we have no hope of finishing
#		1. Aquire a lock on all database tables. 
#		2. Stop the MariaDB service (systemctl - it will be restarted by the post-backup script)
#		3. Create an LVM snaphot of the disk volume ( this takes very little time )
# 		4. Mount the snapshot volume
# 		5. Fork a child process, starting a SECOND mysqld, using a different configuration file, port#, socket, etc, and using the snapshot 
# 		   as the disk volume.  Parent process waits for a socket to be created, indicating the database is ready to be used
#		6. Use mysqldump to dump the entire SECOND database to text files (compressed)
#		7. Stop the SECOND mysqld, by killing the pid of the db, and that of the child
#		8. Unmount and remove the snapshot
#		9. Release the lock file
#
# Room for Improvement:
# - convert to OO paradigm ('cause features can also be used when re-creating a replica)
# - much better error control 
# - send email alerts on error to appropriate accounts
# - need a configuration file where we can make adjustments to key variables
# - release as an RPM, in its own repo
# - using backticks `` is a bad idea if you need to read the return code
# - generalized testing

use strict;
use v5.10.1;  # using the "for" version of switch
use IPC::Open3;
use UALBackups;

my $DEBUG = 0;  # disabled by default
$DEBUG = $ENV{"DEBUG"} if defined $ENV{"DEBUG"};  # settable from the environment, if you like

$ENV{"PATH"} = "/sbin:/bin:/usr/sbin:/usr/bin:/root/bin";

# security measure, and for sanity
$ENV{"TMPDIR"} = "/tmp";  					# Enormous bug: External backup s/w resets TMPDIR environment variable, but mysqldump needs to write something there, and it's unwriteable

# 0.1.0 Read your configuration file
$UALBackups::operation="pre-scan"; # set a global 
my $cfg=readConfigFile();

# 0.1.1 Acquire a lock - ensure this never runs more than once at a time
#  -violation of lock results in alerts - email to admins + pager
my $lockFile = "/var/run/cvbackup.lock"; my $LOCKH;
if (-e $lockFile) {
	# Lock file exists - try to recover the lock - UUCP-style lock file contains PID of process that created it
	&gone  ("Cannot read the lock to recover it") unless open( $LOCKH, "<$lockFile"); # &gone() does not return
	my $lockPID=<$LOCKH>;
	&gone ("Lock recovery failed, invalid contents, $lockFile") unless 	
			(defined $lockPID && $lockPID =~ /^[0-9]+$/); #&gone() doesn't return
	close $LOCKH;
	&gone ("Cannot read process list") unless open ( $LOCKH, "ps -ef|"); # &gone() doesn't return
	my $testPID;  
	while (	<$LOCKH> ) {
		(undef, $testPID, undef) = split ;  # heavy defaults, here
		next unless  (defined $testPID && $testPID =~ /^[0-9]+$/) ;
		if ($lockPID == $testPID) {
			&gone ("Unable to steal the lock - PID $lockPID is still running!"); # doesn't return
		}	
	}
	close $LOCKH;
	# So, we didn't die, in the loop above.  That means we're gonna steal the lock
	# Before stealing the lock, run the post-backup script!
	&log ("Stealing stale lockfile: but first, run the post-backup script");
	my $postBackupPath=$cfg->{"binDir"} . "/post-backup.pl";
	`$postBackupPath`; 
	unlink $lockFile;
}
if (! -e $lockFile ) {
	# create the lock file
	&gone ("Cannot create lock file: $!") unless open( $LOCKH, ">$lockFile" );  # &gone() does not return
	print $LOCKH $$;   # print my process ID number into the file
	close $LOCKH; 
} 

&gone ("Exit: because the config file /etc/snap.cnf does not exist") unless -f "/etc/snap.cnf";

# 0.1.2 (Perhaps not required by Veeam?)
# Gonna touch my output file first!
my $backupDir = $cfg->{"backupDir"};
# encode a timestamp on each tarball:
my ($sec, $min, $hour, $mday, $mon, $year,  $yday, $isdst); 
($sec, $min, $hour, $mday, $mon, $year, undef, undef, undef) = localtime(time); $year +=1900; $mon++;
my $timeStamp = $year .  sprintf("%02d%02d%02d%02d%02d",  $mon, $mday, $hour, $min, $sec );  
my $tarName="$backupDir/mysql_backup_$timeStamp.tar"; 
`touch $backupDir/mysql_backup_$timeStamp.tar`;


# 0.2 Don't even consider starting unless there is broadly sufficient disk space to accomplish the backup
# ... because despite my best attempts below, neither tar nor mysqldump report if there is insufficient space!
# We are using on-the-fly compression, typically taking up only 5% of the database size(!)
# But copying it into the tarball doubles that to 10%
# Let's give ourselves lots of runway, double, to 20% (meaning, divide by 5)
# The filesystem must have room for 12 copies at all times...
my $diskRequired =  &sizeof ($backupDir) / 8;   # Adjusted this ratio, TicketID=9680, Mar 12, 2014, Neil
my $remaining = &diskRemaining("/var/backups"); 
if ($remaining < $diskRequired) {
	`/bin/rm -rf $backupDir/tmp/*`; # silently cleanup the tmpdir, which can result if a previous run of this script failed
	$remaining = &diskRemaining("/var/backups");  # recalculate -- did that help?
}
&gone("Insufficient disk space to begin, need $diskRequired Kb, have only $remaining Kb available in /var/backups")  unless ($remaining > $diskRequired); 
&log ("Broadly, sufficient disk space found");

# Since we've acquired the lockFile, we have exclusive access. 
# How much cleanup do we want to do?  Well, a lot!
# check that the snapshot isn't mounted
&gone ("Filesystem is still mounted, exiting") if -d "/mnt/snapshot/mysql";
&log ("Good: the snapshot is not mounted");

# check that the snapshot doesn't exist
&gone ("Snapshot exists, exiting") if -e "/dev/" . $cfg->{"mysqlVolumeGroup"} . "/snap"; 
&log ("Good: the snapshot doesn't exist");

# retrieve a list of the database tables that exist
use DBI;   # first, gotta connect to the DB
#my $dsn = "DBI:mysql:mysql;mysql_read_default_file=$ENV{HOME}/.my.cnf"; 
my $dsn = "DBI:mysql:mysql;mysql_read_default_file=/root/.my.cnf"; 
my $dbh = DBI->connect($dsn, undef, undef, {RaiseError => 1}) || &gone ("Cannot connect to local database: $!");
&log ("Successfully connected to the database");

my $sth = $dbh->prepare ("show databases") || &gone ("Cannot query list of databases, $dbh->errstr"); 
$sth->execute or &gone ("Unable to retrieve a list of databases, reason: " .  $sth->errstr);
&log ("Good: retrieved a list of database names");
my @dbName;
while (my @results = $sth->fetchrow_array ) {
	# validation - what if there are none? do we care? 
	next if $results[0] eq "information_schema"; # this is an database which mysql manages internally
	next if $results[0] eq "performance_schema"; # New in MariaDB -- don't ever try to dump this database
	#next if $results[0] eq "#mysql50#lost+found"; # ugh!
	push @dbName, $results[0];
}
my $databaseCount = $#dbName + 1;
&log ("There are " . $databaseCount . " databases to back up");
$sth->finish; 

#  2. Completely shut down the database!
stopDatabase();

# 3. Snapshot the disk volume containing the database 
# Better get that size from a text config file, eh?  It's likely to change over time
`sync`; 
$DEBUG && print "Creating Snapshot...\n";
my $LV="/dev/" . $cfg->{"mysqlVolumeGroup"} . "/mysql";
my $snapLV="/dev/" . $cfg->{"mysqlVolumeGroup"} . "/snap";
my $LVcommand = "lvcreate --snapshot --size=" . $cfg->{"snapshotSize"} . " --name=snap $LV";
`$LVcommand`;
if ($? != 0) {   # then the snapshot failed
	&log  ("Failed to create the snapshot -- check for sufficient (250Mb) space in the '" . $cfg->{"mysqlVolumeGroup"} . "' volume group?");
	`systemctl start mariadb.service`; # the slave process will autorestart
	&gone ("Backup failed, but I tried to restart the primary mariadb.service"); # does not return
}
$DEBUG && print "Snapshot created: $snapLV...\n";


# 4. Put that volume online, ready for backups
(`mkdir /mnt/snapshot` or &gone("Could not create /mnt/snapshot")) unless ( -d "/mnt/snapshot" ); 
# xfs filesystems like to be mounted, to play their logs, before trying to run xfs_repair
 `mount -o nouuid $snapLV /mnt/snapshot` ;
if ($? != 0) {
	&log("running first xfs_repair of snapshot..."); `xfs_repair  $snapLV`; 
	&log("running second xfs_repair of snapshot...");`xfs_repair -L $snapLV`;  &gone("xfs_repair of the snapshot failed") unless ($? == 0);   # does not return
	`mount -o nouuid $snapLV /mnt/snapshot` ; &gone("mounting the snapshot, after repair, failed") unless ($? == 0);  # does not return
}
&log ("Snapshot mounted");

# 5. Start a NEW Database daemon using the snapshot as its data directory
# Slightly complex - I need this to be in the background, but this process never finishes
# So, I must fork a child process & let the child start it
my $forkStatus = fork();
&log ("I am the parent") if (defined $forkStatus  && $forkStatus > 0);
&log ("I am the child") if (defined $forkStatus  && $forkStatus == 0);
&log ("Cannot fork") unless defined $forkStatus;
die "Cannot fork" unless defined $forkStatus;  # you can't die here, you left the snapshot mounted!

if ($forkStatus == 0 ) {
	$ENV{"LD_LIBRARY_PATH"} = "";
	&log("Child process starting mysqld_safe on 3307");
	`/usr/bin/mysqld_safe --defaults-file=/etc/snap.cnf --skip-slave-start`; # note, does not return
	exit;
}
my $count = 0;
sleep 5;
my $socket = "/mnt/snapshot/snapshot.sock";  # ought to read this value from /etc/snap.cnf
while ( ! -e $socket ) {  # this is an awful hack - needs a time limit
	sleep 5;
	$count ++; 
	&log ("Waiting for $socket to appear");
	die "Unable to start the alternate mysql on port 3307 after 1 minute" unless $count < 11; 
}
&log ("mysqld running on port 3307 - starting dump!");

# 6. Use mysqldump to dump from this database to text files
my ($pid,$child_exit_status); 
foreach my $db (@dbName) {
	# really need return status from this!	
	# Consider using --single-transaction for databases using the InnoDB engine
	# Consider using --lock-tables
	# Hey, shoud we get a read-lock on *this* copy of the database? Wouldn't that obviate the need for any locking?
	&log ("Backing up database: $db...");

	# We used to run backups like this:
	#	`mysqldump --port=3307 --socket=$socket --databases --events --routines $db | gzip > $backupDir/tmp/$db.sql.gz `;   # this dumps truncated SQL ? 
	# ... which was great for efficiency, but it turns out there's no reliable way to get return codes from *both* sides of a pipe, from a system command... :(
	$pid = open3(undef, undef, \*CHLD_ERR, "HOME=/root/ /usr/bin/mysqldump --port=3307 --socket=$socket --databases --events --routines --triggers $db > $backupDir/tmp/$db.sql");
	waitpid( $pid, 0 );
	$child_exit_status = $? >> 8;
	if ($child_exit_status ne 0) {
		&log("Backup failed, here are the error message(s):\n");   # presuming this works, we'd want to error-out here, telling Veeam we have garbage & not to back up anything
		while (<CHLD_ERR>) {
			&log ("Error from mysqldump: $_");
		}
		&gone ("mysqldump failed, so this backup is not valid");
	}
	
	$pid = open3(undef, undef, \*CHLD_ERR, "gzip $backupDir/tmp/$db.sql");
	waitpid( $pid, 0 );
	$child_exit_status = $? >> 8;
	if ($child_exit_status ne 0) {
		&log( "gzip failed, likely meaning we're out of disk space, error message follows:");
		while (<CHLD_ERR>) {
			&log ("Error from gzip: $_");
		}
		&gone ("gzip failed, so this backup is not valid");
	}
	
	# need to check the return value from the mysqldump command
	# need to ensure that the output file exists, and is of a minimum size
	# There's something inherently dangerous about this - if we run out of disk space performing the dump, we're hornswaggled!	
}

chdir $backupDir || die "Cannot chdir to $backupDir"; 
### NOTE:  despite this, it seems that the return value from tar is lost!  I tested it with the disk nearly full, but the
## return code was "true".   I must be doing something wrong.   So, I added the initial test above to estimate disk space
system ("tar cf $tarName tmp/*.sql.gz") == 0 || &gone ("System call to tar failed: $?"); 
&gone ("Tarball found missing, exiting early") unless (-e $tarName);
use File::stat; 
my $statBlob = stat($tarName);
&gone ("Tarball is too small, just " . $statBlob->size . ", exiting early")  unless ($statBlob->size > $cfg->{"minimumTarballSize"} );
`/bin/rm -rf /var/backups/mysql/tmp/*`;  # clean up after yourself
&log ("Dump completed...");

# 7. Kill that mysql process:
# ,,,OR
my $pidfile = "/var/run/mariadb/snapshot.pid";  # ? read this value from the /etc/snap.cnf?
if ( -e $pidfile ) {
	open (PID, "<$pidfile" ) || &gone ("Cannot open PID file, $pidfile, $!");
	my $pid = <PID>;
	close PID;
	&gone ("PID file $pidfile did not contain a valid PID") unless (defined $pid && $pid =~ m/^[0-9]+$/);
	&log ("killing process mysqld: $pid");
	kill 15, $pid;  
} else {
	&gone ("The 3307-pidfile doesn't exist: $pidfile");
}
# also kill the child process
&log ("Killing child process: $forkStatus"); 
kill 15,$forkStatus;
my $child = wait();
my $killTimeout = $cfg->{"killTimeout"};
&log ("Sleeping for $killTimeout sec...") if (-e $pidfile); 
sleep $killTimeout; 
&gone ("Unable to stop the 3307-database") if ( -e $pidfile);  # check that the PID file went away
#  Start an independent subjob to monitor the duration of the backup, alert if the snapshot fills
#    or the job runs too long.
&log ("Please write the monitoring job which will tattle if the backup takes too long...");

# 8. Unmount and remove the snapshot
unmountSnapshot();
removeSnapshot($cfg);

# 9. Release the lock; Exit 
if ( -e $lockFile ) {
	&gone ("Cannot remove $lockFile: $!") unless unlink $lockFile; 
} else {
	&gone ("Tried to release lock on $lockFile, but it didn't exist!");
}
#
# (Commvault performs the backup)
#
# NOTE Post job will unmount the snapshot, and delete the snapshot, in just a few minutes
&log ("pre-scan.pl finishes - External backup starts now");

# -------------------------------------------- Function definitions ------------------------------------------
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
# intended EOF
