package RUM::Iterator;

use strict;
use warnings;

use Carp;
use Scalar::Util qw(blessed);

sub new {
    my ($class, $x) = @_;
    
    my $f;

    if (ref($x) =~ /^ARRAY/) {
        my $i = 0;
        $f = sub { $i <= $#$x ? $x->[$i++] : undef };
    }
    
    elsif (ref($x) =~ /^CODE/) {
        $f = $x;
    }

    return bless { next_val => $f }, $class if $f;

    return bless $x || {}, $class;

}

sub group_by {
    my $self = shift;
    my $group_fn = shift;
    my $merge_fn = shift || sub { RUM::Iterator->new(shift) };
    
    my $val = $self->next_val;
    
    my $it = sub {
        return unless $val;
        
        my @group = ($val);
        
        while ($val = $self->next_val) {
            last unless $group_fn->($group[0], $val);
            push @group, $val;
        }
        return $merge_fn->(\@group);
    };

    return RUM::Iterator->new($it);
}

sub next_val {
    my ($self) = @_;
    $self->{next_val}->();
}

sub take {
    my ($self) = @_;
    $self->next_val;
}

sub peekable {
    my ($self) = @_;
    return RUM::Iterator::Buffered->new($self);
}

sub to_array {
    my ($self) = @_;
    my @result;
    while (defined(my $item = $self->next_val)) {
        push @result, $item;
    }
    return \@result;
}

sub imap {
    my $self = shift;
    my $f    = shift;
    my $next_item = sub {
        my $item = $self->next_val;
        return defined($item) ? $f->($item) : undef;
    };
    return RUM::Iterator->new($next_item);
}

sub ireduce {
    my $self = shift;
    my $code = shift;

    my @args = @_;

    my $type = Scalar::Util::reftype($code);

    unless($type and $type eq 'CODE') {
        Carp::croak("Not a subroutine reference");
    }
    no strict 'refs';
    
    use vars qw($a $b);
    
    my $caller = caller;
    local(*{$caller."::a"}) = \my $a;
    local(*{$caller."::b"}) = \my $b;
    
    $a = @args ? $args[0] : $self->next_val;

    while ($b = $self->next_val) {
        $a = &{$code}();
    }
    
    return $a;
}


sub igrep {
    my $self = shift;
    my $f    = shift;
    my $next_item = sub {
        my $item;
        do { $item = $self->next_val } until ((!defined($item)) || $f->($item));
        return $item;
    };
    return RUM::Iterator->new($next_item);
}

sub append {
    shift unless ref $_[0];
    my ($self, @others) = @_;

    if (!@others) {
        return $self;
    }

    if (@others == 1) {
        my $other = shift @others;
        my $f = sub {
            my $next = $self->next_val;
            return $next if defined $next; 
            return $other->next_val;
        };
        return RUM::Iterator->new($f);
    }

    else {
        for my $other (@others) {
            $self = $self->append($other);
        }
        return $self;
    }
}

package RUM::Iterator::Buffered;

use strict;
use warnings;

use Carp;
use Scalar::Util qw(blessed);
use Data::Dumper;

use base 'RUM::Iterator';

sub new {
    my ($class, $source) = @_;
    croak "Source must be a RUM::Iterator, not $source" unless blessed($source) && $source->isa("RUM::Iterator");
    my $self = $class->SUPER::new;

    $self->{buffer} = [];
    $self->{source} = $source;
    
    return $self;
}

sub source {
    return shift->{source};
}

sub buffer { shift->{buffer} };

sub next_val {
    my ($self) = @_;
    $self->fill(1);
    return shift @{ $self->buffer };
}

sub fill {
    my ($self, $n) = @_;

    my $buffer = $self->buffer;

    while (@{ $buffer } - 1 < $n) {
        if (defined(my $val = $self->source->next_val)) {
            push @$buffer, $val;
        }
        else {
            return;
        }
    }
}

sub peek {
    my $self = shift;
    my $skip = shift || 0;
    $self->fill($skip);
    return $self->buffer->[$skip];
}

sub merge {
    my ($self, $cmp, $other, $handle_dup) = @_;
    $handle_dup ||= sub { shift };
    if ( ! $other->can('peek')) {
        die "Can only merge with a peekable iterator";
    }

    my @buffer;

    my $f = sub {
        
        if (@buffer) {
            return shift @buffer;
        }

        my $mine   = $self->peek;
        my $theirs = $other->peek;
        
        # If we've exhausted both lists, return undef to indicate that
        # the merged iterator is exhausted.
        return if ! ( $mine || $theirs );

        # If we've exhausted my list, we need to pick the next item
        # from the other list. If we've exhausted the other list, pick
        # the next iterm from my list. Otherwise we'll need to compare
        # the next item from both lists.
        my $val = !$mine &&  $theirs ?  1
        :          $mine && !$theirs ? -1
        :                               $cmp->($mine, $theirs);

        my @group;
        
        if ($val <= 0) {
            push @group, $self->next_val;
        }
        if ($val >= 0) {
            push @group, $other->next_val;
        }
        @buffer = $handle_dup->(\@group);
        return shift @buffer;
    };
    return RUM::Iterator->new($f);
}

1;
