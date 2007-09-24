
#=======================
package SNMP::Effective;
#=======================

use warnings;
use strict;
use SNMP;
use POSIX qw(:errno_h);

our $VERSION = '0.01';
our @ISA     = qw/SNMP::Effective::Var SNMP::Effective::Dispatch/;
our %METHOD  = map { $_ => $_ } qw/get getnext set/;
our %SNMPARG = (
                   Version   => '2c',
                   Community => 'public',
                   Timeout   => 1e6,
                   Retries   => 2
               );


sub new { #===================================================================

    ### init
    my $class = shift;
    my %args  = @_;
    my $self  = (ref $class) ? $class : bless {
        MaxSessions    => $args{'MaxSessions'}   || 1,
        MasterTimeout  => $args{'MasterTimeout'},
        _sessions      => 0,
        _dispatch_lock => 0,
    }, $class;

    ### setup VarReq
    SNMP::Effective::Var::new($self, %args);

    ### initialize Log4perl
    unless(Log::Log4perl->initialized) {
        Log::Log4perl->init({
            "log4perl.rootLogger"      => "ERROR, screen",
            "log4perl.appender.screen" => "Log::Log4perl::Appender::Screen",
        });
    }

    $self->{'__logger'} = Log::Log4perl->get_logger($class);

    ### the end
    return $self;
}

sub execute { #===============================================================

    ### init
    my $self = shift;
    $self->log->warn("Start execute");

    eval {

        if($self->{'MasterTimeout'}) {
            local $SIG{'ALRM'} = sub { die "alarm_clock_timeout" };
        }

        ### no hosts to get data from
        return 0 unless($self->Host_length);

        ### Dispatch
        alarm $self->{'MasterTimeout'} if($self->{'MasterTimeout'});
        $self->Dispatch() and SNMP::MainLoop();
        alarm 0 if($self->{'MasterTimeout'});

        $self->log->warn("Start execute");
    };

    ### check result from eval
    if($@ and $@ =~ m/alarm_clock_timeout/) {
        $self->{'_dispatch_lock'} = 0;
        $self->{'MasterTimeout'}  = 0;
        $self->log->error("Master timeout!");
        SNMP::finish();
    }
    elsif($@) {
        $self->log->logdie($@);
    }

    ### the end
    $self->log->warn("End execute");
    return 1;
}

sub _create_session { #=======================================================

    ### init
    my $self = shift;
    my $host = shift;
    my $snmp;

    ### create session
    $!    = 0;
    $snmp = SNMP::Session->new(%SNMPARG, $host->Arg);

    ### check error
    unless($snmp) {
        my($retry, $msg) = $self->_check_errno($!);
        $self->log->error($msg);
        return ($retry) ? '' : undef;
    }

    ### the end
    return $snmp;
}

sub _check_errno { #==========================================================
    
    ### init
    my $err    = pop;
    my $retry  = 0;
    my $string = '';

    ### some strange error
    unless($!) {
        $string  = "Couldn't resolve hostname";
    }
        
    ### some other error
    else {
        $string = $! + '';
        if(
            $err == EINTR  ||  # Interrupted system call
            $err == EAGAIN ||  # Resource temp. unavailable
            $err == ENOMEM ||  # No memory (temporary)
            $err == ENFILE ||  # Out of file descriptors
            $err == EMFILE     # Too many open fd's
        ) {
            $string .= ' (will retry)';
            $retry   = 1;
        }
    }

    ### the end
    return($retry, $string);
}

sub log { #===================================================================
    return shift()->{'__logger'};
}

sub match_oid { #=============================================================

    ### init
    my $p = shift or return;
    my $c = shift or return;
    
    ### check
    return ($p =~ /^\.?$c\.?(.*)/) ? $1 : undef;
}

sub make_numeric_oid { #======================================================

    ### init
    local $_;
    my @input = @_;
    
    ### fix
    for(@input) {
        next if(/^[\d\.]+$/);
        $_ = SNMP::translateObj($_);
    }
    
    ### the end
    return wantarray ? @input : $input[0];
}

sub make_name_oid { #=========================================================

    ### init
    local $_;
    my @input = @_;
    
    ### fix
    for(@input) {
        $_ = SNMP::translateObj($_) if(/^[\d\.]+$/);
    }
    
    ### the end
    return wantarray ? @input : $input[0];

}


#=================================
package SNMP::Effective::Dispatch;
#=================================

use strict;
use warnings;
use Time::HiRes qw/usleep/;


sub _set { #==================================================================

    ### init
    my $self     = shift;
    my $host     = shift;
    my $request  = shift;
    my $response = shift;

    ### timeout
    unless(ref $response) {
        return $self->_end($host, 'Timeout');
    }

    ### handle response
    for my $r (grep { ref $_ } @$response) {
        my $cur_oid = SNMP::Effective::make_numeric_oid($r->name);
        $host->data($r, $cur_oid);
    }

    ### the end
    $self->_end($host);
}

sub _get { #==================================================================

    ### init
    my $self     = shift;
    my $host     = shift;
    my $request  = shift;
    my $response = shift;

    ### timeout
    unless(ref $response) {
        return $self->_end($host, 'Timeout');
    }

    ### handle response
    for my $r (grep { ref $_ } @$response) {
        my $cur_oid = SNMP::Effective::make_numeric_oid($r->name);
        $host->data($r, $cur_oid);
    }

    ### the end
    $self->_end($host);
}

sub _getnext { #==============================================================

    ### init
    my $self     = shift;
    my $host     = shift;
    my $request  = shift;
    my $response = shift;
    my $i        = 0;

    ### timeout
    unless(ref $response) {
        return $self->_end($host, 'Timeout');
    }

    ### handle response
    while($i < @$response) {
        my $splice = 2;

        ### handle result
        if(my $r = $response->[$i]) {
            my($cur_oid, $ref_oid) = SNMP::Effective::make_numeric_oid(
                $r->name, $request->[$i]->name
            );
            $r->[0] = $cur_oid;
            $splice--;

            ### valid oid
            if(defined SNMP::Effective::match_oid($cur_oid, $ref_oid)) {
                $host->data($r, $ref_oid);
                $splice--;
                $i++;
            }
        }

        ### bad result
        if($splice) {
            splice @$request, $i, 1;
            splice @$response, $i, 1;
        }
    }

    ### to be continued
    if(@$response) {
        $$host->getnext($response, [ \&_getnext, $self, $host, $request ]);
    }

    ### the end
    else {
        $self->_end($host);
    }
}

sub _end { #==================================================================

    ### init
    my $self  = shift;
    my $host  = shift;
    my $error = shift;

    ### cleanup
    $host->Callback->($host, $error);

    ### the end
    $self->Dispatch($host)
}

sub Dispatch { #==============================================================

    ### init
    my $self  = shift;
    my $host  = shift;
    my $_Host = $self->_Host;
    my $log   = $self->log;
    my $request;

    ### setup
    usleep 900 + int rand 200 while($self->{'_dispatch_lock'});
    $self->{'_dispatch_lock'} = 1;

    ### iterate host list
    while($self->{'_sessions'} < $self->{'MaxSessions'} or $host) {

        ### init
        $host  ||= shift @$_Host or last;
        $request = shift @$host;
        my $sess_id;

        ### test request
        next unless(ref $request);

        ### fetch or create snmp session
        unless($$host) {
            unless($$host = $self->_create_session($host)) {
                next;
            }
            $self->{'_sessions'}++;
        }

        ### ready request
        if($$host->can($request->[0]) and $self->can("_$request->[0]")) {
            no strict;
            $cb      = \&{__PACKAGE__ ."::_$request->[0]"};
            $method  = $request->[0];
            $sess_id = $$host->$method(
                $request->[1], [$cb, $self, $host, $request->[1]]
            );
            $log->debug("$host -> $method : $request->[1]");
        }

        ### something went wrong
        unless($sess_id) {
            $log->info("Method: $request->[0] failed \@ $host");
            next;
        }
    }
    continue {
        if(ref $$host and !ref $request) {
            $self->{'_sessions'}--;
            $log->info("complete: $host");
        }
        $host = undef;
    }

    ### the end
    $self->{'_dispatch_lock'} = 0;
    $log->debug("$self->{'_sessions'} < $self->{'MaxSessions'}");
    unless(@$_Host or $self->{'_sessions'}) {
        $log->info("SNMP::finish() is next up");
        SNMP::finish();
    }

    ### the end
    return @$_Host || $self->{'_sessions'};
}


#================================
package SNMP::Effective::VarList;
#================================

use warnings;
use strict;
use Tie::Array;
use constant METHOD => 0;
use constant OID    => 1;
use constant SET    => 2;

our @ISA = qw/Tie::StdArray/;


sub PUSH { #==================================================================

    ### init
    my $self = shift;
    my @args = @_;

    foreach my $r (@args) {

        ### test request
        next unless(ref $r eq 'ARRAY' and $r->[METHOD] and $r->[OID]);
        next unless($SNMP::Effective::METHOD{$r->[METHOD]});

        ### fix OID array
        $r->[OID] = [$r->[OID]] unless(ref $r->[OID] eq 'ARRAY');

        ### setup VarList
        my @varlist = map  {
                          ref $_ eq 'ARRAY' ? $_    :
                          /([0-9\.]+)/      ? [$1]  :
                                              undef ;
                      } @{$r->[OID]};

        ### add elements
        push @$self, [
                         $r->[METHOD],
                         SNMP::VarList->new( grep $_, @varlist ),
                     ];
    }
}


#=============================
package SNMP::Effective::Host;
#=============================

use warnings;
use strict;
use overload '""'  => sub { $_[0]->{'Addr'}    };
use overload '${}' => sub { $_[0]->{'Session'} };
use overload '@{}' => sub { $_[0]->{'VarList'} };

our $AUTOLOAD;


sub Data { data(@_) }
sub data { #==================================================================

    ### init
    my $self = shift;

    ### save data
    if(@_) {
        
        ### init save
        my $r       = shift;
        my $ref_oid = shift || '';
        my $iid     = $r->[1]
                   || SNMP::Effective::match_oid($r->[0], $ref_oid)
                   || 1;

        $ref_oid    =~ s/^\.//;

        ### save
        $self->{'data'}{$ref_oid}{$iid} = $r->[2];
        $self->{'type'}{$ref_oid}{$iid} = $r->[3];
    }

    ### the end
    $self->{'data'};
}

sub Arg { #===================================================================

    ### init
    my $self = shift;
    my $arg  = shift;

    ### set value
    if(ref $arg eq 'HASH') {
        $self->{'Arg'}{$_} = $arg->{$_} for(keys %$arg);
    }

    ### the end
    return wantarray ? (%{$self->{'Arg'}}, DestHost => "$self") : ();
}

sub new { #===================================================================
    
    ### init
    my $class = shift;
    my $addr  = shift or return;
    my %args  = @_;
    my($session, @VarList);

    ### tie
    tie @VarList, "SNMP::Effective::VarList";

    ### the end
    return bless {
        Addr     => $addr,
        Session  => \$session,
        VarList  => \@VarList,
        Callback => sub {},
        Arg      => {},
        data     => {},
        Memory   => {},
        %args,
    }, $class;
}

sub AUTOLOAD { #==============================================================
    
    ### init
    my $self  = shift;
    my($key)  = $AUTOLOAD =~ /::(\w+)$/;
    my $value = shift;

    ### set data
    if(exists $self->{$key}) {
        $self->{$key} = $value if(ref $value eq ref $self->{$key});
        return $self->{$key};
    }
}


#=================================
package SNMP::Effective::HostList;
#=================================

use warnings;
use strict;
use overload '@{}' => \&HostArray;


sub TIEARRAY { #==============================================================
    return $_[1];
}

sub FETCHSIZE { #=============================================================
    return scalar keys %{$_[0]};
}

sub SHIFT { #=================================================================
    my $self = shift;
    my $key  = (keys %$self)[0] or return;
    return delete $self->{$key};
}

sub HostArray { #=============================================================
    my @Array;
    tie @Array, ref $_[0], $_[0];
    return \@Array;
}

sub new { #===================================================================
    bless {}, $_[0];
}


#============================
package SNMP::Effective::Var;
#============================

use warnings;
use strict;
use SNMP;

our $AUTOLOAD;


sub add { #===================================================================

    ### init
    my $self     = shift;
    my %in       = @_;
    my $_Host    = $self->_Host;
    my $_VarList = $self->_VarList;
    my $VarList  = [];

    ### setup host
    if($in{'DestHost'} and ref $in{'DestHost'} ne 'ARRAY') {
        $in{'DestHost'} = [$in{'DestHost'}];
    }

    ### setup varlist
    for my $key (keys %SNMP::Effective::METHOD) {
        push @$VarList, [$key, $in{$key}] if($in{$key});
    }
    unless(@$VarList) {
        $VarList = $_VarList;
    }

    ### log
    $self->log->info("Vars: " .scalar(@$VarList));

    ### add new hosts
    if(ref $in{'DestHost'} eq 'ARRAY') {
        for my $addr (@{$in{'DestHost'}}) {
            
            ### create new host
            unless($_Host->{$addr}) {
                $_Host->{$addr} = SNMP::Effective::Host->new($addr);
                $_Host->{$addr}->Arg($self->{'Arg'});
                $_Host->{$addr}->Callback($self->{'Callback'});
            }

            ### alter created/existing host
            push @{$_Host->{$addr}}, @$VarList;
            $_Host->{$addr}->Arg($in{'Arg'});
            $_Host->{$addr}->Callback($in{'Callback'});
            $_Host->{$addr}->Memory($in{'Memory'});
        }

        local $" = ", ";
        $self->log->debug("Added @{$in{'DestHost'}}");
    }

    ### update hosts
    else {
        push @$_VarList, @$VarList;
        $self->Arg($in{'Arg'});
        $self->Callback($in{'Callback'});
    }
}

sub new { #===================================================================
    
    ### init
    my $self = shift;

    ### fix self
    $self->{'_Host'}    = SNMP::Effective::HostList->new();
    $self->{'_VarList'} = [];
    $self->{'Arg'}      = {};
    $self->{'Callback'} = sub {};

    ### add data
    add($self, @_) if(@_ > 1);
}

sub Host_length { #===========================================================
    return $_ = @{ $_[0]->{'_Host'} };
}

sub AUTOLOAD { #==============================================================
    
    ### init
    my $self  = shift;
    my($key)  = $AUTOLOAD =~ /::(\w+)$/;
    my $value = shift;

    ### set/get data
    if(exists $self->{$key}) {
        $self->{$key} = $value if(ref $value eq ref $self->{$key});
        return $self->{$key};
    }

    ### the end
    return;
}

#=============================================================================
1983;
__END__

=head1 NAME

SNMP::Effective - An effective SNMP-information-gathering module

=head1 VERSION

This document refers to version 0.01 of SNMP::Effective.

=head1 SYNOPSIS

 use SNMP::Effective;
 
 my $snmp = SNMP::Effective->new(
     MaxSessions   => $NUM_POLLERS,
     MasterTimeout => $TIMEOUT_SECONDS,
 );
 
 $snmp->add(
     DestHost => $ip,
     Callback => sub { store_data() },
     get      => [ '1.3.6.1.2.1.1.3.0', 'sysDescr' ],
 );
 # lather, rinse, repeat
 
 # retrieve data from all hosts
 $snmp->execute;

=head1 DESCRIPTION

This module collects information, over SNMP, from many hosts and many OIDs,
really fast.

It is a wrapper around the facilities of C<SNMP.pm>, which is the Perl
interface to the C libraries in the C<Net-SNMP> package. Advantages of using
this module include:

=over 4

=item Simple configuration

The data structures required by C<Net-SNMP> are complex to set up before
polling, and parse for results afterwards. This module provides a simpler
interface to that configuration by accepting just a list of SNMP OIDs or leaf
names.

=item Parallel execution

Many users are not aware that C<Net-SNMP> can poll devices asynchronously
using a callback system. By specifying your callback routine as in the
L</"SYNOPSIS"> section above, many network devices can be polled in parallel,
making operations far quicker. Note that this does not use threads.

=item It's fast

To give one example, C<SNMP::Effective> can walk, say, eight indexed OIDs
(port status, errors, traffic, etc) for around 300 devices (that's 8500 ports)
in under 30 seconds. Storage of that data might take an additional 10 seconds
(depending on whether it's to RAM or disk). This makes polling/monitoring your
network every five minutes (or less) no problem at all.

=back

The interface to this module is simple, with few options. The sections below
detail everything you need to know.

=head1 METHODS

=head2 C<new>

This is the object constructor, and returns an SNMP::Effective object.

Arguments:

 MaxSessions   => int # maximum number of simultaneous SNMP sessions
 MasterTimeout => int # maximum number of seconds before killing execute

All other arguments are passed on to SNMP::Effective::Var::new, which from
a user's perspective is the same as calling $snmp_effective->add( ... ).

=head2 C<add>

Adding information about what SNMP data to get and where to get it.

Arguments:

 DestHost => []     # array-ref that contains a list of hosts
                    # either ip-address or hostname
 Arg      => {}     # hash-ref, that is passed on to SNMP::Session
 Callback => sub {} # the callback which handles the response
 get      => []     # array-ref that holds a list of OIDs to get
 getnext  => []     # array-ref that holds a list of OIDs to get

This can be called with many different combinations, such as:

=over 4

=item DestHost / any other argument

This will make changes per DestHost specified. You can use this to change Arg,
Callback or add OIDs on a per-host basis.

=item get / getnext 

The OID list submitted to C<add()> will be added to all DestHosts, if no
DestHost is specified.

=item Arg / Callback

This can be used to alter all hosts' SNMP arguments or callback method.

=back

=head2 C<execute>

This method starts setting and/or getting data. It will run as long as necessary,
or until MasterTimeout seconds has passed. Every time some data is set and/or
retrieved, it will call the callback-method, as defined globally or per host.

=head2 C<log>

This returns the Log4perl object that is used for logging:

 $self->log->warn("log this message!");

=head2 C<make_name_oid>

Takes a list of numeric OIDs and turns them into an mib-object string.

=head2 C<make_numeric_oid>

Inverse of make_name_oid: Takes a list of mib-object strings, and turns them
into numeric format.

=head2 C<match_oid>

Takes two arguments: One OID to match against, and the OID to match.

 mathc_oid("1.3.6.10",   "1.3.6");    # return 10
 mathc_oid("1.3.6.10.1", "1.3.6");    # return 10.1
 mathc_oid("1.3.6.10",   "1.3.6.11"); # return undef

=head1 The callback method

When C<Net-SNMP> is done collecting data from a host, it calls a callback
method, provided by the C<< Callback => sub{} >> argument. Here is an example of a
callback method:

 sub my_callback {
     my($host, $error) = @_
  
     if($error) {
         warn "$host failed with this error: $error"
         return;
     }
 
     my $data = $host->data;
 
     for my $oid (keys %$data) {
         print "$host returned oid $oid with this data:\n";
 
         print join "\n\t",
               map { "$_ => $data->{$oid}{$_}" }
                   keys %{ $data->{$oid}{$_} };
         print "\n";
     }
 }

=head1 DEBUGGING

Debugging is enabled through Log::Log4perl. If nothing else is spesified,
it will default to "error" level, and print to STDERR. The component-name
you want to change is "SNMP::Effective", inless this module ins inherited.

=head1 TODO

=over 4

=item Improve debugging support

=back

=head1 DEPENDENCIES

In addition to the contents of the standard Perl distribution, this module
requires the following:

=over 4

=item C<SNMP>

Note that this is B<not> the same as C<Net::SNMP> on the CPAN. You want the
C<SNMP> CPAN distribution or the C<Net-SNMP> distribution.

=item C<Time::HiRes>

Perl versions greater than C<5.7.3> are supplied with this module.

=item C<Tie::Array>

Perl versions greater than C<5.5.0> are supplied with this module.

=item C<constant> and C<overload>

Perl versions greater than C<5.4.0> will have these modules.

=back

=head1 AUTHOR

Jan Henning Thorsen, C<< <pm at flodhest.net> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-snmp-effective at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=SNMP-Effective>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc SNMP::Effective

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/SNMP-Effective>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/SNMP-Effective>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=SNMP-Effective>

=item * Search CPAN

L<http://search.cpan.org/dist/SNMP-Effective>

=back

=head1 ACKNOWLEDGEMENTS

Various contributions by Oliver Gorwits.

=head1 COPYRIGHT & LICENSE

Copyright 2007 Jan Henning Thorsen, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
