-module(blockchain_subnetwork_rewards_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("blockchain_vars.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    mobile_test/1,
    iot_test/1
]).

all() ->
    [
        mobile_test,
        iot_test
    ].

%%--------------------------------------------------------------------
%% TEST SUITE SETUP
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    {ok, StorePid} = blockchain_test_reward_store:start(),
    [{store, StorePid} | Config].

%%--------------------------------------------------------------------
%% TEST SUITE TEARDOWN
%%--------------------------------------------------------------------

end_per_suite(_Config) ->
    blockchain_test_reward_store:stop(),
    ok.

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(TestCase, Config) ->
    Config0 = blockchain_ct_utils:init_base_dir_config(?MODULE, TestCase, Config),

    HNTBal = 50000,
    HSTBal = 10000,
    MobileBal = 1000,
    IOTBal = 100,

    Config1 = [
        {hnt_bal, HNTBal},
        {hst_bal, HSTBal},
        {mobile_bal, MobileBal},
        {iot_bal, IOTBal}
        | Config0
    ],

    {ok, Sup, {PrivKey, PubKey}, Opts} = test_utils:init(?config(base_dir, Config1)),

    ExtraVars = extra_vars(TestCase),
    TokenAllocations = token_allocations(TestCase, Config1),

    {ok, GenesisMembers, _GenesisBlock, ConsensusMembers, Keys} =
        test_utils:init_chain_with_opts(
            #{
                balance =>
                    HNTBal,
                sec_balance =>
                    HSTBal,
                keys =>
                    {PrivKey, PubKey},
                in_consensus =>
                    false,
                have_init_dc =>
                    true,
                extra_vars =>
                    ExtraVars,
                token_allocations =>
                    TokenAllocations
            }
        ),

    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    Swarm = blockchain_swarm:tid(),
    N = length(ConsensusMembers),

    {EntryMod, _} = blockchain_ledger_v1:versioned_entry_mod_and_entries_cf(Ledger),

    [
        {hnt_bal, HNTBal},
        {hst_bal, HSTBal},
        {mobile_bal, MobileBal},
        {iot_bal, IOTBal},
        {entry_mod, EntryMod},
        {sup, Sup},
        {pubkey, PubKey},
        {privkey, PrivKey},
        {opts, Opts},
        {chain, Chain},
        {swarm, Swarm},
        {n, N},
        {consensus_members, ConsensusMembers},
        {genesis_members, GenesisMembers},
        Keys
        | Config1
    ].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------

end_per_testcase(_TestCase, Config) ->
    Sup = ?config(sup, Config),
    % Make sure blockchain saved on file = in memory
    case erlang:is_process_alive(Sup) of
        true ->
            true = erlang:exit(Sup, normal),
            ok = test_utils:wait_until(fun() -> false =:= erlang:is_process_alive(Sup) end);
        false ->
            ok
    end,
    test_utils:cleanup_tmp_dir(?config(base_dir, Config)),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

mobile_test(Config) ->
    run_test(mobile, Config).

iot_test(Config) ->
    run_test(iot, Config).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

run_test(TT, Config) ->
    {NetworkPriv, _} = ?config(master_key, Config),
    Chain = ?config(chain, Config),
    Ledger = blockchain:ledger(Chain),
    ConsensusMembers = ?config(consensus_members, Config),

    %% Generate a random subnetwork signer
    [{SubnetworkPubkeyBin, {_SubnetworkPub, _SubnetworkPriv, SubnetworkSigFun}}] = test_utils:generate_keys(
        1
    ),

    %% Generate a random reward server
    [{RewardServerPubkeyBin, {_, _, RewardServerSigFun}}] = test_utils:generate_keys(1),

    NetworkSigfun = libp2p_crypto:mk_sig_fun(NetworkPriv),

    Premine = 5000,
    T = blockchain_txn_add_subnetwork_v1:new(
        TT,
        SubnetworkPubkeyBin,
        [RewardServerPubkeyBin],
        Premine
    ),
    ST0 = blockchain_txn_add_subnetwork_v1:sign_subnetwork(T, SubnetworkSigFun),
    ST = blockchain_txn_add_subnetwork_v1:sign(ST0, NetworkSigfun),

    IsValid = blockchain_txn:is_valid(ST, Chain),
    ?assertEqual(ok, IsValid),

    {ok, Block} = test_utils:create_block(ConsensusMembers, [ST]),
    _ = blockchain_gossip_handler:add_block(Block, Chain, self(), blockchain_swarm:tid()),

    ?assertEqual({ok, blockchain_block:hash_block(Block)}, blockchain:head_hash(Chain)),
    ?assertEqual({ok, Block}, blockchain:head_block(Chain)),
    ?assertEqual({ok, 2}, blockchain:height(Chain)),

    ?assertEqual({ok, Block}, blockchain:get_block(2, Chain)),

    LedgerSubnetworks = blockchain_ledger_v1:subnetworks_v1(Ledger),
    LedgerSubnetwork = maps:get(TT, LedgerSubnetworks),
    ?assertEqual(TT, blockchain_ledger_subnetwork_v1:type(LedgerSubnetwork)),
    ?assertEqual(Premine, blockchain_ledger_subnetwork_v1:token_treasury(LedgerSubnetwork)),
    ?assertEqual(
        [RewardServerPubkeyBin],
        blockchain_ledger_subnetwork_v1:reward_server_keys(LedgerSubnetwork)
    ),
    ?assertEqual(0, blockchain_ledger_subnetwork_v1:hnt_treasury(LedgerSubnetwork)),
    ?assertEqual(0, blockchain_ledger_subnetwork_v1:nonce(LedgerSubnetwork)),

    %% Generate some random addresses to reward to
    [{Rewardee1, _}, {Rewardee2, _}] = test_utils:generate_keys(2),
    Rewards = [
        blockchain_txn_subnetwork_rewards_v1:new_reward(Rewardee1, 100),
        blockchain_txn_subnetwork_rewards_v1:new_reward(Rewardee2, 200)
    ],
    Start = 10,
    End = Start + 30,

    %% Sign with the wrong signature
    InvRewardsTxn1 = blockchain_txn_subnetwork_rewards_v1:new(TT, Start, End, Rewards),
    InvRewardsTxn2 = blockchain_txn_subnetwork_rewards_v1:sign(InvRewardsTxn1, SubnetworkSigFun),
    {error, invalid_signature} = blockchain_txn:is_valid(InvRewardsTxn2, Chain),

    %% Incorrect start-end range
    InvRewardsTxn3 = blockchain_txn_subnetwork_rewards_v1:new(
        TT,
        Start,
        End - 30 - 11,
        Rewards
    ),
    InvRewardsTxn4 = blockchain_txn_subnetwork_rewards_v1:sign(InvRewardsTxn3, RewardServerSigFun),
    {error, {invalid_reward_range, _, _, _}} = blockchain_txn:is_valid(InvRewardsTxn4, Chain),

    %% Rewarding too quick
    InvRewardsTxn5 = blockchain_txn_subnetwork_rewards_v1:new(TT, Start, End, Rewards),
    InvRewardsTxn6 = blockchain_txn_subnetwork_rewards_v1:sign(InvRewardsTxn5, RewardServerSigFun),
    %% This one is invalid because we don't have enough blocks yet
    {error, {invalid_end_block, End, 2}} = blockchain_txn:is_valid(InvRewardsTxn6, Chain),

    %% Add some blocks
    lists:foreach(
        fun(_) ->
            {ok, B} = test_utils:create_block(ConsensusMembers, []),
            _ = blockchain_gossip_handler:add_block(B, Chain, self(), blockchain_swarm:tid())
        end,
        lists:seq(1, 38)
    ),
    ?assertEqual({ok, 40}, blockchain:height(Chain)),

    %% Rewarding more than what is held in the token_treasury for this token
    ExcessRewards = [
        blockchain_txn_subnetwork_rewards_v1:new_reward(Rewardee1, 1000),
        blockchain_txn_subnetwork_rewards_v1:new_reward(Rewardee2, 4001)
    ],
    InvRewardsTxn7 = blockchain_txn_subnetwork_rewards_v1:new(TT, Start, End, ExcessRewards),
    InvRewardsTxn8 = blockchain_txn_subnetwork_rewards_v1:sign(InvRewardsTxn7, RewardServerSigFun),
    {error, {insufficient_tokens_to_fulfil_rewards, _, _}} = blockchain_txn:is_valid(
        InvRewardsTxn8,
        Chain
    ),

    %% Rewarding too much per block
    ExcessRewardsPerBlock = [
        blockchain_txn_subnetwork_rewards_v1:new_reward(Rewardee1, 200),
        blockchain_txn_subnetwork_rewards_v1:new_reward(Rewardee2, 400)
    ],
    InvRewardsTxn9 = blockchain_txn_subnetwork_rewards_v1:new(
        TT,
        Start,
        End,
        ExcessRewardsPerBlock
    ),
    InvRewardsTxn10 = blockchain_txn_subnetwork_rewards_v1:sign(InvRewardsTxn9, RewardServerSigFun),
    {error, {rewards_too_large, 600, 300}} = blockchain_txn:is_valid(
        InvRewardsTxn10,
        Chain
    ),

    RewardsTxn = blockchain_txn_subnetwork_rewards_v1:new(TT, Start, End, Rewards),
    SignedRewardsTxn = blockchain_txn_subnetwork_rewards_v1:sign(RewardsTxn, RewardServerSigFun),
    %% This one should be valid now
    ok = blockchain_txn:is_valid(SignedRewardsTxn, Chain),

    {ok, Block41} = test_utils:create_block(ConsensusMembers, [SignedRewardsTxn]),
    _ = blockchain_gossip_handler:add_block(Block41, Chain, self(), blockchain_swarm:tid()),

    ?assertEqual({ok, blockchain_block:hash_block(Block41)}, blockchain:head_hash(Chain)),
    ?assertEqual({ok, Block41}, blockchain:head_block(Chain)),
    ?assertEqual({ok, 41}, blockchain:height(Chain)),
    ?assertEqual({ok, Block41}, blockchain:get_block(41, Chain)),

    {ok, E1} = blockchain_ledger_v1:find_entry(Rewardee1, Ledger),
    {ok, E2} = blockchain_ledger_v1:find_entry(Rewardee2, Ledger),
    ?assertEqual(100, blockchain_ledger_entry_v2:balance(E1, TT)),
    ?assertEqual(200, blockchain_ledger_entry_v2:balance(E2, TT)),
    ?assertEqual(0, blockchain_ledger_entry_v2:balance(E1, hnt)),
    ?assertEqual(0, blockchain_ledger_entry_v2:balance(E2, hnt)),
    ?assertEqual(0, blockchain_ledger_entry_v2:balance(E1, hst)),
    ?assertEqual(0, blockchain_ledger_entry_v2:balance(E2, hst)),

    {ok, LedgerSubnet} = blockchain_ledger_v1:find_subnetwork_v1(TT, Ledger),
    %% 5000 - (100 + 200)
    4700 = blockchain_ledger_subnetwork_v1:token_treasury(LedgerSubnet),

    ok.

extra_vars(_) ->
    #{
        ?allowed_num_reward_server_keys => 1,
        ?token_version => 2,
        ?subnetwork_reward_per_block_limit => 10
    }.

token_allocations(_, Config) ->
    HNTBal = ?config(hnt_bal, Config),
    HSTBal = ?config(hst_bal, Config),
    MobileBal = ?config(mobile_bal, Config),
    IOTBal = ?config(iot_bal, Config),
    #{hnt => HNTBal, hst => HSTBal, mobile => MobileBal, iot => IOTBal}.
