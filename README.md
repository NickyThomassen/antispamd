antispamd is a Perl daemon, written to give mail administrators a way for their users to train SpamAssassin. Besides this document, antispamd consists of 3 parts:

  antispamd.pl    -  The daemon itself
  antispamd.init  -  The Debian init-script
  antispamd.conf  -  The configurationfile

It's all licensed as GPLv2 in the hopes others can use the software, but please note that I wrote it to solve my own spam-problem and therefore it may not solve yours, or even work for you.

The background for this daemon comes from my need to run a virtual mailserver, with heavy focus on security and useablility. Debian GNU/Linux and Postfix handles security while Postfix' postscreen coupled with conservative DNS-based blackhole lists and Apaches SpamAssassin mostly takes care of the spam. But by using Bayers learning it's almost a given fact that SpamAssassin will need some training from the users.

By using Dovecots dovecot-antispam package in the Debian repository, a plain-text copy of a mail can be placed in a directory if it's moved in or out of the users spam folder. This, of course, requires the use of IMAP. Then depending of the operation, dovecot-antispam can prepend either "spam" or "ham" to the copys filename, and this is where antispamd comes in. It takes those spams and hams and feed them into SpamAssassins learning tool sa-learn, deletes old copys, and moves procesed copys to a archive directory for later deletion.

It's written as a daemon, compared to a script cron could run, to ensure it's fairly system agnostic. Therefore the daemon itself should be able to run on UNIX/Linux in general, while the init-script is limited to Debians sysV / init. The daemons memory footprint is around 5mb, and sa-learn takes roughly 1 - 1.5 second for each plain-text mail it's feeded.

It's designed to run for months on end, and only supports the most basic features, with the sole purpose to enhance a mailserver. Please note that other solutions exists to train a SpamAssassin instance, and that this setup requires Dovecot and SpamAssassin to be on the same machine. One way to circumvent this limitation would be to use NFS mounted directorys from the server running SpamAssassin.

The init-script depends on the daemon being located in /usr/local/bin/antispamd.pl, but this can be changed be editing the init-script, line 11 and 12. Please don't edit line 13, the location of the PID-file, since the daemon itself is hardcoded to use this location, unless you also change the daemon, line 59.

So, to install antispamd on Debian, simply cp/mv antispamd.pl to /usr/local/bin/antispamd.pl, cp/mv antispamd.init to /etc/init.d/antispamd, cp/mv antispamd.conf to /etc/default/antispamd.conf (if you plan on using it) and delete this file. The daemon and the init-script needs the execution bit set, which can be done with "chmod +x /usr/local/bin/antispamd.pl" and "chmod +x /etc/init.d/antispamd" and if antispamd.pl should start at boot, init needs to be updated with something like "update-rc.d antispamd defaults". Please read the manual pages for chmod and update-rc.d before using them from some random document.

And for an example on setting up Dovecot, add these lines to the main configuration file:
(the 3 dots represents other content in the file, and should not be added)

plugin {

  ...

  antispam_verbose_debug = 1
  antispam_backend = spool2dir
  antispam_trash = Trash
  antispam_spam = Spam
  antispam_spool2dir_spam    = /var/spool/dovecot-antispam/spam-%%020lu-%u-%%05lu.dove
  antispam_spool2dir_notspam = /var/spool/dovecot-antispam/ham-%%020lu-%u-%%05lu.dove
}

protocol imap {
  mail_plugins = ... antispam
}

Versions used at the time of writing:
Debian 7 - Wheezy Stable
Perl 5.14.2, patch 21
Postfix 2.9.6, patch 2
Dovecot 2.1.7, patch 7
SpamAssassin 3.3.2, patch 5

Bugs and suggetions can be mailed to nicky@aptget.dk, but please note that I don't have the time to enhance the daemon with new functions. It's open source; do it yourself.
