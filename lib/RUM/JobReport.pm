package RUM::JobReport;

use strict;
use warnings;
use autodie;

use base 'RUM::Base';

use Cwd qw(realpath);
use List::Util qw(max);
use FindBin qw($Bin);

FindBin->again;

sub filehandle {
    my ($self) = @_;
    open my $fh, '>>', $self->config->in_output_dir('rum_job_report.txt');
    return $fh;
}

sub print_header {
    my ($self) = @_;

    my $config = $self->config;

    my $fh = $self->filehandle;

    my $rum_home = realpath("$Bin/../");

print $fh <<"EOF";
RUM Information
===============

 Version: $RUM::Pipeline::VERSION
Released: $RUM::Pipeline::RELEASE_DATE
Location: $rum_home

Job Configuration
=================
EOF

    my @name_table = (
        name                  => 'Job name',
        output_dir            => 'Output directory',
        reads                 => 'Input read files',

        paired_end            => 'Paired-end?',
        read_length           => 'Read length',
        variable_length_reads => 'Variable-length reads?',

        rum_index             => 'Index directory',
        genome_bowtie         => 'Bowtie genome index',
        trans_bowtie          => 'Bowtie transcriptome index',
        annotations           => 'Annotations',
        genome_fa             => 'Genome fasta file',
        genome_size           => 'Genome size',

        dna                   => 'DNA mode?',
        genome_only           => 'Genome only (no transcriptome)?',
        junctions             => 'Junctions?',
        preserve_names        => 'Preserve names?',
        quantify              => 'Quantify?',
        strand_specific       => 'Strand-specific?',

        max_insertions        => 'Max insertions',
        min_identity          => 'Min identity',

        num_chunks            => 'Chunks',

        platform              => 'Platform',
        ram                   => 'RAM available (GB)',
        ram_ok                => undef,
        alt_genes             => 'Alternate gene model',
        alt_quant             => undef,
        alt_quant_model       => 'Alternate quantifications',
        bowtie_nu_limit       => 'Limit Bowtie non-unique output?',
        count_mismatches      => 'Count mismatches?',
        input_is_preformatted => undef,
        input_needs_splitting => undef,
        limit_nu_cutoff       => undef,
        nu_limit              => 'Max non-unique mappers per read?',
        min_length            => 'Min alignment length',
        user_quals            => undef,

        blat_max_intron       => 'BLAT max intron',
        blat_min_identity     => 'BLAT min identity',
        blat_only             => 'BLAT only (no bowtie)',
        blat_rep_match        => 'BLAT rep match',
        blat_step_size        => 'BLAT step size',
        blat_tile_size        => 'BLAT tile size',

    );

    my %overrides = (
        junctions => $config->should_do_junctions,
        quantify  => $config->should_quantify
    );

    my %name_for = @name_table;
    
    my @ordered_keys = @name_table[ grep { ! ( $_ % 2 ) } (0 .. $#name_table) ];

    for my $key ($self->config->properties) {
        if ( ! exists $name_for{$key} ) {
            $name_for{$key} = $key;
            push @ordered_keys, $key;
        }
    }

    my @lengths = map { length($_) } values %name_for;
    my $max_len_name = max(@lengths);
    print "max is $max_len_name\n";
    print "Ordered keys are @ordered_keys\n";
        
  PROPERTY: for my $key (@ordered_keys) {
        my $name = $name_for{$key};
        my $val = exists $overrides{$key} ? $overrides{$key} : $self->config->get($key);

        next PROPERTY if ! $name;

        if (ref($val)) {
            $val = Data::Dumper->new([$val])->Indent(0)->Dump if ref($val);
            $val =~ s/\$VAR (?: \d+) \s* = \s*//mx;
        }

        printf $fh "%${max_len_name}s : %s\n", $name, $val;
    }

    print $fh <<"EOF";

Milestones
==========

EOF


}

sub print_start_preproc   { shift->print_milestone("Started preprocessing") }
sub print_start_proc      { shift->print_milestone("Started processing") }
sub print_start_postproc  { shift->print_milestone("Started postprocessing") }
sub print_skip_preproc    { shift->print_milestone("Skipped preprocessing") }
sub print_skip_proc       { shift->print_milestone("Skipped processing") }
sub print_skip_postproc   { shift->print_milestone("Skipped postprocessing") }
sub print_finish_preproc  { shift->print_milestone("Finished preprocessing") }
sub print_finish_proc     { shift->print_milestone("Finished processing") }
sub print_finish_postproc { shift->print_milestone("Finished postprocessing") }


sub print_milestone {
    my ($self, $label) = @_;
    my $fh = $self->filehandle;
    printf $fh "%24s: %s", $label, `date`;
}

1;