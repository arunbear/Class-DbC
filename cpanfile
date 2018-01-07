requires 'perl', '5.008001';
requires 'Class::Method::Modifiers', '2.12';

on 'test' => sub {
    requires 'Test::More', '0.98';
    requires 'Test::Lib',  '0.002';
};

