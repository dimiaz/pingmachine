package Pingmachine::Probe::HTTPing;

use Any::Moose;
use AnyEvent;
use AnyEvent::Util;
use Log::Any qw($log);
use List::Util qw(shuffle);
use Data::Dumper;

my $HTTPING_BIN = '/usr/bin/httping';

my $TIMEOUT   = 15000; # -t option (in ms)

has 'name' => (
    is => 'ro',
    isa => 'Str',
    default => sub { "httping" },
);

has 'max_orders' => (
    is => 'ro',
    isa => 'Int',
    default => 15,
);

has 'results' => (
    is => 'ro',
    isa => 'HashRef',
    default => sub { {} },
);

has 'current_job' => (
    is => 'rw',
    isa => 'HashRef',
);

has 'interval' => (
    is => 'ro',
    isa => 'Int',
    default => 1,
);

has 'url' => (
    is => 'ro',
    isa => 'Str',
);

has 'proxy' => (
    is => 'ro',
    isa => 'Str',
);

has 'user_agent' => (
    is => 'ro',
    isa => 'Str',
    default => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/87.0.4280.67 Safari/537.36",
);

with 'Pingmachine::Probe';

sub _start_new_job {
    my ($self) = @_;
    my $cv;

    my $step  = $self->step;
    my $pings = $self->pings;
    my $interval = $self->interval;
    my $user_agent = $self->user_agent;

    my $urlcount = $self->order_list->count;

    return unless $urlcount;

    # Make sure that we can process the request
    if(($TIMEOUT + $interval * 1000) * $pings > $step * 1000) {
        die "httping: step * 1000 must be higher than (timeout + interval * 1000) * pings (step = $step, timeout=$TIMEOUT, interval=$interval, pings=$pings)\n";
    }

    # Prepare job
    my %job = (
        url2order  => {},
        output     => {},
        cmd        => {},
        pid        => {},
    );
    for my $order ($self->order_list->get_all) {
        my $url = $order->httping->url;
        push @{$job{url2order}{$url}}, $order;
    }
    $self->current_job(\%job);
    
    for my $url (keys %{$job{url2order}}) {
        # Run httping
        my $cmd = [
            $HTTPING_BIN,
            $url,
            '-I', $user_agent,
            '-c', $pings,
            '-i', $interval,
            '-t', $TIMEOUT,
        ];

        if ( $self->proxy ) {
            push @{$cmd}, '-x';
            push @{$cmd}, $self->proxy;
        }

        $job{cmd}{$url} = join(' ', @$cmd);
        $cv = run_cmd $cmd,
            '2>', '/dev/null',
            '>', \$job{output}{$url},
            '$$', \$job{pid}{$url};
    }

    $cv->cb(
        sub {
            my $cbv = shift;
            for my $url (keys %{$job{url2order}}) {
                $job{pid}{$url} = undef;
            }
            my $exit = $cbv->recv;
            $exit = $exit >> 8;
            if($exit and $exit != 1 and $exit != 2) {
                # exit 1 means that some urls aren't reachable
                # exit 2 means "any IP addresses were not found"
                $log->warning("httping seems to have failed (exit: $exit, stderr: " . Dumper(\$job{output}) . ")");
                return;
            }  

            $log->debug("finished:" . Dumper(\$job{cmd}) . "(step: $step, pings: $pings, offset: " . $self->time_offset() . ")") if $log->is_debug();
                
            $self->_collect_current_job();

            $log->debug("collected:". Dumper(\$job{cmd}) . "(step: $step, pings: $pings, offset: " . $self->time_offset() . ")") if $log->is_debug();
        }
    );
}

sub _kill_current_job {
    my ($self) = @_;

    # Kill httping, if still running
    my $job = $self->current_job;
    for my $url (keys %{$job->{url2order}}) {
        if($job->{pid}{$url}) {
            # Check that we are killing the process we started and not an innocent bystander
            my $cmd_match = 0;
            if (open(proc_fh, "/proc/$job->{pid}{$url}/cmdline")) {
                $cmd_match = (join('', readline(proc_fh)) eq $job->{cmd}{$url});
                close(proc_fh);
            }
            if($cmd_match && kill(0, $job->{pid}{$url})) {
                $log->warning("killing unfinished httping process (step: ".$self->step.", pings: ".$self->pings.", offset: ".$self->time_offset().")");
                kill 9, $job->{pid}{$url};
                $job->{pid}{$url} = undef;
	    }
            elsif($job->{output}{$url}) {
                $log->warning("httping has finished, but we didn't notice... collecting (step: ".$self->step.", pings: ".$self->pings.", offset: ".$self->time_offset.")");
                $self->_collect_current_job();
            }
            else {
                $log->warning("httping has finished, but we didn't notice... no output found (?)");
            }
        }
    }
}

sub _collect_current_job {
    my ($self) = @_;
    my $text;

    my $job = $self->current_job;
    $self->current_job({});
    my %results;

    # Parse httping report
    for my $url (keys %{$job->{url2order}}) {
        # Do nothing, if httping didn't run yet or if job has been already collected
        return unless $job->{output}{$url};
        
        my $raw_text = $job->{output}{$url};
        # sample output
        # PING neverssl.com:80 (/):
        #	connected to neverssl.com:80 (524 bytes), seq=0 time= 10.86 ms
        #	connected to neverssl.com:80 (524 bytes), seq=1 time= 15.46 ms
        #	--- http://neverssl.com/ ping statistics ---
        #	2 connects, 2 ok, 0.00% failed, time 2027ms
        #	round-trip min/avg/max = 10.9/13.2/15.5 ms
        # parse line by line httping output and format it as with fping
        my @lines = split /\n/, $raw_text;
        my $values;
        foreach my $line (@lines) {
            # if the line contains an error (i.e. timeout, connection refused, ...) add a -
            if ($line =~ /could not connect|timeout|short read/) {
                $values .= '- ';
            }
            # if the line contains the httping result add the number
            if ($line =~ /time=\s*(\d\d*.\d\d*) ms/) {
                $values .= "$1 ";
            }
            # ignore all the rest
        }
        $values =~ s/\s+$//;
        $text .= "$url : $values\n";

    }

    while($text !~ /\G\z/gc) {
        if($text =~ /\G(\S+)[ \t]+:/gc) {
            my $url = $1;
            my @data;
            while($text =~ /\G[ \t]+([-\d\.]+)/gc) {
                push @data, $1;
            }
            # raw ping times
            my @pings = map {$_ eq '-' ? undef : $_ / 1000} @data;
            $results{$url}{pings} = \@pings;
            # sorted rtt times
            my @rtts = map {sprintf "%.6e", $_ / 1000} sort {$a <=> $b} grep /^\d/, @data;
            $results{$url}{rtts} = \@rtts;
        }

        # discard any other output on the line (ICMP host unreachable errors, etc.)
        $text =~ /\G.*\n/gc;
    }
    $log->debug("adding results") if $log->is_debug();

    # Add results (to RRD)
    if(scalar keys %results) {
        my $now = int(AnyEvent->now);
        my $step = $self->step;
        my $rrd_time = $now - $step - $now%$step;
        for my $url (keys %results) {
            my $u2o = $job->{url2order}{$url};
            if(not defined $u2o) {
                $log->warning("httping produced results for unknown url (url: $url, step: $step)");
                next;
            }
            for my $order (@{$u2o}) {
                $order->add_results($rrd_time, $results{$url});
            }
        }
    }
    $log->debug("adding results finished") if $log->is_debug();
}

sub run {
    my ($self) = @_;

    $self->_kill_current_job();
    $self->_start_new_job();
}

__PACKAGE__->meta->make_immutable;

1;
