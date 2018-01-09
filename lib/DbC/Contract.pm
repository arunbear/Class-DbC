package Class::DbC;

use strict;
use Class::Method::Modifiers qw(install_modifier);
use Carp;
use Params::Validate qw(:all);
my %Spec_for;

sub import {
    strict->import();
    my ($class, %arg) = @_;

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
    my ($class, $pkg, $type) = @_;
    
        # use Data::Dump 'pp'; die pp();
    $type ||= 'all';
    my $interface_hash = $Spec_for{$class}{interface};

    foreach my $name (keys %{ $interface_hash }) {
        $pkg->can($name)
          or confess "Class $pkg does not have a '$name' method, which is required by $class";
        $class->_add_pre_conditions($pkg, $name, $interface_hash->{$name}{precond});
        $class->_add_post_conditions($pkg, $name);
    }
    $class->_add_invariants($pkg);
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
    my ($class, $pkg, $name) = @_;
    
}

sub _add_invariants {
    my ($class, $pkg) = @_;
    
}

sub _validate_contract_def {
    validate(@_, {
        precond   => { type => HASHREF, optional => 1 },
        postcond  => { type => HASHREF, optional => 1 },
    });
}

1;
