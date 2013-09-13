use strict;
use warnings;
package Test::WebDriver;
use parent  'Selenium::Remote::Driver';
# ABSTRACT: Useful testing subclass for Selenium WebDriver!

use Test::WebDriver::WebElement;
use Test::More;
use Test::Builder;
use Test::LongString;
use IO::Socket;

our $AUTOLOAD;

my $Test = Test::Builder->new;
$Test->exported_to(__PACKAGE__);

my %comparator = (
    is       => 'is_eq',
    isnt     => 'isnt_eq',
    like     => 'like',
    unlike   => 'unlike',
);
my $comparator_keys = join '|', keys %comparator;

# These commands don't require a locator
my %no_locator = map { $_ => 1 }
                qw( alert_text current_window_handle current_url
                    title page_source body location path);

sub no_locator {
    my $self   = shift;
    my $method = shift;
    return $no_locator{$method};
}

sub AUTOLOAD {
    my $name = $AUTOLOAD;
    $name =~ s/.*:://;
    return if $name eq 'DESTROY';
    my $self = $_[0];

    my $sub;
    if ($name =~ /(\w+)_($comparator_keys)$/i) {
        my $getter = "get_$1";
        my $comparator = $comparator{lc $2};

        # make a subroutine that will call Test::Builder's test methods
        # with driver data from the getter
        if ($self->no_locator($1)) {
            $sub = sub {
                my( $self, $str, $name ) = @_;
                diag "Test::WebDriver running no_locator $getter (@_[1..$#_])"
                    if $self->{verbose};
                $name = "$getter, '$str'"
                    if $self->{default_names} and !defined $name;
                no strict 'refs';
                my $rc = $Test->$comparator( $self->$getter, $str, $name );
                if (!$rc && $self->error_callback) {
                    &{$self->error_callback}($name);
                }
                return $rc;
            };
        }
        else {
            $sub = sub {
                my( $self, $locator, $str, $name ) = @_;
                diag "Test::WebDriver running with locator $getter (@_[1..$#_])"
                    if $self->{verbose};
                $name = "$getter, $locator, '$str'"
                    if $self->{default_names} and !defined $name;
                no strict 'refs';
                no strict 'refs';
                my $rc = $Test->$comparator( $self->$getter($locator), $str, $name );
                if (!$rc && $self->error_callback) {
                    &{$self->error_callback}($name);
                }
                return $rc;
            };
        }
    }
    elsif ($name =~ /(\w+?)_?ok$/i) {
        my $cmd = $1;

        # make a subroutine for ok() around the selenium command
        $sub = sub {
            my( $self, $arg1, $arg2, $name ) = @_;
            if ($self->{default_names} and !defined $name) {
                $name = $cmd;
                $name .= ", $arg1" if defined $arg1;
                $name .= ", $arg2" if defined $arg2;
            }
            diag "Test::WebDriver running _ok $cmd (@_[1..$#_])"
                    if $self->{verbose};

            local $Test::Builder::Level = $Test::Builder::Level + 1;
            my $rc = '';
            eval { $rc = $self->$cmd( $arg1, $arg2 ) };
            die $@ if $@ and $@ =~ /Can't locate object method/;
            diag($@) if $@;
            $rc = ok( $rc, $name );
            if (!$rc && $self->error_callback) {
                &{$self->error_callback}($name);
            }
            return $rc;
        };
    }

    # jump directly to the new subroutine, avoiding an extra frame stack
    if ($sub) {
        no strict 'refs';
        *{$AUTOLOAD} = $sub;
        goto &$AUTOLOAD;
    }
    else {
        # try to pass through to Selenium::Remote::Driver
        my $sel = 'Selenium::Remote::Driver';
        my $sub = "${sel}::${name}";
        goto &$sub if exists &$sub;
        my ($package, $filename, $line) = caller;
        die qq(Can't locate object method "$name" via package ")
            . __PACKAGE__
            . qq(" (also tried "$sel") at $filename line $line\n);
    }
}

sub error_callback {
    my ($self, $cb) = @_;
    if (defined($cb)) {
        $self->{error_callback} = $cb;
    }
    return $self->{error_callback};
}

=head2 new ( %opts )

This will create a new Test::WebDriver object, which subclasses 
L<Selenium::Remote::Driver>.  This subclass provides useful testing
functions.  It is modeled on L<Test::WWW::Selenium>.

Environment vars can be used to specify options to pass to
L<Selenium::Remote::Driver>. ENV vars are prefixed with C<TWD_>.

Set the Selenium server address with C<$TWD_HOST> and C<$TWD_PORT>.

Pick which browser is used using the  C<$TWD_BROWSER>, C<$TWD_VERSION>,
C<$TWD_PLATFORM>, C<$TWD_JAVASCRIPT>, C<$TWD_EXTRA_CAPABILITIES>.

See L<Selenium::Driver::Remote> for the meanings of these options.

=cut

sub new {
    my ($class, %p) = @_;

    for my $opt (qw/remote_server_addr port browser_name version platform
                    javascript auto_close extra_capabilities/) {
        $p{$opt} ||= $ENV{ 'TWD_' . uc($opt) };
    }
    $p{browser_name}       ||= $ENV{TWD_BROWSER}; # ykwim
    $p{remote_server_addr} ||= $ENV{TWD_HOST};    # ykwim
    $p{webelement_class}   ||= 'Test::WebDriver::WebElement';

    my $self = $class->SUPER::new(%p);
    $self->{verbose} = $p{verbose};
    return $self;
}

=head2 server_is_running( $host, $port )

Returns true if a Selenium server is running.  The host and port 
parameters are optional, and default to C<localhost:4444>.

Environment vars C<TWD_HOST> and C<TWD_PORT> can also be used to
determine the server to check.

=cut

sub server_is_running {
    my $class_or_self = shift;
    my $host = $ENV{TWD_HOST} || shift || 'localhost';
    my $port = $ENV{TWD_PORT} || shift || 4444;

    return ($host, $port) if IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
    );
    return;

}

=head2 $twd->content_like( $regex [, $desc ] )

   $twd->content_like( $regex [, $desc ] )
   $twd->content_like( [$regex_1, $regex_2] [, $desc ] )

Tells if the content of the page matches I<$regex>. If an arrayref of regex's
are provided, one 'test' is run for each regex against the content of the
current page.

A default description of 'Content is like "$regex"' will be provided if there
is no description.

=cut

sub content_like {
    my $self = shift;
    my $regex = shift;
    my $desc = shift;

    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $content = $self->get_page_source();

    if (not ref $regex eq 'ARRAY') {
        my $desc = qq{Content is like "$regex"} if (not defined $desc);
        return like_string($content , $regex, $desc );
    }
    elsif (ref $regex eq 'ARRAY') {
        for my $re (@$regex) {
            my $desc = qq{Content is like "$re"} if (not defined $desc);
            like_string($content , $re, $desc );
        }
    }
}

=head2 $twd->content_unlike( $regex [, $desc ] )

   $twd->content_unlike( $regex [, $desc ] )
   $twd->content_unlike( [$regex_1, $regex_2] [, $desc ] )

Tells if the content of the page does NOT match I<$regex>. If an arrayref of regex's
are provided, one 'test' is run for each regex against the content of the
current page.

A default description of 'Content is unlike "$regex"' will be provided if there
is no description.

=cut

sub content_unlike {
    my $self = shift;
    my $regex = shift;
    my $desc = shift;

    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $content = $self->get_page_source();

    if (not ref $regex eq 'ARRAY') {
        my $desc = qq{Content is unlike "$regex"} if (not defined $desc);
        return unlike_string($content , $regex, $desc );
    }
    elsif (ref $regex eq 'ARRAY') {
        for my $re (@$regex) {
            my $desc = qq{Content is unlike "$re"} if (not defined $desc);
            unlike_string($content , $re, $desc );
        }
    }
}


=head2 $twd->text_like( $regex [, $desc ] )

   $twd->text_like( $regex [, $desc ] )
   $twd->text_like( [$regex_1, $regex_2] [, $desc ] )

Tells if the text of the page (as returned by C<< get_body() >>)  matches
I<$regex>. If an arrayref of regex's are provided, one 'test' is run for each
regex against the content of the current page.

A default description of 'Content is like "$regex"' will be provided if there
is no description.

To also match the HTML see, C<< content_unlike() >>.

=cut

sub text_like {
    my $self = shift;
    my $regex = shift;
    my $desc = shift;

    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $text = $self->get_body();

    if (not ref $regex eq 'ARRAY') {
        my $desc = qq{Text is like "$regex"} if (not defined $desc);
        return like_string($text , $regex, $desc );
    }
    elsif (ref $regex eq 'ARRAY') {
        for my $re (@$regex) {
            my $desc = qq{Text is like "$re"} if (not defined $desc);
            like_string($text , $re, $desc );
        }
    }
}

=head2 $twd->text_unlike( $regex [, $desc ] )

   $twd->text_unlike( $regex [, $desc ] )
   $twd->text_unlike( [$regex_1, $regex_2] [, $desc ] )

Tells if the text of the page (as returned by C<< get_body() >>)
 does NOT match I<$regex>. If an arrayref of regex's
are provided, one 'test' is run for each regex against the content of the
current page.

A default description of 'Text is unlike "$regex"' will be provided if there
is no description.

To also match the HTML see, C<< content_unlike() >>.

=cut

sub text_unlike {
    my $self = shift;
    my $regex = shift;
    my $desc = shift;

    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $text = $self->get_body();

    if (not ref $regex eq 'ARRAY') {
        my $desc = qq{Text is unlike "$regex"} if (not defined $desc);
        return unlike_string($text , $regex, $desc );
    }
    elsif (ref $regex eq 'ARRAY') {
        for my $re (@$regex) {
            my $desc = qq{Text is unlike "$re"} if (not defined $desc);
            unlike_string($text , $re, $desc );
        }
    }
}


1;

__END__

=head1 NOTES

For Best Practice - I recommend subclassing Test::WebDriver for your application,
and then refactoring common or app specific methods into MyApp::WebDriver so that
your test files do not have much duplication.  As your app changes, you can update
MyApp::WebDriver rather than all the individual test files.

=head1 AUTHORS

=over 4

=item *

Created by: Luke Closs <lukec@cpan.org>, but inspired by
 L<Test::WWW::Selenium> and it's authors.

=back

=head1 CONTRIBUTORS

This work was sponsored by Prime Radiant, Inc. Mark Stosberg <mark@stosberg.com> also contributed.

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2012 Prime Radiant, Inc.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.
