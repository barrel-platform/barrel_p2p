%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% Shared filesystem helpers.
%%%
%%% `write_secure/2' is the atomic-write-with-restrictive-permissions
%%% primitive used by every on-disk secret in the tree (trust-store
%%% pins, Ed25519 keypair, TLS private key). Two race-closures:
%%%
%%%   1. Permissions are set on the temp file *before* any plaintext
%%%      bytes are written, so the file never lives on disk with
%%%      world-readable mode while it contains secret data.
%%%
%%%   2. The reveal is a `file:rename/2', which is atomic within a
%%%      single filesystem on the POSIX targets we support. A crash
%%%      mid-write leaves the temp file behind, never a half-written
%%%      destination.
%%%
-module(mycelium_file).

-export([write_secure/2]).

%% @doc Atomically write `Data' to `Path' with 0600 permissions.
%% Writes through a `Path ++ ".tmp"' shadow, chmods the empty file
%% to 0600, then writes the payload and renames. Cleans up the
%% temp file on any failure.
-spec write_secure(file:name_all(), iodata()) -> ok | {error, term()}.
write_secure(Path, Data) ->
    TmpPath = iolist_to_binary([Path, <<".tmp">>]),
    case file:open(TmpPath, [write, raw, binary]) of
        {ok, F} ->
            try
                ok = file:change_mode(TmpPath, 8#600),
                ok = file:write(F, Data),
                ok = file:close(F),
                case file:rename(TmpPath, Path) of
                    ok ->
                        ok;
                    {error, _} = E ->
                        _ = file:delete(TmpPath),
                        E
                end
            catch
                _:Reason ->
                    catch file:close(F),
                    _ = file:delete(TmpPath),
                    {error, Reason}
            end;
        {error, _} = E ->
            E
    end.
