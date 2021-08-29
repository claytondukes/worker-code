
=head1 NAME

WebService::Helper - Interface to Amazon

=cut

=head1 DESCRIPTION

This library allows simple operations to be carried out against
Amazon's Route53 library.

=cut


use strict;
use warnings;

package WebService::Helper;


use DNSAPI::Config;
use WebService::Amazon::Route53;


=begin doc

Constructor.

=end doc

=cut

sub new
{
    my ( $proto, %supplied ) = (@_);
    my $class = ref($proto) || $proto;

    my $self = {};
    bless( $self, $class );

    $self->{ 'zone' } = $supplied{ 'zone' } if ( $supplied{ 'zone' } );

    $self->{ 'r53' } =
      WebService::Amazon::Route53->new( id  => $DNSAPI::Config::AWS_ID,
                                        key => $DNSAPI::Config::AWS_KEY );


    return $self;

}


=begin doc

Find or create the specified zone.

=end doc

=cut

sub find_or_create_zone
{
    my ( $self, %args ) = (@_);

    my $zone = $self->{ 'zone' }      || $args{ 'zone' }      || die "No zone";
    my $user = $self->{ 'user' }      || $args{ 'user' }      || die "No user";
    my $find = $self->{ 'find_only' } || $args{ 'find_only' } || 0;

    $zone .= "." unless ( $zone =~ /\.$/ );

    #
    #  Attempt to find the zone.
    #
    my $response = $self->{ 'r53' }->find_hosted_zone( name => $zone );

    #
    #  We found it.
    #
    if ( $response && $response->{ 'hosted_zone' } )
    {
        return ( $response->{ 'hosted_zone' } );
    }

    #
    #  If we're finding only then we'll avoid creating the zone here.
    #
    return if ($find);


    #
    #  Create the zone, since it wasn't found.
    #
    my $time = scalar( localtime() );

    my $res =
      $self->{ 'r53' }->create_hosted_zone( name             => "$zone",
                                            caller_reference => "$zone - $time",
                                            comment          => "Owner: $user"
                                          );

    if ( !$res )
    {
        my $res;
        $res->{ 'error' } = $self->{ 'r53' }->error();
        return ($res);
    }

    # Get the result.
    my $result = $res->{ 'hosted_zone' };
    $result->{ 'created' } = 1;
    return ($result);
}



=begin doc

Retrieve all existing records from DNS about the zone.

=end doc

=cut

sub get_all_records
{
    my ( $self, %args ) = (@_);

    my $zone_id = $self->{ 'zone_id' } ||
      $args{ 'zone_id' } ||
      die "No zone ID";

    $zone_id =~ s/^\/hostedzone\///g;

    my $records;

    #
    #  These are here to provide an offset in the iteration case.
    #
    #  The "fetch records" call will return no more than 100 records
    # at a time.
    #
    my $cont     = 1;
    my $tmp_name = undef;
    my $tmp_type = undef;
    my $tmp_id   = undef;

    while ($cont)
    {
        my $response =
          $self->{ 'r53' }->list_resource_record_sets( zone_id    => $zone_id,
                                                       name       => $tmp_name,
                                                       type       => $tmp_type,
                                                       identifier => $tmp_id,
                                                     );

        $tmp_name = $response->{ 'next_record_name' };
        $tmp_type = $response->{ 'next_record_type' };
        $tmp_id   = $response->{ 'next_record_identifier' };

        $cont = 0 unless ( $tmp_name && $tmp_type && $tmp_id );

        if ( $response->{ 'resource_record_sets' } )
        {
            foreach my $ent ( @{ $response->{ 'resource_record_sets' } } )
            {
                push( @$records, $ent );
            }
        }
    }

    return ($records);
}



sub delete_records
{
    my ( $self, %args ) = (@_);

    my $zone_id = $self->{ 'zone_id' } ||
      $args{ 'zone_id' } ||
      die "No zone ID";

    $zone_id =~ s/^\/hostedzone\///g;


    my $name = $args{ 'name' }  || die "Missing name";
    my $type = $args{ 'type' }  || die "Missing type";
    my $val  = $args{ 'value' } || die "Missing value";
    my $ttl  = $args{ 'ttl' }   || 300;


    #
    #  The action we'll carry out.
    #
    my %hash = ( action => "delete",
                 name   => $name,
                 type   => $type,
                 ttl    => $ttl,
               );

    #  The current value of the record to delete.
    if ( ref( \$val ) eq "SCALAR" )
    {
        $hash{ 'value' } = $val;
    }
    else
    {
        $hash{ 'records' } = $val,;
    }

    #
    #  Carry out the change.
    #
    my $res =
      $self->{ 'r53' }->change_resource_record_sets( zone_id => $zone_id,
                                                     changes => [\%hash] );

    if ( !$res )
    {
        if ( ref \$val eq "SCALAR" )
        {
            print "DELETING SINGLE-RECORD FAILED: $name - $type - $val\n";
        }
        else
        {
            print "DELETING RECORDS FAILED: $name - $type : " .
              join( ",", sort @$val ) . "\n";
        }
        my $error = $self->{ 'r53' }->error();
        use Data::Dumper;
        print Dumper( \$error );
    }

}


=begin doc

Update a given DNS record.  This is a one-step operation
which will change any existing value for the name/type
to match.

So rather than having to remove "foo.example.com" of
type A with valu 1.2.3.4, then add "foo.example.com[A] -> 1.22.33.44"
this is done atomicly.

=end doc

=cut

sub update_record
{
    my ( $self, %args ) = (@_);

    my $zone_id = $self->{ 'zone_id' } ||
      $args{ 'zone_id' } ||
      die "No zone ID";

    $zone_id =~ s/^\/hostedzone\///g;

    my $name = $args{ 'name' }  || die "Missing name";
    my $type = $args{ 'type' }  || die "Missing type";
    my $val  = $args{ 'value' } || die "Missing value";
    my $ttl  = $args{ 'ttl' }   || 300;


    #
    #  The action we'll carry out.
    #
    my %hash = ( action => "upsert",
                 name   => $name,
                 type   => $type,
                 ttl    => $ttl,
               );

    #  The current value of the record to upsert.
    if ( ref( \$val ) eq "SCALAR" )
    {
        $hash{ 'value' } = $val;
    }
    else
    {
        $hash{ 'records' } = $val,;
    }

    my $res =
      $self->{ 'r53' }->change_resource_record_sets( zone_id => $zone_id,
                                                     changes => [\%hash] );

    if ( !$res )
    {
        if ( ref \$val eq "SCALAR" )
        {
            print "SETTING RECORD FAILED: $name - $type - $val\n";
        }
        else
        {
            print "SETTING RECORD FAILED: $name - $type : " .
              join( ",", sort @$val ) . "\n";
        }
        my $error = $self->{ 'r53' }->error();
        return ($error);
    }
    return undef;
}



=head1 AUTHOR

Steve Kemp <steve@steve.org.uk>

=cut

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014 Steve Kemp <steve@steve.org.uk>.

This library is free software. You can modify and or distribute it under
the same terms as Perl itself.

=cut



1;
