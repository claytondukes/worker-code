
=head1 NAME

DNSAPI::Config - Configuration variables for the site/hook-handler.

=cut

=head1 DESCRIPTION

This package contains configuration values for the web-application, and
the hook-processor.

=cut


use strict;
use warnings;


package DNSAPI::Config;


#
# Sender address for auto-generated emails
#
our $SENDER = "steve\@example.com";


#
#  Amazon AWS credentials
#
our $AWS_ID  = 'nope';
our $AWS_KEY = 'nope.nope.nope';



#
#  Site administrators
#
our %SITE_ADMINS;
$SITE_ADMINS{ 'steve' } = 1;
$SITE_ADMINS{ 'sarah' } = 1;


1;
