package Class::DbC;

use strict;
use Class::Method::Modifiers qw(install_modifier);
use Carp;
use Module::Runtime qw(require_module);
use Params::Validate qw(:all);
use Storable qw( dclone );

my %Spec_for;
my %Contract_pkg_for;

my %Contract_validation_spec = (
    type      => HASHREF,
    optional  => 1,
);

sub import {
    strict->import();
    my $class = shift;
    my %arg = validate(@_, {
        interface => \%Contract_validation_spec,
        invariant => \%Contract_validation_spec,
        extends   => { type => SCALAR, optional => 1 },
        clone_with       => { type => CODEREF, optional => 1 },
        constructor_name => { type => SCALAR, default => 'new' },
    });

    my $caller_pkg = (caller)[0];
    $Spec_for{ $caller_pkg } = \%arg;
    _handle_extentions($caller_pkg, $arg{extends});
    _add_governor($caller_pkg);
}

sub merge {
    my ($h1, $h2) = @_;

    foreach my $k (keys %{ $h2 }) {
        if (exists $h1->{$k}) {
            if (   ref $h1->{$k} eq 'HASH'
                && ref $h2->{$k} eq 'HASH'
            ) {
                merge($h1->{$k}, $h2->{$k});
            }
        }
        else {
            $h1->{$k} = $h2->{$k};
        }
    }
}

sub _handle_extentions {
    my ($pkg, $super) = @_;

    return unless $super;

    require_module($super);
    merge($Spec_for{$pkg}, $Spec_for{$super});
}

sub _add_governor {
    my ($pkg) = @_;

    no strict 'refs';
    *{"${pkg}::govern"} = \&_govern;
}

sub _govern {
    my $class = shift;
    my ($pkg, $opt) = validate_pos(@_,
        { type => SCALAR },
        { type => HASHREF, default => { all => 1 } },
    );
    _validate_govern_options(%$opt);
    
    if ($opt->{all}
        || ($opt->{emulate} && scalar keys %$opt == 1 )) {
        $opt->{$_} = 1 for qw/pre post invariant/;
    }

    my $interface_hash = $Spec_for{$class}{interface};
    scalar keys %$interface_hash > 0
      or confess "Contract $class has no specified methods";

    my $invariant_hash = $Spec_for{$class}{invariant};

    my $contract_pkg_prefix = _contract_pkg_prefix($class, $pkg);

    my $target_pkg = $pkg;
    my $emulated = $pkg;

    if ($opt->{emulate}) {
        my @types = grep { $opt->{$_} } qw[invariant post pre];
        my $key = join '_', @types;

        $Contract_pkg_for{$class}{$pkg}{$key} = "${contract_pkg_prefix}$key";
        ($emulated, $target_pkg) = _emulate($class, $pkg, $key);
    }
    foreach my $name (keys %{ $interface_hash }) {
        $pkg->can($name)
          or confess "Class $pkg does not have a '$name' method, which is required by $class";

        if ($opt->{pre}) {
            my $contract = $interface_hash->{$name};
            _validate_contract_definition(%$contract);
            _add_pre_conditions($class, $target_pkg, $name, $contract->{precond});
        }
        if ($opt->{post}) {
            my $contract = $interface_hash->{$name};
            _validate_contract_definition(%$contract);
            _add_post_conditions($class, $target_pkg, $name, $contract->{postcond});
        }
        if ($opt->{invariant} && %$invariant_hash) {
            _add_invariants($class, $target_pkg, $name, $invariant_hash, $emulated);
        }
    }
    if ($opt->{emulate}) {
        return $emulated;
    }
}

sub _validate_contract_definition {
    validate(@_, {
        precond  => \%Contract_validation_spec,
        postcond => \%Contract_validation_spec,
    });
}

sub _contract_pkg_prefix {
    my ($class, $pkg) = @_;

    sprintf '%s_%s_%s_', __PACKAGE__, $class, $pkg;
}

sub _add_pre_conditions {
    my ($class, $pkg, $name, $pre_cond_hash) = @_;

    return unless $pre_cond_hash;

    my $guard = sub {
        foreach my $desc (keys %{ $pre_cond_hash }) {
            my $sub = $pre_cond_hash->{$desc};
            ref $sub eq 'CODE'
              or confess "precondition of $class, '$desc' on '$name' is not a code ref";
            $sub->(@_)
              or confess "Precondition '$desc' on '$name', mandated by $class is not satisfied";
        }
    };
    install_modifier($pkg, 'before', $name, $guard);
}

sub _add_post_conditions {
    my ($class, $pkg, $name, $post_cond_hash) = @_;
    
    return unless $post_cond_hash;

    my $cloner = $Spec_for{$class}{clone_with} || \&dclone;

    my $guard = sub {
        my $orig = shift;
        my $self = shift;

        my @old;
        my @invocant = ($self);

        my $type = ref $self ? 'object' : 'class';
        if ($type eq 'object') {
            @old = ( $cloner->($self) );
        }
        my $results = [$orig->($self, @_)];
        my $results_to_check = $results;

        if ($type eq 'class' && $name eq $Spec_for{$class}{constructor_name}) {
            $results_to_check = $results->[0];
            @invocant = ();
        }

        foreach my $desc (keys %{ $post_cond_hash }) {
            my $sub = $post_cond_hash->{$desc};
            ref $sub eq 'CODE'
              or confess "postcondition of $class, '$desc' on '$name' is not a code ref";

            $sub->(@invocant, @old, $results_to_check, @_)
              or confess "Method '$pkg::$name' failed postcondition '$desc' mandated by $class";
        }
        return unless defined wantarray;
        return wantarray ? @$results : $results->[0];
    };
    install_modifier($pkg, 'around', $name, $guard);
}

sub _add_invariants {
    my ($class, $pkg, $name, $invariant_hash, $emulated) = @_;
    
    my $guard = sub {
        # skip methods called by the invariant
        return if (caller 1)[0] eq $class;
        return if (caller 2)[0] eq $class;

        my $self = shift;
        return unless ref $self;

        foreach my $desc (keys %{ $invariant_hash }) {
            my $sub = $invariant_hash->{$desc};
            ref $sub eq 'CODE'
              or confess "invariant of $class, '$desc' is not a code ref";
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

sub _emulate {
    my ($class, $pkg, $key) = @_;

    my $contract_pkg = $Contract_pkg_for{$class}{$pkg}{$key};
    _add_super($pkg, $contract_pkg);

    my $emulated = sprintf '%s_emulated', _contract_pkg_prefix($class, $pkg);
    _setup_forwards($class, $pkg, $emulated, $contract_pkg);

    return ($emulated, $contract_pkg);
}

sub _add_super {
    my ($super, $pkg) = @_;

    no strict 'refs';

    if ( @{"${pkg}::ISA"} ) {
        my $between = shift @{"${pkg}::ISA"};
        unshift @{"${pkg}::ISA"}, $super;
        _add_super($between, $super);
    }
    else {
        unshift @{"${pkg}::ISA"}, $super;
    }
}

sub _setup_forwards {
    my ($class, $orig_pkg, $from_pkg, $to_pkg) = @_;

    my $version;
    {
        no strict 'refs';
        ${"${from_pkg}::Target"} = $to_pkg;
        $version = ${"${from_pkg}::VERSION"};
    }

    if ( ! $version ) {

        my $interface_hash = $Spec_for{$class}{interface};
        my @code = (
            "package $from_pkg;",
            "our \$VERSION = 1;",
            "our \@ISA = ('$orig_pkg');",
            "our \$Target;",
        );

        foreach my $name (keys %{ $interface_hash }) {

            push @code, qq[
                sub $name {
                    \$Target->can('$name')->(\@_);
                }
            ];
        }
        eval join "\n", @code, '1;';
    }
}

sub _validate_govern_options {
    validate(@_, {
        all       => { type => BOOLEAN, optional => 1 },
        pre       => { type => BOOLEAN, optional => 1 },
        post      => { type => BOOLEAN, optional => 1 },
        invariant => { type => BOOLEAN, optional => 1 },
        emulate   => { type => BOOLEAN, optional => 1 },
    });
}

1;

__END__

=head1 NAME

Class::DbC - Add Design By Contract easily and flexibly to existing code.

=head1 SYNOPSIS

    # Some existing class
    package Example;

    sub new {
        # code not shown
    }

    sub do_something {
        # code not shown
    }

    # A contract
    package Example::Contract;

    use Class::DbC
        interface => {
            do_something => {
                precond => {
                    a_description => sub {
                        # return true if precondition is satistifed
                    },
                },
                postcond => {
                    a_description => sub {
                        # return true if postcondition is satistifed
                    },
                }
            },
            new => {
                # contracts not shown
            }
        },
        invariant => {
            a_description => sub {
                # return true if invariant is satistifed
            },
        },
    ;

    # A program
    package main;
    use Example;
    use Example::Contract;

    Example::Contract->govern('Example');

    my $e = Example->new(...);
    $e->do_something();

=head1 DESCRIPTION

Class::DbC allows Eiffel style L<Contracts|https://www.eiffel.com/values/design-by-contract/introduction/> to be easily and flexibly added to existing code.

These contracts are separate from the code that they verify, and they can be turned on or not (or even off) at runtime.


=head1 REQUIRES

L<Class::Method::Modifiers> 

L<Module::Runtime> 

L<Params::Validate> 

=head1 USAGE

=head2 Defining a contract

A contract is a package defined by using Class::DbC and providing a configuration hash with the following keys

=head3 interface

The value of this key is a hash that describes the interface (methods called by users of the class) of the class being verified.

This hash maps the name of a method to a contract hash which in turn has the following keys:

=head4 precond (preconditions)

The corresponding value is a hash of description => subroutine pairs.

Each such subroutine is a method that receives the same parameters as the method the precondition is attached to,
and returns either a true or false result. If false is returned, an exception is raised indicating which precondition
was violated.

A precondition is an assertion that is run before a given method, that defines one or more conditions that must
be met in order for the given method to be callable.

=head4 postcond (postconditions)

The corresponding value is a hash of description => subroutine pairs.

Each such subroutine is a method that receives the following parameters: the object as it is after the method call,
the object as it was before the method call, the results of the method call stored in array ref, and any parameters
that were passed to the method.

The subroutine should return either a true or false result. If false is returned, an exception is raised indicating which postcondition was violated.

A postcondition is an assertion that is run after a given method, that defines one or more conditions that must
be met after the given method has been called.

=head3 invariant

The value of this key is a hash of description => subroutine pairs that describes the invariants of the class being verified.

Each such subroutine is a method that receives the object as its only parameter, and returns either a true or false result. If false is returned, an exception is raised indicating which invariant
was violated.

An invariant is an assertion that is run before and after every method in the interface, that defines one or more conditions that must be met before and after the method has been called.

=head3 extends

The value of this key is the name of another contract (the parent) which the one being defined (the child) will extend i.e. any specifications in the parent that are not found in the child contract will be copied to the child contract.

=head2 Applying a contract

Once defined, a contract package is able to call its C<govern> method to verify the behaviour of the target class.

=head3 govern(TARGET, [{ OPTIONS }])

The C<govern> class method expects to be given the name of the target class and an optional hashref of boolean options which are as follows

=head4 pre

Preconditions wil be enabled if this value is true.

=head4 post

Postconditions wil be enabled if this value is true.

=head4 invariant

Invariants wil be enabled if this value is true.

=head4 all

All contract types wil be enabled if this value is true. This is the assumed behaviour if no options are given.

=head4 emulate

If this option is true, C<govern> will not modify the target class, but will return a new class that emulates the target class but is governed by the contract. This emulation can have its contracts adjusted at run time by making further calls to C<govern>.

=head1 EXAMPLES

=head2 Defining a contract
