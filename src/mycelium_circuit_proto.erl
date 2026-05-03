%%% -*- erlang -*-
%%%
%%% Mycelium Circuit Wire Protocol (v2)
%%%
%%% Each circuit rides on a `mycelium_streams' user stream tagged
%%% `<<"mycelium:circuit">>'. After the streams-layer tag preamble is
%%% consumed, the stream carries a sequence of length-self-describing
%%% frames defined here. The same protocol is used in both directions.
%%%
%%% Frames:
%%%
%%%   <<?FRAME_CREATE:8, IdLen:8, Id:IdLen/binary,
%%%     InitLen:16/big, Init:InitLen/binary,
%%%     PathLen:8, [<<NameLen:16/big, Name:NameLen/binary>>] * PathLen>>
%%%
%%%   <<?FRAME_RESUME:8, IdLen:8, Id:IdLen/binary,
%%%     RxNextExpectedSeq:48/big,
%%%     PathLen:8, [<<NameLen:16/big, Name:NameLen/binary>>] * PathLen>>
%%%
%%%   <<?FRAME_DATA:8, Seq:48/big, Len:32/big, Payload:Len/binary>>
%%%
%%%   <<?FRAME_ACK:8, CumulativeSeq:48/big>>
%%%
%%%   <<?FRAME_FIN:8, Seq:48/big>>
%%%
%%% `Id' is a 16-byte random identifier shared by both endpoints for
%%% the lifetime of the circuit; it survives migration. `Init' is the
%%% originator node atom. `Path' on CREATE is the list of remaining
%%% hops (destination last). `Path' on RESUME is the new path to
%%% take after a hop failure; on the destination -> initiator
%%% acknowledgement leg the path is empty (relays splice bytes back
%%% along the new chain without a routing decision).
%%%
%%% Sequence numbers are 48-bit; both DATA and FIN consume one.
%%% `CumulativeSeq' in ACK covers any frame (DATA or FIN) with
%%% `Seq <= CumulativeSeq'.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0

-module(mycelium_circuit_proto).

-export([
    circuit_id/0,
    encode_create/3,
    encode_resume/3,
    encode_data/2,
    encode_ack/1,
    encode_fin/1,
    try_decode/1
]).

-define(ID_BYTES, 16).
-define(MAX_PATH, 255).
-define(MAX_NAME, 65535).

-define(FRAME_CREATE, 1).
-define(FRAME_RESUME, 2).
-define(FRAME_DATA,   3).
-define(FRAME_ACK,    4).
-define(FRAME_FIN,    5).

-type path() :: [node()].
-type seq()  :: non_neg_integer().

-type frame() ::
        {create, binary(), node(), path()}
      | {resume, binary(), seq(), path()}
      | {data, seq(), binary()}
      | {ack, seq()}
      | {fin, seq()}.

-export_type([frame/0]).

%%====================================================================
%% Encoders
%%====================================================================

-spec circuit_id() -> binary().
circuit_id() ->
    crypto:strong_rand_bytes(?ID_BYTES).

-spec encode_create(binary(), node(), path()) -> binary().
encode_create(Id, InitNode, Path)
  when is_binary(Id), byte_size(Id) =:= ?ID_BYTES,
       is_atom(InitNode), is_list(Path), length(Path) =< ?MAX_PATH ->
    InitBin = atom_to_binary(InitNode, utf8),
    InitLen = byte_size(InitBin),
    true = InitLen =< ?MAX_NAME,
    PathBins = encode_path(Path),
    <<?FRAME_CREATE:8,
      ?ID_BYTES:8, Id/binary,
      InitLen:16/big, InitBin/binary,
      (length(Path)):8, PathBins/binary>>.

-spec encode_resume(binary(), seq(), path()) -> binary().
encode_resume(Id, RxNextExpectedSeq, Path)
  when is_binary(Id), byte_size(Id) =:= ?ID_BYTES,
       is_integer(RxNextExpectedSeq), RxNextExpectedSeq >= 0,
       is_list(Path), length(Path) =< ?MAX_PATH ->
    PathBins = encode_path(Path),
    <<?FRAME_RESUME:8,
      ?ID_BYTES:8, Id/binary,
      RxNextExpectedSeq:48/big,
      (length(Path)):8, PathBins/binary>>.

-spec encode_data(seq(), iodata()) -> iodata().
encode_data(Seq, Payload) when is_integer(Seq), Seq >= 0 ->
    Bin = iolist_to_binary(Payload),
    Len = byte_size(Bin),
    <<?FRAME_DATA:8, Seq:48/big, Len:32/big, Bin/binary>>.

-spec encode_ack(seq()) -> binary().
encode_ack(CumulativeSeq) when is_integer(CumulativeSeq), CumulativeSeq >= 0 ->
    <<?FRAME_ACK:8, CumulativeSeq:48/big>>.

-spec encode_fin(seq()) -> binary().
encode_fin(Seq) when is_integer(Seq), Seq >= 0 ->
    <<?FRAME_FIN:8, Seq:48/big>>.

encode_path(Path) ->
    << <<(encode_name(N))/binary>> || N <- Path >>.

encode_name(Node) when is_atom(Node) ->
    Bin = atom_to_binary(Node, utf8),
    Len = byte_size(Bin),
    true = Len =< ?MAX_NAME,
    <<Len:16/big, Bin/binary>>.

%%====================================================================
%% Decoder
%%====================================================================

%% @doc Try to peel one frame off the front of `Buffer'. The frame is
%% returned as a tagged tuple together with the unconsumed tail.
%% Incomplete buffers return `{more, BytesNeeded}'. Malformed input
%% returns `{error, _}'.
-spec try_decode(binary()) ->
    {ok, frame(), Rest :: binary()}
  | {more, non_neg_integer()}
  | {error, term()}.
try_decode(<<>>) ->
    {more, 1};
try_decode(<<?FRAME_CREATE:8, R/binary>>) ->
    decode_create_or_resume(R, fun create_to_frame/4);
try_decode(<<?FRAME_RESUME:8, R/binary>>) ->
    decode_resume(R);
try_decode(<<?FRAME_DATA:8, Seq:48/big, Len:32/big, R/binary>>)
  when byte_size(R) >= Len ->
    <<Payload:Len/binary, Rest/binary>> = R,
    {ok, {data, Seq, Payload}, Rest};
try_decode(<<?FRAME_DATA:8, _Seq:48/big, Len:32/big, R/binary>>) ->
    {more, Len - byte_size(R)};
try_decode(<<?FRAME_DATA:8, _/binary>> = B) ->
    %% Less than 1+6+4 = 11 bytes after tag.
    {more, 11 - byte_size(B)};
try_decode(<<?FRAME_ACK:8, Seq:48/big, Rest/binary>>) ->
    {ok, {ack, Seq}, Rest};
try_decode(<<?FRAME_ACK:8, _/binary>> = B) ->
    {more, 7 - byte_size(B)};
try_decode(<<?FRAME_FIN:8, Seq:48/big, Rest/binary>>) ->
    {ok, {fin, Seq}, Rest};
try_decode(<<?FRAME_FIN:8, _/binary>> = B) ->
    {more, 7 - byte_size(B)};
try_decode(<<Tag:8, _/binary>>) ->
    {error, {bad_frame_tag, Tag}}.

decode_create_or_resume(<<IdLen:8, R/binary>>, Build)
  when byte_size(R) >= IdLen ->
    <<Id:IdLen/binary, R1/binary>> = R,
    decode_after_id(Id, R1, Build);
decode_create_or_resume(<<IdLen:8, R/binary>>, _Build) ->
    {more, IdLen - byte_size(R)};
decode_create_or_resume(<<>>, _Build) ->
    {more, 1}.

decode_after_id(Id, <<InitLen:16/big, R/binary>>, Build)
  when byte_size(R) >= InitLen ->
    <<InitBin:InitLen/binary, R1/binary>> = R,
    InitAtom = to_atom(InitBin),
    decode_after_init(Id, InitAtom, R1, Build);
decode_after_id(_Id, <<InitLen:16/big, R/binary>>, _Build) ->
    {more, InitLen - byte_size(R)};
decode_after_id(_Id, _Buf, _Build) ->
    {more, 2}.

decode_after_init(Id, InitAtom, <<PathLen:8, R/binary>>, Build) ->
    case decode_path(R, PathLen, []) of
        {ok, Path, Rest} -> {ok, Build(Id, InitAtom, Path, Rest), Rest};
        {more, N}        -> {more, N}
    end;
decode_after_init(_Id, _Init, _Buf, _Build) ->
    {more, 1}.

create_to_frame(Id, Init, Path, _Rest) ->
    {create, Id, Init, Path}.

%% RESUME has the same skeleton as CREATE plus a 6-byte
%% RxNextExpectedSeq sandwiched between Id and PathLen.
decode_resume(<<IdLen:8, R/binary>>) when byte_size(R) >= IdLen ->
    <<Id:IdLen/binary, R1/binary>> = R,
    case R1 of
        <<RxNext:48/big, PathLen:8, R2/binary>> ->
            case decode_path(R2, PathLen, []) of
                {ok, Path, Rest} -> {ok, {resume, Id, RxNext, Path}, Rest};
                {more, N}        -> {more, N}
            end;
        _ ->
            {more, 7 - byte_size(R1)}
    end;
decode_resume(<<IdLen:8, R/binary>>) ->
    {more, IdLen - byte_size(R)};
decode_resume(<<>>) ->
    {more, 1}.

decode_path(Rest, 0, Acc) ->
    {ok, lists:reverse(Acc), Rest};
decode_path(<<NameLen:16/big, R/binary>>, N, Acc) when byte_size(R) >= NameLen ->
    <<NameBin:NameLen/binary, R2/binary>> = R,
    decode_path(R2, N - 1, [to_atom(NameBin) | Acc]);
decode_path(<<NameLen:16/big, R/binary>>, _N, _Acc) ->
    {more, NameLen - byte_size(R)};
decode_path(R, _N, _Acc) ->
    {more, 2 - byte_size(R)}.

%% Existing-atom-first to avoid creating atoms from unsanitised wire
%% data when the node is one we already know.
to_atom(Bin) when is_binary(Bin) ->
    case (catch binary_to_existing_atom(Bin, utf8)) of
        {'EXIT', _} -> binary_to_atom(Bin, utf8);
        Atom when is_atom(Atom) -> Atom
    end.

%% (Build callback unused in this branch; kept for shape parity with
%% decode_create_or_resume.)
-compile({nowarn_unused_function, [{create_to_frame, 4}]}).
