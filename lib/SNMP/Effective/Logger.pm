package SNMP::Effective::Logger;

use strict;
use warnings;

our $LOGCONFIG     = {
    "log4perl.rootLogger"             => "ERROR, screen",
    "log4perl.appender.screen"        => "Log::Log4perl::Appender::Screen",
    "log4perl.appender.screen.layout" => "Log::Log4perl::Layout::SimpleLayout",
};
our $AUTOLOAD;


BEGIN {
    eval { require Log::Log4perl };
    warn $@ if($@);
}

sub new {
    if(%{ Log::Log4perl:: }) {
        Log::Log4perl->init($LOGCONFIG) unless(Log::Log4perl->initialized);
        return Log::Log4perl->get_logger(__PACKAGE__);
    }
    else {
        return bless [], __PACKAGE__;
    }
}

sub AUTOLOAD {

    my $self   = shift;
    my $msg    = shift || '';
    my($level) = $AUTOLOAD =~ /::(\w+)$/mx;

    return if($level eq 'DESTROY');

    warn "$level: $msg\n";

    return;
}

1;
__END__

=head1 NAME

SNMP::Effective::Logger

=head1 VERSION

See SNMP::Effective

=head1 DESCRIPTION

This is a wrapper around C<Log::Log4perl>, but falls back to log everything,
if C<Log::Log4perl> is missing.

=head1 METHODS

=head2 new

Returns either a C<Log::Log4perl> or C<SNMP::Effective::Logger> object.

=head2 trace

=head2 debug

=head2 info

=head2 warn

=head2 error

=head2 fatal

=head1 AUTHOR

Jan Henning Thorsen, C<< <pm at flodhest.net> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-docsis-perl at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=SNMP-Effective>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc SNMP::Effective

You can also look for information at
L<http://search.cpan.org/dist/SNMP-Effective>

=head1 ACKNOWLEDGEMENTS

=head1 COPYRIGHT & LICENSE

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

Copyright (c) 2007 Jan Henning Thorsen

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

=cut
