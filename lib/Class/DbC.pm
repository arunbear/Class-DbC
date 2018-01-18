package Class::DbC;

use strict;
use Class::Method::Modifiers qw(install_modifier);
use Carp;
use Params::Validate qw(:all);
use Storable qw( dclone );

my %Spec_for;
my %Contract_pkg_for;

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
}

sub _governor {
    my $class = shift;
    my ($pkg, $opt) = validate_pos(@_,
        { type => SCALAR },
        { type => HASHREF, default => { all => 1 } },
    );
    
    if ($opt->{all}
        || ($opt->{emulate} && scalar keys %$opt == 1 )) {
        $opt->{$_} = 1 for qw/pre post invariant/;
    }

    my $interface_hash = $Spec_for{$class}{interface};
    my $invariant_hash = $Spec_for{$class}{invariant};
    my $contract_pkg_prefix = _contract_pkg_prefix($class, $pkg);

    my $target_pkg = $pkg;
    my $emulated = $pkg;

    if ($opt->{emulate}) {
        my @types = grep { $opt->{$_} } qw[invariant post pre];
        if (@types) {
            my $key = join '_', @types;
            $Contract_pkg_for{$class}{$pkg}{$key} = "${contract_pkg_prefix}$key";
            ($emulated, $target_pkg) = _emulate($class, $pkg, $key);
        }
    }
    foreach my $name (keys %{ $interface_hash }) {
        $pkg->can($name)
          or confess "Class $pkg does not have a '$name' method, which is required by $class";

        if ($opt->{pre}) {
            _add_pre_conditions($class, $target_pkg, $name, $interface_hash->{$name}{precond});
        }
        if ($opt->{post}) {
            _add_post_conditions($class, $target_pkg, $name, $interface_hash->{$name}{postcond});
        }
        if ($opt->{invariant} && %$invariant_hash) {
            _add_invariants($class, $target_pkg, $name, $invariant_hash, $emulated);
        }
    }
    if ($opt->{emulate}) {
        return $emulated;
    }
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
    my ($class, $pkg, $name, $invariant_hash, $emulated) = @_;
    
    my $guard = sub {
        # skip methods called by the invariant
        return if (caller 1)[0] eq $class;
        return if (caller 2)[0] eq $class;

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

sub _emulate {
    my ($class, $pkg, $key) = @_;

    my $contract_pkg = $Contract_pkg_for{$class}{$pkg}{$key};
    _add_super($pkg, $contract_pkg);

    my $emulated = sprintf '%s_emulated', _contract_pkg_prefix($class, $pkg);
    _setup_forwards($class, $emulated, $contract_pkg);

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
    my ($class, $from_pkg, $to_pkg) = @_;

    no strict 'refs';
    ${"${from_pkg}::Target"} = $to_pkg;

    if ( ! ${"${from_pkg}::VERSION"} ) {

        my $interface_hash = $Spec_for{$class}{interface};
        my @code = (
            "package $from_pkg;",
            "our \$VERSION = 1;",
            "our \$Target;",
        );

        foreach my $name (keys %{ $interface_hash }) {

            *{"${from_pkg}::$name"} = sub {
                ${"${from_pkg}::Target"}->can($name)->(@_);
            };
            push @code, qq[
                sub $name {
                    \$Target->can('$name')->(\@_);
                }
            ];
        }
        eval join "\n", @code, '1;';
    }
}

sub _validate_contract_def {
    validate(@_, {
        precond   => { type => HASHREF, optional => 1 },
        postcond  => { type => HASHREF, optional => 1 },
    });
}

1;
