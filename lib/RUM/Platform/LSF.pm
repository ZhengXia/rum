package RUM::Platform::LSF;

use strict;
use warnings;

use Carp;
use Data::Dumper;

use RUM::Logging;
use RUM::Common qw(shell);
use base 'RUM::Platform::Cluster';

our $log = RUM::Logging->get_logger();

our $MAX_UPDATE_STATUS_TRIES = 5;
our $JOB_ID_FILE = "rum_sge_job_ids";
our @JOB_TYPES = qw(parent preproc proc postproc);
our %JOB_TYPE_NAMES = (
    parent => "parent",
    preproc => "preprocessing",
    proc => "processing",
    postproc => "postprocessing"
);

sub new {
    my ($class, $config) = @_;

    local $_;

    my $self = $class->SUPER::new($config);

    my $dir = $config->output_dir;

    $self->{cmd} = {};
    $self->{cmd}{preproc}  =  "perl $0 resume --child --output $dir --preprocess";
    $self->{cmd}{proc}     =  "perl $0 resume --child --output $dir --chunk \$LSB_JOBINDEX --process";
    $self->{cmd}{postproc} =  "perl $0 resume --child --output $dir --postprocess";

    $self->{cmd}{proc} .= " --no-clean" if $config->no_clean;

    $self->{jids}{$_} = [] for @JOB_TYPES;

    my $filename = $config->in_output_dir($JOB_ID_FILE);
    if (-e $filename) {
        $self->{jids} = do $filename;
    }
    return bless $self, $class;
}

sub save {
    my ($self) = @_;
    open my $out, ">", $self->config->in_output_dir($JOB_ID_FILE);
    print $out Dumper($self->{jids});
}

################################################################################
###
### Submitting jobs
###

sub start_parent {
    my ($self) = @_;

    $log->info("Submitting a job to monitor child tasks, then exiting.");
    my $c = $self->config;
    my $dir = $c->output_dir;
    my $cmd =  "$0 resume --parent --output $dir --lock $RUM::Lock::FILE";
    $cmd .= " --preprocess"  if $c->preprocess;
    $cmd .= " --process"     if $c->process;
    $cmd .= " --postprocess" if $c->postprocess;
    $cmd .= " --no-clean"    if $self->config->no_clean;
    my $name = $c->name;
    my $jid = $self->_bsub("-J", "rum_parent_$name", $cmd);
    push @{ $self->_parent_jids }, $jid;
    $self->save;
}

sub submit_preproc {
    my ($self) = @_;
    $log->info("Submitting preprocessing job");
    my $sh = $self->_write_shell_script("preproc");
    my $name = $self->config->name;
    my $jid = $self->_bsub("-J", "rum_preproc_$name", $sh);
    push @{ $self->_preproc_jids }, $jid;
    $self->save;
}

sub submit_proc {
    my ($self, @chunks) = @_;
    my $sh = $self->_write_shell_script("proc");
    my $n = $self->config->chunks;
    my $name = $self->config->name;
    my @prereqs = @{ $self->_preproc_jids };

    my @args;

    my @jids;

    if (@prereqs) {
        $log->info("Submitting processing job; waiting for preprocessing (@prereqs) to finish");

        my @waits = map { "ended($_)" } @prereqs;
	if ( @waits ) {
            push @args, "-w '" . join(" && ", @waits) . "'";
        }
    }
    else {
        $log->info("Submitting processing jobs");
    }

    if (@chunks) {
        $log->info("Submitting jobs for chunks " . join(", ", @chunks));
        for my $chunk (@chunks) {
            my $jid = $self->_bsub(@args, "-J rum_proc_$name\[$chunk\]", $sh);
            $log->info("Chunk $chunk is job id $jid");
            push @jids, $jid;
        }
    }
    else {
        $log->info("Submitting an array job for $n chunks");
        my $jid = $self->_bsub(@args, "-J rum_proc_$name\[1-$n\]", $sh);
        $log->info("Array job id is $jid");
        push @jids, $jid;
    }

    push @{ $self->_proc_jids }, @jids;
    $self->save;
}

sub submit_postproc {
    my ($self, $c) = @_;
    # RUM::Platform::Cluster might call me to submit a new
    # postprocessing job, but the last chunk should handle it. So make
    # sure there's no other postprocessing task running before
    # actually submitting it.
    $self->submit_proc($self->config->chunks) unless $self->postproc_ok;
}

################################################################################
###
### Checking job status
###

sub log_last_status_warning {
    my ($self) = @_;
    my @lines = @{ $self->{last_bjobs_output} || []};
    for my $line (@lines) {
        $log->info("bjobs: $line");
    }
}

sub update_status {
    my ($self) = @_;

    my $tries = 0;

    while ($tries++ < $MAX_UPDATE_STATUS_TRIES) {
        $log->info("Running bjobs");
        my @bjobs = `bjobs -w`;
        $log->info("Ran it");
        # $log->debug("bjobs: $_") foreach @bjobs;
        $self->{last_bjobs_output} = \@bjobs;
        if ($?) {
            $log->info("bjobs command failed with status: $?");
            next;
        }
        elsif (my $status = $self->_parse_bjobs_out(@bjobs)) {
            $log->info("Parsed bjobs output");
            $self->_build_job_states($self->_parse_bjobs_out(@bjobs));
            $self->save;
            return 1;
        }
        else {
            $log->info("Couldn't parse bjobs output");
        }
    }

    die "I tried to update my status with bjobs $tries times and it ".
        "failed every time. This means that I can't determine the " .
        "status of the jobs I've started. It could be that they've all ".
        "failed, but it could also just be that bjobs is returning ".
        "output that I can't parse. I'm exiting.";
}

sub preproc_ok {
    my ($self) = @_;
    return $self->_some_job_ok("preproc", $self->_preproc_jids);
}

sub proc_ok {
    my ($self, $chunk) = @_;
    $chunk or croak "$self->proc_ok() called without chunk";
    return $self->_some_job_ok("proc", $self->_proc_jids, $chunk);
}

sub postproc_ok {
    my ($self) = @_;
    return $self->proc_ok($self->config->chunks);
}


################################################################################
###
### Private methods
###

sub _ram_args {
    my ($self) = @_;
    my $ram = ($self->config->ram || $self->config->min_ram_gb);
    $ram *= 1000;
    return "-R \"rusage[mem=$ram] span[hosts=1]\"";
}

sub _parse_bsub_out {
    my $self = shift;
    local $_ = shift;
    /^Job <(\d+)>/ and return $1;
}

sub _bsub {
    my ($self, @args) = @_;
    my $dir = $RUM::Logging::LOGGING_DIR;
    my $dir_opt = $dir ? "-o $dir/%J.%I.o -e $dir/%J.%I.e" : "";
    my $flags = $self->config->platform_flags || "-n 2 -q plus " . $self->_ram_args;
    my $cmd = "bsub $dir_opt $flags @args 2>&1";
    $log->info("Submitting job to LSF: '$cmd'");
    my $out = `$cmd`;

    if ($log->is_debug) {
        for my $line (split /\n/, $out) {
            $log->debug("bsub: $line");
        }
    }
    if ($?) {
        for my $line (split /\n/, $out) {
            $log->error("bsub: $line");
        }
        croak "Error running $cmd";
    }
    $log->info("Submitted the job");
    return $self->_parse_bsub_out($out);
}

sub _field_start_len {
    my ($field) = @_;
    /(.*)($field\s*)/ or croak "Can't find field $field in bjobs output:\n$_\n";
    return (length($1), length($2))
}

sub _extract_field {
    my ($line, $off, $len) = @_;
    return unless $off < length($line);
    my $text = substr $line, $off, $len;
    $text =~ s/^\s*//;
    $text =~ s/\s*$//;
    return $text if $text;
}

sub _parse_bjobs_out {
    my ($self, @lines) = @_;
    $log->info("In parse_bjobs_out");
    if (!@lines) {
        return [];
    }

    # Skip the header line
    my $header = shift @lines;

    my @result;

    for my $line (@lines) {
        my @fields = split /\s+/, $line;

        my $job = $fields[0];
        # Handles cases where LSF reports the ids of arrayed jobs in the
        # jid[\d+] format.
        if ($job =~ /^(.+)\[\d+\]/ ) {
            $job = $1;
        }
        my $state = $fields[2];
        my $name = $fields[6];
        my $task;
        if ( $name =~ /\[(\d+)\]/ ) {
            $task = $1;
        }

        unless ($job && $state) {
            $log->info("Got invalid output from bjobs: $line");
            return undef;
        }

        my %rec = (job_id => $job, state => $state);

        if ($task) {
            push @result, { %rec, task_id => $task };
        }
        else {
            push @result, { %rec };
        }
    }
    return \@result;
}

sub _build_job_states {
    my ($self, $jobs) = @_;

    # For preproc and postproc, %states maps a job id to the state of
    # that job according to bjobs. For proc, %states maps a job id to
    # an array ref where each slot holds the status for that task of
    # the array job.
    my %states;
    for my $job (@{ $jobs }) {
        my ($jid, $state, $task_id) = @$job{'job_id', 'state', 'task_id'};

        if ($task_id) {
            $states{$jid} ||= [];
            $states{$jid}[$task_id] = $state;
        }
        else {
            $states{$jid} = $state;
        }
    }
    $self->{job_states} = \%states;
    my @jids = keys %states;

    # Some of the jids I used to know about might have
    # disappeared. Remove from my jids map any jids that no longer
    # appear in bjobs.
    for my $phase (@JOB_TYPES) {
        my @jids = @{ $self->{jids}{$phase} || [] };
        my @active = grep { $states{$_} } @jids;
        $self->{jids}{$phase}  = \@active;
    }
}

sub _job_state {
    my ($self, $jid, $chunk) = @_;

    my $state = $self->{job_states}{$jid} or return undef;

    if (defined $chunk) {
        ref($state) =~ /^ARRAY/ or croak
            "Corrupt job state, should be array ref, was $state";
        return $state->[$chunk];
    }

    return $state;
}

sub _some_job_ok {
    my ($self, $phase, $jids, $task) = @_;
    my @jids = @{ $jids } or return 0;
    my @states = map { $self->_job_state($_, $task) || "" } @jids;
    my @ok = grep { $_ && /^(DONE|RUN|SSUSP|USUSP|PSUSP|PEND)/ } @states;

    if ($log->is_debug) {
        $log->debug("Jids are " . Dumper(\@jids));
    }

    my $task_label = "phase $phase " . ($task ? " task $task" : "");

    my $msg = (
        "I have these jobs for phase $task_label: ".
        "[" .
        join(", ",
             map "$jids[$_]($states[$_])", grep { $states[$_] } (0 .. $#jids))
        . "] ");

    if (@ok == 1) {
        $log->debug($msg);
        return 1;
    }
    if (@ok == 0) {
        $log->info("$msg and none of them are running or waiting");
    }
    else {
        $msg .= join(
        " ", "and more than one of them are running or waiting.",
        "This is probably because LSF was not reporting a status",
        "of running or waiting, and I started a new job, and then",
        "the job started running again");
        $log->info($msg);

        return 1;
    }

    return 0;
}

sub stop {
    my ($self) = @_;
    $self->update_status;

    my @table = (
        ["parent",         $self->_parent_jids ],
        ["preprocessing",  $self->_preproc_jids ],
        ["processing",     $self->_proc_jids ],
    );

    for my $type (@JOB_TYPES) {
        my $name = $JOB_TYPE_NAMES{$type};
        my @jids = @{ $self->{jids}{$type} };

        if (@jids) {
            $self->say("Deleting $name job ids @jids");
            system("bkill @jids");
            if ($?) {
                warn "Couldn't delete jobs: " . ($? >> 8);
            }
        }
        else {
            $self->say("Don't seem to have any $name job ids running");
        }
    }
    unlink $self->config->lock_file;
}

# These methods return the LSF job ids for the jobs that are currently
# running to perform the preprocessing, processing, and postprocessing
# phases.

sub _parent_jids   { $_[0]->{jids}{parent} };
sub _preproc_jids  { $_[0]->{jids}{preproc} };
sub _proc_jids     { $_[0]->{jids}{proc} };

sub _script_filename {
    my ($self, $phase) = @_;
    return $self->config->in_output_dir(
        "rum_" . $self->config->name . "_$phase" . ".sh");
}


sub _write_shell_script {
    my ($self, $phase) = @_;
    my $filename = $self->_script_filename($phase);
    open my $out, ">", $filename or croak "Can't open $filename for writing: $!";
    my $cmd = $self->{cmd}{$phase} or croak "Don't have command for phase $phase";

    print $out 'RUM_CHUNK=$LSB_JOBINDEX' . "\n";
    print $out 'RUM_OUTPUT_DIR=' . $self->config->output_dir . "\n";

    if ($phase eq 'proc') {
        print $out 'RUM_INFO_LOG_FILE=$RUM_OUTPUT_DIR/log/rum_$RUM_CHUNK.log', "\n";
        print $out 'RUM_ERROR_LOG_FILE=$RUM_OUTPUT_DIR/log/rum_errors_$RUM_CHUNK.log', "\n";
    }
    else {
        print $out 'RUM_INFO_LOG_FILE=$RUM_OUTPUT_DIR/log/rum.log', "\n";
        print $out 'RUM_ERROR_LOG_FILE=$RUM_OUTPUT_DIR/log/rum_errors.log', "\n";
    }
    print $out $self->{cmd}{$phase} . "\n";
    my $last_chunk = $self->config->chunks;
    if ($phase eq 'proc') {
        print $out "if [ \$RUM_CHUNK == $last_chunk ]; then\n";
        print $out '  RUM_INFO_LOG_FILE=$RUM_OUTPUT_DIR/log/rum_postproc.log', "\n";
        print $out '  RUM_ERROR_LOG_FILE=$RUM_OUTPUT_DIR/log/rum_errors_postproc.log', "\n";
        print $out "  $self->{cmd}{postproc};\n";
        print $out "fi\n";
    }

    close $out;
    chmod 0755, $filename;
    return $filename;
}

sub is_running {
    my ($self) = @_;
    $self->update_status;
    my %jids_for_job_type= %{ $self->{jids} };
    for my $job_type (keys %jids_for_job_type) {
        my $jids = $jids_for_job_type{$job_type} || [];
        if (@{ $jids }) {
            return 1;
        }
    }
    return 0;
}

sub show_running_status {
    my ($self) = @_;
    $self->update_status;
    my $output = "";

    my %jids_for_job_type= %{ $self->{jids} };

    my @jids = map { @{ $_ || [] } } values %jids_for_job_type;

    if (@jids) {
        $self->say("RUM is running (job ids "
                   . join(', ', @jids) . ').');
    }
    else {
        $self->say("RUM is not running.");
    }
}

sub clean {
    my ($self) = @_;
    for my $phase (@JOB_TYPES) {
        unlink $self->_script_filename($phase);
    }
    unlink $self->config->in_output_dir($JOB_ID_FILE);
}

1;

__END__

=head1 NAME

RUM::Platform::LSF - Run the rum pipeline on the Sun Grid Engine.

=head1 DESCRIPTION

Provides methods for submitting phases of the rum pipeline to the Sun
Grid Engine, and checking on their status.

=head1 CONSTRUCTORS

=over 4

=item new

Construct a RUM::Cluster::LSF with the given configuration. Loads the
state of the jobs from rum_sge_job_ids in the output directory, if
such a file exists.

=back

=head1 METHODS

=over 4

=item start_parent

Submits a job to run rum_runner on this output directory with the
--parent option. This way, when the user runs rum_runner with --bsub
or --platform LSF, that process calls start_parent and then exits
quickly. When rum_runner is called with --parent, it monitors the
status of the other tasks it submits.

Updates $JOB_ID_FILE so that we keep track of which jobs we've
submitted.

=item submit_preproc

Submits the preprocessing task, adds the job ids to my state, and
updates $JOB_ID_FILE.

=item submit_proc

Submits an array job to run all of the chunks, adds the job id to my
state, and updates $JOB_ID_FILE. The array job depends on the
preprocessing job, if I have the job id of a preprocessing job on
record.

=item submit_postproc

Submits a job for the postprocessing phase and updates
$JOB_ID_FILE. Note that this does not add a dependency on the array
job for the processing phase, since we may restart one or more of
those array tasks if they fail. The caller must not call
submit_postproc until the processing is done.

=item update_status

Run bjobs and parse the results, updating my internal model of the
status of all jobs.

=item preproc_ok

=item proc_ok

=item postproc_ok

These methods return true if the preproc, proc, or postproc phase is
in an 'ok' status, meaning that it is running or at least in the queue
in a state that indicates it can be run in the future.

=item save

Save the job ids to the $JOB_IDS_FILE.

=item stop

Delete all jobs associated with this output directory.

=item clean

Remove the shell script files used to submit the jobs to LSF.

=item show_running_status

Print a message to stdout indicating whether the job is running or
not.

=item is_running

Return true of the job appears to be running, false otherwise.

=item log_last_status_warning

Log some messages at warning level showing the last output of bjobs.

=back

=head1 AUTHOR

Mike DeLaurentis (delaurentis@gmail.com)

=head1 COPYRIGHT

Copyright 2012, University of Pennsylvania

