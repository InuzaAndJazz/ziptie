package ZipTie::Adapters::Oracle::TPMMv6;

use strict;

use ZipTie::Adapters::Oracle::TPMMv6::AutoLogin;
use ZipTie::Adapters::Oracle::TPMMv6::Parsers qw(parse_routing create_config parse_local_accounts parse_chassis parse_filters parse_snmp parse_system parse_interfaces parse_static_routes parse_vlans parse_stp);

use ZipTie::Adapters::Utils qw(get_model_filehandle close_model_filehandle);
use ZipTie::Adapters::GenericAdapter;
use ZipTie::CLIProtocol;
use ZipTie::CLIProtocolFactory;
use ZipTie::ConnectionPath;
use ZipTie::Credentials;
use ZipTie::Logger;
use ZipTie::Model::XmlPrint;
use ZipTie::SNMP;
use ZipTie::SnmpSessionFactory;
use ZipTie::Typer;

# Grab a reference to the ZipTie::Logger
my $LOGGER = ZipTie::Logger::get_logger();

sub backup
{
	my $packageName = shift;
	my $backupDoc   = shift;    # how to backup this device
	my $responses    = {};       # will contain device responses to be handed to the Parsers module

	# Translate the backup operation XML document into ZipTie::ConnectionPath
	my ($connectionPath) = ZipTie::Typer::translate_document( $backupDoc, 'connectionPath' );

	# Set up the XmlPrint object for printing the ZiptieElementDocument (ZED)
	my $filehandle = get_model_filehandle( 'TPMM Test v6', $connectionPath->get_ip_address() );
	my $printer = ZipTie::Model::XmlPrint->new( $filehandle, 'common' );
	$printer->open_model();

	# The initial adapter makes use of SNMP to gather well known pieces of information
	# such as the system uptime, the system name and interface layer 2 and 3 addresses.
	my $snmpSession = ZipTie::SnmpSessionFactory->create($connectionPath);
	$responses->{snmp}       = ZipTie::Adapters::GenericAdapter::get_snmp($snmpSession);
	$responses->{interfaces} = ZipTie::Adapters::GenericAdapter::get_interfaces($snmpSession);

	# Make a Telnet or SSH connection
	my ( $cliProtocol, $promptRegex ) = _connect($connectionPath);
	# $responses->{systemInfo} = $cliProtocol->send_and_wait_for( 'get system info',        $promptRegex, '60' );
	# $responses->{interfaces} = $cliProtocol->send_and_wait_for( 'get ipconfig all',       $promptRegex, '60' );
	# $responses->{traps}      = $cliProtocol->send_and_wait_for( 'get ipconfig TrapDest1', $promptRegex, '60' );
	# $responses->{trapVer}    = $cliProtocol->send_and_wait_for( 'get snmp TrapVersion',   $promptRegex, '60' );

	parse_system( $responses, $printer );
	parse_chassis( $responses, $printer );

	# Get the name of the active config file
	my $activeFileResponse = $cliProtocol->send_and_wait_for( 'cat /tpmm/tpmm.cfg', $promptRegex, '60' );
	( $responses->{'activeConfig'} ) = $activeFileResponse =~ m/(\S+\.xml)/m;
	$LOGGER->debug( 'The active configuration file is ' . $responses->{'activeConfig'} );

	# Create a tarball of all the XML configuration files and SCP it back
	# my $filelist = '/etc/dfs/config* /etc/syslog.conf /etc/inet/ntp* /etc/inetd.conf /etc/init.d/*';
	
	my $hostname = $cliProtocol->send_and_wait_for( 'hostname', $promptRegex, '60' );
	if ($hostname =~ /\d{5}([a-z\d]{3})/im)
	{
		my $LID = lc($1);	
		$filelist .= ' /tpmm/'.$LID.'*';
	}
	
	# $cliProtocol->send_and_wait_for( 'tar -cvf /tmp/backup.tar '.$filelist, $promptRegex, '60' );
	# my $localBackupFile = get_backup_files( $cliProtocol, $connectionPath, "/tmp/backup.tar" );
	# $responses->{unzippedBackup} = _parse_tarball($localBackupFile);
	# create_config( $responses, $printer );
	# unlink($localBackupFile);

	$responses->{activeConfigContents} = $cliProtocol->send_and_wait_for( 'cat /tpmm/'.$responses->{activeConfig}, $promptRegex, '60' );
	
	# Interfaces come from SNMP walks
	# parse_interfaces( $responses, $printer );

	# Local Accounts come from /etc/passwd	
	$responses->{passwd} = $cliProtocol->send_and_wait_for( 'cat /etc/passwd', $promptRegex, '60' );
	parse_local_accounts( $responses, $printer );
	
	# INETD
	# $responses->{inetd} = $cliProtocol->send_and_wait_for( 'cat /etc/inetd.conf', $promptRegex, '60' );
	# parse_ntp( $responses, $printer );
	
	# SNMP Information
	# $responses->{snmpd} = $cliProtocol->send_and_wait_for( 'cat /etc/sma/snmp/snmpd.conf', $promptRegex, '60' );
	# parse_snmp( $responses, $printer );
	
	# Static Routes
	# $responses->{static_routes} = $cliProtocol->send_and_wait_for( "netstat -rn", $promptRegex );
	# parse_static_routes( $responses, $printer );

	parse_system( $responses, $printer );
	parse_chassis( $responses, $printer );
	create_config( $responses, $printer );
	# parse_interfaces( $responses, $printer );
	# parse_snmp( $responses, $printer );

	_disconnect($cliProtocol);
	$printer->close_model();                # close out the ZiptieElementDocument
	close_model_filehandle($filehandle);    # Make sure to close the model file handle
}

sub commands
{
	my $packageName = shift;
	my $commandDoc  = shift;

	my ( $connectionPath, $commands ) = ZipTie::Typer::translate_document( $commandDoc, 'connectionPath' );
	my ( $cliProtocol, $devicePromptRegex ) = _connect($connectionPath);

	ZipTie::Adapters::GenericAdapter::execute_cli_commands( 'TPMM Test v6', $cliProtocol, $commands, $devicePromptRegex . '|(#|\$|>)\s*$' );
	_disconnect($cliProtocol);
}

sub _connect
{

	# Grab our arguments
	my $connectionPath = shift;

	# Create a new CLI protocol object by using the ZipTie::CLIProtocolFactory::create sub-routine
	# to examine the ZipTie::ConnectionPath argument for any command line interface (CLI) protocols
	# that may be specified.
	my $cliProtocol = ZipTie::CLIProtocolFactory::create($connectionPath);

	# Make a connection to and successfully authenticate with the device
	my $devicePromptRegex = ZipTie::Adapters::Oracle::TPMMv6::AutoLogin::execute( $cliProtocol, $connectionPath );

	# Store the regular expression that matches the primary prompt of the device under the key "prompt"
	# on the ZipTie::CLIProtocol object
	$cliProtocol->set_prompt_by_name( 'prompt', $devicePromptRegex );

	# Return the created ZipTie::CLIProtocol object and the device prompt encountered after successfully connecting to a device.
	return ( $cliProtocol, $devicePromptRegex );
}

sub _disconnect
{

	# Grab the ZipTie::CLIProtocol object passed in
	my $cliProtocol = shift;

	# Close this session and exit
	$cliProtocol->send("exit");
}

sub _get_uptime
{

	# retrieve the sysUpTime via SNMP
	my $snmpSession = shift;

	$snmpSession->translate( [ '-timeticks' => 0, ] );    # turn off Net::SNMP translation of timeticks
	my $sysUpTimeOid = '.1.3.6.1.2.1.1.3.0';                              # the OID for sysUpTime
	my $getResult = ZipTie::SNMP::get( $snmpSession, [$sysUpTimeOid] );
	return $getResult->{$sysUpTimeOid};
}

1;