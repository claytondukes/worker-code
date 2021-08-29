
=head1 NAME

DNSAPI::User - A user account on our web-service.

=head1 SYNOPSIS

This module relates to managing the users signed up with our account.

=cut


package DNSAPI::User;

use strict;
use warnings;

# Perl
use File::Temp qw/ tempfile /;

# Our code
use DNSAPI::User::Auth;
use Singleton::MySQL;
use Singleton::Redis;


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

    return $self;

}


=begin doc

Does the user exist?

=end doc

=cut

sub exists
{
    my ( $self, $user ) = (@_);

    $user = lc($user) if ($user);

    my $db = Singleton::MySQL->instance() || die "Missing DB-handle";
    my $sql = $db->prepare("SELECT login FROM users WHERE login=?");
    $sql->execute($user);
    my $found = $sql->fetchrow_array() || undef;
    $sql->finish();

    return ( $found ? 1 : 0 );
}


=begin doc

Get the ID of the given user.

=end doc

=cut

sub id
{
    my ( $self, %args ) = (@_);

    my $user = $self->{ 'user' } || $args{ 'user' } || die "Missing user";

    # If we have the data return it, or null otherwise
    my $data = $self->get( user => $user );
    return ( $data ? $data->{ 'id' } : $data );
}


=begin doc

How many days ago did the user register their account?

=end doc

=cut

sub age
{
    my ( $self, %args ) = (@_);

    my $user = $self->{ 'user' } || $args{ 'user' } || die "Missing user";


    #
    #  Lookup
    #
    my $db = Singleton::MySQL->instance() || die "Missing DB-handle";
    my $sql =
      $db->prepare("SELECT DATEDIFF(NOW(), created) FROM users WHERE  login=?")
      or
      die "Failed to prepare";

    $sql->execute($user) or
      die "Failed to execute";
    my $found = $sql->fetchrow_array();

    if ($found)
    {
        return ( abs($found) );
    }
    else
    {
        return 0;
    }

}

=begin doc

Get the users email address.

=end doc

=cut

sub get_email
{
    my ( $self, %args ) = (@_);

    my $user = $self->{ 'user' } || $args{ 'user' } || die "Missing user";

    # If we have the data return it, or null otherwise
    my $data = $self->get( user => $user );
    return ( $data ? $data->{ 'email' } : $data );
}


=begin doc

Get the users state address.

=end doc

=cut

sub get_state
{
    my ( $self, %args ) = (@_);

    my $user = $self->{ 'user' } || $args{ 'user' } || die "Missing user";

    # If we have the data return it, or null otherwise
    my $data = $self->get( user => $user );
    return ( $data ? $data->{ 'status' } : $data );
}


=begin doc

Set the user's email address.

=end doc

=cut

sub set_email
{
    my ( $self, %args ) = (@_);

    my $user = $self->{ 'user' } || $args{ 'user' } || die "Missing user";
    my $mail = $self->{ 'mail' } || $args{ 'mail' } || die "Missing email";
    $user = lc($user);

    my $db = Singleton::MySQL->instance();
    my $sql = $db->prepare("UPDATE users SET email=? WHERE login=?") or
      die "Failed to prepare statement";
    $sql->execute( $mail, $user ) or
      die "Failed to execute statement";
    $sql->finish();

}


=begin doc

Get all public-keys a user has.

These keys are used for accessing the repo we host on the users' behalf.

=end doc

=cut

sub get_all_public_keys
{
    my ( $self, %args ) = (@_);

    my $user = $self->{ 'user' } || $args{ 'user' } || die "Missing user";
    $user = lc($user);

    #
    #  The results
    #
    my $results;

    my $db = Singleton::MySQL->instance();
    my $sql = $db->prepare(
        "SELECT a.id,a.key_text,a.fingerprint FROM ssh_keys AS a JOIN users AS b WHERE a.owner=b.id AND b.login=?"
      ) or
      die "Failed to prepare statement";
    $sql->execute($user) or
      die "Failed to execute statement";

    #
    #  Bind the colums
    #
    my ( $id, $key, $fingerprint );
    $sql->bind_columns( undef, \$id, \$key, \$fingerprint );

    while ( $sql->fetch() )
    {
        push( @$results,
              {  id          => $id,
                 key         => $key,
                 fingerprint => $fingerprint
              } );
    }
    $sql->finish();

    return $results;
}


=begin doc

Add a public-key for the given user.

These keys are used for accessing the repo we host on the users' behalf.

=end doc

=cut

sub add_public_key
{
    my ( $self, %args ) = (@_);

    my $user = $self->{ 'user' } || $args{ 'user' } || die "Missing user";
    my $key = $self->{ 'ssh_key' } ||
      $args{ 'ssh_key' } ||
      "";
    $user = lc($user);


    #
    #  Get the user-id
    #
    my $db = Singleton::MySQL->instance();
    my $sql = $db->prepare("SELECT id FROM users WHERE login=?") or
      die "Failed to prepare statement";
    $sql->execute($user) or
      die "Failed to execute statement";
    my $user_id = $sql->fetchrow_array();
    $sql->finish();

    #
    #  Get a fingerprint
    #
    my ( $fh, $filename ) = tempfile();
    print $fh $key;
    close($fh);

    #
    #  Open the command
    #
    open( my $handle, "-|", "ssh-keygen -lf $filename" );
    my $fingerprint = <$handle>;
    close($handle);

    if ($fingerprint)
    {
        my @d = split( /[ \t]/, $fingerprint );
        $fingerprint = $d[1];
    }

    unlink($filename) if ( -e $filename );

    #
    #  Now do the insert.
    #
    $sql = $db->prepare(
           "INSERT INTO ssh_keys (owner,key_text,fingerprint) VALUES(?,?,?)") or
      die "Failed to prepare";
    $sql->execute( $user_id, $key, $fingerprint ) or
      die "Failed to execute statement";
    $sql->finish();

}


=begin doc

Delete a given public-key.

These keys are used for accessing the repo we host on the users' behalf.

=end doc

=cut

sub delete_public_key
{
    my ( $self, %args ) = (@_);

    my $user = $self->{ 'user' } || $args{ 'user' } || die "Missing user";
    my $id   = $self->{ 'id' }   || $args{ 'id' }   || 0;
    $user = lc($user);


    #
    # Get the user-id
    #
    my $db = Singleton::MySQL->instance();
    my $sql = $db->prepare("SELECT id FROM users WHERE login=?") or
      die "Failed to prepare statement";
    $sql->execute($user) or
      die "Failed to execute statement";
    my $user_id = $sql->fetchrow_array();
    $sql->finish();

    #
    #  Run the deletion
    #
    $sql = $db->prepare("DELETE FROM ssh_keys WHERE (owner=? AND id=?)") or
      die "Failed to prepare statement";
    $sql->execute( $user_id, $id ) or
      die "Failed to execute statement";
    $sql->finish();

}


=begin doc

Get all details about the user.

=end doc

=cut

sub get
{
    my ( $self, %args ) = (@_);

    my $user = $self->{ 'user' } || $args{ 'user' } || die "Missing user";
    $user = lc($user);

    my $db = Singleton::MySQL->instance();
    my $sql = $db->prepare("SELECT * FROM users WHERE login=?") or
      die "Failed to prepare statement";
    $sql->execute($user) or
      die "Failed to execute statement";
    my $result = $sql->fetchrow_hashref();
    $sql->finish();

    return ($result);
}


sub set_notification
{
    my ( $self, %args ) = (@_);

    my $user = $self->{ 'user' } || $args{ 'user' } || die "Missing user";
    $user = lc($user);

    my $state = $self->{ 'enable' } || $args{ 'enable' } || 0;

    my $db = Singleton::MySQL->instance();
    my $sql =
      $db->prepare("UPDATE users SET hook_notification=? WHERE login=?") or
      die "Failed to prepare statement";
    $sql->execute( $state, $user ) or
      die "Failed to execute statement";
    $sql->finish();

}

=begin doc

Set the stripe token for the given user.

This also marks the user as a subscriber, by setting their status to "paid".

=end doc

=cut

sub set_token
{
    my ( $self, %args ) = (@_);

    my $user  = $self->{ 'user' }  || $args{ 'user' }  || die "Missing user";
    my $token = $self->{ 'token' } || $args{ 'token' } || die "Missing token";

    $user = lc($user);

    my $db = Singleton::MySQL->instance();
    my $sql = $db->prepare(
               "UPDATE users SET stripe_token=?,status='paid' WHERE login=?") or
      die "Failed to prepare statement.";
    $sql->execute( $token, $user ) or
      die "Failed to execute statement.";
    $sql->finish();

}




=begin doc

Create a new user-account.

=end doc

=cut

sub create
{
    my ( $self, %args ) = (@_);

    my $user = $args{ 'user' } || die "Missing username";
    my $pass = $args{ 'pass' } || die "Missing password";
    my $mail = $args{ 'mail' } || "";
    my $ip   = $args{ 'ip' }   || "";

    $user = lc($user);

    #
    #  Create the new user.
    #
    my $db = Singleton::MySQL->instance() || die "Missing DB-handle";
    my $sql =
      $db->prepare("INSERT INTO users (login,email,ip) VALUES( ?,?,? )");
    $sql->execute( $user, $mail, $ip );
    $sql->finish();

    #
    # Now set their password
    #
    my $auth = DNSAPI::User::Auth->new();
    $auth->set_password( user => $user, pass => $pass );

}


=begin doc

Delete a user from the system.

NOTE: This also delects records of hosted zones and pushevents.

=end doc

=cut

sub delete
{
    my ( $self, $user ) = (@_);

    $user = lc($user);

    #
    #  Get the user ID
    #
    my $uid = $self->id( user => $user );

    my $db = Singleton::MySQL->instance();

    #
    #  Delete the user from the database.
    #
    my $sql = $db->prepare("DELETE FROM users WHERE login=?") or
      die "Failed to prepare";
    $sql->execute($user);
    $sql->finish();

    #
    #  Delete any old events
    #
    $sql = $db->prepare("DELETE FROM webhooks WHERE owner=?") or
      die "Failed to prepare";
    $sql->execute($uid);
    $sql->finish();

    #
    #  Delete any hosted-zones.
    #
    $sql = $db->prepare("DELETE FROM domains WHERE owner=?") or
      die "Failed to prepare";
    $sql->execute($uid);
    $sql->finish();

    #
    #  Delete the user's SSH-keys
    #
    $sql = $db->prepare("DELETE FROM ssh_keys WHERE owner=?") or
      die "Failed to prepare";
    $sql->execute($uid);
    $sql->finish();

    #
    #  Trigger an update of our SSH-keys
    #
    my $r = Singleton::Redis->instance();
    $r->rpush( "UPDATE:KEYS", time() );

}



=begin doc

Find a user by login or email.

=end doc

=cut

sub find
{
    my ( $self, $text ) = (@_);

    $text = lc($text);

    my $db = Singleton::MySQL->instance() || die "Missing DB-handle";

    my $result = undef;

    #
    #  The queries we have.
    #
    my @queries = ( "SELECT login FROM users WHERE login=?",
                    "SELECT login FROM users WHERE email=?"
                  );

    foreach my $attempt (@queries)
    {
        my $sql = $db->prepare($attempt) or
          die "Failed to prepare statement: $attempt";
        $sql->execute($text) or
          die "Failed to execute statement";
        $result = $sql->fetchrow_array();
        $sql->finish();

        return $result if ($result);
    }

    return $result;
}


=begin doc

Update the list of domains which will be visible on the home-page.

=end doc

=cut

sub update_domain_nameservers
{
    my ( $self, $owner, $zone, @records ) = (@_);

    $owner = lc($owner);

    my $db = Singleton::MySQL->instance() || die "Missing DB-handle";

    #
    #  Find the User-ID
    #
    my $sql = $db->prepare("SELECT id FROM users WHERE login=?") or
      die "Failed to prepare statement";
    $sql->execute($owner) or
      die "Failed to execute statement";
    my $user_id = $sql->fetchrow_array();
    $sql->finish();

    #
    # Count the existing nameservers.
    #
    $sql = $db->prepare("SELECT COUNT(DISTINCT(ns)) FROM domains WHERE zone=?");
    $sql->execute($zone);
    my $count = $sql->fetchrow_array();
    $sql->finish();

    #
    #  If there are some, then we'll do nothing.
    #
    return if ( $count && ( $count > 3 ) );

    #
    #  OK at this point there are <=3 nameservers:
    #
    #   * If the zone is new there will be zero.
    #
    #   * If there was a problem there might be 1/2/3
    #
    #  Remove the existing values, and add the new ones.
    #
    $sql = $db->prepare("DELETE FROM domains WHERE zone=?") or
      die "Failed to prepare";
    $sql->execute($zone);
    $sql->finish();

    #
    #  Add the new ones
    #
    $sql = $db->prepare("INSERT INTO domains (owner,zone,ns) VALUES(?,?,?)") or
      die "Failed to prepare";
    foreach my $entry (@records)
    {
        $sql->execute( $user_id, $zone, $entry ) or
          die "Failed to execute";
    }
    $sql->finish();
}


=begin doc

Delete domain

=end doc

=cut

sub delete_domain
{
    my ( $self, $zone ) = (@_);


    my $db = Singleton::MySQL->instance() || die "Missing DB-handle";

    my $sql = $db->prepare("DELETE FROM domains WHERE zone=?") or
      die "Failed to prepare";
    $sql->execute($zone);
    $sql->finish();

}



=begin doc

Get zone source

=end doc

=cut

sub domain_exists
{
    my ( $self, $zone ) = (@_);

    my $db = Singleton::MySQL->instance() || die "Missing DB-handle";
    my $sql = $db->prepare("SELECT zone FROM domains WHERE zone=?");
    $sql->execute($zone);
    my $found = $sql->fetchrow_array() || undef;
    $sql->finish();

    return ( $found ? 1 : 0 );

}


=begin doc

Get the list of domains the user will be shown on the panel.

=end doc

=cut

sub get_domains
{
    my ( $self, $user ) = (@_);

    $user = lc($user);

    my $db = Singleton::MySQL->instance() || die "Missing DB-handle";

    #
    #  Find the User-ID
    #
    my $sql = $db->prepare("SELECT id FROM users WHERE login=?") or
      die "Failed to prepare statement";
    $sql->execute($user) or
      die "Failed to execute statement";
    my $user_id = $sql->fetchrow_array();
    $sql->finish();

    #
    #  Now find the domains
    #
    my @tmp;
    $sql = $db->prepare(
           "SELECT DISTINCT(zone) FROM domains WHERE owner=? ORDER BY zone ASC")
      or
      die "Failed to prepare";
    my ($dom);
    $sql->execute($user_id) or die "Failed to execute";
    $sql->bind_columns( undef, \$dom );
    while ( $sql->fetch() )
    {
        push( @tmp, $dom );

    }
    $sql->finish();


    #
    #  The results we return.
    #
    my $results;

    foreach my $dom (@tmp)
    {

        my $sql =
          $db->prepare("SELECT ns FROM domains WHERE owner=? AND zone=?") or
          die "Failed to prepare";
        my $nslist;
        my ($ns);
        $sql->execute( $user_id, $dom ) or die "Failed to execute";
        $sql->bind_columns( undef, \$ns );
        while ( $sql->fetch() )
        {
            push( @$nslist, { nameserver => $ns } );
        }
        $sql->finish();

        push( @$results, { zone => $dom, ns => $nslist } );
    }


    return ($results);
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
