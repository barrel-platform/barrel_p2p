-module(mycelium_protocol).

-include("mycelium.hrl").

%% API
-export([send/2]).
-export([handle_message/2]).

%% Encoding/Decoding
-export([encode/1, decode/1]).

-define(PROTOCOL_TAG, '$mycelium_hyparview').

%%====================================================================
%% API
%%====================================================================

-spec send(node(), hyparview_msg()) -> ok.
send(Node, Msg) ->
    %% Send via Erlang distribution to mycelium_bridge on remote node
    erlang:send({mycelium_bridge, Node}, {?PROTOCOL_TAG, node(), Msg}, [noconnect]),
    ok.

-spec handle_message({atom(), node(), term()}, pid()) -> ok.
handle_message({?PROTOCOL_TAG, From, Msg}, _Handler) ->
    mycelium_hyparview:handle_msg(Msg, From),
    ok;
handle_message(_Other, _Handler) ->
    ok.

%%====================================================================
%% Encoding/Decoding (for potential custom framing)
%%====================================================================

-spec encode(hyparview_msg()) -> binary().
encode({join, Sender}) ->
    term_to_binary({join, encode_peer(Sender)});
encode({forward_join, NewPeer, TTL, Sender}) ->
    term_to_binary({forward_join, encode_peer(NewPeer), TTL, encode_peer(Sender)});
encode({disconnect, Sender}) ->
    term_to_binary({disconnect, encode_peer(Sender)});
encode({neighbor, Priority, Sender}) ->
    term_to_binary({neighbor, Priority, encode_peer(Sender)});
encode({neighbor_reply, Accept, Sender}) ->
    term_to_binary({neighbor_reply, Accept, encode_peer(Sender)});
encode({shuffle, TTL, Peers, Sender}) ->
    term_to_binary({shuffle, TTL, [encode_peer(P) || P <- Peers], encode_peer(Sender)});
encode({shuffle_reply, Peers, Sender}) ->
    term_to_binary({shuffle_reply, [encode_peer(P) || P <- Peers], encode_peer(Sender)}).

-spec decode(binary()) -> hyparview_msg().
decode(Bin) ->
    case binary_to_term(Bin) of
        {join, Sender} ->
            {join, decode_peer(Sender)};
        {forward_join, NewPeer, TTL, Sender} ->
            {forward_join, decode_peer(NewPeer), TTL, decode_peer(Sender)};
        {disconnect, Sender} ->
            {disconnect, decode_peer(Sender)};
        {neighbor, Priority, Sender} ->
            {neighbor, Priority, decode_peer(Sender)};
        {neighbor_reply, Accept, Sender} ->
            {neighbor_reply, Accept, decode_peer(Sender)};
        {shuffle, TTL, Peers, Sender} ->
            {shuffle, TTL, [decode_peer(P) || P <- Peers], decode_peer(Sender)};
        {shuffle_reply, Peers, Sender} ->
            {shuffle_reply, [decode_peer(P) || P <- Peers], decode_peer(Sender)}
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

encode_peer(#peer{id = Id, address = Addr, port = Port, priority = Priority}) ->
    {Id, Addr, Port, Priority}.

decode_peer({Id, Addr, Port, Priority}) ->
    #peer{
        id = Id,
        address = Addr,
        port = Port,
        connected = false,
        priority = Priority,
        last_seen = undefined
    }.
