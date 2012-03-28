#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 4;
use FindBin qw($Bin);
use File::Copy;
use lib "$Bin/../lib";
use_ok "RUM::Script::FinalCleanup";
use RUM::TestUtils;

my $unique_in = "$INPUT_DIR/RUM_Unique_temp.1";
my $non_unique_in = "$INPUT_DIR/RUM_NU_temp.1";
my $non_unique_out = temp_filename(TEMPLATE => "non-unique.XXXXXX");
my $unique_out = temp_filename(TEMPLATE => "unique.XXXXXX");
my $sam_header_out = temp_filename(TEMPLATE => "sam-headers.XXXXXX");

my $genome = "_testing/indexes/Arabidopsis_thaliana_TAIR10_genome_one-line-seqs.fa";

SKIP: {
    skip "Don't have arabidopsis index", 3 unless -e $genome;

    for my $type (qw(paired)) {
        @ARGV = ("--unique-in", $unique_in,
                 "--non-unique-in", $non_unique_in, 
                 "--unique-out", $unique_out,
                 "--non-unique-out", $non_unique_out,
                 "--genome", $genome,
                 "--sam-header-out", $sam_header_out,
                 "--faok",
                 "-q");
        RUM::Script::FinalCleanup->main();
        no_diffs($unique_out,     "$EXPECTED_DIR/RUM_Unique_temp2.1");
        no_diffs($non_unique_out, "$EXPECTED_DIR/RUM_NU_temp2.1");
        no_diffs($sam_header_out, "$EXPECTED_DIR/sam_header.1");
    }
}