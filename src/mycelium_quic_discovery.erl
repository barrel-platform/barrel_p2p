-module(mycelium_quic_discovery).
-behaviour(quic_discovery).

%% QUIC Discovery Backend for Mycelium
%%
%% Resolves peer node names to QUIC dist addresses. HyParView only
%% tracks node atoms (not transport addresses), so this module reads
%% from static configuration in `{quic, [{dist, [{nodes, ...}]}]}'
%% and falls back to DNS by extracting the host part of `name@host'.

-include("mycelium.hrl").

%% quic_discovery callbacks
-export([init/1, register/3, lookup/2, list_nodes/1]).

%%====================================================================
%% Types
%%====================================================================

-record(state, {
    static_nodes :: #{atom() => {inet:ip_address() | string(), inet:port_number()}}
}).

%%====================================================================
%% Behaviour Callbacks
%%====================================================================

%% @doc Initialize the discovery backend.
%% Reads static node configuration from {quic, [{dist, [{nodes, [...]}]}]}.
-spec init(proplists:proplist() | map()) -> {ok, #state{}} | {error, term()}.
init(Opts) ->
    %% Get static nodes from configuration
    StaticNodes = case Opts of
        Map when is_map(Map) ->
            maps:get(nodes, Map, []);
        List when is_list(List) ->
            proplists:get_value(nodes, List, [])
    end,
    %% Convert to map for fast lookup
    NodesMap = lists:foldl(fun
        ({Node, {Addr, Port}}, Acc) ->
            maps:put(Node, {Addr, Port}, Acc);
        ({Node, Addr, Port}, Acc) ->
            maps:put(Node, {Addr, Port}, Acc);
        (_, Acc) ->
            Acc
    end, #{}, StaticNodes),
    {ok, #state{static_nodes = NodesMap}}.

%% @doc Register this node with the discovery backend.
%% In Mycelium, registration is handled by HyParView, so this is a no-op.
-spec register(atom(), inet:port_number(), #state{}) -> {ok, #state{}} | {error, term()}.
register(_NodeName, _Port, State) ->
    %% HyParView handles node registration via JOIN/FORWARD_JOIN
    {ok, State}.

%% @doc Look up a node's QUIC address.
%% Reads static configuration first, then falls back to DNS resolution
%% of the host part of `name@host'.
-spec lookup(atom(), string()) ->
    {ok, {inet:ip_address() | string(), inet:port_number()}} | {error, term()}.
lookup(Node, Host) ->
    lookup_static(Node, Host).

%% @doc List nodes from static configuration.
-spec list_nodes(string()) -> {ok, [{atom(), inet:port_number()}]} | {error, term()}.
list_nodes(_Host) ->
    {ok, get_static_nodes()}.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @private
%% Look up a node in static configuration.
lookup_static(Node, Host) ->
    DistOpts = application:get_env(quic, dist, []),
    StaticNodes = proplists:get_value(nodes, DistOpts, []),
    case lists:keyfind(Node, 1, StaticNodes) of
        {Node, {Addr, Port}} ->
            {ok, {Addr, Port}};
        {Node, Addr, Port} ->
            {ok, {Addr, Port}};
        false ->
            %% Try to construct from host
            lookup_from_host(Node, Host)
    end.

%% @private
%% Try to look up using the host from node name.
lookup_from_host(Node, Host) ->
    %% Get default QUIC port from config
    DistOpts = application:get_env(quic, dist, []),
    DefaultPort = proplists:get_value(port, DistOpts, 4433),
    case resolve_host(Host) of
        {ok, Addr} ->
            {ok, {Addr, DefaultPort}};
        {error, _} ->
            %% Try extracting from node name
            case extract_host(Node) of
                {ok, NodeHost} ->
                    case resolve_host(NodeHost) of
                        {ok, Addr} -> {ok, {Addr, DefaultPort}};
                        Error -> Error
                    end;
                Error ->
                    Error
            end
    end.

%% @private
%% Get static nodes from configuration.
get_static_nodes() ->
    DistOpts = application:get_env(quic, dist, []),
    StaticNodes = proplists:get_value(nodes, DistOpts, []),
    lists:filtermap(fun
        ({Node, {_Addr, Port}}) -> {true, {Node, Port}};
        ({Node, _Addr, Port}) -> {true, {Node, Port}};
        (_) -> false
    end, StaticNodes).

%% @private
%% Extract hostname from node name (name@host).
extract_host(Node) when is_atom(Node) ->
    case string:split(atom_to_list(Node), "@") of
        [_, Host] -> {ok, Host};
        _ -> {error, invalid_node_name}
    end.

%% @private
%% Resolve hostname to IP address.
resolve_host(Host) when is_list(Host) ->
    case inet:parse_address(Host) of
        {ok, Addr} ->
            {ok, Addr};
        {error, _} ->
            case inet:getaddr(Host, inet) of
                {ok, Addr} ->
                    {ok, Addr};
                {error, _} ->
                    inet:getaddr(Host, inet6)
            end
    end;
resolve_host(Host) when is_binary(Host) ->
    resolve_host(binary_to_list(Host)).
