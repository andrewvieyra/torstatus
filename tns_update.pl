#!/usr/bin/perl
#
# tns_update.pl
# Copyright (c) 2007-2008 Kasimir Gabert
# A Perl script designed to update the database of TorStatus for the
# most current information from a local Tor server.
#
# See http://project.torstatus.kgprog.com/ for more information on TorStatus
# and https://www.torproject.org/ for more information about the Tor software.
#
#    This program is part of TorStatus
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU Affero General Public License as published 
#    by the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU Affero General Public License for more details.
#
#    You should have received a copy of the GNU Affero General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# The Tor(TM) trademark and Tor Onion Logo are trademarks of The Tor Project. 
#
# Required Perl packages:
#  * DBI from CPAN to access the MySQL database
#  * IO::Socket::INET from CPAN to communicate with Tor
#  * MIME::Base64 from CPAN (alternately libmime-base64-perl in Debian)
#  * LWP::Simple from CPAN
#  * Date::Parse from CPAN
#  * Geo::IP   ** Geo::IP::PurePerl should be used for those without
#		  access to the C version of GeoIP.
#  * Compress::Zlib from CPAN required to decompress GeoIP files after updating
#
# Included Perl packages
#  * serialize.pm
#
# Optional Perl packages
#  * RRDs

# Include the required packages
use DBI;
use IO::Socket::INET;
use serialize;
use Geo::IP;
use MIME::Base64;
use LWP::Simple;
use Date::Parse;
use RRDs;
use Compress::Zlib;

# Debugging Control
my $debugging = 0;
if ($debugging == 1)
{
	$| = 1;
}

# Set the constant to break out of getting the hostnames
use constant TIMEOUT => 1;
$SIG{ALRM} = sub {die "timeout"};

# Caching constansts for increased speed
my %CACHE;
my %geoIPCache;
my %hostnameCache;

# Counter for updating mirror list
my $updateCounter = 0;

# First the configuration file must be read
# All of the variables will be inputed into a hash for ease of use
my %config;
open ($config_handle, "<", "web/config.php");
while (<$config_handle>)
{
	# A regular expression is going to try to pull out the configuration
	# items
	
	chomp (my $line = $_);
	if ($line =~ /^\$(.*?) = (.*?);/)
	{
		my $item = $1;
		my $data = $2;

		# Remove any quotations around the data
		$data =~ s/'$//;
		$data =~ s/^'//;
		$data =~ s/"$//;
		$data =~ s/^"//;

		# Save the configuration item
		$config{$item} = $data;
	}
}
close ($config_handle);

# Determine whether bandwidth history is enabled
if ($config{'BandwidthHistory'} eq "true" || $config{'TorHistory'} eq "true")
{
	use RRDs;
}

# Loop through until killed
while (1)
{

# Don't die on errors
eval
{

# Find the initial time
my $start_time = time();

if ($debugging == 1)
{
	my $curtime = time() - $start_time; print "[$curtime] starting...\n"; # DEBUG
}

# Initiate a connection to the MySQL server
if ($debugging == 1) {
	$dbh = DBI->connect('DBI:mysql:database='.$config{'SQL_Catalog'}.';host='.$config{'SQL_Server'},$config{'SQL_User'},$config{'SQL_Pass'}, {
		PrintError => 1,
		RaiseError => 1
	}) or die "Unable to connect to MySQL server";
} else {
	$dbh = DBI->connect('DBI:mysql:database='.$config{'SQL_Catalog'}.';host='.$config{'SQL_Server'},$config{'SQL_User'},$config{'SQL_Pass'}, {
        	PrintError => 0,
	        RaiseError => 1
	}) or die "Unable to connect to MySQL server";
}


$query;
$dbresponse;
$record;

# Determine if the GeoIP database should be automatically updated
if ($config{'AutomaticallyUpdateGeoIPDatbase'} eq "yes")
{
	# Handle any potential error so as not to stall the
	# network updating
	eval
	{

	# Query the last set date from the database
	$query = "SElECT geoip FROM Status LIMIT 1;";
	$dbresponse = $dbh->prepare($query);
	$dbresponse->execute();
	$record = $dbresponse->fetchrow();
	
	# Extract the month from the record
	my @time = localtime(time());
	my $month = $time[4]+1;
	my $day = $time[3];
	my $oldmonth;
	if ($record =~ m/.*?\-(.*?)\-/)
	{
		$oldmonth = $1;
	}
	if ($oldmonth != $month && $day > 2) # Give extra time
	{
		# The GeoIP database should be updated
		my $getresponse = getstore('http://geolite.maxmind.com/download/geoip/database/GeoLiteCountry/GeoIP.dat.gz','/tmp/GeoIP.dat.gz');
		unless (is_success($getresponse))
		{
			print "Error retrieving GeoIP file.  Please contact Kasimir <kasimir\@kgprog.com>. \n(not dying)\n";
		}
		else
		{
			# Convert and save the new GeoIP file
			my $gz = gzopen ("/tmp/GeoIP.dat.gz","rb");
			open (my $output, ">" . $config{'GEOIP_Database_Path'} . "GeoIP.dat");
			my $buffer;
			while ($gz->gzread($buffer))
			{
				print $output $buffer;	
			}
			$gz->gzclose;
			close ($output);
			# The update has completed - save the new time
			$query = "UPDATE Status SET geoip=NOW();";
			$dbresponse = $dbh->prepare($query);
			$dbresponse->execute();
			# Clear the cache to ensure incorrect entries are
			# fixed
			%geoIPCache = ();
		}
	}

	};
	if ($@)
	{
		print "The GeoIP database could not be updated.  An error is occuring.\n";
	}
}

if ($debugging == 1)
{
	my $curtime = time() - $start_time; print "[$curtime] mirror?\n"; # DEBUG
}

# Determine whether or not the mirror list needs to be updated
if ($updateCounter % 20 == 0)
{
	$updateCounter = 0;
}
if ($updateCounter == 0)
{
	my $changeanything = 1;
	my $mirrorList;
	my %mirrors;
	# Determine whether the list needs to be downloaded
	if ($config{'useMirrorList'} eq "1")
	{
		# Update the mirror list
		my $newList = get($config{'mirrorListURI'});
		if (!$newList)
		{
			$changeanything = 0;
			$newList = serialize(["0"=>"0"]);
		}
		%mirrors = %{unserialize($newList)};
	}
	else
	{
		my $newList = $config{'manualMirrorList'};
		$newList =~ s/array\((.*?)\)/$1/;
		$newList = "%mirrors = (" . $newList . ");";
		eval($newList);
	}
	# Parse the list
	foreach my $k  (sort keys %mirrors)
	{
		my $v = $mirrors{$k};
		unless ($k eq $config{'myMirrorName'})
		{
			$mirrorList .= '<a href="' . $v . '" class="plain">'.$k.'</a> | ';
		}
	}
	chop($mirrorList);
	chop($mirrorList);
	chop($mirrorList);
	if ($changeanything == 1)
	{
		# Update the mirror list in the database
		$query = "TRUNCATE `Mirrors`;";
		$dbresponse = $dbh->prepare($query);
		$dbresponse->execute();
		$query = "INSERT INTO `Mirrors` (`id`,`mirrors`) VALUES (1,'$mirrorList');";
		$dbresponse = $dbh->prepare($query);
		$dbresponse->execute();
	}
}
$updateCounter++;

if ($debugging == 1)
{
	my $curtime = time() - $start_time; print "[$curtime] connecting to Tor\n"; # DEBUG
}

# Initiate a connection to the Tor server
my $torSocket = IO::Socket::INET->new(
	PeerAddr	=> $config{'LocalTorServerIP'},
	PeerPort	=> $config{'LocalTorServerControlPort'},
	Proto		=> "tcp",
	Type		=> SOCK_STREAM)
	or die "Could not connect to Tor server: $!\n";

if ($debugging == 1)
{
	my $curtime = time() - $start_time; print "[$curtime] authenticating with Tor\n"; # DEBUG
}

# Prepare all of the database information, which Descriptor table, make sure
# database is installed, etc
$query = "SElECT count(*) AS Count FROM Status;";
$dbresponse = $dbh->prepare($query);
$dbresponse->execute();
$record = $dbresponse->fetchrow();

# If the count is less then one, then an initial row needs to be created
if ($record < 1)
{
	die "There was an error with the installation of TorStatus. " .
	"Please make sure that the SQL database has been created.";
}

# Determine which tables should be updated in the next cycle
$query = "SELECT ActiveNetworkStatusTable, ActiveDescriptorTable FROM Status WHERE ID = 1;";
$dbresponse = $dbh->prepare($query);
$dbresponse->execute();
my @record = $dbresponse->fetchrow_array;
$descriptorTable = 1;
if ($record[0] =~ /1/)
{
	$descriptorTable = 2;
}

#Determine whether or not we need to authenticate with a password to the server
my $torPass = "";
if ($config{'LocalTorServerPassword'} ne "null")
{
	$torPass = " \"" . $config{'LocalTorServerPassword'} . "\"";
}
print $torSocket "AUTHENTICATE${torPass}\r\n";

# Wait for a response
my $response = <$torSocket>;
if ($response !~ /250/)
{
	die "Unable to authenticate with the Tor server.";
}

if ($debugging == 1)
{
	my $curtime = time() - $start_time; print "[$curtime] starting descriptions\n"; # DEBUG
}

############ Updating router descriptions ####################################

# Delete all of the records from the descriptor table that is going to be
# modified as well as the DNSEL table
$dbh->do("TRUNCATE TABLE Descriptor${descriptorTable};");
$dbh->do("TRUNCATE TABLE DNSEL_INACT;");

# Prepare the updating query
$query = "INSERT INTO Descriptor${descriptorTable} (Name, IP, ORPort, DirPort, Platform, LastDescriptorPublished, Fingerprint, Uptime, BandwidthMAX, BandwidthBURST, BandwidthOBSERVED, OnionKey, SigningKey, Hibernating, Contact, WriteHistoryLAST, WriteHistoryINC, WriteHistorySERDATA, ReadHistoryLAST, ReadHistoryINC, ReadHistorySERDATA, FamilySERDATA, ExitPolicySERDATA, DescriptorSignature) VALUES ( ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? );";
$dbresponse = $dbh->prepare($query);

# Prepare the DNSEL update
$query = "INSERT INTO DNSEL_INACT (IP,ExitPolicy) VALUES ( ? , ? );";
my $dbresponse2 = $dbh->prepare($query);

# Now all of the recent descriptors data needs to be retrieved
my @descAll;
print $torSocket "GETINFO desc/all-recent\r\n";
$response = <$torSocket>;
unless ($response =~ /250+/) { die "There was an error retrieving descriptors."; }

# Now iterate through each line of response
my %currentRouter;

while (<$torSocket>)
{
	chop(my $line = $_);
	chop($line);
	# Trim the line so as to remove odd data
	
	if ($line =~ /250 OK/) { last; } # Break when done

	# Format for the router line:
	# "router" nickname address ORPort SOCKSPort DirPort NL
	if ($line =~ /^router (.*?) (.*?) (.*?) (.*?) (.*?)$/)
	{
		# Gather the data
		$currentRouter{'nickname'} = $1;
		$currentRouter{'address'} = $2;
		$currentRouter{'ORPort'} = $3;
		$currentRouter{'DirPort'} = $5;
		# Set hibernate because it will be published on demand
		$currentRouter{'Hibernating'} = 0;
	}

	# Format for the bandwidth line
	#  "bandwidth" bandwidth-avg bandwidth-burst bandwidth-observed NL
	if ($line =~ /^bandwidth (.*?) (.*?) (.*?)$/)
	{
		$currentRouter{'BandwidthMAX'} = $1;
		$currentRouter{'BandwidthBURST'} = $2;
		#$currentRouter{'BandwidthOBSERVED'} = $3;  # Bandwidth calculated now
	}

	# Format for the platform line
	# "platform" string NL
	if ($line =~ /platform (.*?)$/)
	{
		$currentRouter{'Platform'} = $1;
	}

	# Format for the last descriptor published line
	# "published" YYYY-MM-DD HH:MM:SS NL
	if ($line =~ /^published (.*?)$/)
	{
		$currentRouter{'LastDescriptorPublished'} = $1;
	}

	# Format for the fingerprint line
	# "fingerprint" fingerprint NL
	if ($line =~ /fingerprint (.*?)$/)
	{
		# Remove all of the spaces from the fingerprint
		my $fingerprint = $1;
		$fingerprint =~ s/ //g;
		$currentRouter{'Fingerprint'} = $fingerprint;
	}

	# Format for the hibernating line
	# "hibernating" bool NL
	if ($line =~ /hibernating (.*?)$/)
	{
		$currentRouter{'Hibernating'} = $1;
	}
	
	# Format for the uptime line
	# "uptime" number NL
	if ($line =~ /uptime (.*?)$/)
	{
		$currentRouter{'Uptime'} = $1;
	}
	
	# Format for the onion-key line
	# "onion-key" NL a public key in PEM format
	if ($line =~ /onion-key/)
	{
		my $onion_key;
		# Continue to receive lines until the end of the key
		my $current_line;
		while ($current_line !~ /-----END RSA PUBLIC KEY-----/)
		{
			$current_line = <$torSocket>;
			$onion_key .= $current_line;
		}
		chomp($onion_key);
		$currentRouter{'OnionKey'} = $onion_key;
	}

	# Format for the signing-key line
	# "signing-key" NL a public key in PEM format
	if ($line =~ /signing-key/)
	{
		my $signing_key;
		# Continue to receive lines until the end of the key
		my $current_line;
		while ($current_line !~ /-----END RSA PUBLIC KEY-----/)
		{
			$current_line = <$torSocket>;
			$signing_key .= $current_line;
		}
		chomp($signing_key);
		$currentRouter{'SigningKey'} = $signing_key;
	}

	# Format for the contact info line
	# "contact" info NL
	if ($line =~ /contact (.*?)$/)
	{
		$currentRouter{'Contact'} = $1;
	}

	# Format for the extra-info-digest line
	# "extra-info-digest" digest NL
	if ($line =~ /extra-info-digest (.*?)$/)
	{
		$currentRouter{'Digest'} = $1;
	}

	# Format for family line
	# "family" names NL
	if ($line =~ /family (.*?)$/)
	{
		my @family = split(/ /,$1);
		$currentRouter{'FamilySERDATA'} = serialize(\@family);
	}

	# Format for either reject or accept line
	# "accept" exitpattern NL
	# "reject" exitpattern NL
	if ($line =~ /^reject/ || $line =~ /^accept/)
	{
		$line =~ s/[^\w\d :\.\*\/\-]//g; 
		$currentRouter{'exitpolicy'} = $currentRouter{'exitpolicy'} . $line . "!";
	}

	# Format for the read-history line
	# "read-history" YYYY-MM-DD HH:MM:SS (NSEC s) NUM,NUM,NUM,NUM,NUM... NL
	if ($line =~ /read-history (.*?) (.*?) \((.*?) s\) (.*?)$/)
	{
		# Format for storing the data:
		# "time:NUM"
		my $time = str2time("$1 $2","GMT");
		my $increment = $3;
		# Find and split the numbers
		my @nums = reverse(split(/,/,$4));
		# Loop through the numbers, and attach each to a timestamp
		my $offset = 0;
		my @readhistory;
		foreach my $num (@nums)
		{
			my $numtime = $time - $offset;
			push @readhistory, "$numtime:$num";
			$offset += $increment;
			$currentRouter{'bandwidthcounter'} += $num;
		}
		$currentRouter{'read'} = join(' ',@readhistory);

		# TEMPORARY FOR BACKWARDS COMPATIBILITY
		$currentRouter{'ReadHistoryLAST'} = "$1 $2";
		$currentRouter{'ReadHistoryINC'} = $3;
		# Serialize the last part of the data
		@readhistory = split(/,/,$4);
		$currentRouter{'ReadHistorySERDATA'} = serialize(\@readhistory);
		
		# Add to the observed bandwidth counter
		$currentRouter{'rh'} = \@readhistory;
		$currentRouter{'readnumber'} = scalar(@readhistory);
	}

	# Format for the write-history line
	# "write-history" YYYY-MM-DD HH:MM:SS (NSEC s) NUM,NUM,NUM,NUM,NUM... NL
	if ($line =~ /write-history (.*?) (.*?) \((.*?) s\) (.*?)$/)
	{
		# Format for storing the data:
		# "time:NUM"
		my $time = str2time("$1 $2","GMT");
		my $increment = $3;
		# Find and split the numbers
		my @nums = reverse(split(/,/,$4));
		# Loop through the numbers, and attach each to a timestamp
		my $offset = 0;
		my @writehistory;
		foreach my $num (@nums)
		{
			my $numtime = $time - $offset;
			push @writehistory, "$numtime:$num";
			$offset += $increment;
			$currentRouter{'bandwidthcounter'} += $num;
		}
		$currentRouter{'write'} = join(' ',@writehistory);
		
		# TEMPORARY FOR BACKWARDS COMPATIBILITY
		$currentRouter{'WriteHistoryLAST'} = "$1 $2";
		$currentRouter{'WriteHistoryINC'} = $3;
		# Serialize the last part of the data
		@writehistory = split(/,/,$4);
		$currentRouter{'WriteHistorySERDATA'} = serialize(\@writehistory);
		
		# Add to the observed bandwidth counter
		$currentRouter{'wh'} = \@writehistory;
		$currentRouter{'writenumber'} = scalar(@writehistory);
	}

	# Format for the router-signature line
	# "router-signature" NL Signature NL
	if ($line =~ /router-signature/)
	{
		# This always comes at the very end
		my $signature;
		# Continue to receive lines until the end of the key
		my $current_line;
		while ($current_line !~ /-----END SIGNATURE-----/)
		{
			$current_line = <$torSocket>;
			$signature .= $current_line;
		}
		chomp($signature);
		$currentRouter{'DescriptorSignature'} = $signature;

		# Serialize the exit policy
		chop $currentRouter{'exitpolicy'};
		my @exitpolicy = split(/!/,$currentRouter{'exitpolicy'});
		$currentRouter{'ExitPolicySERDATA'} = serialize(\@exitpolicy);
		# Create a string for the exit policy as well (for DNSEL)
		my $exitpolicystring = join ('::',@exitpolicy);

		# See if there is no family.  It should be blank, not NULL
		# if there is none
		unless ($currentRouter{'FamilySERDATA'})
		{
			$currentRouter{'FamilySERDATA'} = "";
		}

		if ($currentRouter{'Digest'})
		{
		# If there is a digest, extra information needs to be retrieved
		# for this router
		# A second Tor control stream will be opened
		my $digestSocket = IO::Socket::INET->new(
			PeerAddr	=> $config{'LocalTorServerIP'},
			PeerPort	=> $config{'LocalTorServerControlPort'},
			Proto		=> "tcp",
			Type		=> SOCK_STREAM)
			or die "Could not connect to Tor server: $!\n";
		# Authenticate with it
		print $digestSocket "AUTHENTICATE${torPass}\r\n";
		# Wait for a response
		my $response = <$digestSocket>;
		if ($response !~ /250/)
		{
			die "Unable to authenticate with the Tor server.";
		}
		# And request the data
		print $digestSocket "GETINFO extra-info/digest/" . $currentRouter{'Digest'} . "\r\n";

		while (<$digestSocket>)
		{
			chop (my $dline = $_);
			chop($dline);
			if ($dline =~ /^250 OK/) { last; } # Break when done
			if ($dline =~ /^552 /) { last; } # Break on error
			
			# Format for the read-history line
			# "read-history" YYYY-MM-DD HH:MM:SS (NSEC s) NUM,NUM,NUM,NUM,NUM... NL
			if ($dline =~ /read-history (.*?) (.*?) \((.*?) s\) (.*?)$/)
			{
				# Format for storing the data:
				# "time:NUM"
				my $time = str2time("$1 $2","GMT");
				my $increment = $3;
				# Find and split the numbers
				my @nums = reverse(split(/,/,$4));
				# Loop through the numbers, and attach each to a timestamp
				my $offset = 0;
				my @readhistory;
				foreach my $num (@nums)
				{
					my $numtime = $time - $offset;
					push @readhistory, "$numtime:$num";
					$offset += $increment;
					$currentRouter{'bandwidthcounter'} += $num;
				}
				$currentRouter{'read'} = join(' ',@readhistory);
			
				# TEMPORARY FOR BACKWARDS COMPATIBILITY
				$currentRouter{'ReadHistoryLAST'} = "$1 $2";
				$currentRouter{'ReadHistoryINC'} = $3;
				# Serialize the last part of the data
				@readhistory = split(/,/,$4);
				$currentRouter{'ReadHistorySERDATA'} = serialize(\@readhistory);
				
				# Add to the observed bandwidth counter
				$currentRouter{'rh'} = \@readhistory;
				$currentRouter{'readnumber'} = scalar(@readhistory);
			}
		
			# Format for the write-history line
			# "write-history" YYYY-MM-DD HH:MM:SS (NSEC s) NUM,NUM,NUM,NUM,NUM... NL
			if ($dline =~ /write-history (.*?) (.*?) \((.*?) s\) (.*?)$/)
			{
				# Format for storing the data:
				# "time:NUM"
				my $time = str2time("$1 $2","GMT");
				my $increment = $3;
				# Find and split the numbers
				my @nums = reverse(split(/,/,$4));
				# Loop through the numbers, and attach each to a timestamp
				my $offset = 0;
				my @writehistory;
				foreach my $num (@nums)
				{
					my $numtime = $time - $offset;
					push @writehistory, "$numtime:$num";
					$offset += $increment;
					$currentRouter{'bandwidthcounter'} += $num;
				}
				$currentRouter{'write'} = join(' ',@writehistory);
				
				# TEMPORARY FOR BACKWARDS COMPATIBILITY
				$currentRouter{'WriteHistoryLAST'} = "$1 $2";
				$currentRouter{'WriteHistoryINC'} = $3;
				# Serialize the last part of the data
				@writehistory = split(/,/,$4);
				$currentRouter{'WriteHistorySERDATA'} = serialize(\@writehistory);
				
				# Add to the observed bandwidth counter
				$currentRouter{'wh'} = \@writehistory;
				$currentRouter{'writenumber'} = scalar(@writehistory);
			}
		}
		# Close the new Tor connection
		close ($digestSocket);
		}

		# Calculate the bandwidth using a linear weighted average
		my $n = ($currentRouter{'writenumber'} + $currentRouter{'readnumber'})/2;
		my $divisor = (($n*($n+1))/2);
		
		# Ensure that no division by zero occurs
		if ($divisor == 0)
		{
			$divisor = 96*97/2;
		}

		# Add up all of the values, weighting them
		my $i = $n;
		my @writehistory = reverse(@{$currentRouter{'wh'}});
		my @readhistory = reverse(@{$currentRouter{'rh'}});
		my $sum = 0;
		foreach my $num (@writehistory)
		{
			$sum += ($num + $readhistory[$n - $i])/(2*$currentRouter{'ReadHistoryINC'})*$i;
			$i--;
		}
		$currentRouter{'BandwidthOBSERVED'} = $sum/$divisor;
		
		# Save the data to the MySQL database
		$dbresponse->execute( $currentRouter{'nickname'},
		 $currentRouter{'address'},
		 $currentRouter{'ORPort'},
		 $currentRouter{'DirPort'},
		 $currentRouter{'Platform'},
		 $currentRouter{'LastDescriptorPublished'},
		 $currentRouter{'Fingerprint'},
		 $currentRouter{'Uptime'},
		 $currentRouter{'BandwidthMAX'},
		 $currentRouter{'BandwidthBURST'},
		 $currentRouter{'BandwidthOBSERVED'},
		 $currentRouter{'OnionKey'},
		 $currentRouter{'SigningKey'},
		 $currentRouter{'Hibernating'},
		 $currentRouter{'Contact'},
		 $currentRouter{'WriteHistoryLAST'},
		 $currentRouter{'WriteHistoryINC'},
		 $currentRouter{'WriteHistorySERDATA'},
		 $currentRouter{'ReadHistoryLAST'},
		 $currentRouter{'ReadHistoryINC'},
		 $currentRouter{'ReadHistorySERDATA'},
		 $currentRouter{'FamilySERDATA'},
		 $currentRouter{'ExitPolicySERDATA'},
		 $currentRouter{'DescriptorSignature'}
		);

		# Update the read and write bandwidth history
		# Only do this once every 900*10 seconds to retain
		# speed, and more frequent updates are not necessary
		if ($config{'BandwidthHistory'} eq "true" && $updateCounter % 5 == 1)
		{
		updateBandwidth( $currentRouter{'Fingerprint'},
			$currentRouter{'write'},
			$currentRouter{'read'},
			$currentRouter{'WriteHistoryINC'},
			$currentRouter{'nickname'}
		);
		}

		# Save to the DNSEL table as well
		$dbresponse2->execute($currentRouter{'address'},$exitpolicystring);

		# Clear the old data
		%currentRouter = ();
	}
}

if ($debugging == 1)
{
	$curtime = time() - $start_time; print "[$curtime] starting status\n"; # DEBUG
}

############ Updating network status #########################################

# Geo::IP needs to be loaded - include a built-in cache
my $gi = Geo::IP->open($config{'GEOIP_Database_Path'} . "GeoIP.dat",GEOIP_MEMORY_CACHE);

# Delete all of the records from the network status table that is going to be
# modified
$dbh->do("TRUNCATE TABLE NetworkStatus${descriptorTable};");

# Request the network status information
print $torSocket "GETINFO ns/all \r\n";
$response = <$torSocket>;
unless ($response =~ /250+/) { die "There was an error retrieving the network status."; }

# Prepare the query so that data entry is faster
$query = "INSERT INTO NetworkStatus${descriptorTable} (Name,Fingerprint,DescriptorHash,LastDescriptorPublished,IP,Hostname,ORPort,DirPort,FAuthority,FBadDirectory,FBadExit,FExit,FFast,FGuard,FNamed,FStable,FRunning,FValid,FV2Dir,FHSDir,CountryCode) VALUES ( ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ? , ?);";
my $dhresponse = $dbh->prepare($query);

while (<$torSocket>)
{
	chop(my $line = $_);
	chop($line);
	# Trim the line so as to remove odd data
	
	if ($line =~ /250 OK/) { last; } # Break when done
	
	# Format for the "r" line
	# "r" SP nickname SP identity SP digest SP publication SP IP SP ORPort
	# SP DirPort NL
	
	if ($line =~ /^r (.*?) (.*?) (.*?) (.*?) (.*?) (.*?) (.*?) (.*?)$/ || $line =~ /^\./)
	{
		# If there is previous data, it should be saved now
		#

		if ($currentRouter{'Nickname'})
		{
			# Form the Flags list
#			$currentRouter{'flags'} = "0b";
#			my @flagorder = split(',',$config{'FlagOrder'});
#			foreach my $flag (@flagorder)
#			{
#				$currentRouter{'flags'} .= ($currentRouter{$flag}?1:0);
#			}
#			$currentRouter{'flags'} = oct($currentRouter{'flags'});
			unless ($currentRouter{'Country'})
			{
				$currentRouter{'Country'} = "NA";
			}
			$dhresponse->execute(
			 $currentRouter{'Nickname'},
			 $currentRouter{'Identity'},
			 $currentRouter{'Digest'},
			 $currentRouter{'Publication'},
			 $currentRouter{'IP'},
			 $currentRouter{'Hostname'},
			 $currentRouter{'ORPort'},
			 $currentRouter{'DirPort'},
			 ($currentRouter{'Authority'}?1:0),
			 ($currentRouter{'BadDirectory'}?1:0),
			 ($currentRouter{'BadExit'}?1:0),
			 ($currentRouter{'Exit'}?1:0),
			 ($currentRouter{'Fast'}?1:0),
			 ($currentRouter{'Guard'}?1:0),
			 ($currentRouter{'Named'}?1:0),
			 ($currentRouter{'Stable'}?1:0),
			 ($currentRouter{'Running'}?1:0),
			 ($currentRouter{'Valid'}?1:0),
			 ($currentRouter{'V2Dir'}?1:0),
			 ($currentRouter{'HSDir'}?1:0),
			 $currentRouter{'Country'}
			);
		
			# Clear the old data
			%currentRouter = ();
		}

		# This makes sure that it is not the last router
		if ($1)
		{
		
		$currentRouter{'Nickname'} = $1;
		$currentRouter{'Identity'} = unpack('H*',decode_base64($2));
		$currentRouter{'Digest'} = $3;
		$currentRouter{'Publication'} = "$4 $5";
		$currentRouter{'IP'} = $6;
		$currentRouter{'ORPort'} = $7;
		$currentRouter{'DirPort'} = $8;

		# We need to find the country of the IP (using caching)
		if ($geoIPCache{$6})
		{
			$currentRouter{'Country'} = $geoIPCache{$6};
		}
		else
		{
			$currentRouter{'Country'} = $gi->country_code_by_addr($6);
			$geoIPCache{$6} = $currentRouter{'Country'};
		}

		# And the host by addr (using caching)
#		if ($hostnameCache{$6})
#		{
#			$currentRouter{'Hostname'} = $hostnameCache{$6};
#		}
#		else
#		{
			$currentRouter{'Hostname'} = lookup($6);
			# If the hostname was not found, it should be an IP
			unless ($currentRouter{'Hostname'})
			{
				$currentRouter{'Hostname'} = $6;
			}
#			$hostnameCache{$6} = $currentRouter{'Hostname'};
#		}
		}
	}

	# Format for the "s" line
	# "s" SP Flags NL
	if ($line =~ /^s (.*?)$/)
	{
		my @flags = split(/ /,$1);
		foreach my $flag (@flags)
		{
			$currentRouter{$flag} = 1;
		}
	}
}

# Update the opinion source
# We need to find out who we are
print $torSocket "GETCONF nickname \r\n";
chop (my $line = <$torSocket>);
chop($line);
my $nickname = "UNKNOWNNICK";
if ($line =~ /250 Nickname=(.*?)$/)
{
	$nickname = $1;
}
$dbh->do("TRUNCATE TABLE NetworkStatusSource");
# Prevent multiple usernames from being an issue
# Determine whether a fingerprint is present
my $sourceQuery = "Name = '$nickname'";
if ($config{'SourceFingerprint'})
{
	$sourceQuery = "Fingerprint = '" . $config{'SourceFingerprint'} . "'";
}	
$dbh->do("INSERT INTO NetworkStatusSource SELECT * FROM Descriptor${descriptorTable} WHERE $sourceQuery LIMIT 1;");
# Set the ID back to one
$dbh->do("UPDATE NetworkStatusSource SET ID=1;");

my $end_time = time();

# Set the status to use the new data
$dbh->do("UPDATE Status SET LastUpdate = UTC_TIMESTAMP(), LastUpdateElapsed = ($end_time-$start_time), ActiveNetworkStatusTable = 'NetworkStatus${descriptorTable}', ActiveDescriptorTable = 'Descriptor${descriptorTable}' WHERE ID = 1;");

# Rename the DNSEL table so it is used
$dbh->do("RENAME TABLE DNSEL TO tmp_table, DNSEL_INACT TO DNSEL, tmp_table TO DNSEL_INACT;");

if ($debugging == 1)
{
	$curtime = time() - $start_time; print "[$curtime] starting history\n"; #DEBUG
}

################# Tor History #################

if ($config{'TorHistory'} eq "true") {

# check for RRD Files, and create it if not found
my $serverflagfile = $config{'TNS_Path'} . "serverflags.rrd";
my $servernumberfile = $config{'TNS_Path'} . "servernumbers.rrd";
my $graphfile = $config{'TNS_Path'} . "web/history/";

# set global RRD arguments
@RRDargs = (
	"--lower-limit=0",
	"--end=now",
	"--lazy",
	"--height=130",
	"--color=BACK#FFFFFF",
	"--color=FRAME#FFF368",
	"--color=SHADEA#FFF368",
	"--color=SHADEB#FFF368",
	"--color=FONT#0000BF",
	"--color=ARROW#000000"
);


unless (-e $serverflagfile) {
	my $err = RRDs::create(
		$serverflagfile,
		"--start=1199145600",		# start on Jan 1, 2008
		"--step=300",			# maybe change to $config{$Cache_Expire_Time}, and heartbeat to 2times|3times expire time ???
		"DS:run:GAUGE:900:0:U",		# number of running servers
		"DS:runExit:GAUGE:900:0:U",	# number of running exits
		"DS:runGuard:GAUGE:900:0:U",	# number of guard nodes
		"DS:runFast:GAUGE:900:0:U",	# number of fast nodes
		"RRA:AVERAGE:0.5:1:288",	# every 5 minutes, for 1 day
		"RRA:AVERAGE:0.5:12:168",	# every hour, for 1 week
		"RRA:AVERAGE:0.5:48:558",	# every 4 hours, for 93 days
		"RRA:AVERAGE:0.5:144:732",	# every 12 hours, for 1 year
		"RRA:AVERAGE:0.5:576:549"	# every 48 hours, for 3 years
		);
	print "RRDs::create error: $err\n" if $err and $err != 1;
}

unless (-e $servernumberfile) {
	my $err = RRDs::create(
		$servernumberfile,
		"--start=1199145600",		# start on Jan 1, 2008
		"--step=300",			# maybe change to $config{$Cache_Expire_Time}, and heartbeat to 2times|3times expire time ???
		"DS:runUS:GAUGE:900:0:U",	# number of servers in: US
		"DS:runExitUS:GAUGE:900:0:U",	# US - Exit
		"DS:runDE:GAUGE:900:0:U",	# DE
		"DS:runExitDE:GAUGE:900:0:U",	# DE - Exit
		"DS:runCN:GAUGE:900:0:U",	# CN
		"DS:runExitCN:GAUGE:900:0:U",	# CN - Exit
		"DS:runFR:GAUGE:900:0:U",	# FR
		"DS:runExitFR:GAUGE:900:0:U",	# FR - Exit
		"DS:runSE:GAUGE:900:0:U",	# SE
		"DS:runExitSE:GAUGE:900:0:U",	# SE - Exit
		"DS:runRU:GAUGE:900:0:U",	# RU
		"DS:runExitRU:GAUGE:900:0:U",	# RU - Exit
		"DS:runNL:GAUGE:900:0:U",	# NL
		"DS:runExitNL:GAUGE:900:0:U",	# NL - Exit
		"DS:runCA:GAUGE:900:0:U",	# CA
		"DS:runExitCA:GAUGE:900:0:U",	# CA - Exit
		"DS:runGB:GAUGE:900:0:U",	# GB
		"DS:runExitGB:GAUGE:900:0:U",	# GB - Exit
		"DS:runIT:GAUGE:900:0:U",	# IT
		"DS:runExitIT:GAUGE:900:0:U",	# IT - Exit
		"DS:runAT:GAUGE:900:0:U",	# AT
		"DS:runExitAT:GAUGE:900:0:U",	# AT - Exit
		# ADD OTHERS HERE ...
		"DS:runOther:GAUGE:900:0:U",		# other countries
		"DS:runExitOther:GAUGE:900:0:U",	# other countries - Exit
		"RRA:AVERAGE:0.5:1:288",	# every 5 minutes, for 1 day
		"RRA:AVERAGE:0.5:12:168",	# every hour, for 1 week
		"RRA:AVERAGE:0.5:48:558",	# every 4 hours, for 93 days
		"RRA:AVERAGE:0.5:144:732",	# every 12 hours, for 1 year
		"RRA:AVERAGE:0.5:576:549"	# every 48 hours, for 3 years
		);
	print "RRDs::create error: $err\n" if $err and $err != 1;

}



# get the values from the database
# serverflags.rrd
$query = "SELECT count( * ) FROM NetworkStatus${descriptorTable} WHERE FRunning = '1'; ";
$dbresponse = $dbh->prepare($query);
$dbresponse->execute();
my $run = $dbresponse->fetchrow();
$dbresponse->finish();

$query = "SELECT count( * ) FROM NetworkStatus${descriptorTable} WHERE FRunning = '1' AND FExit = '1' ";
$dbresponse = $dbh->prepare($query);
$dbresponse->execute();
my $runExit = $dbresponse->fetchrow();
$dbresponse->finish();

$query = "SELECT count( * ) FROM NetworkStatus${descriptorTable} WHERE FRunning = '1' AND FGuard = '1' ";
$dbresponse = $dbh->prepare($query);
$dbresponse->execute();
my $runGuard = $dbresponse->fetchrow();
$dbresponse->finish();
	
$query = "SELECT count( * ) FROM NetworkStatus${descriptorTable} WHERE FRunning = '1' AND FFast = '1' ";
$dbresponse = $dbh->prepare($query);
$dbresponse->execute();
my $runFast = $dbresponse->fetchrow();
$dbresponse->finish();

#servernumbers.rrd
# US
my $runUS = &country_query('US');
my $runExitUS = &country_exit_query('US');

# DE
my $runDE = &country_query('DE');
my $runExitDE = &country_exit_query('DE');

# CN
my $runCN = &country_query('CN');
my $runExitCN = &country_exit_query('CN');

# FR
my $runFR = &country_query('FR');
my $runExitFR = &country_exit_query('FR');

# SE
my $runSE = &country_query('SE');
my $runExitSE = &country_exit_query('SE');

# RU
my $runRU = &country_query('RU');
my $runExitRU = &country_exit_query('RU');

# NL
my $runNL = &country_query('NL'); 
my $runExitNL = &country_exit_query('NL');

# CA
my $runCA = &country_query('CA');
my $runExitCA = &country_exit_query('CA');

# GB
my $runGB = &country_query('GB');
my $runExitGB = &country_exit_query('GB');

# IT
my $runIT = &country_query('IT');
my $runExitIT = &country_exit_query('IT');

# AT
my $runAT = &country_query('AT');
my $runExitAT = &country_exit_query('AT');

# Totals:
my $runOther = $run-$runUS-$runDE-$runCN-$runFR-$runSE-$runRU-$runNL-$runCA-$runGB-$runIT-$runAT;
my $runExitOther = $runExit-$runExitUS-$runExitDE-$runExitCN-$runExitFR-$runExitSE-$runExitRU-$runExitNL-$runExitCA-$runExitGB-$runExitIT-$runExitAT;


# put values into RRDs
my $err = RRDs::update($serverflagfile, "--template", "run:runExit:runGuard:runFast", "N:".$run.":".$runExit.":".$runGuard.":".$runFast);
print "RRDs::update error: $err\n" if $err and $err != 1;

my $err = RRDs::update($servernumberfile, "--template", "runUS:runExitUS:runDE:runExitDE:runCN:runExitCN:runFR:runExitFR:runSE:runExitSE:runRU:runExitRU:runNL:runExitNL:runCA:runExitCA:runGB:runExitGB:runIT:runExitIT:runAT:runExitAT:runOther:runExitOther", "N:".$runUS.":".$runExitUS.":".$runDE.":".$runExitDE.":".$runCN.":".$runExitCN.":".$runFR.":".$runExitFR.":".$runSE.":".$runExitSE.":".$runRU.":".$runExitRU.":".$runNL.":".$runExitNL.":".$runCA.":".$runExitCA.":".$runGB.":".$runExitGB.":".$runIT.":".$runExitIT.":".$runAT.":".$runExitAT.":".$runOther.":".$runExitOther);
print "RRDs::update error: $err\n" if $err and $err != 1;


# draw RRD graphs - running server
&drawHistory('Running', '6h');
&drawHistory('Running', '1d');
&drawHistory('Running', '1w');
&drawHistory('Running', '1m');
&drawHistory('Running', '3m');
&drawHistory('Running', '1y');

# draw RRD graphs - running exit server
&drawHistory('Exit', '6h');
&drawHistory('Exit', '1d');
&drawHistory('Exit', '1w');
&drawHistory('Exit', '1m');
&drawHistory('Exit', '3m');
&drawHistory('Exit', '1y');

# draw RRD graphs - running Guard Servers 
&drawHistory('Guard', '6h');
&drawHistory('Guard', '1d');
&drawHistory('Guard', '1w');
&drawHistory('Guard', '1m');
&drawHistory('Guard', '3m');
&drawHistory('Guard', '1y'); 

# draw RRD graphs - running Fast Servers
&drawHistory('Fast', '6h');
&drawHistory('Fast', '1d');
&drawHistory('Fast', '1w');
&drawHistory('Fast', '1m');
&drawHistory('Fast', '3m');
&drawHistory('Fast', '1y');

# draw RRD History graphs - countries
&graph_multiplier('US');
&graph_multiplier('DE');
&graph_multiplier('CN');
&graph_multiplier('FR');
&graph_multiplier('SE');
&graph_multiplier('RU');
&graph_multiplier('NL');
&graph_multiplier('CA');
&graph_multiplier('GB');
&graph_multiplier('IT');
&graph_multiplier('AT');
&graph_multiplier('Other');
}

# Close both the database connection and the Tor server connection
$dbh->disconnect();
close($torSocket);

if ($debugging == 1)
{
	$curtime = time() - $start_time; print "[$curtime] done\n"; # DEBUG
}

};
if ($@) {
	print "The TorStatus database was not updated properly.  An error has occured.	I will continue to try to update, however.\n";
}

# Sleep for the desired time from the configuration file
sleep($config{'Cache_Expire_Time'});

}

############ Subroutines #####################################################

# This is used to look up hostnames
sub lookup {
	my $ip = shift;
	return $ip unless $ip=~/\d+\.\d+\.\d+\.\d+/;
	unless (exists $CACHE{$ip}) {
		my @h = eval <<'END';
		alarm(TIMEOUT);
		my @i = gethostbyaddr(pack('C4',split('\.',$ip)),2);
		alarm(0);
		@i;
END
		$CACHE{$ip} = $h[0] || undef;
	}
	return $CACHE{$ip} || $ip;
}


sub country_query {
	my ($country) = @_;
	$query = "SELECT count( * ) FROM NetworkStatus${descriptorTable} WHERE FRunning = '1' AND CountryCode = '$country' ";
	$dbresponse = $dbh->prepare($query);
	$dbresponse->execute();
	my $temp = $dbresponse->fetchrow();
	$dbresponse->finish();
	return $temp;
}

sub country_exit_query {
	my ($country) = @_;	
	$query = "SELECT count( * ) FROM NetworkStatus${descriptorTable} WHERE FRunning = '1' AND FExit = '1' AND CountryCode = '$country' ";
	$dbresponse = $dbh->prepare($query);
	$dbresponse->execute();
	my $temp = $dbresponse->fetchrow();
	$dbresponse->finish();
	return $temp;
}

# Takes care of creating the right graphs ...
sub graph_multiplier {
	my ($country) = @_;

	&drawHistory_run($country, '6h'); 
	&drawHistory_run($country, '1d'); 
	&drawHistory_run($country, '1w');
	&drawHistory_run($country, '1m'); 
	&drawHistory_run($country, '3m'); 
	&drawHistory_run($country, '1y');

	&drawHistory_Exit_run($country, '6h');
	&drawHistory_Exit_run($country, '1d');
	&drawHistory_Exit_run($country, '1w');
	&drawHistory_Exit_run($country, '1m');
	&drawHistory_Exit_run($country, '3m');
	&drawHistory_Exit_run($country, '1y');
}

# This draws overall Network History Graphs
sub drawHistory {
	my ($type, $time) = @_;
	my $timeExt = "unknown";
	if ($time eq '6h') {$timeExt = '6 Hours';};
	if ($time eq '1d') {$timeExt = '24 Hours';};
	if ($time eq '1w') {$timeExt = 'Week';};
	if ($time eq '1m') {$timeExt = 'Month';};
	if ($time eq '3m') {$timeExt = '3 Months';};
	if ($time eq '1y') {$timeExt = 'Year';};

	my $serverflagfile = $config{'TNS_Path'} . "serverflags.rrd";
	my $graphfile = $config{'TNS_Path'} . "web/history/";

	if ($type eq 'Running') {
		RRDs::graph(
		   $graphfile . "running_" . $time . ".png",
		   "--title=Running Servers in the last " . $timeExt,
		   "--vertical-label=Number of Servers",
		   "--start=end-$time",
		   "DEF:myrun=$serverflagfile:run:AVERAGE",
		   "AREA:myrun#0000BF",
		   @RRDargs
		);
	} 
	else {
		RRDs::graph(
		    $graphfile . "run$type" . "_" . $time . ".png",
		    "--title=Running $type Servers in the last " . $timeExt,
		    "--vertical-label=Number of $type Servers",
		    "--start=end-$time",
		    "DEF:myrun=$serverflagfile:run$type:AVERAGE",
		    "AREA:myrun#0000BF",
		    @RRDargs
		);
	}
}


# This draws custom RRD graphs for Network History
sub drawHistory_run {
	my ($country, $time) = @_;
	my $timeExt = "unknown";
	if ($time eq '6h') {$timeExt = "6 Hours";};
	if ($time eq '1d') {$timeExt = "24 Hours";};
	if ($time eq '1w') {$timeExt = "Week";};
	if ($time eq '1m') {$timeExt = "Month";};
	if ($time eq '3m') {$timeExt = "3 Months";};
	if ($time eq '1y') {$timeExt = "Year";};
	
	my $servernumberfile = $config{'TNS_Path'} . "servernumbers.rrd";
	my $graphfile = $config{'TNS_Path'} . "web/history/";

	RRDs::graph(
	    $graphfile . "countries/running_" . $country . "_" . $time . ".png",
	    "--title=Running $country Servers in the last " . $timeExt,
	    "--vertical-label=Number of Servers",
	    "--start=end-$time",
	    "DEF:myrun=$servernumberfile:run$country:AVERAGE",
	    "AREA:myrun#0000BF",
	    @RRDargs
	);

}

# This draws custom Exit RRD graphs for Network History
sub drawHistory_Exit_run {
	my ($country, $time) = @_;
	my $timeExt = "unknown";
	if ($time eq '6h') {$timeExt = "6 Hours";};
	if ($time eq '1d') {$timeExt = "24 Hours";};
	if ($time eq '1w') {$timeExt = "Week";};
	if ($time eq '1m') {$timeExt = "Month";};
	if ($time eq '3m') {$timeExt = "3 Months";};
	if ($time eq '1y') {$timeExt = "Year";};

	my $servernumberfile = $config{'TNS_Path'} . "servernumbers.rrd";
	my $graphfile = $config{'TNS_Path'} . "web/history/";

	RRDs::graph(
	    $graphfile . "countries/runExit_" . $country . "_" . $time . ".png",
	    "--title=Running $country Exit Servers in the last " . $timeExt,
	    "--vertical-label=Number of Exit Servers",
	    "--start=end-$time",
	    "DEF:myrun=$servernumberfile:runExit$country:AVERAGE",
	    "AREA:myrun#0000BF",
	    @RRDargs
	);

}


# This updates the bandwidth history database for a given router
sub updateBandwidth {
	my ($fingerprint, $write, $read, $inc, $name) = @_;

	# Determine whether a bandwidth history file for this router exists
	my $bwfile = $config{'TNS_Path'} . "bandwidthhistory/$fingerprint.rrd";
	
	unless (-e $bwfile)
	{
		# Create the bandwidth history file
		# There will be two datasources, read and write
		#open (my $create_file, ">", $bwfile);
		#close ($create_file);
		my $hbtime = $inc * 2;
		my $err = RRDs::create(
			$bwfile,
			"--start=1167634800", # start on Jan 1, 2007
			"--step=$inc",
			# Add read, write history values
			"DS:read:GAUGE:$hbtime:U:U",
			"DS:write:GAUGE:$hbtime:U:U", 
			# Add RRAs
			"RRA:AVERAGE:0.5:1:96",
			"RRA:AVERAGE:0.5:8:82",
			"RRA:AVERAGE:0.5:48:62",
			"RRA:AVERAGE:0.5:144:62",
			"RRA:AVERAGE:0.5:576:62"
		);
		print "RRDs::create error: $err\n" if $err and $err != 1;
	}
	# Add the known bandwidth data into the RRD database
	# Put the bandwidth into a hash to match the rh and wh
	my %bandwidth = ();
	my @readarray = split(" ",$read);
	my @writearray = split(" ",$write);
	foreach my $rhitem (@readarray)
	{
		my @rh = split(":",$rhitem);
		my $rhb = $rh[1]/$inc/1024;
		$bandwidth{$rh[0]} = $rhb . ":U"; # By default assume 
						    # no write history
	}
	foreach my $whitem (@writearray)
	{
		my @wh = split(":",$whitem);
		unless ($bandwidth{$wh[0]})
		{
			$bandwidth{$wh[0]} = "U:U";
		}
		my $whb = $wh[1]/$inc/1024;
		$bandwidth{$wh[0]} =~ s/\:U/\:$whb/;
	}
	my $lastrow = RRDs::last($bwfile) or 1167634800;
	
	# Update the RRD database
	foreach my $time (sort { $a <=> $b } (keys %bandwidth))
	{
		if ($time > $lastrow)
		{
			RRDs::update(
				$bwfile,
				$time . ":" . $bandwidth{$time}
			);
			my $err = RRDs::error;
			print "RRDs::update error: $err\n" if $err;
		}
	}
}
