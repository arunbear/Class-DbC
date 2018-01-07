package DbC::Contract;

use strict;
use Carp;
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
}

sub _governor {
    my ($class, $pkg, $type) = @_;
    
        # use Data::Dump 'pp'; die pp();
    $type ||= 'all';

    foreach my $name (keys %{ $Spec_for{$class}{interface} }) {
        $pkg->can($name)
          or confess "Class $pkg does not have a '$name' method, which is required by $class";
    }
}

1;
