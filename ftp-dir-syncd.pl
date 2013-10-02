#!/usr/bin/perl
use Getopt::Long;
use Net::FTP;
use strict;
use warnings;

#Global variables
use constant {
	DAEMON_VERSION    => "0.1",
	DEFAULT_User      => "anonymous",
	DEFAULT_Password  => undef,
	DEFAULT_FTPType   => "passive",
	DEFAULT_FTPPath   => "/",
	DEFAULT_LocalPath => "./",
	DEFAULT_FileMask  => "*",
	DEFAULT_Period    => "3600",
	DEFAULT_DifDate   => "yes",
	DEFAULT_DifSize   => "yes",
};
my @config_search_paths = ( '/etc/ftp-dir-sync.conf', './' );

sub print_usage() {
	print "Use:
$0 --help		to view help
$0 --version		to view version
$0 --daemon		to start as daemon
";
	return 1;
}

sub error($) {
	my ($message) = @_;
	die "$message\n";
}

sub print_to_log($) {
	my ($message) = @_;
}

sub print_version() {
	print "ftp-dir-sync daemon version " . DAEMON_VERSION . "\n";
	return 0;
}

sub print_help() {
	print_version();
	print_usage();
	return 0;
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
}

sub daemonize {
	use POSIX;
	POSIX::setsid or die "setsid: $!";
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

sub check_is_config_valid($$) {
	my ( $config_hash_ref, $message_str_ref ) = @_;
	return 1;
}

sub download_files($) {
	my ($config_hash_ref) = @_;
	
	my $use_passive = !exists $config_hash_ref->{'FTPType'}
	  || $config_hash_ref->{'FTPType'} eq 'passive';
	my $host = $config_hash_ref->{'Host'};
	my $ftp = Net::FTP->new(
		$host,
		Debug   => 0,
		Passive => $use_passive
	) or die "Cannot connect to $host: $@";
	
	$ftp->login(
		$config_hash_ref->{'User'},
		$config_hash_ref->{'Password'}
	) or die "Cannot login ", $ftp->message;
	
	my $remote_path = $config_hash_ref->{'FTPPath'};
	my $local_path = $config_hash_ref->{'LocalPath'};
	my @files = $ftp->ls($remote_path);
	
	for my $file (@files){
		$ftp->get($remote_path.'/'.$file, $local_path.'/'.$file);
	}
}

sub run_daemon($) {
	my ($config_hash_ref) = @_;
	daemonize();

	while (1) {
		eval { download_files($config_hash_ref); };
		if ( defined $@ ) {
			print_to_log($@);
		}
		sleep $config_hash_ref->{'Period'};
	}
}

sub main() {
	my ( $config_file_path, $daemon, $help, $version );
	GetOptions(
		"config:s" => \$config_file_path,
		"daemon"   => \$daemon,
		"help"     => \$help,
		"version"  => \$version,
	);

	if ($help) {
		exit print_help();
	}
	elsif ($version) {
		exit print_version();
	}
	elsif ($daemon) {
		unless ( defined $config_file_path ) {
			for my $path (@config_search_paths) {
				$config_file_path = $path if -f $path;
			}
		}
		unless ( defined $config_file_path ) {
			error "Unable to open configuration file.";
		}
		my $config_hash_ref = read_config($config_file_path);
		my $msg;
		unless ( check_is_config_valid( $config_hash_ref, \$msg ) ) {
			error $msg;
		}
		unless ( defined $config_hash_ref->{'Host'} ) {
			error "Host is not specified.";
		}
		run_daemon($config_hash_ref);
	}
	else {
		exit print_usage();
	}
}

main();
