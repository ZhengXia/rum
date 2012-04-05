use Test::More tests => 4;
use Test::Exception;

use FindBin qw($Bin);
use lib "$Bin/../lib";
use RUM::Repository;
use RUM::TestUtils;
use RUM::WorkflowRunner;
use File::Path;
use File::Temp qw(tempdir);
use strict;
use warnings;

BEGIN { 
    use_ok('RUM::Workflow', qw(pre post));
}

my $w = RUM::Workflow->new();

$w->add_command(
    name => "code ref of array ref of array refs",
    commands => sub { 
        [["sort", "input", "> intermediate"],
         ["uniq", "-c", "intermediate", "> output"]]
    }
);

$w->add_command(
    name => "array ref of array refs",
    commands => 
        [["sort", "input", "> intermediate"],
         ["uniq", "-c", "intermediate", "> output"]]
);


$w->add_command(
    name => "with tags",
    commands => [[
        "sort", pre("input"), ">", post("output")
    ]]
);



is_deeply([$w->commands("array ref of array refs")],
          ["sort input > intermediate", 
           "uniq -c intermediate > output"],
          "array ref of array refs");

is_deeply([$w->commands("code ref of array ref of array refs")],
          ["sort input > intermediate", 
           "uniq -c intermediate > output"],
          "code ref of array ref of array refs");

my @cmds = $w->commands("with tags");
like($cmds[0], qr/sort input > output/, "with tags");