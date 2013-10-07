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

use constant SERVICE_CONTROL_STOP                  => 0x00000001;
use constant SERVICE_CONTROL_PAUSE                 => 0x00000002;
use constant SERVICE_CONTROL_CONTINUE              => 0x00000003;
use constant SERVICE_CONTROL_INTERROGATE           => 0x00000004;
use constant SERVICE_CONTROL_SHUTDOWN              => 0x00000005;
use constant SERVICE_CONTROL_PARAMCHANGE           => 0x00000006;
use constant SERVICE_CONTROL_NETBINDADD            => 0x00000007;
use constant SERVICE_CONTROL_NETBINDREMOVE         => 0x00000008;
use constant SERVICE_CONTROL_NETBINDENABLE         => 0x00000009;
use constant SERVICE_CONTROL_NETBINDDISABLE        => 0x0000000A;
use constant SERVICE_CONTROL_DEVICEEVENT           => 0x0000000B;
use constant SERVICE_CONTROL_HARDWAREPROFILECHANGE => 0x0000000C;
use constant SERVICE_CONTROL_POWEREVENT            => 0x0000000D;
use constant SERVICE_CONTROL_SESSIONCHANGE         => 0x0000000E;
use constant SERVICE_CONTROL_PRESHUTDOWN           => 0x0000000F;
use constant SERVICE_CONTROL_TIMECHANGE            => 0x00000010; # XP & Vista: Not Supported
use constant SERVICE_CONTROL_TGIGGEREVENT          => 0x00000020; # XP & Vista: Not Supported

use constant SERVICE_STOPPED                       => 0x00000001;
use constant SERVICE_START_PENDING                 => 0x00000002;
use constant SERVICE_STOP_PENDING                  => 0x00000003;
use constant SERVICE_RUNNING                       => 0x00000004;
use constant SERVICE_CONTINUE_PENDING              => 0x00000005;
use constant SERVICE_PAUSE_PENDING                 => 0x00000006;
use constant SERVICE_PAUSED                        => 0x00000007;

my %Context = (
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
	
	error("Unsupported by this platform.") unless $^O eq 'MSWin32';
	
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
	error("Unsupported by this platform.") unless $^O eq 'MSWin32';
	
	if ( Win32::Daemon::DeleteService( $service_properties_hash{'name'} ) ) {
		print "Uninstalled";
		return 0;
	}
	else {
		print "Error with code: ".Win32::Daemon::GetLastError()." occured.";
		return 1;
	}
}

sub service_callback {
    my( $Event, $Context ) = @_;
    my $Event_debug = Win32::Daemon::QueryLastMessage();
    Win32::Daemon::QueryLastMessage(1); # Reset the Event
    my $State = Win32::Daemon::State();
    print_to_log( "---------- Entering Loop with Status/Event: $State/$Event ($Event_debug)" );

    # Evaluate STATE
    if( SERVICE_RUNNING == $State ) {
        $Context->{count}++;
        print_to_log( "Running!!! Count=$Context->{count}. Timer:".Win32::Daemon::CallbackTimer() );
    } elsif( SERVICE_START_PENDING == $State ) {
        # Initialization code
        $Context->{last_state} = SERVICE_RUNNING;
        Win32::Daemon::State( SERVICE_RUNNING );
        print_to_log( "Service initialized. Setting state to Running." );
    } elsif( SERVICE_PAUSE_PENDING == $State ) {
        $Context->{last_state} = SERVICE_PAUSED;
        Win32::Daemon::State( SERVICE_PAUSED );
        Win32::Daemon::CallbackTimer( 0 );
        print_to_log( "Pausing." );
    } elsif( SERVICE_CONTINUE_PENDING == $State ) {
        $Context->{last_state} = SERVICE_RUNNING;
        Win32::Daemon::State( SERVICE_RUNNING );
        Win32::Daemon::CallbackTimer( 5000 );
        print_to_log( "Resuming from paused state." );
    } else {
        print_to_log( "Service got an unknown STATE: $State" );
    }
    
    # Evaluate CONTROLS / Events
    if( SERVICE_CONTROL_STOP == $Event ) {
        $Context->{last_state} = SERVICE_STOPPED; # eigentlich STOP_PENDING ???
        Win32::Daemon::State( [ state => SERVICE_STOPPED, error => 1234 ] );
        print_to_log( "Stopping service." );
        
        # We need to notify the Daemon that we want to stop callbacks and the service.
        Win32::Daemon::StopService();
    } elsif( SERVICE_CONTROL_SHUTDOWN == $Event ) {
        print_to_log( "Event: SHUTTING DOWN!  *** Stopping this service ***" );
        # We need to notify the Daemon that we want to stop callbacks and the service.
        Win32::Daemon::StopService();
    } elsif( SERVICE_CONTROL_PRESHUTDOWN == $Event ) {
        print_to_log( "Event: Preshutdown!" );
    } elsif( SERVICE_CONTROL_INTERROGATE == $Event ) {
        print_to_log( "Event: Interrogation!" );
    } elsif( SERVICE_CONTROL_NETBINDADD == $Event )    {
        print_to_log( "Event: Adding a network binding!" );
    } elsif( SERVICE_CONTROL_NETBINDREMOVE == $Event ) {
        print_to_log( "Event: Removing a network binding!" );
    } elsif( SERVICE_CONTROL_NETBINDENABLE == $Event ) {
        print_to_log( "Event: Network binding has been enabled!" );
    } elsif( SERVICE_CONTROL_NETBINDDISABLE == $Event )    {
        print_to_log( "Event: Network binding has been disabled!" );
    } elsif( SERVICE_CONTROL_DEVICEEVENT == $Event ) {
        print_to_log( "Event: A device has issued some event of some sort!" );
    } elsif( SERVICE_CONTROL_HARDWAREPROFILECHANGE == $Event ) {
        print_to_log( "Event: Hardware profile has changed!" );
    } elsif( SERVICE_CONTROL_POWEREVENT == $Event ) {
        print_to_log( "Event: Some power event has occured!" );
    } elsif( SERVICE_CONTROL_SESSIONCHANGE == $Event ) {
        print_to_log( "Event: User session has changed!" );
    } else {
        # Take care of unhandled states by setting the State()
        # to whatever the last state was we set...
        Win32::Daemon::State( $Context->{last_state} );
        print_to_log( "Got an unknown EVENT: $Event" );
    }
    return();
}

sub setup_service {
	Win32::Daemon::AcceptedControls(&SERVICE_CONTROL_STOP        |
                                &SERVICE_CONTROL_PAUSE        |
                                &SERVICE_CONTROL_CONTINUE    |
                                &SERVICE_CONTROL_INTERROGATE|
                                &SERVICE_CONTROL_SHUTDOWN    |
                                &SERVICE_CONTROL_PARAMCHANGE|
                                &SERVICE_CONTROL_NETBINDADD |
                                &SERVICE_CONTROL_NETBINDREMOVE |
                                &SERVICE_CONTROL_NETBINDENABLE | 
                                &SERVICE_CONTROL_NETBINDDISABLE|
                                &SERVICE_CONTROL_DEVICEEVENT   |
                                &SERVICE_CONTROL_HARDWAREPROFILECHANGE |
                                &SERVICE_CONTROL_POWEREVENT        |
                                &SERVICE_CONTROL_SESSIONCHANGE  |
                                &SERVICE_CONTROL_PRESHUTDOWN    |
                                &SERVICE_CONTROL_TIMECHANGE        |
                                &SERVICE_CONTROL_TGIGGEREVENT );
	Win32::Daemon::RegisterCallbacks( \&service_callback ) or error("register callbacks failed\n");
	print_to_log("Registered");

	Win32::Daemon::StartService( \%Context, 5000 );
	print_to_log("Started");
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
