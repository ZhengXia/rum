use strict;
use warnings;

use Test::More tests => 19;
use Test::Exception;

use FindBin qw($Bin);
use File::Temp qw(tempdir);
use lib "$Bin/../lib";
use RUM::Cluster::SGE;
use RUM::Config;

BEGIN { use_ok('RUM::Cluster::SGE') or BAIL_OUT "Couldn't load RUM::Cluster::SGE" }

my $class = "RUM::Cluster::SGE";
is ($class->parse_qsub_out(
    'Your job-array 634877.1-10:1 ("sh") has been submitted'),
    634877, 
    "job-array output");

is ($class->parse_qsub_out(
    'Your job 634877 ("sh") has been submitted'),
    634877, 
    "job output");


my $QSTAT_GROUPED = <<'EOF';
job-ID  prior   name       user         state submit/start at     queue                          slots ja-task-ID
-----------------------------------------------------------------------------------------------------------------
 628724 0.36365 QLOGIN     midel        r     04/05/2012 08:40:17 all.q@node-r1-u2-c33-p11-o2.lo     1
 636537 0.25420 QLOGIN     midel        r     04/11/2012 09:22:20 all.q@node-r1-u2-c33-p11-o2.lo     1
 636813 0.00000 sh         midel        qw    04/11/2012 14:55:50                                    1 1-3:1
 636814 0.00000 sh         midel        hqw   04/11/2012 14:55:50                                    1
EOF

my $QSTAT_UNGROUPED = <<'EOF';
job-ID  prior   name       user         state submit/start at     queue                          slots ja-task-ID 
-----------------------------------------------------------------------------------------------------------------
 628724 0.36365 QLOGIN     midel        r     04/05/2012 08:40:17 all.q@node-r1-u2-c33-p11-o2.lo     1        
 636537 0.25420 QLOGIN     midel        r     04/11/2012 09:22:20 all.q@node-r1-u2-c33-p11-o2.lo     1        
 636813 0.25000 sh         midel        r     04/11/2012 14:56:11 all.q@node-r2-u19-c16-p12-o13.     1 1
 636813 0.25000 sh         midel        r     04/11/2012 14:56:11 all.q@node-r1-u14-c21-p11-o11.     1 2
 636813 0.25000 sh         midel        r     04/11/2012 14:56:11 all.q@node-r1-u31-c6-p10-o22.l     1 3
 636814 0.00000 sh         midel        hqw   04/11/2012 14:55:50                                    1      
EOF


is_deeply($class->parse_qstat_out($QSTAT_UNGROUPED),
          [{job_id => 628724, state => 'r'},
           {job_id => 636537, state => 'r'},
           {job_id => 636813, state => 'r', task_id => 1},
           {job_id => 636813, state => 'r', task_id => 2},
           {job_id => 636813, state => 'r', task_id => 3},
           {job_id => 636814, state => 'hqw'}],
          "qstat ungrouped");

is_deeply($class->parse_qstat_out($QSTAT_GROUPED),
          [{job_id => 628724, state => 'r'},
           {job_id => 636537, state => 'r'},
           {job_id => 636813, state => 'qw', task_id => 1},
           {job_id => 636813, state => 'qw', task_id => 2},
           {job_id => 636813, state => 'qw', task_id => 3},
           {job_id => 636814, state => 'hqw'}],
          "qstat ungrouped");

my $sge = RUM::Cluster::SGE->new(RUM::Config->new(output_dir => tempdir(CLEANUP => 1)));

push @{ $sge->preproc_jids }, 628724;
is_deeply($sge->preproc_jids, [628724], "Get preproc job id");
$sge->_build_job_states($sge->parse_qstat_out($QSTAT_UNGROUPED));
is($sge->{job_states}{628724}, 'r', "Set state to r");
is($sge->_job_state(628724), 'r', "Can get job state");

ok($sge->preproc_ok, "Preproc is ok");
ok( ! $sge->proc_ok(1), "Proc is not ok");

push @{ $sge->proc_jids }, 636813;
is_deeply($sge->proc_jids, [636813], "Get proc job id");
$sge->_build_job_states($sge->parse_qstat_out($QSTAT_UNGROUPED));
is_deeply($sge->{job_states}{636813}, [undef, 'r', 'r', 'r'], "Set state to r");
is($sge->_job_state(636813, 3), 'r', "Can get job state");
ok($sge->proc_ok(3), "Proc chunk is ok");
ok(! $sge->proc_ok(4), "Unknown chunk is not ok");

push @{ $sge->postproc_jids }, 636814;
is_deeply($sge->postproc_jids, [636814], "Get postproc job id");
$sge->_build_job_states($sge->parse_qstat_out($QSTAT_UNGROUPED));
is($sge->{job_states}{636814}, 'hqw', "Set state to hqw");
is($sge->_job_state(636814), 'hqw', "Can get job state");
ok($sge->postproc_ok, "Postproc is ok");

