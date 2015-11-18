#!/usr/bin/perl -w
#
# Glue program to make Postfix, Dovecot and
# SpamAssassin more tightly integrated.
#   *Made by mad hound nicky*
#     nicky@aptget.dk
#
# Version 0.1, 01/11 2013 - Initial release
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#   http://www.gnu.org/licenses/gpl-2.0.txt
#
################################################################################
# Things to fix and / or enhance at some point.
#
# Give each exit condition its own exit status, and document them somewhere.
#
# It might not be to much work to subtract runtime from sleeptime, and thereby
# control the spacing between actual runtimes instead of sleeptimes.
#
################################################################################
# Pragmas used throughout the program.
use strict; # No shortcommings throughout the code.
use warnings; # Any and all warnings are printet.
use POSIX qw(setsid); # Sets the session identifier.
use Sys::Syslog qw(:DEFAULT setlogsock); # Gives access the easy syslogging.
use Time::HiRes qw(time); # Gives access to nanoseconds.
use Scalar::Util qw(looks_like_number); # Makes evaluating a number easy.
use File::Copy; # Gives easy file copy / move ability.
use Getopt::Std; # Standard interface to collect given flags.
#
################################################################################
# To avoid scoping problems variables is declared beforehand, exept those used
# by loops and subroutines, they are out of this scope.
#
# Some of these variables holds a standard value, that will only change if they
# are defined in the configuration file, and stands up to validation. Others
# can't be changed at all. They start the comment with a *.
our %opts; # Holds the paramters given to the program, if any.
my %config_options; # Holds every name:value pair from the config.
my @files_old; # Used to store a list of the exiting files in $archive.
my $files_old_num; # Holds the number of old files to move.
my $pid; # Will contain the PID, if the program executes as a daemon.
my $pid_filefh; # Used as the filehandle for the PID file.
my $p_name = 'antispamd'; #* Name of the process.
my $pid_dir = '/var/run'; #* Path to the PID directory.
my $stop_daemon = 0; # Stops all and any work and hopefully exists cleanly.
my $sleep_time; # Number of seconds the daemon sleeps before starting a new run.
my @files_hams; # Contains the hams from $processing.
my @files_spam; # Contains the spams from $processing.
my $sal_args_hams = '--ham --file'; #* Prepended the ham call to sa-learn.
my $sal_args_spam = '--spam --file';  #* Prepended the spam call to sa-learn.
my $pre_hams; # The prepended part of the filename to distinguish ham from spam.
my $pre_spam; # The prepended part of the filename to distinguish spam from ham.
my $sal; # Holds the path to sa-learn.
my $sal_run = 'no'; # Tells if sa-learn can be used.
my $config_file; # Holds the path to the configuration file.
my $logfilefh; # Holds the filehandle for the logfile.
my $syslog_open; # Tells if syslog is already open.
my $execution_time; # Allows to skip timming of execution.
my $time_start; # Logs the epoch at execution start.
my $time_total; # Holds the time for logging.
my $use_sa_learn; # Allows sa-learn to be skipped.
my $process_dir; # Directory where Dovecot saves the files / mails.
my $archive_dir; # Directory to archive processed files.
my $counter; # Used to count various actions throughout the program.
my $delete_old; # If old files should be deleted.
my $delete_age; # And at what age, in days.
my $log_level; # Defines the verbosity of the program.
my $use_syslog; # Sets if syslog should be used for logging.
my $syslog_facility; # And if syslog is used, what facility to log to.
my $use_logfile; # Sets if the program should log to file.
my $log_dir; # And if set, what directory the logfile should be placed in.
#
################################################################################
# Some initial tests to be conducted before using more CPU cycles.
#
# Collection of given paramters, if any.
getopts('cf:', \%opts);
#
# If '-f' is set, we'll try to use that as the configurationfile.
if ($opts{f}) {
  $config_file = $opts{f};
}
else {
  # Otherwise we'll try to use this file.
  $config_file = "/etc/default/$p_name.conf";
}
# We better check if the selected file exists.
if (! -e "$config_file") {
  print STDOUT "Fatal: Configurationfile antispamd.conf was not found in \"$config_file\"\n";
  print STDOUT "Please create it, or link to one with -f\n";
  exit 10;
}
# Call the configuration validation subroutine.
# It exists the program if errors or typos is found in the configurationfile.
&parse_config_file($config_file, \%config_options);
# And then the extended configuration validation subroutine is called.
# It sets some sane defaults, and do basic validation of the values.
&read_config_file;
#
# Since parameter '-c' means 'check config', and the above functions would have
# exited the program at any sign of trouble, we'll exit with success now.
if ($opts{c}) {
  # But not before printing the name:value pairs of the configuration.
  print "No errors in the configuration detected. List of parameters:\n";
  foreach my $config_key (sort(keys %config_options)) {
    print "$config_key = $config_options{$config_key}\n";
  }
  exit 0
}
# Check for existing PID file and exit if found.
if (-e "$pid_dir/$p_name.pid") {
  print STDOUT "Fatal: PID file \"$pid_dir/$p_name.pid\" found, exiting\n";
  exit 10;
}
# root is needed, since we'll be working on mails.
if ($< != 0) {
  print STDOUT "Fatal: Not enough privilegies, root required. Exiting\n";
  exit 10;
}
#
################################################################################
# Launching of the daemon.
#
# Change to the root folder, so we don't lock the current folder.
if (! (chdir '/')) {
  print STDOUT "Fatal: Can't chdir to root (/): $!\n";
  exit 10;
}
# Not strictly needed, since we only create 1 file, but it's standard.
umask 0;
# The fork itself, which copys the parent to a child.
if (! (defined($pid = fork))) {
  print STDOUT "Fatal: Can't fork: $!\n";
  exit 10;
}
# And if $pid contains something, we may exit the parent.
if ($pid) {
  exit 0
}
# Let's ensure we're completely dissociated from the parents tty.
if (! (setsid() != -1)) {
  print STDOUT "Can't start a new session: $!\n";
  exit 10
}
# Close the open file descriptors.
close(STDIN); close(STDOUT); close(STDERR);
# And then we open them to the bitbucket.
if (! (open STDIN,   '<', '/dev/null')) {
  logging("Fatal: Can't read from /dev/null: $!", 1);
  exit 10;
}
if (! (open STDOUT, '>>', '/dev/null')) {
  logging("Fatal: Can't write STDOUT to /dev/null: $!", 1);
  exit 10;
}
if (! (open STDERR, '>>', '/dev/null')) {
  logging("Fatal: Can't write STDERR to /dev/null: $!", 1);
  exit 10;
}
# Let's log the successful launch of our shinny new program.
logging("Starts with PID $$", 2);
# A PID file should be made. First the file is opened for writting.
if (! open($pid_filefh, '>', "$pid_dir/$p_name.pid")) {
  logging("Fatal: Could not create \"$pid_dir/$p_name.pid\": $!", 1);
  exit 10;
}
# Then the PID is written to the file.
if (! print $pid_filefh "$$\n") {
  logging("Fatal: Could not write to \"$pid_dir/$p_name.pid\": $!", 1);
  exit 10
}
# Then we close the filehandle.
close($pid_filefh);
# And sets some proper permissions on the file, since Perls standard is 0666.
if (! chmod 0644, "$pid_dir/$p_name.pid") {
  logging("Fatal: Could not set permissions for \"$pid_dir/$p_name.pid\": $!", 1);
  exit 10
}
#
################################################################################
# The actual content of the daemon.
#
# Interception of signals can sometimes insure a cleanish shutdown.
$SIG{INT} = $SIG{TERM} = $SIG{HUP} = \&ipc;
#
# The code from this point on is run in a loop by the daemon.
until ($stop_daemon) {
  # We'll time the execution, if wanted, that is.
  if ($execution_time eq 'yes') {
    # Saves the current UNIX epoch time.
    $time_start = time;
  }
  # In two rounds SpamAssassin will be trained, if $sal_run is equal to 'yes'.
  if ($sal_run eq 'yes') {
    # Opens the directory with the files for processing.
    if (opendir(DIR_PROCESS, $process_dir)) {
      # Using glob matching the two arrays will be built.
      # Note the use of quotation marks, glob needs them under some conditions.
      @files_hams = glob("$process_dir/$pre_hams-*.dove");
      @files_spam = glob("$process_dir/$pre_spam-*.dove");
      # Even though it's the first use, we resest it just in case.
      $counter = 0;
      # However, if both arrays are empty, we will skip sa-learn on this run.
      if (! (@files_hams || @files_spam)) {
        logging("No files to be processed by sa-learn", 2);
      }
      else {
        # Loops through @files_hams, one line at a time, if it's not empty.
        if (@files_hams) {
          foreach my $file (@files_hams) {
            # Feeds that line to sa-learn with the arguments.
            system("$sal $sal_args_hams $file");
            # Some verbose logging, so single files may be traced.
            logging("sa-learn processed \"$file\"", 3);
            # Adds 1 to the counter for each mail SA has trained on.
            $counter++;
            # Checks if the program has been interupted since the last loop.
            if ($stop_daemon == 1) {
              # And exists if it has.
              exit 0
            }
          }
        }
        # Very much the same as above, just with spam instead of ham.
        if (@files_spam) {
          foreach my $file (@files_spam) {
            system("$sal $sal_args_spam $file");
            logging("sa-learn processed \"$file\"", 3);
            $counter++;
            if ($stop_daemon == 1) {
              exit 0
            }
          }
        }
        logging("sa-learn processed $counter file(s)", 2);
      }
      # We are done with the directory in this context.
      close(DIR_PROCESS);
    }
    # If the directory could not be opened, we surely want to know about it.
    else {
      logging("Can't open directory: $!", 1);
      logging("sa-learn and, if set, movement of old files, will not be done", 1);
      # And since it failed, we'll not be doing more work in the filesystem.
      $sal_run = 'no';
    }
  }
  # Only if $delete_old is yes will we examine and potentiel delete old files.
  if ($delete_old eq 'yes') {
    # Opens the $archive directory.
    if (opendir(DIR_ARCHIVE, $archive_dir)) {
      # Adds all the files in $archive to the array.
      @files_old = glob("$archive_dir/*.dove");
      # Logs the number of old files.
      $files_old_num = scalar(grep {defined $_} @files_old);
      logging("The number of old files in \"$archive_dir\" is $files_old_num", 3);
      # Resets the counter.
      $counter = 0;
      # Time to go through the list of old files.
      foreach my $file_old (@files_old) {
        # stat() returns 12 fields from the file; field 9 is the files mtime.
        if (((stat($file_old))[9]) < (time - $delete_age)) {
          # If mtime is less than current time minus $delete_age, we'll unlink it.
          unlink $file_old;
          logging("Deleted \"$file_old\"", 3);
          # And then raise the counter by 2*0.5.
          $counter++;
        }
      }
      # We're done with the directory in this context.
      close(DIR_ARCHIVE);
      if ($counter == 0) {
        logging("No old files were deleted from \"\$archive_dir\"", 2);
      }
      else {
        logging("$counter old file(s) were deleted from \"\$archive_dir\"", 2);
      }
    }
    # If the directory could not be opened, we want to know about it.
    else {
      logging("Can't open directory: $!", 1);
      logging("Old files will not be deleted and moved", 1);
      # And since it failed, we'll not be doing more work in the filesystem.
      $sal_run = 'no';
    }
  }
  # If $sal_run still equals 'yes', it's time to move some files to $archive.
  if ($sal_run eq 'yes') {
    # But only if the arrays contained something.
    if (@files_hams || @files_spam) {
      # And only if both directorys can be opened.
      if ((opendir(DIR_PROCESS, $process_dir)) && (opendir(DIR_ARCHIVE, $archive_dir))) {
        # Moves ham and spam to $archive, if the array is not empty.
        if (@files_hams) {
          # Take each line from the array and put it in $file.
          foreach my $file (@files_hams) {
            # Then the moving.
            move("$file", "$archive_dir");
            # And then some verbose logging.
            logging("Moved \"$file\" to \"$archive_dir\"", 3);
          }
        }
        # Very much the same thing, just with spam instead of ham.
        if (@files_spam) {
          foreach my $file (@files_spam) {
            move("$file", "$archive_dir");
            logging("Moved \"$file\" to \"$archive_dir\"", 3);
          }
        }
        # And then close the directorys.
        close(DIR_PROCESS); close(DIR_ARCHIVE);
      }
      # If one of the directorys could not be opened, we better log it.
      else {
        logging("Can't open directory: $!", 1);
        logging("Old files will not be deleted", 1);
        # And since it failed, we'll not doing more work in the filesystem.
        $sal_run = 'no';
      }
    }
  }
  # If timming was wanted, we can now print the execution time.
  if ($execution_time eq 'yes') {
    $time_total = (time - $time_start);
    # Log the epoch difference.
    logging("Completed in $time_total seconds", 2);
  }
  # Time to take a nap.
  logging("Sleeps for $sleep_time seconds", 2);
  sleep $sleep_time;
}
#
################################################################################
# Declaration of subroutines
#
# Subroutine which enables logging to syslog and file.
sub logging {
  # Splits the log message from the log verbosity, and declare the variables.
  my ($log_message, $verbosity) = @_;
  # Check if logging to syslog is wanted.
  if ($use_syslog eq "yes") {
      # If syslog has been called earlier, there is no reason to open it again.
      if (! $syslog_open) {
        # The syslog type is UNIX.
        setlogsock('unix');
        # We will log with the chosen name to the mail facility.
        openlog("$p_name",'',"$syslog_facility");
        # Avoids opening syslog again.
        $syslog_open = 1;
      }
    # Only if $verbosity is equal to, or higher than, $log_level, will the
    # message be logged.
    if ($verbosity <= $log_level) {
      # The actual logging to syslog.
      syslog('info', "$log_message\n");
    }
  }
  # Check if logging to file is wanted.
  if ($use_logfile eq "yes") {
    # Only if $verbosity is equal to, or higher than, $log_level, will the
    # message be logged.
    if ($verbosity <= $log_level) {
      # Only if the logfile can be opened will the program continue.
      open($logfilefh, '>>', "$log_dir/$p_name.log") or die "Could not open logfile: $!";
      # Populates the variables with the current systime.
      my ($sec, $min, $hour, $mday, $mon, $year) = localtime(time);
      # Logs the time and the passed on message.
      printf $logfilefh "%2d/%2d-%4d %2d:%02d:%02d - $log_message\n",
        $mday, $mon, $year+1900, $hour, $min, $sec;
      # Closes the filehandle.
      close($logfilefh);
    }
  }
}
#
# Validate and hash the configurationfile.
sub parse_config_file {
  # These are all needed for the subroutine, which their scope is.
  my ($config, $config_line, $file, $name, $value);
  # Read the paramteres given to the subroutine.
  ($file, $config) = @_;
  # Open the file in $file.
  (open(CONFIG, "$file")) or die "Configurationfile could not be opened: $!";
  # Reads one line at a time from $file.
  while (<CONFIG>) {
    # Read each line from the file.
    $config_line = $_;
    # Remove linebreaks.
    chop($config_line);
    # Remove midline comments.
    $config_line =~ s/#.*//;
    # Remove spaces at the start of the line.
    $config_line =~ s/^\s*//;
    # Remove spaces at the end of the line.
    $config_line =~ s/\s*$//;
    # Ignore lines starting with # and blank lines.
    if (($config_line !~ /^#/) && ($config_line ne "")) {
      # Split each line into name value pairs.
      ($name, $value) = split(/=/, $config_line);
      # Removes spaces after $name.
      $name =~ s/\s*$//;
      # Removes spaces before $value.
      $value =~ s/^\s*//;
      # Check for spaces within $name.
      if ($name =~ /\s/) { die "\"$name\" may not contain space(s), exiting.\n"; }
      # Check for spaces within $value.
      if ($value =~ /\s/) { die "\"$value\" may not contain space(s), exiting.\n"; }
      # Creates a hash of the name:value pairs.
      $$config{$name} = $value;
    }
  }
  # Close the configurationfile.
  close(CONFIG);
}
#
# Provides extended configuration file validation and sets some sane standards.
sub read_config_file {
  # Sleep time between runs.
  if (exists $config_options{sleep_time}) {
    $sleep_time = $config_options{sleep_time};
  }
  else {
    $sleep_time = 3600;
  }
  # Should execution be timed.
  if (exists $config_options{execution_time}) {
    $execution_time = $config_options{execution_time};
  }
  else {
    $execution_time = 'no';
  }
  # Should old files be deleted.
  if (exists $config_options{delete_old}) {
    $delete_old = $config_options{delete_old};
  }
  else {
    $delete_old = 'no';
  }
# If set, at what age in days should old files be deleted.
  if ($delete_old eq 'yes') {
    if (exists $config_options{delete_age}) {
      $delete_age = $config_options{delete_age};
      if (! looks_like_number($delete_age)) {
        print STDOUT "delete_age has to be a whole number, and not \"$delete_age\".\n";
        exit 10
      }
    }
    else {
      $delete_age = '30';
    }
  # $delete_age needs to be in the same format as the call stat() gives.
  $delete_age = (60 * 60 * 24 * $delete_age);
  }
  # Defines the verbosity of the logging.
  if (exists $config_options{log_level}) {
    $log_level = $config_options{log_level};
    if (! looks_like_number($log_level)) {
      print STDOUT "log_level has to be a whole number, and not \"$log_level\"\n";
      exit 10;
    }
  }
  else {
    $log_level = 0;
  }
  # Defines if syslog should be used.
  if (exists $config_options{use_syslog}) {
    $use_syslog = $config_options{use_syslog};
  }
  else {
    $use_syslog = 'no';
  }
  # And, if syslog is used, what facality to use.
  if ($use_syslog eq 'yes') {
    if (exists $config_options{syslog_facility}) {
      $syslog_facility = $config_options{syslog_facility};
    }
    else {
      $syslog_facility = 'mail';
    }
  }
  # Defines if there should be logged to file.
  if (exists $config_options{use_logfile}) {
    $use_logfile = $config_options{use_logfile};
  }
  else {
    $use_logfile = 'no';
  }
  # And what directory to use for the logfile.
  if ($use_logfile eq 'yes') {
    if (exists $config_options{log_dir}) {
      $log_dir = $config_options{log_dir};
    }
    else {
      $log_dir = '/var/log';
    }
  }
  # If $use_logfile is 'yes', some additional tests is conducted.
  if ($use_logfile eq 'yes') {
    # The direcotry should exist.
    if (! -e $log_dir) {
      print STDOUT "The log directory \"$log_dir\" doesn't exist, exiting\n";
      exit 10;
    }
    # If the logfile already exists, it should be writeable.
    if (-e "$log_dir/$p_name.log") {
      if (! -w "$log_dir/$p_name.log") {
        print STDOUT "Logfile \"$log_dir/$p_name.log\" isn't writeable, exiting\n";
        exit 10;
      }
    }
    else {
      # But if the logfile doesn't exist, we need the directory to be writeable.
      if (! -w $log_dir) {
        print STDOUT "Can't create logfile \"$log_dir/$p_name.log\", exiting\n";
        exit 10;
      }
    }
  }
  # Should sa-learn be used.
  if (exists $config_options{use_sa_learn}) {
    $use_sa_learn = $config_options{use_sa_learn};
  }
  else {
    $use_sa_learn = 'no';
  }
  # Let us try to find sa-learn, if $use_sa_learn is yes.
  if ($use_sa_learn eq 'yes') {
    # chomp removes any returned newlines.
    chomp($sal = `which sa-learn`);
    # If which can't find sa-learn we will deactivate it.
    if ($? == 0) {
      $sal_run = 'yes';
    }
    else {
      print STDOUT "sa-learn not found, skipping the training of SpamAssassin.\n";
      $sal_run = 'no';
    }
  }
  # Only if either sa-learn or delete old files is set, will the directorys be checked.
  if (($sal_run || $delete_old) eq 'yes') {
    if (exists $config_options{process_dir}) {
      $process_dir = $config_options{process_dir};
    }
    else {
      print STDOUT "\"process_dir\" needs to be set in the configurationfile, exiting.\n";
      exit 10
    }
    if (! -d $process_dir) {
      print STDOUT "Directory \"$process_dir\" does not exist, exiting.\n";
      exit 10
    }
    if (exists $config_options{archive_dir}) {
      $archive_dir = $config_options{archive_dir};
    }
    else {
      print STDOUT "\"archive_dir\" needs to be set in the configurationfile, exiting.\n";
      exit 10
    }
    if (! -d $archive_dir) {
      print STDOUT "Directory \"$archive_dir\" does not exist, exiting.\n";
      exit 10
    }
  }
  # What string to prepend the filenames for spam / hams.
  if (exists $config_options{pre_hams}) {
    $pre_hams = $config_options{pre_hams};
  }
  else {
    $pre_hams = 'ham';
  }
  if (exists $config_options{pre_spam}) {
    $pre_spam = $config_options{pre_spam};
  }
  else {
    $pre_spam = 'spam';
  }
}
#
# Provide Inter Program Communication so requests to quit can be cought.
sub ipc {
  logging("Called by @_, exiting");
  $stop_daemon = 1;
}
#
# Last desperate act of the show: unlink the PID file, if it's there.
unlink "$pid_dir/$p_name.pid";
exit 0
