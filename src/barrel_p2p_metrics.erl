%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% Observability surface for barrel_p2p. Thin wrapper over `instrument'
%%% so all instruments live in one place and call sites stay readable.
%%%
%%% Convention: dot-namespaced names under the `barrel_p2p' prefix. Each
%%% emit takes attributes (peer node, outcome) that become OTel-style
%%% dimensions on the backend. Instruments are cached in persistent_term
%%% after first use; subsequent emits are a single map lookup plus a
%%% NIF call.

-module(barrel_p2p_metrics).

-export([
    hyparview_event/1,
    auth_attempt/3,
    gossip_sent/1,
    gossip_received/1,
    ihave_sent/1,
    graft_sent/1,
    prune_sent/1,
    gc_reap/1,
    migrate_result/2,
    router_request_dropped/0,
    proxy_cast_dropped/0,
    pending_timeout/1,
    streams_preamble_dropped/0
]).

-define(METER_KEY, {?MODULE, meter}).

%%====================================================================
%% Public API
%%====================================================================

-spec hyparview_event(term()) -> ok.
hyparview_event({peer_up, Peer}) ->
    add(<<"barrel_p2p.hyparview.peer_up">>, 1, #{peer => Peer});
hyparview_event({peer_down, Peer, Reason}) ->
    add(
        <<"barrel_p2p.hyparview.peer_down">>,
        1,
        #{peer => Peer, reason => reason_attr(Reason)}
    );
hyparview_event({peer_down, Peer}) ->
    add(
        <<"barrel_p2p.hyparview.peer_down">>,
        1,
        #{peer => Peer, reason => unknown}
    );
hyparview_event(joined) ->
    add(<<"barrel_p2p.hyparview.joined">>, 1, #{});
hyparview_event(left) ->
    add(<<"barrel_p2p.hyparview.left">>, 1, #{});
hyparview_event({shuffle, Target}) ->
    add(<<"barrel_p2p.hyparview.shuffle">>, 1, #{target => Target});
hyparview_event(_) ->
    ok.

%% Role :: outgoing | incoming, Outcome :: ok | fail, DurationMs :: integer().
-spec auth_attempt(outgoing | incoming, ok | fail, integer()) -> ok.
auth_attempt(Role, Outcome, DurationMs) ->
    Attrs = #{role => Role, outcome => Outcome},
    add(<<"barrel_p2p.dist.auth.attempts">>, 1, Attrs),
    record(<<"barrel_p2p.dist.auth.duration_ms">>, DurationMs, Attrs).

-spec gossip_sent(non_neg_integer()) -> ok.
gossip_sent(0) ->
    ok;
gossip_sent(N) when is_integer(N), N > 0 ->
    add(<<"barrel_p2p.plumtree.gossip.sent">>, N, #{}).

-spec gossip_received(node()) -> ok.
gossip_received(From) ->
    add(<<"barrel_p2p.plumtree.gossip.received">>, 1, #{from => From}).

-spec ihave_sent(non_neg_integer()) -> ok.
ihave_sent(0) ->
    ok;
ihave_sent(N) when is_integer(N), N > 0 ->
    add(<<"barrel_p2p.plumtree.ihave.sent">>, N, #{}).

-spec graft_sent(node()) -> ok.
graft_sent(Peer) ->
    add(<<"barrel_p2p.plumtree.graft.sent">>, 1, #{peer => Peer}).

-spec prune_sent(node()) -> ok.
prune_sent(Peer) ->
    add(<<"barrel_p2p.plumtree.prune.sent">>, 1, #{peer => Peer}).

-spec gc_reap(node()) -> ok.
gc_reap(Peer) ->
    add(<<"barrel_p2p.dist_gc.reap">>, 1, #{peer => Peer}).

-spec migrate_result(node(), ok | fail) -> ok.
migrate_result(Peer, Outcome) ->
    add(<<"barrel_p2p.dist.migrate">>, 1, #{peer => Peer, outcome => Outcome}).

-spec router_request_dropped() -> ok.
router_request_dropped() ->
    add(<<"barrel_p2p.router.request_dropped">>, 1, #{}).

-spec proxy_cast_dropped() -> ok.
proxy_cast_dropped() ->
    add(<<"barrel_p2p.service_proxy.cast_dropped">>, 1, #{}).

-spec pending_timeout(node()) -> ok.
pending_timeout(Peer) ->
    add(<<"barrel_p2p.hyparview.pending_timeout">>, 1, #{peer => Peer}).

-spec streams_preamble_dropped() -> ok.
streams_preamble_dropped() ->
    add(<<"barrel_p2p.streams.preamble_dropped">>, 1, #{}).

%%====================================================================
%% Internal: instrument cache + safe emit
%%====================================================================

add(Name, Value, Attrs) ->
    case counter(Name) of
        {ok, I} ->
            safe(fun() -> instrument_meter:add(I, Value, Attrs) end);
        skip ->
            ok
    end.

record(Name, Value, Attrs) ->
    case histogram(Name) of
        {ok, I} ->
            safe(fun() -> instrument_meter:record(I, Value, Attrs) end);
        skip ->
            ok
    end.

counter(Name) ->
    instrument(Name, counter).

histogram(Name) ->
    instrument(Name, histogram).

instrument(Name, Kind) ->
    Key = {?MODULE, instrument, Name, Kind},
    case persistent_term:get(Key, undefined) of
        undefined ->
            case create(Name, Kind) of
                {ok, I} ->
                    persistent_term:put(Key, I),
                    {ok, I};
                skip ->
                    skip
            end;
        I ->
            {ok, I}
    end.

create(Name, Kind) ->
    case meter() of
        {ok, M} ->
            safe_create(M, Name, Kind);
        skip ->
            skip
    end.

safe_create(M, Name, counter) ->
    try
        {ok, instrument_meter:create_counter(M, Name)}
    catch
        _:_ -> skip
    end;
safe_create(M, Name, histogram) ->
    try
        {ok, instrument_meter:create_histogram(M, Name)}
    catch
        _:_ -> skip
    end.

meter() ->
    case persistent_term:get(?METER_KEY, undefined) of
        undefined ->
            try
                M = instrument_meter:get_meter(<<"barrel_p2p">>),
                persistent_term:put(?METER_KEY, M),
                {ok, M}
            catch
                _:_ ->
                    skip
            end;
        M ->
            {ok, M}
    end.

%% Never let a metrics emit blow up the caller. Telemetry is best-effort.
safe(F) ->
    try
        F(),
        ok
    catch
        _:_ ->
            ok
    end.

reason_attr(Reason) when is_atom(Reason) -> Reason;
reason_attr({Tag, _}) when is_atom(Tag) -> Tag;
reason_attr(_) -> other.
