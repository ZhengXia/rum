#!/usr/bin/perl

# Written by Gregory R. Grant
# University of Pennsylvania, 2010

if(@ARGV < 2) {
    die "
Usage: sam2xs-flag.pl <sam file> <genome seq>

";
}

$genome_sequence = $ARGV[1];

$|=1;

# Splice Junctions:
# ----------------
# The Canonical:
#  GTAG
$donor[0] = "GT";
$donor_rev[0] = "AC";
$acceptor[0] = "AG";
$acceptor_rev[0] = "CT";
# Other Characterized:
#  GCAG
$donor[1] = "GC";
$donor_rev[1] = "GC";
$acceptor[1] = "AG";
$acceptor_rev[1] = "CT";
#  GCTG
$donor[2] = "GC";
$donor_rev[2] = "GC";
$acceptor[2] = "TG";
$acceptor_rev[2] = "CA";
#  GCAA
$donor[3] = "GC";
$donor_rev[3] = "GC";
$acceptor[3] = "AA";
$acceptor_rev[3] = "TT";
#  GCCG
$donor[4] = "GC";
$donor_rev[4] = "GC";
$acceptor[4] = "CG";
$acceptor_rev[4] = "CG";
#  GTTG
$donor[5] = "GT";
$donor_rev[5] = "AC";
$acceptor[5] = "TG";
$acceptor_rev[5] = "CA";
#  GTAA
$donor[6] = "GT";
$donor_rev[6] = "AC";
$acceptor[6] = "AA";
$acceptor_rev[6] = "TT";
# U12-dependent:
#  ATAC
$donor[7] = "AT";
$donor_rev[7] = "AT";
$acceptor[7] = "AC";
$acceptor_rev[7] = "GT";
#  ATAA
$donor[8] = "AT";
$donor_rev[8] = "AT";
$acceptor[8] = "AA";
$acceptor_rev[8] = "TT";
#  ATAG
$donor[9] = "AT";
$donor_rev[9] = "AT";
$acceptor[9] = "AG";
$acceptor_rev[9] = "CT";
#  ATAT
$donor[10] = "AT";
$donor_rev[10] = "AT";
$acceptor[10] = "AT";
$acceptor_rev[10] = "AT";

#  TAGA
$donor[11] = "TA";
$donor_rev[11] = "TA";
$acceptor[11] = "GA";
$acceptor_rev[11] = "TC";

open(GENOMESEQ, $genome_sequence) or die "\nError: in script make_RUM_junctions_file.pl: cannot open file '$genome_sequence' for reading\n\n";
while($line = <GENOMESEQ>) {
    chomp($line);
    $line =~ s/^>//;
    $name = $line;
    $line = <GENOMESEQ>;
    chomp($line);
    $CHR2SEQ{$name} = $line;
}
close(GENOMESEQ);

open(INFILE, $ARGV[0]) or die "\nError: Cannot open '$ARGV[0]' for reading\n\n";
$line = <INFILE>;
while($line =~ /^@..\t/) {
    print $line;
    $line = <INFILE>;
}
while (defined $line) {
    chomp $line;
    my (undef, undef, $chr, $current_loc, undef, $cigar, undef) 
        = split /\t/, $line;
    my $intron_at_span;
    $chr =~ s/:.*//;

    # Examine the CIGAR string to build up a list of spans, and mark a
    # span (in $intron_at_span) that is over an intron.
    my @spans;
    while($cigar =~ /^(\d+)([^\d])/) {
	$num = $1;
	$type = $2;
	if ($type eq 'M') {
	    $E = $current_loc + $num - 1;
            push @spans, [$current_loc, $E];
	    $current_loc = $E;
	}
	if ($type eq 'D' || $type eq 'N') {
	    $current_loc = $current_loc + $num + 1;
	}
        if ($type eq 'N') {
	    $intron_at_span = $#spans;
	}
	if ($type eq 'I') {
	    $current_loc++;
	}
	$cigar =~ s/^\d+[^\d]//;
    }

    $XS_tag = "";
    if(defined($intron_at_span)) {
	$istart = $spans[$intron_at_span    ][1] + 1;
        $iend   = $spans[$intron_at_span + 1][0] - 1;
	$splice_signal_upstream   = substr $CHR2SEQ{$chr}, $istart - 1, 2;
	$splice_signal_downstream = substr $CHR2SEQ{$chr}, $iend   - 2, 2;
        
	for ($sig=0; $sig<@donor; $sig++) {
	    if ($splice_signal_upstream   eq $donor[$sig] && 
                $splice_signal_downstream eq $acceptor[$sig]) {
                $XS_tag = "\tXS:A:+";
            }
            elsif ($splice_signal_upstream   eq $acceptor_rev[$sig] &&
                   $splice_signal_downstream eq $donor_rev[$sig]) {
                $XS_tag = "\tXS:A:-";
            }
	}
    }
    print "$line$XS_tag\n";
    $line = <INFILE>;
}
