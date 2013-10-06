#!/usr/bin/perl
use Getopt::Long;
use Net::FTP;
use Config::IniFiles;
use Data::Dumper;
use Pod::Usage;
use Term::ReadKey;
use File::Basename;
use strict	qw(refs vars);
use warnings;

BEGIN {
	if ( $^O eq 'MSWin32' ) {
		require Win32::Daemon;
		Win32::Daemon->import();
	}
}

#
#
# Global variables
#
#
use constant {
	DAEMON_VERSION    => "0.1",
	DEFAULT_User      => "anonymous",
	DEFAULT_Password  => '',
	DEFAULT_FTPType   => "passive",
	DEFAULT_FTPPath   => "/",
	DEFAULT_LocalPath => "./",
	DEFAULT_FileMask  => "*",
	DEFAULT_Period    => "3600",
	DEFAULT_DifDate   => "yes",
	DEFAULT_DifSize   => "yes",
};
my @config_search_paths = (
	'/etc/ftp-dir-sync.conf',
	'/etc/ftp-dir-sync.ini',
	'./ftp-dir-sync.conf',
	'./ftp-dir-sync.ini',
	dirname($0).'/ftp-dir-sync.conf',
	dirname($0).'/ftp-dir-sync.ini',
);

my $config_hash_ref;

#
#
# Platform specific code
#
#

my %service_context = (
	'last_state' => SERVICE_STOPPED,
	'start_time' => time(),
);

my %service_properties_hash = (
	'name'        => 'ftp-dir-sync service',
	'description' => 'keep local and remote directories in sync',
	'display'     => 'ftp-dir-sync service',
	'path'        => $^X,
	'parameters'  => "\"$0\" --daemon",
);

sub install($) {
	my ($user) = @_;
	if (defined $user){
		$service_properties_hash{'user'} = ".\\$user";
		print "Password for user $user: ";
		ReadMode('noecho');
		$service_properties_hash{'password'} = ReadLine(0);
		chomp( $service_properties_hash{'password'} );
		print "\n";
		ReadMode('restore');
	}
	if ( Win32::Daemon::CreateService( \%service_properties_hash ) ) {
		print "Installed";
	}
	else {
		print "Error " . Win32::Daemon::GetLastError();
		exit 1;
	}
}

sub uninstall() {
	if ( Win32::Daemon::DeleteService( $service_properties_hash{'name'} ) ) {
		print "Uninstalled";
		return 0;
	}
	else {
		print "Error with code: ".Win32::Daemon::GetLastError()." occured.";
		return 1;
	}
}

sub service_callback_start() {
	my( $event, $context ) = @_;
	$service_context{last_state} = SERVICE_RUNNING;
	Win32::Daemon::State( SERVICE_RUNNING );
	print_to_log("Event start: $event");
}

sub service_callback_running() {
	my( $event, $context ) = @_;
	print_to_log("Event running start: $event");
	if( SERVICE_RUNNING == Win32::Daemon::State() ) {
		#eval { download_files($config_hash_ref); };
		sleep 20;
	}
	print_to_log("Event running end: $event");
}

sub service_callback_stop() {
	my( $event, $context ) = @_;
	$service_context{'last_state'} = SERVICE_RUNNING;
	Win32::Daemon::State( SERVICE_RUNNING );
	print_to_log("Event stop: $event");
}

sub service_callback_pause() {
	my( $event, $context ) = @_;
	$service_context{'last_state'} = SERVICE_RUNNING;
	Win32::Daemon::State( SERVICE_RUNNING );
	print_to_log("Event pause: $event");
}

sub service_callback_continue() {
	my( $event, $context ) = @_;
	$service_context{'last_state'} = SERVICE_STOPPED;
	Win32::Daemon::State( SERVICE_STOPPED );
	print_to_log("Event continue: $event");
}

sub setup_service {
	Win32::Daemon::RegisterCallbacks({
		start    => \&service_callback_start,
		running  => \&service_callback_running,
		stop     => \&service_callback_stop,
		pause    => \&service_callback_pause,
		continue => \&service_callback_continue,
	}) or error("register callbacks failed\n");
	print "Registered\n";
	Win32::Daemon::StartService( \%service_context, 1000 );
	print "Started\n";
	exit 0;
}

#
#
# Platform independent code
#
#

#
# Utils
#

sub error($) {
	my ($message) = @_;
	die "$message\n";
}

sub print_to_log($) {
	my ($message) = @_;
	open LOG, '>>', dirname($0).'/log.txt';
	print LOG "$message\n";	#ToDo: remove it after debug completed.
	close LOG;
}

sub read_config($) {
	my ($config_file_path) = @_;
	my %config = (
		'Host'      => undef,
		'User'      => DEFAULT_User,
		'Password'  => DEFAULT_Password,
		'FTPType'   => DEFAULT_FTPType,
		'FTPPath'   => DEFAULT_FTPPath,
		'LocalPath' => DEFAULT_LocalPath,
		'FileMask'  => DEFAULT_FileMask,
		'Period'    => DEFAULT_Period,
		'DifDate'   => DEFAULT_DifDate,
		'DifSize'   => DEFAULT_DifSize,
	);
	my %ini;
	tie %ini, 'Config::IniFiles', ( -file => $config_file_path );
	for my $k (keys %{$ini{'global'}}) {
		$config{$k} = $ini{'global'}{$k};
	}
	return \%config;
}

sub print_usage() {
	pod2usage(2);
	return 1;
}

sub daemonize() {
	my $pid = fork();
	if ( $pid < 0 ) {
		error "Daemonization failed.";
	}
	elsif ($pid) {
		exit 0;
	}
	open( STDIN,  "<", "/dev/null" );
	open( STDOUT, ">", "/dev/null" );
	open( STDERR, ">", "/dev/null" );
}

#
# Logic
#

sub print_version() {
	print "ftp-dir-sync daemon version " . DAEMON_VERSION . "\n";
	return 0;
}

sub print_help() {
	print_version();
	pod2usage(1);
	return 0;
}

sub print_man(){
	pod2usage( -verbose => 2 );
	return 0;
}

sub download_files() {
	my $use_passive = !exists $config_hash_ref->{'FTPType'} || $config_hash_ref->{'FTPType'} eq 'passive';
	my $host = $config_hash_ref->{'Host'};
	my $ftp  = Net::FTP->new(
		$host,
		Debug   => 0,
		Passive => $use_passive,
		Timeout => 10,
	) or die "Cannot connect to $host: $@";

	$ftp->login( $config_hash_ref->{'User'},
		$config_hash_ref->{'Password'} )
	  or die "Cannot login ", $ftp->message;

	my $remote_path = $config_hash_ref->{'FTPPath'};
	my $local_path  = $config_hash_ref->{'LocalPath'};
	my @files       = $ftp->ls($remote_path);

	for my $file (@files) {
		print "getting file $file\n";    #ToDo: remove it after debug completed.
		$ftp->get(
			$remote_path . '/' . $file,
			$local_path . '/' . $file
		);
	}
}

sub run_daemon($$) {
	my ($config_file_path, $config_search_paths_ref) = @_;
	unless ( defined $config_file_path ) {
		for my $path (@{$config_search_paths_ref}) {
			$config_file_path = $path if -f $path;
		}
	}
	unless ( defined $config_file_path ) {
		error "Unable to open configuration file.";
		print_to_log("Unable to open configuration file.");
	}
	$config_hash_ref = read_config($config_file_path);
	print Dumper $config_hash_ref;    #ToDo: remove it after debug completed.

	unless ( defined $config_hash_ref->{'Host'} ) {
		error "Host is not specified.";
	}
	if($^O eq 'linux'){
		daemonize();
		
		while (1) {
			eval { download_files(); };
			if ( defined $@ ) {
				print_to_log($@);
			}
			print_to_log( "Files were downloaded. Waiting "
				  . $config_hash_ref->{'Period'}
				  . " s." );
			sleep $config_hash_ref->{'Period'};
		}
	}
	elsif($^O eq 'MSWin32'){
		setup_service();
	}
	else{
		error("Unsupported platform.");
	}
}

sub main() {
	my ($config_file_path, $daemon, $help, $man, $version, $install, $uninstall, $user);
	GetOptions(
		"config:s"  => \$config_file_path,
		"daemon"    => \$daemon,
		"help"      => \$help,
		"man"       => \$man,
		"version"   => \$version,
		"install"   => \$install,  #ToDo: remove this from linux version
		"user:s"    => \$user,
		"uninstall" => \$uninstall,
	);

	if ($help) {
		exit print_help();
	}
	elsif ($man) {
		exit print_man();
	}
	elsif ($version) {
		exit print_version();
	}
	elsif ($daemon) {
		exit run_daemon($config_file_path, \@config_search_paths);
	}
	elsif ($install) {
		exit install($user);
	}
	elsif ($uninstall) {
		exit uninstall();
	}
	else {
		exit print_usage();
	}
}

main();

=head1 NAME

ftp-dir-syncd - Crossplatform daemon/service to keep local and remote(accessible via ftp) directories in sync

=head1 SYNOPSIS

ftp-dir-syncd.pl [action]

Actions:
	
	--help                          to view help
	
	--man                           to view full documentation
	
	--version                       to print version
	
	--daemon [--config=<file>]      to start as daemon/service
	
Windows only actions:
	
	--install [--user=<user>]       to install service to run as system user(or specified user)
	
	--uninstall                     to uninstall service
	
	

=head1 OPTIONS

=over 8

=item B<--help>

Just print help.

=item B<--man>

Print standard linux man page with navigation.

=item B<--version>

Just print current version.

=item B<--daemon>

Start run in background.

=item B<--config>

By default script search configuration file ftp-dir-sync.[conf|ini] in locations: /etc, current dir, script dir. 
This option override this setting.

=item B<--install>

Instal on Windows machines as system service runned as system user if username not explicitly specified.

=item B<--user>

Specify user to run service.

=item B<--uninstall>

Uninstall system service on Windows.

=back

=head1 DESCRIPTION

B<This daemon/service> work in background to keep directories in sync

=cut
