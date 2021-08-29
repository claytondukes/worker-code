#!/usr/bin/perl -I/srv/current/common/
#
# This is the hook that executes every time
# a new local-git repository is created.
#
# Steve
# --
#

use strict;
use warnings;

use File::Basename qw! basename !;
use JSON;
use Redis;
use UUID::Tiny;


#
# Find which repository invoked us.
#
my $dir = `pwd`;
$dir =~ s/[\r\n]//g;
my $name = basename($dir);

#
# What we post to the internal-queue.
#
my %hash;
$hash{ 'owner' } = $name;
$hash{ 'url' }   = $dir;
$hash{ 'uuid' }  = UUID::Tiny::create_uuid_as_string();

#
# Add the JSON object to our queue
#
my $redis = Redis->new();
my $txt   = to_json( \%hash );
$redis->rpush( "HOOK:JOBS", $txt );

#
# Show a  pretty message to the user.
#
print "\n";
print "See the result of your push at:\n";
print "\thttps://dns-api.com/pushevent/" . $hash{ 'uuid' } . "\n";
print "\n";
exit(0);
