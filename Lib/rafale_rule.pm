package Lib::rafale_rule;
use Data::Dumper;
our $Logger;

sub new {
    my ($class,$this) = @_;
    return bless($this,ref($class) || $class);
}

sub isMatch {
    my ($self,$value) = @_;
    return $value =~ $self->{regexp} ? 1 : 0;
}

sub getField {
    my ($self) = @_;
    return $self->{field};
}

sub processAlarm {
    my ($self,$PDSRef) = @_;
    my @fieldArr    = split(/\./,"$self->{field}");
    my $fieldValue  = $PDSRef;
    foreach(@fieldArr) {
        return 0 if !defined $fieldValue->{$_};
        $fieldValue = $fieldValue->{$_};
    }
    if(defined $self->{severity}) {
        return 0 if $self->{severity} != $PDSRef->{udata}->{severity};
    }
    return $self->isMatch(${fieldValue});
}

1;