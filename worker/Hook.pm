#!/usr/bin/perl -w -I/srv/current/common/ -I.

=head1 NAME

Hook - Process Hook Events

=head1 DESCRIPTION

This module allows is the main code which handles the submission of
C<git> pushes.

It can be called in two ways:

=over 8

=item Via a git push
This will result in the cloning of a git repository, some sanity checks
then the parsing of a number of zones.

=item With a single file
In this mode only basic tests are done, and a single zone-file is
processed.

=back

The usage for both looks pretty simple.

=cut


package Hook;

use strict;
use warnings;

#
#  Standard perl.
#
use Data::Dumper;
use File::Basename qw! basename !;
use JSON;
use Log::Message;

#
#  Our modules
#
use DNSAPI::User;
use Singleton::Redis;
use TinyDNS::Reader::Merged;
use WebService::Amazon::Route53;
use WebService::Helper;

#
# Prefix for our repositories
#
my $PREFIX = "/git";


#
# Ignored domains
#
my %IGNORE;
$IGNORE{ 'spare.io' }      = "Not hosted here";
$IGNORE{ 'rsync.io' }      = "This domain doesn't live here.";



=head2 new

Constructor.

This is expected to be created with a series of arguments, if it was
created as a result of a trigger.

If there was no trigger, and we're just performing local testing,
then the arguments may be empty.

=cut

sub new
{
    my ( $proto, %supplied ) = (@_);
    my $class = ref($proto) || $proto;

    my $self = {};
    bless( $self, $class );

    # save away any keys we were given.
    foreach my $key ( keys %supplied )
    {
        $self->{ $key } = $supplied{ $key };
    }

    # ensure we have somewhere to clone our repositories to.
    system( "mkdir", "-p", $PREFIX ) unless ( -d $PREFIX );

    $self->_setup_logger();

    return $self;
}


=head2 _setup_logger

This method sets up a new L<Log::Message> object, which is used
to get the output of our job.

If there is already a logger present we leave it in-place.

=cut

sub _setup_logger
{
    my ($self) = (@_);

    return ( $self->{ 'logger' } )
      if ( $self->{ 'logger' } );

    $self->{ 'logger' } = Log::Message->new(

        # per-object stack
        private => 1,

        # don't show output
        verbose => 0,

        # retrieve in FIFO order.
        chrono => 1,

        # DON'T Remove items when retrieving
        # them - so we can retrieve once
        # to add to MySQL and once to add
        # to Redis.
        remove => 0
    );

    # return the newly-created object.
    return ( $self->{ 'logger' } );
}


=head2 process

If we've been created in response to a git-push then this
method will be invoked and will trigger most of the magic:

=over 8

=item clone the repo

=item find the zones

=item process each of them

=back

=cut

sub process
{
    my ($self) = (@_);

    #
    #  Get access to our logger.
    #
    my $logger = $self->_setup_logger();

    my $start = time;
    $logger->store( "Starting to process push event at " . localtime(time) );

    #
    #  Ensure we have all the expected data:
    #
    #   1.  The username of the account that this job belongs to.
    #
    #   2.  The "URL" of the remote git repository.
    #
    #   3.  A UUID to identify the job.
    #
    foreach my $key (qw! url owner uuid !)
    {
        if ( !$self->{ $key } )
        {
            $logger->store("Missing key: $key");
            return;
        }
    }

    #
    #  Get the owner and ensure it is valid.
    #
    my $owner = $self->{ 'owner' };
    if ( $owner !~ /^([a-z0-9_-]+)$/i )
    {
        $logger->store(
                   "Submission from a user who failed our regexp-test: $owner");
        return;
    }

    #
    #  Get the rest of the data
    #
    my $url  = $self->{ 'url' };
    my $uuid = $self->{ 'uuid' };

    if ( $uuid !~ /^([a-z0-9_-]+)$/i )
    {
        $logger->store("Submission with a bogus UUID, by $owner\n");
        return;
    }

    #
    #  Ensure the owner is a valid registered-user.
    #
    my $user = DNSAPI::User->new();
    if ( !$user->exists($owner) )
    {
        $logger->store("Submission from a user who doesn't exist: $owner\n");
        return;
    }

    #
    #  Log some details.
    #
    $logger->store("\tThe job belongs to $owner.");

    #
    #  Get the user-data, because we're not going to process
    # jobs that belong to those people who have been expired.
    #
    my $data = $user->get( user => $owner );
    my $status = $data->{ 'status' } || "unknown";
    my $expired = 0;

    if ( $status =~ /expired/i )
    {
        $expired = 1;
        $logger->store("\tThis user has expired their free trial.");
        $logger->store("\n");
    }
    else
    {
        $logger->store("\tUser-status: $status");
        $logger->store("\n");
    }


    #
    # ensure we have somewhere to clone our repositories to.
    #
    system( "mkdir", "-p", $PREFIX ) unless ( -d $PREFIX );


    #
    # So we know what we're cloning, and we need to pick
    # a destination directory.
    #
    # We'll do that by taking "/repos/cdukes" into
    # /git/cdukes
    #
    # i.e. basename of repo.
    #
    my $dst = basename( $self->{ 'url' } );

    #
    # Files we're going to process.
    #
    my @files;

    #
    # If the repository exists then update to it.
    #
    if ( -d $PREFIX . "/" . $dst . "/.git" )
    {

        #
        # Get old revision.
        #
        my $rev = `cd $PREFIX/$dst && git rev-parse HEAD`;
        chomp($rev);
        $logger->store("git repository exists locally.");
        $logger->store("existing repository has revision ID $rev");

        #
        # Run git pull.
        #
        system("cd $PREFIX/$dst && git pull");

        #
        # Get differences
        #
        my $diff = `cd $PREFIX/$dst && git diff --name-only $rev..HEAD`;

        #
        # For each zone-file that changed.
        #
        foreach my $line ( split( /[\n\r]/, $diff ) )
        {
            chomp($line);
            if ( $line =~ /zones/ )
            {
                push( @files, "$PREFIX/$dst/" . $line );
                $logger->store("New commit modified: $line");
            }
        }
    }
    else
    {

        $logger->store("Cloning the git repository.");

        #
        # Fetch it.
        #
        system("cd $PREFIX/ && git clone --quiet $self->{ 'url' }");

        #
        #  Ensure the repository exists.
        #
        if ( !-d "$PREFIX/$dst/.git" )
        {
            $logger->store("\tCloning the repository failed.");
            return;
        }
        else
        {
            $logger->store("\tSuccessfully cloned the repository.");
        }

        #
        # These are the files we're going to process.
        #
        @files = sort( glob("$PREFIX/$dst/zones/*") );
    }

    #
    #  Get the commit message for reference
    #
    my $out = `cd $PREFIX/$dst && git log -1 --pretty=\%B 2>/dev/null`;
    if ( $out && length($out) )
    {
        $out =~ s/&/&amp;/g;
        $out =~ s/</&lt;/g;
        $out =~ s/</&gt;/g;

        $logger->store("\nThe last commit message was:\n");
        $logger->store( "-" x 80 );
        $logger->store($out);
        $logger->store( "-" x 80 );
        $logger->store("\n\n");
    }


    #
    #  Ensure the repository has content.
    #
    my $project = "$PREFIX/$dst";
    if ( !-d $project . "/zones/" )
    {
        $logger->store(
               "The repository doesn't contain a zones/ directory - skipping.");
        return;
    }


    #
    #  Process the zones
    #
    foreach my $filename (@files)
    {
        #
        #  Get the zone from the filename
        #
        my $zone = basename($filename);
        $zone = lc($zone);

        #
        #  Log the start of activity.
        #
        $logger->store("\n\nPreparing to parse the file zones/$zone");

        #
        #  Are we ignoring this zone?
        #
        my $ignored = 0;
        if ( $IGNORE{ $zone } )
        {
            my $reason = $IGNORE{ $zone };
            $logger->store("\tZone explicitly ignored: $reason");
            $ignored = 1;
        }

        #
        #  Is it an example domain?
        #
        if ( $zone =~ /^example\./i )
        {
            $logger->store("\tZone is a reserved domain, and is ignored.");
            $ignored = 1;
        }

        #
        # Only process files that exist.
        #
        if ( !-e $filename )
        {
            $logger->store("\tWas the file removed?");
            $ignored = 1;
        }


        #
        #  If the user has expired their trial then we'll not process
        # their record.
        #
        if ($expired)
        {
            $ignored = 1;
            $logger->store(
                       "\tIgnoring zone, as the user is in the expired-state.");
            $logger->store(
                "\tPlease register a credit-card at https://dns-api.com/subscription/\n"
            );
        }

        #
        next if ($ignored);

        #
        #  Otherwise process the job
        #
        $self->process_input( filename => $filename,
                              user     => $owner,
                              zone     => $zone
                            );
    }

    my $end = time;
    $logger->store( "\n\nFinished at " . localtime( time() ) );
    $logger->store( "\tRun-time " . ( $end - $start ) . " seconds." );

    #
    # Add the results of the operation to the queue, where it
    # will be emailed to the user.
    #
    # If there is no email address then the worker will just skip the
    # job.  Otherwise it will be sent to the user.
    #
    my %hash;

    #
    #  If the user has notifications turned on then add their email to
    # the hash we add to the queue.  Without this the mail will go to steve
    # alone.
    #
    my $notify = $data->{ 'hook_notification' } || 0;
    if ($notify)
    {
        $hash{ 'email' } = $data->{ 'email' };
    }
    else
    {
        $hash{ 'email' } = undef;
    }

    #
    # The rest of the objects.
    #
    $hash{ 'user' } = $owner;
    $hash{ 'uuid' } = $uuid;

    #
    #  Get the text
    #
    $hash{ 'text' } = $self->get_output();

    #
    #  Encode to JSON, and add to the queue.
    #
    my $txt = encode_json( \%hash );
    my $r   = Singleton::Redis->instance();
    $r->rpush( "HOOK:OUTPUT", $txt );

    #
    #  At this point we're done.
    #
}


=head2 get_output

Return the output of this run.

=cut

sub get_output
{
    my ($self) = (@_);

    my $text = "";

    my @items = $self->{ 'logger' }->retrieve();
    if (@items)
    {
        foreach my $ent (@items)
        {
            $text .= $ent->{ 'message' } . "\n";
        }
    }
    return $text;
}


=head2 process_input

Process a single file:

=over 8

=item Parse the file.

=item Remove orphaned records.

=item Add/Update other records.

=back

=cut

sub process_input
{
    my ( $self, %params ) = (@_);

    # Ensure the logger is setup
    $self->_setup_logger() unless ( $self->{ 'logger' } );
    my $logger = $self->{ 'logger' };

    #
    # Get the parameters we expected to have received.
    #
    my $file = $params{ 'filename' };
    my $zone = $params{ 'zone' };
    my $user = $params{ 'user' };


    #
    # Do the magic.
    #
    $logger->store("\tProcessing the zone $zone");
    sleep(2);

    #
    #  Parse the records, via our DNS-reader object.
    #
    my $records;
    eval {
        my $td = TinyDNS::Reader::Merged->new( file => $file, zone => $zone );
        $records = $td->parse();
    };
    if ($@)
    {
        $logger->store(
            "\t<span style=\"color:red; font-weight:bold\">Failed to parse zone: $zone\n$@</span>"
        );
        return;
    }

    #
    #  Show the result of the record-parsing.
    #
    if ($records)
    {
        $logger->store( "\t\tParsed " . scalar(@$records) . " records." );
    }
    else
    {
        $logger->store(
            "\t<span style=\"color:red; font-weight:bold\">Found zero valid records.</span>"
        );
        return;
    }

    #
    #  Find the zone, via Route53.
    #
    my $helper = WebService::Helper->new();
    my $data =
      $helper->find_or_create_zone( zone => $zone,
                                    user => $user );

    #
    #  If there was an error finding/creating the zone then we'll
    # abort now.
    #
    if ( $data->{ 'error' } )
    {
        $logger->store(
            "\tThere was an error finding/creating the zone $zone - $data->{'error'}->{'code'}"
        );
        return;
    }

    #
    #  Inside the result we'll have the owner of the zone.
    #
    #  If the owner doesn't match that who is submitting the job
    # then we will abort.
    #
    my $creator = "";
    if ( $data &&
         $data->{ 'config' } &&
         $data->{ 'config' }->{ 'comment' } )
    {
        $creator = $data->{ 'config' }->{ 'comment' };
    }
    if ( length($creator) )
    {
        $creator =~ s/^Owner://g;
        $creator =~ s/^\s+|\s+$//g;

        if ( $user ne $creator )
        {
            print "OWNER: $user - CREATOR: $creator\n";
            $logger->store(
                "\t<span style=\"color:red; font-weight:bold\">Security mismatch for zone.</span>"
            );
            return;
        }
    }

    #
    #  If the zone was new then we'll add a notice to one of
    # our work-queues, such that we can mail the admin(s)
    # asynchronously.
    #
    if ( $data->{ 'created' } )
    {
        $logger->store(
            "\t<span style=\"color:red; font-weight:bold\">The zone is new: $zone</span>"
        );

        my %x;
        $x{ 'user' } = $user;
        $x{ 'zone' } = $zone;
        my $t = encode_json( \%x );

        my $r = Singleton::Redis->instance();
        $r->rpush( "NEW:ZONE", $t );
    }

    #
    #  Now get the records
    #
    my $zone_id = $data->{ 'id' } || $data->{ 'zone' }->{ 'id' };

    $logger->store("\tThe zone $zone has ID $zone_id");


    #
    #  Find the records for this zone.
    #
    #  Once we've found them we create a hash of the existing records - by
    # name and type.
    #
    #  This will be used in the future to ensure that we don't
    # update records that are already present.
    #
    my $existing = $helper->get_all_records( zone_id => $zone_id );

    my %present;
    if ($existing)
    {
        foreach my $entry (@$existing)
        {
            my $name = $entry->{ 'name' };
            my $type = $entry->{ 'type' };
            next unless $name;
            next unless $type;

            $name = lc($name);
            $type = lc($type);

            # We don't care about these record types.
            next if ( $type =~ /^(NS|SOA)$/i );
            $present{ $name }{ $type } = $entry;
        }
    }


    #
    #  Debug Information
    #
    my $x = "Existing Records for zone $zone\n";
    print $x;
    print "=" x length($x) . "\n";
    print Dumper( \%present );
    print "#" x 80 . "\n";

    #
    # Look at the existing records.
    #
    # For each one see if there is a record in the new/updating set.
    #
    $logger->store("\tLooking for orphaned records:");

    my @orphan;
    foreach my $name ( sort keys %present )
    {
        foreach my $type ( sort keys %{ $present{ $name } } )
        {
            #
            #  Look for the value
            #
            my $found = 0;

            #
            #  Did we even parse anything?
            #
            next unless ($records);

            #
            #  If we did then look for each record to see if we've
            # found something with the same name/type as the existing
            # one.
            #
            foreach my $x (@$records)
            {
                my $en = $x->{ 'name' };
                next unless $en;

                $en .= ".";
                $en = lc($en);

                my $et = $x->{ 'type' };
                next unless $et;
                $et = lc($et);

                if ( ( $et eq $type ) &&
                     ( $en eq $name ) )
                {
                    $found = 1;
                }
            }
            if ( !$found )
            {
                push( @orphan, $present{ $name }{ $type } );
            }
        }
    }


    #
    #  Now we should have all the information we need to remove the
    # orphaned record(s).
    #
    $logger->store( "\t\t" . scalar(@orphan) . " orphaned records found." );
    foreach my $ent (@orphan)
    {
        $logger->store(
            "\t\t<span style=\"color:red; font-weight:bold\">Removing orphaned record $ent->{'name'} [$ent->{'type'}]</span>"
        );

        $helper->delete_records( zone_id => $zone_id,
                                 name    => $ent->{ 'name' },
                                 ttl     => $ent->{ 'ttl' },
                                 type    => $ent->{ 'type' },
                                 value   => $ent->{ 'resource_records' },
                               );
    }

    # Record the number of orphans.
    $self->{ 'orphans' } = scalar(@orphan);

    $logger->store("\tProcessing the records in the zone:");

    #
    # For each record the user has uploaded, which we've successfully
    # parsed we should now see if we need to update it.
    #
    foreach my $expected ( sort {$a->{ 'name' } cmp $b->{ 'name' }} @$records )
    {
        next unless $expected;

        my $et = $expected->{ 'type' };
        next unless $et;
        next if ( $et =~ /error/i );

        my $en = $expected->{ 'name' };
        next unless $en;
        $en .= ".";

        my $ttl = $expected->{ 'ttl' } || 300;

        $logger->store("\t\tProcessing $et record $en");

        sleep(1);
        my $val = $expected->{ 'value' };
        my $x =
          $helper->update_record( zone_id => $zone_id,
                                  name    => $en,
                                  ttl     => $ttl,
                                  type    => $et,
                                  value   => $val,
                                );

        if ( $x && $x->{ 'message' } )
        {
            $logger->store(
                "\t\t\t<span style=\"color:red; font-weight:bold\">$x->{'message'}</span>"
            );

        }
        if ($x)
        {
            print Dumper( \$x );
        }
    }

    #
    #  Update the users domains table - first find the right name
    # servers to record.
    #
    my @ns = ();
    foreach my $records (@$existing)
    {
        next unless ( $records && $records->{ 'type' } eq "NS" );
        foreach my $ns ( @{ $records->{ 'resource_records' } } )
        {
            push( @ns, $ns ) if ( $ns =~ /awsdns/i );
        }
    }

    #
    #  Updating the zone-table to show the current/correct nameservers.
    #
    my $h = DNSAPI::User->new();
    $h->update_domain_nameservers( $user, $zone, @ns );
}


1;
