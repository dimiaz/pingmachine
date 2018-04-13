package Pingmachine::Probe::SPing;

use Any::Moose;
use AnyEvent;
use AnyEvent::Util;
use Log::Any qw($log);
use List::Util qw(shuffle);

my $scionDir = $ENV{'SC'}'
my $SPING_BIN = $scionDir.'bin/scmp_fping';

my $TIMEOUT   = 3000; # -t option (in ms)
my $MIN_WAIT  =   10; # -i option (is ms)

has 'name' => (
    is => 'ro',
    isa => 'Str',
    default => sub { "sping" },
);

has 'max_orders' => (
    is => 'ro',
    isa => 'Int',
    default => 1000,
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
);

has 'source_ip' => (
    is  => 'ro',
    isa => 'Str',
);

has 'interface' => (
    is  => 'ro',
    isa => 'Str',
);

has 'ipv6' => (
    is  => 'ro',
    isa => 'Bool',
    default => 0,
);

with 'Pingmachine::Probe';

sub _start_new_job {
    my ($self) = @_;

    # We want to distribute the samples as homogeneously as possible in the
    # available $step time (to increase the probability of detecting periodic
    # problems and to decrease the network peak load).
    # - We wait for at least 1 seconds for each ping ($interval).
    # - We can instruct fping to distribute the pings (fping -p parameter).
    #   That parameter also determines the maximal wait time, so we
    #   can have at most $step/$interval pings if we ping a single
    #   host.
    # - If multiple hosts are pinged, then we need also to consider the $MIN_WAIT
    #   (fping -i) parameter.
    # - The total time needed by fping is (assuming $hostcount*MIN_WAIT < $interval):
    #     ($pings-1)*interval + *$hostcount*$MIN_WAIT + $TIMEOUT

    my $step  = $self->step;
    my $pings = $self->pings;
    my $hostcount = $self->order_list->count;

    return unless $hostcount;

    # Determine $interval (fping -p)
    my $interval; # interval applies only to periods between pings in series (fping -p)
    if($self->interval) {
        $interval = $self->interval;
    }
    else {
        $interval = int(($step * 1000 * 0.8 - $hostcount*$MIN_WAIT - $TIMEOUT) / $pings);
        $interval >= 1000 or
            die "fping: calculated interval too small: $interval (step = $step, pings = $pings)\n";
    }


    # Make sure that we can process all hosts
    if($interval / $hostcount < $MIN_WAIT) {
        die "fping: step * 1000 / (pings * hostcount) must be at least 10 (step=$step, pings=$pings, hostcount=$hostcount\n";
    }

    # Prepare job
    my %job = (
        host2order => {},
        output     => '',
        pid        => '',
    );
    for my $order ($self->order_list->get_all) {
        my $host = $order->sping->host;
        push @{$job{host2order}{$host}}, $order;
    }
    $job{hostlist} = join("\n", shuffle keys %{$job{host2order}}) . "\n",
    $self->current_job(\%job);

    # Run scmp
    my $single_host = substr $job{hostlist}, 0, -1;
    $log->info("single_host: ".$single_host);
    my $cmd = [
        $SPING_BIN,
        '-id', 'scmp_echo',
        '-interval', $interval.'ms',
        '-c', $pings,
        '-timeout', $TIMEOUT.'s',
        '-remote', $single_host,
        '-local', $self->source_ip,
    ];
    my $switch_dir = 'cd '.$scionDir;
    my $cmd_string = $switch_dir." && ".join(" ", @$cmd);
    my $effective_cmd = [ 'su', 'scion', '-c', $cmd_string ];
    $log->debug("starting: @$cmd (step: $step, pings: $pings, offset: ".$self->time_offset().")") if $log->is_debug();

    my $cv = run_cmd $effective_cmd,
        '2>', '/dev/null',
        '>', \$job{output},
        '$$', \$job{pid};

    # Install sping exit callback
    $cv->cb(
        sub {
            my $cbv = shift;
            $job{pid} = undef;
            my $exit = $cbv->recv;
            $exit = $exit >> 8;
            if($exit and $exit != 1 and $exit != 2) {
                # exit 1 means that some hosts aren't reachable
                # exit 2 means "any IP addresses were not found"
                $log->warning("sping seems to have failed (exit: $exit, stderr: ".$job{output}.")");
                return;
            }

	    $log->debug("finished: @$cmd (step: $step, pings: $pings, offset: ".$self->time_offset().")") if $log->is_debug();

            $self->_collect_current_job();

	    $log->debug("collected: @$cmd (step: $step, pings: $pings, offset: ".$self->time_offset().")") if $log->is_debug();
        }
    );
}

sub _kill_current_job {
    my ($self) = @_;

    # Kill sping, if still running
    my $job = $self->current_job;
    if($job->{pid}) {
        if(kill(0, $job->{pid})) {
            $log->warning("killing unfinished sping process (step: ".$self->step.", pings: ".$self->pings.", offset: ".$self->time_offset().")");
            kill 9, $job->{pid};
            $job->{pid} = undef;
	}
        elsif($job->{output}) {
            $log->warning("sping has finished, but we didn't notice... collecting (step: ".$self->step.", pings: ".$self->pings.", offset: ".$self->time_offset.")");
            $self->_collect_current_job();
        }
        else {
            $log->warning("sping has finished, but we didn't notice... no output found (?)");
        }
    }
}

sub _collect_current_job {
    my ($self) = @_;

    my $job = $self->current_job;
    $self->current_job({});
    my %results;

    # Do nothing, if sping didn't run yet or if job has been already collected
    return unless $job->{output};

    # Parse sping report
    my $text = $job->{output};
    $log->info("Output to parse: text: ".$text."--");
    while($text !~ /\G\z/gc) {
        if($text =~ /\G(\S+)[ \t]+:/gc) {
            my $host = $1;
            my @data;
            while($text =~ /\G[ \t]+([-\d\.]+)/gc) {
                push @data, $1;
            }
            # raw ping times
            my @pings = map {$_ eq '-' ? undef : $_ / 1000} @data;
            $results{$host}{pings} = \@pings;
            # sorted rtt times
            my @rtts = map {sprintf "%.6e", $_ / 1000} sort {$a <=> $b} grep /^\d/, @data;
            $results{$host}{rtts} = \@rtts;
            $log->info("adding results: rtts: ".join(" ", @rtts));
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
        for my $host (keys %results) {
            my $h2o = $job->{host2order}{$host};
            if(not defined $h2o) {
                $log->warning("sping produced results for unknown host (host: $host, step: $step)");
                next;
            }
            for my $order (@{$h2o}) {
                $order->add_results($rrd_time, $results{$host});
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
