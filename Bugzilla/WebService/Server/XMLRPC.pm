# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the Bugzilla Bug Tracking System.
#
# Contributor(s): Marc Schumann <wurblzap@gmail.com>
#                 Max Kanat-Alexander <mkanat@bugzilla.org>
#                 Rosie Clarkson <rosie.clarkson@planningportal.gov.uk>
#                 
# Portions © Crown copyright 2009 - Rosie Clarkson (development@planningportal.gov.uk) for the Planning Portal

package Bugzilla::WebService::Server::XMLRPC;

use strict;
use XMLRPC::Transport::HTTP;
use Bugzilla::WebService::Server;
our @ISA = qw(XMLRPC::Transport::HTTP::CGI Bugzilla::WebService::Server);

use Bugzilla::WebService::Constants;

sub initialize {
    my $self = shift;
    my %retval = $self->SUPER::initialize(@_);
    $retval{'serializer'}   = Bugzilla::XMLRPC::Serializer->new;
    $retval{'deserializer'} = Bugzilla::XMLRPC::Deserializer->new;
    $retval{'dispatch_with'} = WS_DISPATCH;
    return %retval;
}

sub make_response {
    my $self = shift;

    $self->SUPER::make_response(@_);

    # XMLRPC::Transport::HTTP::CGI doesn't know about Bugzilla carrying around
    # its cookies in Bugzilla::CGI, so we need to copy them over.
    foreach (@{Bugzilla->cgi->{'Bugzilla_cookie_list'}}) {
        $self->response->headers->push_header('Set-Cookie', $_);
    }
}

sub handle_login {
    my ($self, $classes, $action, $uri, $method) = @_;
    my $class = $classes->{$uri};
    my $full_method = $uri . "." . $method;
    $self->SUPER::handle_login($class, $method, $full_method);
    return;
}

1;

# This exists to validate input parameters (which XMLRPC::Lite doesn't do)
# and also, in some cases, to more-usefully decode them.
package Bugzilla::XMLRPC::Deserializer;
use strict;
# We can't use "use base" because XMLRPC::Serializer doesn't return
# a true value.
use XMLRPC::Lite;
our @ISA = qw(XMLRPC::Deserializer);

use Bugzilla::Error;
use Scalar::Util qw(tainted);

sub deserialize {
    my $self = shift;
    my ($xml) = @_;
    my $som = $self->SUPER::deserialize(@_);
    if (tainted($xml)) {
        $som->{_bz_do_taint} = 1;
    }
    bless $som, 'Bugzilla::XMLRPC::SOM';
    Bugzilla->input_params($som->paramsin || {}); 
    return $som;
}

# Some method arguments need to be converted in some way, when they are input.
sub decode_value {
    my $self = shift;
    my ($type) = @{ $_[0] };
    my $value = $self->SUPER::decode_value(@_);
    
    # We only validate/convert certain types here.
    return $value if $type !~ /^(?:int|i4|boolean|double|dateTime\.iso8601)$/;
    
    # Though the XML-RPC standard doesn't allow an empty <int>,
    # <double>,or <dateTime.iso8601>,  we do, and we just say
    # "that's undef".
    if (grep($type eq $_, qw(int double dateTime))) {
        return undef if $value eq '';
    }
    
    my $validator = $self->_validation_subs->{$type};
    if (!$validator->($value)) {
        ThrowUserError('xmlrpc_invalid_value',
                       { type => $type, value => $value });
    }
    
    # We convert dateTimes to a DB-friendly date format.
    if ($type eq 'dateTime.iso8601') {
        if ($value !~ /T.*[\-+Z]/i) {
           # The caller did not specify a timezone, so we assume UTC.
           # pass 'Z' specifier to datetime_from to force it
           $value = $value . 'Z';
        }
        $value = $self->datetime_format_inbound($value);
    }

    return $value;
}

sub _validation_subs {
    my $self = shift;
    return $self->{_validation_subs} if $self->{_validation_subs};
    # The only place that XMLRPC::Lite stores any sort of validation
    # regex is in XMLRPC::Serializer. We want to re-use those regexes here.
    my $lookup = Bugzilla::XMLRPC::Serializer->new->typelookup;
    
    # $lookup is a hash whose values are arrayrefs, and whose keys are the
    # names of types. The second item of each arrayref is a subroutine
    # that will do our validation for us.
    my %validators = map { $_ => $lookup->{$_}->[1] } (keys %$lookup);
    # Add a boolean validator
    $validators{'boolean'} = sub {$_[0] =~ /^[01]$/};
    # Some types have multiple names, or have a different name in
    # XMLRPC::Serializer than their standard XML-RPC name.
    $validators{'dateTime.iso8601'} = $validators{'dateTime'};
    $validators{'i4'} = $validators{'int'};
    
    $self->{_validation_subs} = \%validators;
    return \%validators;
}

1;

package Bugzilla::XMLRPC::SOM;
use strict;
use XMLRPC::Lite;
our @ISA = qw(XMLRPC::SOM);
use Bugzilla::WebService::Util qw(taint_data);

sub paramsin {
    my $self = shift;
    return $self->{bz_params_in} if $self->{bz_params_in};
    my $params = $self->SUPER::paramsin(@_);
    if ($self->{_bz_do_taint}) {
        taint_data($params);
    }
    $self->{bz_params_in} = $params;
    return $self->{bz_params_in};
}

1;

# This package exists to fix a UTF-8 bug in SOAP::Lite.
# See http://rt.cpan.org/Public/Bug/Display.html?id=32952.
package Bugzilla::XMLRPC::Serializer;
use Scalar::Util qw(blessed);
use strict;
# We can't use "use base" because XMLRPC::Serializer doesn't return
# a true value.
use XMLRPC::Lite;
our @ISA = qw(XMLRPC::Serializer);

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    # This fixes UTF-8.
    $self->{'_typelookup'}->{'base64'} =
        [10, sub { !utf8::is_utf8($_[0]) && $_[0] =~ /[^\x09\x0a\x0d\x20-\x7f]/},
        'as_base64'];
    # This makes arrays work right even though we're a subclass.
    # (See http://rt.cpan.org//Ticket/Display.html?id=34514)
    $self->{'_encodingStyle'} = '';
    return $self;
}

# Here the XMLRPC::Serializer is extended to use the XMLRPC nil extension.
sub encode_object {
    my $self = shift;
    my @encoded = $self->SUPER::encode_object(@_);

    return $encoded[0]->[0] eq 'nil'
        ? ['value', {}, [@encoded]]
        : @encoded;
}

# Removes undefined values so they do not produce invalid XMLRPC.
sub envelope {
    my $self = shift;
    my ($type, $method, $data) = @_;
    # If the type isn't a successful response we don't want to change the values.
    if ($type eq 'response'){
        $data = _strip_undefs($data);
    }
    return $self->SUPER::envelope($type, $method, $data);
}

# In an XMLRPC response we have to handle hashes of arrays, hashes, scalars,
# Bugzilla objects (reftype = 'HASH') and XMLRPC::Data objects.
# The whole XMLRPC::Data object must be removed if its value key is undefined
# so it cannot be recursed like the other hash type objects.
sub _strip_undefs {
    my ($initial) = @_;
    if (ref $initial eq "HASH" || (blessed $initial && $initial->isa("HASH"))) {
        while (my ($key, $value) = each(%$initial)) {
            if ( !defined $value
                 || (blessed $value && $value->isa('XMLRPC::Data') && !defined $value->value) )
            {
                # If the value is undefined remove it from the hash.
                delete $initial->{$key};
            }
            else {
                $initial->{$key} = _strip_undefs($value);
            }
        }
    }
    if (ref $initial eq "ARRAY" || (blessed $initial && $initial->isa("ARRAY"))) {
        for (my $count = 0; $count < scalar @{$initial}; $count++) {
            my $value = $initial->[$count];
            if ( !defined $value
                 || (blessed $value && $value->isa('XMLRPC::Data') && !defined $value->value) )
            {
                # If the value is undefined remove it from the array.
                splice(@$initial, $count, 1);
                $count--;
            }
            else {
                $initial->[$count] = _strip_undefs($value);
            }
        }
    }
    return $initial;
}

sub BEGIN {
    no strict 'refs';
    for my $type (qw(double i4 int dateTime)) {
        my $method = 'as_' . $type;
        *$method = sub {
            my ($self, $value) = @_;
            if (!defined($value)) {
                return as_nil();
            }
            else {
                my $super_method = "SUPER::$method"; 
                return $self->$super_method($value);
            }
        }
    }
}

sub as_nil {
    return ['nil', {}];
}

1;

__END__

=head1 NAME

Bugzilla::WebService::Server::XMLRPC - The XML-RPC Interface to Bugzilla

=head1 DESCRIPTION

This documentation describes things about the Bugzilla WebService that
are specific to XML-RPC. For a general overview of the Bugzilla WebServices,
see L<Bugzilla::WebService>.

=head1 XML-RPC

The XML-RPC standard is described here: L<http://www.xmlrpc.com/spec>

=head1 CONNECTING

The endpoint for the XML-RPC interface is the C<xmlrpc.cgi> script in
your Bugzilla installation. For example, if your Bugzilla is at
C<bugzilla.yourdomain.com>, then your XML-RPC client would access the
API via: C<http://bugzilla.yourdomain.com/xmlrpc.cgi>

=head1 PARAMETERS

C<dateTime> fields are the standard C<dateTime.iso8601> XML-RPC field. They
should be in C<YYYY-MM-DDTHH:MM:SS> format (where C<T> is a literal T). As
of Bugzilla B<3.6>, Bugzilla always expects C<dateTime> fields to be in the
UTC timezone, and all returned C<dateTime> values are in the UTC timezone.

All other fields are standard XML-RPC types.

=head2 How XML-RPC WebService Methods Take Parameters

All functions take a single argument, a C<< <struct> >> that contains all parameters.
The names of the parameters listed in the API docs for each function are the
C<< <name> >> element for the struct C<< <member> >>s.

=head1 EXTENSIONS TO THE XML-RPC STANDARD

=head2 Undefined Values

Normally, XML-RPC does not allow empty values for C<int>, C<double>, or
C<dateTime.iso8601> fields. Bugzilla does--it treats empty values as
C<undef> (called C<NULL> or C<None> in some programming languages).

Bugzilla accepts a timezone specifier at the end of C<dateTime.iso8601>
fields that are specified as method arguments. The format of the timezone
specifier is specified in the ISO-8601 standard. If no timezone specifier
is included, the passed-in time is assumed to be in the UTC timezone.
Bugzilla will never output a timezone specifier on returned data, because
doing so would violate the XML-RPC specification. All returned times are in
the UTC timezone.

Bugzilla also accepts an element called C<< <nil> >>, as specified by the
XML-RPC extension here: L<http://ontosys.com/xml-rpc/extensions.php>, which
is always considered to be C<undef>, no matter what it contains.

Bugzilla does not use C<< <nil> >> values in returned data, because currently
most clients do not support C<< <nil> >>. Instead, any fields with C<undef>
values will be stripped from the response completely. Therefore
B<the client must handle the fact that some expected fields may not be 
returned>.

=begin private

nil is implemented by XMLRPC::Lite, in XMLRPC::Deserializer::decode_value
in the CPAN SVN since 14th Dec 2008
L<http://rt.cpan.org/Public/Bug/Display.html?id=20569> and in Fedora's
perl-SOAP-Lite package in versions 0.68-1 and above.

=end private

=head1 SEE ALSO

L<Bugzilla::WebService>