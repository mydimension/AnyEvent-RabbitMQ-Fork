package AnyEvent::RabbitMQ::Fork;

# ABSTRACT: Run AnyEvent::RabbitMQ inside AnyEvent::Fork(::RPC)

use Moo;
use Types::Standard qw(CodeRef Str HashRef InstanceOf Bool);
use Scalar::Util qw(weaken);
use Carp qw(croak);
use File::ShareDir qw(dist_file);

use constant DEFAULT_AMQP_SPEC =>
  dist_file('AnyEvent-RabbitMQ', 'fixed_amqp0-9-1.xml');

use namespace::clean;

use AnyEvent::Fork;
use AnyEvent::Fork::RPC;

use Net::AMQP;

use AnyEvent::RabbitMQ::Fork::Channel;

has verbose => (is => 'rw', isa => Bool, default => 0);
has is_open => (is => 'ro', isa => Bool, default => 0);
has login_user        => (is => 'ro', isa => Str);
has server_properties => (is => 'ro', isa => Str);

has worker_class    => (is => 'lazy', isa => Str);
has channel_class   => (is => 'lazy', isa => Str);
has worker_function => (is => 'lazy', isa => Str);
has init_function   => (is => 'lazy', isa => Str);

sub _build_worker_class    { return ref($_[0]) . '::Worker' }
sub _build_channel_class   { return ref($_[0]) . '::Channel' }
sub _build_worker_function { return $_[0]->worker_class . '::run' }
sub _build_init_function   { return $_[0]->worker_class . '::init' }

has channels => (
    is      => 'ro',
    isa     => HashRef [InstanceOf ['AnyEvent::RabbitMQ::Fork::Channel']],
    clearer => 1,
    default  => sub { {} },
    init_arg => undef,
);

has cb_registry => (
    is       => 'ro',
    isa      => HashRef,
    default  => sub { {} },
    clearer  => 1,
    init_arg => undef,
);

has rpc => (
    is       => 'lazy',
    isa      => CodeRef,
    clearer  => 1,
    init_arg => undef,
);

sub _build_rpc {
    my $self = shift;
    weaken(my $wself = $self);

    return AnyEvent::Fork->new          #
      ->require($self->worker_class)    #
      ->send_arg($self->worker_class, verbose => $self->verbose)    #
      ->AnyEvent::Fork::RPC::run(
        $self->worker_function,
        async      => 1,
        serialiser => $AnyEvent::Fork::RPC::STORABLE_SERIALISER,
        on_event   => sub { $wself->_on_event(@_) },
        on_error   => sub { $wself->_on_error(@_) },
        on_destroy => sub { $wself->_on_destroy(@_) },
        init       => $self->init_function,
        # TODO look into
        #done => '',
      );
}

my $cb_id = 'a';    # textual ++ gives a bigger space than numerical ++

sub _delegate {
    my ($self, $method, $ch_id, @args, %args) = @_;

    unless (@args % 2) {
        %args = @args;
        @args = ();
        foreach my $event (grep { /^on_/ } keys %args) {
            my $id = $cb_id++;

            # store the user callback
            $self->cb_registry->{$id} = delete $args{$event};

            # create a signature to send back to on_event
            $args{$event} = [$id, $event, $method, scalar caller];
        }
    }

    $self->rpc->(
        $method, $ch_id,
        (@args ? @args : %args),
        sub {
            croak @_ if @_;
        }
    );

    return $self;
}

before verbose => sub {
    return if @_ < 2;
    $_[0]->_delegate(verbose => 0, $_[1]);
};

my $_loaded_spec;
sub load_xml_spec {
    my $self = shift;
    my $spec = shift || DEFAULT_AMQP_SPEC;

    if ($_loaded_spec and $_loaded_spec ne $spec) {
        croak(
            "Tried to load AMQP spec $spec, but have already loaded $_loaded_spec, not possible"
        );
    } elsif (!$_loaded_spec) {
        Net::AMQP::Protocol->load_xml_spec($_loaded_spec = $spec);
    }

    return $self->_delegate(load_xml_spec => 0, $spec);
}

foreach my $method (qw(connect open_channel close)) {
    no strict 'refs';
    *$method = sub {
        my $self = shift;
        return $self->_delegate($method => 0, @_);
    };
}

my %event_handlers = (
    cb  => '_handle_callback',
    cbd => '_handle_callback_destroy',
    chd => '_handle_channel_destroy',
    i   => '_handle_info',
);

sub _on_event {
    my $self = shift;
    my $type = shift;

    if (my $handler = $event_handlers{$type}) {
        $self->$handler(@_);
    } else {
        croak "Unknown event type: '$type'";
    }

    return;
}

sub _handle_callback {
    my $self = shift;
    my $sig  = shift;
    my ($id, $event, $method, $pkg) = @$sig;

    warn "_handle_callback $id $event $method $pkg\n" if $self->verbose;

    if (my $cb = $self->cb_registry->{$id}) {
        if (ref($_[0]) eq 'REF' and ref(${ $_[0] }) eq 'ARRAY') {
            my ($class, @args) = @{ ${ $_[0] } };

            if ($class eq 'AnyEvent::RabbitMQ') {
                $_[0] = $self;
            } elsif ($class eq 'AnyEvent::RabbitMQ::Channel') {
                my $channel_id = shift @args;
                $_[0] = $self->channels->{$channel_id}
                  ||= $self->channel_class->new(id => $channel_id,
                    conn => $self);
            } else {
                croak "Unknown class type: '$class'";
            }
        }

        goto &$cb;
    } else {
        croak "Unknown callback id: '$id'";
    }

    return;
}

sub _handle_info {
    my ($self, $info) = @_;

    $self->_handle_connection_info(%{ delete $info->{connection} })
        if $info->{connection};

    $self->_handle_channel_info($_, %{ $info->{$_} }) foreach keys %$info;

    return;
}

# channel information passback
sub _handle_channel_info {
    my ($self, $ch_id, %args) = @_;

    warn "_handle_channel_info $ch_id @{[ keys %args ]}\n" if $self->verbose;

    if (my $ch = $self->channels->{$ch_id}) {
        @$ch{ keys %args } = values %args;
    } else {
        croak "Unknown channel: '$ch_id'";
    }

    return;
}

sub _handle_channel_destroy {
    my ($self, $ch_id) = @_;

    warn "_handle_channel_destroy $ch_id\n" if $self->verbose;

    delete $self->channels->{$ch_id};

    return;
}

# connection information passback
sub _handle_connection_info {
    my ($self, %args) = @_;

    warn "_handle_info @{[ keys %args ]}\n" if $self->verbose;

    @$self{ keys %args } = values %args;

    return;
}

sub _handle_callback_destroy {
    my ($self, $id, $event, $method, $pkg) = @_;

    warn "_handle_callback_destroy $id $event $method $pkg\n" if $self->verbose;

    delete $self->cb_registry->{$id};

    return;
}

sub _on_error {
    my $self = shift;

    croak @_;
}

sub _on_destroy {
    my $self = shift;

    warn "_on_destroy\n" if $self->verbose;

    # TODO implement reconnect
    return;
}

sub DEMOLISH {
    my ($self, $in_gd) = @_;
    return if $in_gd;

    $self->_delegate(DEMOLISH => 0);

    return;
}

1;
