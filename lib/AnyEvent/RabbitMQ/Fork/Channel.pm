package AnyEvent::RabbitMQ::Fork::Channel;

use Moo;
use Types::Standard qw(Int Object Bool);

use namespace::clean;

has id         => (is => 'ro', isa => Int);
has is_open    => (is => 'ro', isa => Bool, default => 0);
has is_active  => (is => 'ro', isa => Bool, default => 0);
has is_confirm => (is => 'ro', isa => Bool, default => 0);
has conn => (
    is       => 'ro',
    isa      => Object,
    weak_ref => 1,
    handles  => { delegate => '_delegate' }
);

my @methods = qw(
  open
  close
  declare_exchange
  delete_exchange
  declare_queue
  bind_queue
  unbind_queue
  purge_queue
  delete_queue
  publish
  consume
  cancel
  get
  ack
  qos
  confirm
  recover
  reject
  select_tx
  commit_tx
  rollback_tx
  );

foreach my $method (@methods) {
    no strict 'refs';
    *$method = sub {
        my $self = shift;
        $self->delegate($method => $self->id, @_);
    };
}

1;
