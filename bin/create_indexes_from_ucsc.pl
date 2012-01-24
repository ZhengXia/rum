#!/usr/bin/perl

# Written by Gregory R. Grant
# Universiry of Pennsylvania, 2010

use FindBin qw($Bin);
use lib "$Bin/../lib";

use Getopt::Long;

use RUM::Index qw(run_bowtie);
use RUM::Transform qw(transform_file);
use RUM::Transform::Fasta qw(:transforms);
use RUM::Transform::GeneInfo qw(:transforms);

use autodie;

my $debug = 0;
$result == GetOptions("debug" => \$debug);

if(@ARGV < 1) {
    die "
Usage: create_indexes_from_ucsc.pl <NAME_genome.txt> <NAME_refseq_ucsc>

This script is part of the pipeline of scripts used to create RUM indexes.
For more information see the library file: 'how2setup_genome-indexes_forPipeline.txt'.

Genome fasta file must be formatted as described in:
'how2setup_genome-indexes_forPipeline.txt'.

";
}

$infile = $ARGV[0];
if(!($infile =~ /\.txt$/)) {
    die "ERROR: the <NAME_gnome.txt> file has to end in '.txt', yours doesn't...\n";
}

# Strip extra characters off the headers, join adjacent sequence lines
# together, and sort the genome by chromosome.
my $F1 = $infile;
my $F2 = $infile;
my $F3 = $infile;
$F1 =~ s/.txt$/.fa/;
$F2 =~ s/.txt$/_one-line-seqs_temp.fa/;
$F3 =~ s/.txt$/_one-line-seqs.fa/;

transform_file \&modify_fasta_header_for_genome_seq_database, $infile, $F1;
transform_file \&modify_fa_to_have_seq_on_one_line, $F1, $F2;
transform_file \&sort_genome_fa_by_chr, $F2, $F3;

unless ($debug) {
  unlink foreach ($F1, $F2);
}

$NAME = $ARGV[1];

$N1 = $NAME . "_gene_info_orig.txt";
$N2 = $F3;
$N3 = $NAME . "_genes_unsorted.fa";
$N4 = $NAME . "_gene_info_unsorted.txt";
$N5 = $NAME . "_genes.fa";
$N6 = $NAME . "_gene_info.txt";

transform_file \&make_master_file_of_genes,
  "gene_info_files", 
  "gene_info_merged_unsorted.txt";

transform_file \&fix_geneinfofile_for_neg_introns, 
  "gene_info_merged_unsorted.txt", 
  "gene_info_merged_unsorted_fixed.txt",
  5, 6, 4;

transform_file \&sort_geneinfofile,
  "gene_info_merged_unsorted_fixed.txt",
  "gene_info_merged_sorted_fixed.txt";

transform_file \&make_ids_unique4geneinfofile,
  "gene_info_merged_sorted_fixed.txt", $N1;

transform_file \&get_master_list_of_exons_from_geneinfofile,
  $N1, "master_list_of_exons.txt";

# TODO: Is this step necessary? I think $N2 already has sequences all on one line
#transform_file \&modify_fa_to_have_seq_on_one_line,
#  $N2, "temp.fa";
system "cp", $N2, "temp.fa";

print STDERR "perl $Bin/make_fasta_files_for_master_list_of_genes.pl temp.fa master_list_of_exons.txt $N1 $N4 > $N3\n";
`perl $Bin/make_fasta_files_for_master_list_of_genes.pl temp.fa master_list_of_exons.txt $N1 $N4 > $N3`;

exit;

print STDERR "perl $Bin/../sort_gene_info.pl $N4 > $N6\n";
`perl $Bin/../sort_gene_info.pl $N4 > $N6`;

print STDERR "perl $Bin/../sort_gene_fa_by_chr.pl $N3 > $N5\n";
`perl $Bin/../sort_gene_fa_by_chr.pl $N3 > $N5`;

unless ($debug) {
  unlink for ($N3, $N4, "temp.fa");
}

exit;

$N6 =~ /^([^_]+)_/;
$organism = $1;

# write rum.config file:
$config = "indexes/$N6\n";
$config = $config . "bin/bowtie\n";
$config = $config . "bin/blat\n";
$config = $config . "bin/mdust\n";
$config = $config . "indexes/$organism" . "_genome\n";
$config = $config . "indexes/$organism" . "_genes\n";
$config = $config . "indexes/$N2\n";
$config = $config . "scripts\n";
$config = $config . "lib\n";
$configfile = "rum.config_" . $organism;
open(OUTFILE, ">$configfile");
print OUTFILE $config;
close(OUTFILE);

unless ($debug) {
  unlink("gene_info_merged_unsorted.txt");
  unlink("gene_info_merged_unsorted_fixed.txt");
  unlink("gene_info_merged_sorted_fixed.txt");
  unlink("master_list_of_exons.txt");
}

# run bowtie on genes index
print STDERR "\nRunning bowtie on the gene index, please wait...\n\n";
run_bowtie($N5, $organism . "_genes");

# run bowtie on genome index
print STDERR "running bowtie on the genome index, please wait this can take some time...\n\n";
run_bowtie($F3, $organism . "_genome");

print STDERR "ok, all done...\n\n";