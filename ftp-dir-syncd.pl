#!/usr/bin/perl
use Getopt::Long;
use strict;
use warnings;

#Global variables
use constant{
	DAEMON_VERSION		=> "0.1",
	DEFAULT_User		=> "anonymous",
	DEFAULT_Password	=> undef,
	DEFAULT_FTPType		=> "passive",
	DEFAULT_FTPPath		=> "/",
	DEFAULT_LocalPath	=> "./",
	DEFAULT_FileMask	=> "*",
	DEFAULT_Period		=> "3600",
	DEFAULT_DifDate		=> "yes",
	DEFAULT_DifSize		=> "yes",
};
my @config_search_paths = ( '/etc/ftp-dir-sync.conf', './' );

sub print_usage(){
	print "Use:
$0 --help		to view help
$0 --version		to view version
$0 --daemon		to start as daemon
";
	return 1;
}

sub print_version(){
	print "ftp-dir-sync daemon version ".DAEMON_VERSION."\n";
	return 0;
}

sub print_help(){
	print_version();
	print_usage();
	return 0;
}

sub main(){
	my ($config, $daemon, $help, $version);
	GetOptions(
		"config:s" => \$config,
		"daemon"   => \$daemon,
		"help"     => \$help,
		"version"  => \$version,
	);
	
	if($help){
		exit print_help();
	}elsif($version){
		exit print_version();
	}elsif($daemon){
		...
	}else{
		exit print_usage();
	}
}

main();