
=head1 NAME

DNSAPI::User::Auth - Handle user-logins and password-changes.

=head1 MIGRATION

This requires a new field to be created in the `users` table
if it is missing.  This is because in the past we used a different
form of password-authentication, now we've migrated to C<bcrypt>
which is better.

=for example begin

   alter table users add hash VARCHAR(100);

=for example end

=cut

=head1 DESCRIPTION

This module contains the code relating to usernames/passwords,
which tests logins etc.  It supports a legacy system, and will
auto-migrate to bcrypt as users login.

=cut

=head1 AUTHOR

Steve Kemp <steve@steve.org.uk>

=cut

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2016 Steve Kemp <steve@steve.org.uk>.

This library is free software. You can modify and or distribute it under
the same terms as Perl itself.

=cut



use strict;
use warnings;

package DNSAPI::User::Auth;


# Legacy auth
use Digest::SHA;

# New auth
use Crypt::Eksblowfish::Bcrypt;


use Singleton::MySQL;


=begin doc

Constructor

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

Test whether a given login is valid.

=end doc

=cut

sub test_login
{
    my ( $self, %params ) = (@_);

    return 0 unless ( $params{ 'user' } );
    return 0 unless ( $params{ 'pass' } );

    if ( $self->_is_new( $params{ 'user' } ) )
    {
        return ( $self->test_login_new(%params) );
    }
    else
    {
        my $result = $self->test_login_old(%params);

        if ($result)
        {
            #
            # Update to the new bcrypt password hash here.
            #
            $self->set_password( user => $params{ 'user' },
                                 pass => $params{ 'pass' } );
        }
        return ($result);
    }
}


=begin doc

Update a user's password.

=end doc

=cut

sub set_password
{
    my ( $self, %params ) = (@_);

    my $user = $params{ 'user' };
    my $pass = $params{ 'pass' };

    $user = lc($user);

    #
    # Generate a salt of printable ASCII chars.
    #
    my $salt = "";
    my @a = map {chr} ( 33 .. 126 );
    $salt .= $a[rand(@a)] for 1 .. 16;
    $salt = Crypt::Eksblowfish::Bcrypt::en_base64($salt);

    #
    #  Now hash the user's passwrod
    #
    my $settings = '$2a$12$' . $salt;
    my $hash = Crypt::Eksblowfish::Bcrypt::bcrypt( $pass, $settings );

    #
    #  We're only going to set the password in the new table - so we
    # don't need to make this conditional at all.
    #
    my $db = Singleton::MySQL->instance() || die "Missing DB-handle";

    my $sql =
      $db->prepare("UPDATE users SET hash=?,password=? WHERE login=?") or
      die "Failed to prepare";
    $sql->execute( $hash, "replaced", $user ) or
      die "Failed to add password";

    $sql->finish();
}


=begin doc

Has this user got a new-style bcrypt-based password?

=end doc

=cut

sub _is_new
{
    my ( $self, $login ) = (@_);

    $login = lc($login);
    my $db = Singleton::MySQL->instance() || die "Missing DB-handle";
    my $sql = $db->prepare("SELECT hash FROM users WHERE login=?") or
      die "Failed to prepare";

    $sql->execute($login) or
      die "Failed to execute";
    my $found = $sql->fetchrow_array();

    if ( $found && ( length($found) > 0 ) )
    {
        return 1;
    }
    else
    {
        return 0;
    }
}


=begin doc

Test a username/password for validity with the old-scheme.

=end doc

=cut

sub test_login_old
{
    my ( $self, %params ) = (@_);

    my $user = $params{ 'user' };
    my $pass = $params{ 'pass' };

    $user = lc($user);

    #
    #  Hash the users password with our Salt
    #
    my $sha = Digest::SHA->new();
    $sha->add("SALT");
    $sha->add($pass);
    my $hash = $sha->hexdigest();


    #
    #  Lookup
    #
    my $db = Singleton::MySQL->instance() || die "Missing DB-handle";
    my $sql =
      $db->prepare("SELECT login FROM users WHERE ( login=? AND password=? )")
      or
      die "Failed to prepare";

    $sql->execute( $user, $hash ) or
      die "Failed to execute";
    my $found = $sql->fetchrow_array();
    return ( $found ? $found : undef );

}


=begin doc

Test the given login/password for validity against the (new) bycrypt hash.

=end doc

=cut

sub test_login_new
{
    my ( $self, %params ) = (@_);

    my $user = $params{ 'user' };
    my $pass = $params{ 'pass' };

    #
    #  Select the hash we have stored for the user.
    #
    my $dbh = Singleton::MySQL->instance();
    my $sql = $dbh->prepare("SELECT hash FROM users WHERE login=?") or
      die "Failed to prepare " . $dbh->errstr();
    $sql->execute( lc $user );

    my ($hash) = $sql->fetchrow_array();
    $sql->finish();

    my $salt = undef;
    if ( $hash =~ m!^\$2a\$\d{2}\$([A-Za-z0-9+\\.\/]{22})! )
    {
        $salt = $1;
    }
    else
    {
        # This shouldn't happen..
        return undef;
    }


    #
    #  Now hash the user's passwrod
    #
    my $settings = '$2a$12$' . $salt;
    my $out = Crypt::Eksblowfish::Bcrypt::bcrypt( $pass, $settings );


    #
    #  Does that match?
    #
    #  NOTE: Ideally we'd use a constant-time comparison here.
    #
    if ( $out eq $hash )
    {
        return $user;
    }
    else
    {
        return undef;
    }
}


1;
