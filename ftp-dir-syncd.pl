#!/usr/bin/perl
use Getopt::Long;
use Net::FTP;
use Config::IniFiles;
use Pod::Usage;
use Term::ReadKey;
use File::Basename;
use strict                      qw(refs vars);
use warnings;
use feature                     qw(state);
use English;

BEGIN {
	if ( $OSNAME eq 'MSWin32' ) {
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
	DAEMON_VERSION    => "0.2",
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
	dirname($PROGRAM_NAME).'/ftp-dir-sync.conf',
	dirname($PROGRAM_NAME).'/ftp-dir-sync.ini',
);

my $global_config_hash_ref;

#
#
# Platform specific code
#
#

my %Context = (
	'last_state' => SERVICE_STOPPED,
	'start_time' => time(),
);

my %service_properties_hash = (
	'name'        => 'ftp-dir-sync service',
	'description' => 'keep local and remote directories in sync',
	'display'     => 'ftp-dir-sync service',
	'path'        => $EXECUTABLE_NAME,
	'parameters'  => "\"$PROGRAM_NAME\" --daemon",
);

sub install($) {
	my ($user) = @_;
	
	error("Unsupported by this platform.") unless $OSNAME eq 'MSWin32';
	
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
		return 1;
	}
	return 0;
}

sub uninstall() {
	error("Unsupported by this platform.") unless $OSNAME eq 'MSWin32';
	
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
	my $State = Win32::Daemon::State();
	
	# Evaluate CONTROLS / Events
	if( SERVICE_CONTROL_STOP == $Event ) {
		$Context->{last_state} = SERVICE_STOPPED;
		Win32::Daemon::State( SERVICE_STOPPED );
		print_to_log( "Stopping service." );
		
		# We need to notify the Daemon that we want to stop callbacks and the service.
		Win32::Daemon::StopService();
	} elsif(SERVICE_CONTROL_START == $Event) {
		Win32::Daemon::State( SERVICE_RUNNING );
		$Context->{last_state} = SERVICE_RUNNING;
	} elsif(SERVICE_CONTROL_RUNNING == $Event) {
		print_to_log( "RUNNING EVENT" );
		eval { download_files(); };
		if ( defined $EVAL_ERROR ) {
			print_to_log($EVAL_ERROR);
		}
		else{
			print_to_log("Synchronization iteration was completed.");
		}
	} elsif(SERVICE_CONTROL_PAUSE == $Event) {
		print_to_log( "PAUSE EVENT" );
		$Context->{last_state} = SERVICE_PAUSED;
		Win32::Daemon::State( SERVICE_PAUSED );
		Win32::Daemon::CallbackTimer( 0 );
		print_to_log( "Pausing." );
	} elsif(SERVICE_CONTROL_CONTINUE == $Event) {
		print_to_log( "CONTINUE EVENT" );
		$Context->{last_state} = SERVICE_RUNNING;
		Win32::Daemon::State( SERVICE_RUNNING );
		Win32::Daemon::CallbackTimer( $global_config_hash_ref->{'Period'} * 1000 );
		print_to_log( "Resuming from paused state." );
	} else {
		# Take care of unhandled states by setting the State()
		# to whatever the last state was we set...
		Win32::Daemon::State( $Context->{last_state} );
		print_to_log( "Got an unknown EVENT: $Event" );
	}
	return();               #i don't know why, but it is necessary
}

sub setup_service {
	Win32::Daemon::AcceptedControls(
		&SERVICE_CONTROL_STOP |
		&SERVICE_CONTROL_PAUSE |
		&SERVICE_CONTROL_CONTINUE
	)or error("register accepted controls failed");
	Win32::Daemon::RegisterCallbacks( \&service_callback ) or error("register callbacks failed");
	print_to_log("Registered");

	print_to_log("Started");
	Win32::Daemon::StartService( \%Context, $global_config_hash_ref->{'Period'} * 1000 );
	print_to_log("Finished");
	return;
}

sub daemonize() {
	my $pid = fork();
	if ( $pid < 0 ) {
		error("Daemonization failed.");
	}
	elsif ($pid) {
		exit 0;
	}
	open( STDIN,  "<", "/dev/null" );
	open( STDOUT, ">", "/dev/null" );
	open( STDERR, ">", "/dev/null" );
	return;
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
	print_to_log("Error: $message");
	die "$message\n";
}

sub print_to_log($) {
	my ($message) = @_;
	if(open my $log_fh, '>>', dirname($PROGRAM_NAME).'/log.txt'){
		print $log_fh time()." $message\n";             #ToDo: remove it after debug completed.
		close $log_fh;
	}
	return;
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
		if($k eq 'Period'){
			if($config{$k} =~ /^(\d)+\s*m$/){
				$config{$k} = int($1 * 60);
			}
			if($config{$k} =~ /^(\d)+\s*h$/){
				$config{$k} = int($1 * 3600);
			}
		}
		if($k eq 'DifDate' || $k eq 'DifSize'){         #ToDo: revork flags handling
			$config{$k} = 'yes' if $config{$k} eq 'true';
		}
	}
	return \%config;
}

sub print_usage() {
	pod2usage(2);
	return 1;
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

sub parse_dir_output($){
	my ($line) = @_;
	my %file;
	my ($mode, undef, $uid, $gid, $size, $month, $day_of_month, $time_year_name) = split /\s+/, $line, 8;
	my ($time_year, $name) = split / /, $time_year_name;
	$file{'name'} = $name;
	$file{'is_dir'} = $mode =~ /^d/;
	$file{'size'} = $size;
	$file{'timestamp'} = "$month $day_of_month $time_year";
	return \%file;
}

sub download_files_recursive($$$$);
sub download_files_recursive($$$$){
	my($ftp, $file_attributes, $remote_path, $local_path) = @_;
	my %dirs;
	my %files;
	for my $line ($ftp->dir($remote_path)){
		my $file_hash_ref = parse_dir_output($line);
		if($file_hash_ref->{'is_dir'}){
			$dirs{ $file_hash_ref->{'name'} } = $file_hash_ref;
		}
		else{
			$files{ $file_hash_ref->{'name'} } = $file_hash_ref;
		}
	}
	
	for my $file (keys %files){
		my $mask = $global_config_hash_ref->{'FileMask'};
		$mask =~ s#\?#\.#;
		$mask =~ s#\*#\.\*#;
		unless ( $file =~ /^$mask$/ ) {        #ToDo: revork mask handling. Direct using provided by user RegExp too risky.
			print_to_log "skipped(not fit to mask) file $remote_path/$file\n";
			next;
		}
		my $need_to_download = 0;
		if($global_config_hash_ref->{'DifDate'} eq 'yes' or $global_config_hash_ref->{'DifSize'} eq 'yes'){
			if($global_config_hash_ref->{'DifSize'} eq 'yes'){
				$need_to_download |= ! exists $file_attributes->{$remote_path . '/' . $file} ||
					$file_attributes->{$remote_path . '/' . $file}{'size'} ne $files{$file}{'size'};
			}
			if($global_config_hash_ref->{'DifDate'} eq 'yes'){
				$need_to_download |= ! exists $file_attributes->{$remote_path . '/' . $file} ||
					$file_attributes->{$remote_path . '/' . $file}{'timestamp'} ne $files{$file}{'timestamp'};
			}
		}
		else{
			$need_to_download = 1
		}
		
		if($need_to_download){
			print_to_log "getting file $remote_path/$file\n";
			mkdir($local_path) unless -d $local_path;
			$ftp->get(
				$remote_path . '/' . $file,
				$local_path . '/' . $file
			);
			$file_attributes->{$remote_path . '/' . $file}{'size'} = $files{$file}{'size'};
			$file_attributes->{$remote_path . '/' . $file}{'timestamp'} = $files{$file}{'timestamp'};
		}
		else{
			print_to_log "skipped(not changed) file $remote_path/$file\n";
		}
	}
	
	for my $dir (keys %dirs){
		print_to_log "recursive call dir $remote_path/$dir\n";    #ToDo: remove it after debug completed.
		download_files_recursive($ftp, $file_attributes, $remote_path.'/'.$dir, $local_path.'/'.$dir);
	}
	return;
}

sub download_files() {
	state $file_attributes = {};
	my $use_passive = !exists $global_config_hash_ref->{'FTPType'} || $global_config_hash_ref->{'FTPType'} eq 'passive';
	my $host = $global_config_hash_ref->{'Host'};
	my $ftp  = Net::FTP->new(
		$host,
		Debug   => 0,
		Passive => $use_passive,
		Timeout => 10,
	) or die "Cannot connect to $host: $@";

	$ftp->login(
		$global_config_hash_ref->{'User'},
		$global_config_hash_ref->{'Password'}
	) or die "Cannot login ", $ftp->message;

	my $remote_path = $global_config_hash_ref->{'FTPPath'};
	my $local_path  = $global_config_hash_ref->{'LocalPath'};
	download_files_recursive($ftp, $file_attributes, $remote_path, $local_path);
	return;
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
	}
	$global_config_hash_ref = read_config($config_file_path);

	unless ( defined $global_config_hash_ref->{'Host'} ) {
		error "Host is not specified.";
	}
	unless ( -d $global_config_hash_ref->{'LocalPath'} ) {
		error "Local path not exists.";
	}
	if($OSNAME eq 'linux'){
		daemonize();
		
		while (1) {
			my $start = time();
			eval { download_files(); };
			my $end = time();
			if ( defined $@ ) {
				print_to_log($@);
			}
			print_to_log( "Files were downloaded. Waiting ".$global_config_hash_ref->{'Period'}." s.");
			my $sleep_time = $global_config_hash_ref->{'Period'} - ($end - $start);
			$sleep_time = 0 if $sleep_time < 0;
			sleep $sleep_time;              #a bit different with windows implementation
		}
	}
	elsif($OSNAME eq 'MSWin32'){
		setup_service();
	}
	else{
		error("Unsupported platform.");
		return 1;
	}
	return 0;
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
