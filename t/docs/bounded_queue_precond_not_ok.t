use strict;
use Test::Lib;
use Test::Most;
use Example::BoundedQueue;
use Example::Contract::BoundedQueue;

Example::Contract::BoundedQueue::->govern('Example::BoundedQueue');

throws_ok { 
    my $q = Example::BoundedQueue::->new(-3);

} qr/failed precondition 'positive_int_size'/;

done_testing();
