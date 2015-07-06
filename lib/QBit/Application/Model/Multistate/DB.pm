package Exception::Multistate::BadAction;
use base qw(Exception::Multistate);

package Exception::Multistate::NotFound;
use base qw(Exception::Multistate);

package QBit::Application::Model::Multistate::DB;

use qbit;

use base qw(QBit::Application::Model::Multistate);

__PACKAGE__->abstract_methods(
    qw(
      _multistate_db_table
      )
);

sub check_action {
    my ($self, $object, $action) = @_;

    $object = $self->_get_object_fields($object, ['multistate']);

    throw Exception::Multistate::NotFound unless defined($object);

    return FALSE unless exists($object->{'multistate'});
    return FALSE unless $self->check_multistate_action($object->{'multistate'}, $action);

    my $can_action_sub_name = "can_action_$action";
    return FALSE if $self->can($can_action_sub_name) && !$self->$can_action_sub_name($object);

    return TRUE;
}

sub get_actions {
    my ($self, $object) = @_;

    $object = $self->_get_object_fields($object, ['multistate']);

    return {
        map {$_ => $self->get_action_name($_)}
          grep {$self->check_action($object, $_)}
          keys(%{$self->get_multistates()->{$object->{'multistate'}} || {}})
    };
}

sub do_action {
    my ($self, $object, $action, %opts) = @_;

    my $pk =
      ref($object) eq 'HASH'
      ? {map {$_ => $object->{$_}} @{$self->_multistate_db_table->primary_key}}
      : $object;

    my $new_multistate;

    $self->_multistate_db_table->db->transaction(
        sub {
            $object = $self->_get_object_fields(
                $pk,
                [
                    @{$self->_multistate_db_table->primary_key}, 'multistate',
                    (ref($object) eq 'HASH' ? keys(%$object) : ())
                ],
                for_update => TRUE
            );
            throw Exception::Multistate::BadAction gettext('Cannot do action "%s".', $action)
              unless $self->check_action($object, $action);

            $new_multistate = $self->get_multistates()->{$object->{'multistate'}}{$action};
            $self->_multistate_db_table()->edit($pk, {multistate => $new_multistate});

            my $on_action_name = "on_action_$action";
            $self->$on_action_name($object, %opts) if $self->can($on_action_name);

            $self->_action_log_db_table()->add($self->_action_log_record($object, $action, $new_multistate, \%opts))
              if $self->_action_log_db_table();
        }
    );

    return $new_multistate;
}

sub _action_log_record {
    my ($self, $object, $action, $new_multistate, $opts) = @_;

    my $action_log_db_table = $self->_action_log_db_table();
    return {
        user_id => $self->get_option('cur_user', {})->{'id'},
        (map {("elem_$_" => $object->{$_})} @{$self->_multistate_db_table->primary_key}),
        old_multistate => $object->{'multistate'},
        action         => $action,
        new_multistate => $new_multistate,
        dt             => curdate(oformat => 'db_time'),
        ($action_log_db_table->have_fields('opts') ? (opts => to_json($opts)) : ())
    };
}

sub get_action_log_entries {
    my ($self, $id_elem, %opts) = @_;

    my $fields = [map {"elem_$_"} @{$self->_action_log_db_table->{'elem_table_pk'}}];

    my $id = {};
    if (ref($id_elem) ne 'HASH' and @$fields > 1) {
        throw gettext('Bad argument. Need hash.');
    } elsif (ref($id_elem) ne 'HASH' and @$fields == 1) {
        $id->{$fields->[0]} = $id_elem;
    } elsif (ref($id_elem) eq 'HASH') {
        $id->{"elem_$_"} = $id_elem->{$_} foreach keys($id_elem);
        throw gettext(
            'Cannot find fields. Need (%s), got (%s).',
            join(', ', @{$self->_action_log_db_table->{'elem_table_pk'}}),
            join(', ', keys(%$id_elem))
        ) if grep {!exists($id->{$_})} @$fields;
    }

    my $filter = $self->_action_log_db_table->db->filter();

    $filter->and([$_ => '=' => \$id->{$_}]) foreach @$fields;

    if (grep {$opts{$_}} qw(fd td)) {
        $filter->and([dt => '>=' => \$opts{'fd'}]) if $opts{'fd'};
        $filter->and([dt => '<=' => \$opts{'td'}]) if $opts{'td'};
    }

    my $res = $self->_action_log_db_table()->get_all(
        filter   => $filter,
        order_by => [qw(dt id)]
    );

    if (grep {$opts{$_}} qw(explain_actions explain_multistates)) {
        foreach (@$res) {
            $_->{'action_name'} = $self->get_action_name($_->{'action'}) if $opts{'explain_actions'};
            if ($opts{'explain_multistates'}) {
                $_->{'old_multistate_name'} = $self->get_multistate_name($_->{'old_multistate'});
                $_->{'new_multistate_name'} = $self->get_multistate_name($_->{'new_multistate'});
            }
        }
    }

    return $res;
}

sub _get_object_fields {
    my ($self, $object, $fields, %opts) = @_;

    if (ref($object) eq 'HASH') {
        return $object if !$opts{'for_update'} && @{arrays_intersection([keys(%$object)], $fields)} == @$fields;

        throw gettext(
            'Cannot find PK fields. Need (%s), got (%s).',
            join(', ', @{$self->_multistate_db_table->primary_key}),
            join(', ', keys(%$object))
        ) if grep {!exists($object->{$_})} @{$self->_multistate_db_table->primary_key};
    }

    push(@$fields, @{$self->_multistate_db_table->primary_key});

    return $self->_get(
        $object,
        for_update => $opts{'for_update'},
        fields     => array_uniq(@$fields)
    );
}

sub _get {
    my ($self, $object, %opts) = @_;

    return $self->_multistate_db_table->get($object, %opts);
}

sub _action_log_db_table { }

TRUE;
