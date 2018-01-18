use strict;
use Test::Lib;
use Test::Most;
use Example::Contract::BoundedQueue;

my $governed = 'Example::BoundedQueue';
eval "require $governed";

my $emulation = Example::Contract::BoundedQueue::->govern($governed, { emulate => 1 });

throws_ok { 
    my $q = $emulation->new(-3);

} qr/failed precondition 'positive_int_size'/;

Example::Contract::BoundedQueue::->govern($governed, { emulate => 1, pre=>0 });
my $q2 = $emulation->new(-3);
is $q2->max_size => -3;

done_testing();
