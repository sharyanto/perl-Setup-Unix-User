package Setup::Unix::Group;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(setup_unix_group);

use Unix::Passwd::File;

# VERSION

our %SPEC;

my %common_args = (
    etc_dir => {
        summary => 'Location of passwd files',
        schema  => ['str*' => {default=>'/etc'}],
    },
    group => {
        schema  => 'str*',
        summary => 'Group name',
    },
);

$SPEC{delgroup} = {
    v => 1.1,
    summary => 'Delete group',
    description => <<'_',

Fixed state: group does not exist.

Fixable state: group exists.

_
    args => {
        %common_args,
    },
    features => {
        tx => {v=>2},
        idempotent => 1,
    },
};
sub delgroup {
    my %args = @_;

    my $tx_action = $args{-tx_action} // '';
    my $dry_run   = $args{-tx_action} // '';
    my $group     = $args{group} or return [400, "Please specify group"];
    $group =~ $Unix::Passwd::File::re_group
        or return [400, "Invalid group"];
    my %ca        = (etc_dir => $args{etc_dir} // "/etc", group=>$group);
    my $res;

    if ($tx_action eq 'check_state') {
        my $res = Unix::Passwd::File::get_group(%ca);
        return $res unless $res->[0] == 200 || $res->[0] == 404;

        return [304, "Group $group already doesn't exist"] if $res->[0] == 404;
        $log->info("(DRY) Deleting Unix group $group ...") if $dry_run;
        return [200, "Group $group needs to be deleted", undef, {undo_actions=>[
            [addgroup => {%ca, gid => $res->[2]{gid}}],
        ]}];
    } elsif ($tx_action eq 'fix_state') {
        # we don't want to have to get_group() when fixing state, to reduce
        # number of read passes to the passwd files
        $log->info("Deleting Unix group $group ...");
        return Unix::Passwd::File::delete_group(%ca);
    }
    [400, "Invalid -tx_action"];
}

$SPEC{addgroup} = {
    v => 1.1,
    summary => 'Add group',
    args => {
        %common_args,
        gid => {
            summary => 'Add with specified GID',
            description => <<'_',

If not specified, will search an unused GID from `min_new_gid` to `max_new_gid`.

If specified, will accept non-unique GID (that which has been used by other
group).

_
            schema => 'int',
        },
        min_gid => {
            summary => 'Specify range for new GID',
            description => <<'_',

If a free GID between `min_gid` and `max_gid` is not available, an error is
returned.

Passed to Unix::Passwd::File's `min_new_gid`.

_
            schema => [int => {between=>[0, 65535], default=>1000}],
        },
        max_gid => {
            summary => 'Specify range for new GID',
            description => <<'_',

If a free GID between `min_gid` and `max_gid` is not available, an error is
returned.

Passed to Unix::Passwd::File's `max_new_gid`.

_
            schema => [int => {between=>[0, 65535], default=>65534}],
        },
    },
    features => {
        tx => {v=>2},
        idempotent => 1,
    },
};
sub addgroup {
    my %args = @_;

    my $tx_action = $args{-tx_action} // '';
    my $dry_run   = $args{-dry_run};
    my $group     = $args{group} or return [400, "Please specify group"];
    $group =~ $Unix::Passwd::File::re_group
        or return [400, "Invalid group"];
    my $gid       = $args{gid};
    my $min_gid   = $args{min_gid} //  1000;
    my $max_gid   = $args{max_gid} // 65534;
    my %ca0       = (etc_dir => $args{etc_dir} // "/etc");
    my %ca        = (%ca0, group=>$group);
    my $res;

    if ($tx_action eq 'check_state') {
        $res = Unix::Passwd::File::get_group(%ca);
        return $res unless $res->[0] == 200 || $res->[0] == 404;

        if ($res->[0] == 200) {
            if (!defined($gid) || $gid == $res->[2]{gid}) {
                return [304, "Group $group already exists"];
            } else {
                return [412, "Group $group already exists but with different ".
                            "GID ($res->[2]{gid}, wanted $gid)"];
            }
        } else {
            $log->info("(DRY) Adding Unix group $group ...") if $dry_run;
            return [200, "Group $group needs to be added", undef,
                    {undo_actions=>[
                        [delgroup => {%ca}],
            ]}];
        }
    } elsif ($tx_action eq 'fix_state') {
        # we don't want to have to get_group() when fixing state, to reduce
        # number of read passes to the passwd files
        $log->info("Adding Unix group $group ...");
        $res = Unix::Passwd::File::add_group(
            %ca, gid=>$gid, min_gid=>$min_gid, max_gid=>$max_gid);
        if ($res->[0] == 200) {
            $args{-stash}{result}{gid} = $gid;
            return [200, "Created"];
        } else {
            return $res;
        }
    }
    [400, "Invalid -tx_action"];
}

$SPEC{setup_unix_group} = {
    v           => 1.1,
    summary     => "Setup Unix group (existence)",
    description => <<'_',

On do, will create Unix group if not already exists. The created GID will be
returned in the result (`{gid => GID}`).

On undo, will delete Unix group previously created.

On redo, will recreate the Unix group with the same GID.

_
    args => $SPEC{adduser}{args},
    features => {
        tx => {v=>2},
        idempotent => 1,
    },
};
for (qw/setup_unix_user/) {
    $SPEC{$_}{args}{min_new_gid} = delete $SPEC{$_}{args}{min_gid};
    $SPEC{$_}{args}{max_new_gid} = delete $SPEC{$_}{args}{max_gid};
    $SPEC{$_}{args}{new_gid}     = delete $SPEC{$_}{args}{gid};
}
sub setup_unix_group {
    my %args = @_;

    $args{min_gid} = delete $args{min_new_gid};
    $args{max_gid} = delete $args{max_new_gid};
    $args{gid}     = delete $args{new_gid};

    addgroup(%args);
}

1;
# ABSTRACT: Setup Unix group (existence)

=head1 FAQ

=head2 How to create group with a specific GID?

Set C<min_new_gid> and C<max_new_gid> to your desired value. Note that the
function will report failure if when wanting to create a group, the desired GID
is already taken. But the function will not report failure if the group already
exists, even with a different GID.


=head1 SEE ALSO

L<Setup>

L<Setup::Unix::User>

=cut
