package Class::DbC;

use strict;
use Class::Method::Modifiers qw(install_modifier);
use Carp;
use Params::Validate qw(:all);
use Storable qw( dclone );

my %Spec_for;

sub import {
    strict->import();
    my ($class, %arg) = @_;

    $arg{constructor_name} ||= 'new';

    my $caller_pkg = (caller)[0];
    $Spec_for{ $caller_pkg } = \%arg;
    _add_governor($caller_pkg);
}

sub _add_governor {
    my ($pkg) = @_;

    no strict 'refs';
    *{"${pkg}::govern"} = \&_governor;
    *{"${pkg}::_add_pre_conditions"} = \&_add_pre_conditions;
    *{"${pkg}::_add_post_conditions"} = \&_add_post_conditions;
    *{"${pkg}::_add_invariants"} = \&_add_invariants;
}

sub _governor {
    my $class = shift;
    my ($pkg, $opt) = validate_pos(@_,
        { type => SCALAR },
        { type => HASHREF, default => { all => 1 } },
    );
    
    if ($opt->{all}) {
        $opt->{$_} = 1 for qw/pre post invariant/;
    }

    my $interface_hash = $Spec_for{$class}{interface};
    my $invariant_hash = $Spec_for{$class}{invariant};

    foreach my $name (keys %{ $interface_hash }) {
        $pkg->can($name)
          or confess "Class $pkg does not have a '$name' method, which is required by $class";

        if ($opt->{pre}) {
            $class->_add_pre_conditions($pkg, $name, $interface_hash->{$name}{precond});
        }
        if ($opt->{post}) {
            $class->_add_post_conditions($pkg, $name, $interface_hash->{$name}{postcond});
        }
        if ($opt->{invariant}) {
            $class->_add_invariants($pkg, $name, $invariant_hash);
        }
    }
}

sub _add_pre_conditions {
    my ($class, $pkg, $name, $pre_cond_hash) = @_;

    return unless $pre_cond_hash;

    my $guard = sub {
        foreach my $desc (keys %{ $pre_cond_hash }) {
            my $sub = $pre_cond_hash->{$desc};
            $sub->(@_)
              or confess "Method '$pkg::$name' failed precondition '$desc' mandated by $class";
        }
    };
    install_modifier($pkg, 'before', $name, $guard);
}

sub _add_post_conditions {
    my ($class, $pkg, $name, $post_cond_hash) = @_;
    
    return unless $post_cond_hash;

    my $guard = sub {
        my $orig = shift;
        my $self = shift;

        my @old;
        my @invocant = ($self);

        my $type = ref $self ? 'object' : 'class';
        if ($type eq 'object') {
            @old = ( dclone($self) );
        }
        my $results = [$orig->($self, @_)];
        my $results_to_check = $results;

        if ($type eq 'class' && $name eq $Spec_for{$class}{constructor_name}) {
            $results_to_check = $results->[0];
            @invocant = ();
        }

        foreach my $desc (keys %{ $post_cond_hash }) {
            my $sub = $post_cond_hash->{$desc};
            $sub->(@invocant, @old, $results_to_check, @_)
              or confess "Method '$pkg::$name' failed postcondition '$desc' mandated by $class";
        }
        return unless defined wantarray;
        return wantarray ? @$results : $results->[0];
    };
    install_modifier($pkg, 'around', $name, $guard);
}

sub _add_invariants {
    my ($class, $pkg, $name, $invariant_hash) = @_;
    
    my $guard = sub {
        # skip methods called by the invariant
        return if (caller 1)[0] eq $class;

        my $self = shift;
        return unless ref $self;

        foreach my $desc (keys %{ $invariant_hash }) {
            my $sub = $invariant_hash->{$desc};
            $sub->($self)
              or confess "Invariant '$desc' mandated by $class has been violated";
        }
    };
    if ( $name eq $Spec_for{$class}{constructor_name} ) {
        my $around = sub {
            my $orig  = shift;
            my $class = shift;
            my $obj = $orig->($class, @_);
            $guard->($obj);
            return $obj;
        };
        install_modifier($pkg, 'around', $name, $around);
    }
    else {
        foreach my $type ( qw[before after] ) {
            install_modifier($pkg, $type, $name, $guard);
        }
    }
}

sub _validate_contract_def {
    validate(@_, {
        precond   => { type => HASHREF, optional => 1 },
        postcond  => { type => HASHREF, optional => 1 },
    });
}

1;
