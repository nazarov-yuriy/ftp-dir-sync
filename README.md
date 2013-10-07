ftp-dir-sync
============

NAME
----
       ftp-dir-syncd - Crossplatform daemon/service to keep local and remote(accessible via ftp) directories in sync

SYNOPSIS
--------
       ftp-dir-syncd.pl [action]

       Actions:

               --help                          to view help

               --man                           to view full documentation

               --version                       to print version

               --daemon [--config=<file>]      to start as daemon/service

       Windows only actions:

               --install [--user=<user>]       to install service to run as system user(or specified user)

               --uninstall                     to uninstall service

OPTIONS
-------
       --help  Just print help.

       --man   Print standard linux man page with navigation.

       --version
               Just print current version.

       --daemon
               Start run in background.

       --config
               By default script search configuration file ftp-dir-sync.[conf|ini] in locations: /etc, current dir, script dir.  This option override this setting.

       --install
               Instal on Windows machines as system service runned as system user if username not explicitly specified.

       --user  Specify user to run service.

       --uninstall
               Uninstall system service on Windows.

EXAMPLES
--------

To start daemon on Linux:
```
$ ./ftp-dir-syncd.pl --daemon
```

To start daemon on Windows:
```
> ftp-dir-syncd.pl --install
```
and then go to Control panel -> Administrative tools -> Services and start ftp-dir-sync service

DESCRIPTION
-----------
       This daemon/service work in background to keep directories in sync
