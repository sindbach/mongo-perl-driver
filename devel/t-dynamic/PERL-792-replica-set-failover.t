#  Copyright 2018 - present MongoDB, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

# Test in t-dynamic as not sure if failover should be tested on install?

use strict;
use warnings;
use JSON::MaybeXS;
use Path::Tiny 0.054; # basename with suffix
use Test::More 0.88;
use Test::Fatal;
use boolean;

use lib "t/lib";
use lib "devel/lib";

use MongoDBTest::Orchestrator; 

use MongoDBTest qw/
    build_client
    get_test_db
    clear_testdbs
    get_unique_collection
    server_version
    server_type
    check_min_server_version
    get_features
/;

my $orc =
MongoDBTest::Orchestrator->new(
  config_file => "devel/config/replicaset-multi-3.6.yml" );
$orc->start;

$ENV{MONGOD} = $orc->as_uri;

my @events;

sub clear_events { @events = () }
sub event_count { scalar @events }
sub event_cb { push @events, $_[0] }

my $conn = build_client(
    retry_writes => 1,
    heartbeat_frequency_ms => 60 * 1000,
    # build client modifies this so we set it explicitly to the default
    server_selection_timeout_ms => 30 * 1000,
    server_selection_try_once => 0,
    monitoring_callback => \&event_cb,
);
my $testdb         = get_test_db($conn);
my $coll = get_unique_collection( $testdb, 'retry_failover' );
my $server_version = server_version($conn);
my $server_type    = server_type($conn);
my $features       = get_features($conn);

plan skip_all => "retryableWrites not supported on this MongoDB"
    unless ( $features->supports_retryWrites );

plan skip_all => "standalone servers dont support retryableWrites"
    if $server_type eq 'Standalone';

my $primary = $conn->_topology->current_primary;

my $fail_conn = build_client( host => $primary->address );

my $step_down_conn = build_client();

my $ret = $coll->insert_one( { _id => 1, test => 'value' } );

is $ret->inserted_id, 1, 'write succeeded';

my $result = $coll->find_one( { _id => 1 } );

is $result->{test}, 'value', 'Successful write';

$fail_conn->send_admin_command([
    configureFailPoint => 'onPrimaryTransactionalWrite',
    mode => 'alwaysOn',
]);

# wrapped in eval as this will just drop connection
eval {
    $step_down_conn->send_admin_command([
        replSetStepDown => 60,
        force => true,
    ]);
};
my $err = $@;
isa_ok( $err, 'MongoDB::NetworkError', 'Step down successfully errored' );

clear_events();

my $post_stepdown_ret = $coll->insert_one( { _id => 2, test => 'again' } );

is $post_stepdown_ret->inserted_id, 2, 'write succeeded';

# All this is to make sure we dont make assumptions on position of the actual
# event, just that the failed one comes first.
my $first_insert_index;

for my $f_idx ( 0 .. $#events - 1 ) {
    my $event = $events[ $f_idx ];
    if ( $event->{ commandName } eq 'insert'
      && $event->{ type } eq 'command_started' ) {
        my $next_event = $events[ $f_idx + 1 ];
        is $next_event->{ commandName }, 'insert', 'found insert reply';
        is $next_event->{ type }, 'command_failed', 'found failed reply';
        $first_insert_index = $f_idx;
        last;
    }
}

ok defined( $first_insert_index ), 'found first command';

my $second_insert_index;

if ( $first_insert_index + 2 > $#events - 1 ) {
  fail 'not enough events captured';
}

for my $s_idx ( $first_insert_index + 2 .. $#events - 1 ) {
    my $event = $events[ $s_idx ];
    if ( $event->{ commandName } eq 'insert'
      && $event->{ type } eq 'command_started' ) {
        my $next_event = $events[ $s_idx + 1 ];
        is $next_event->{ commandName }, 'insert', 'found insert reply';
        is $next_event->{ type }, 'command_succeeded', 'found success reply';
        $second_insert_index = $s_idx;
        last;
    }
}

ok defined( $second_insert_index ), 'found second command';

$fail_conn->send_admin_command([
    configureFailPoint => 'onPrimaryTransactionalWrite',
    mode => 'off',
]);

clear_testdbs;

done_testing;
