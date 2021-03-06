%%==============================================================================
%% Copyright 2016 Erlang Solutions Ltd.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================
%%%-------------------------------------------------------------------
%%% @doc
%% options and defaults:
%% [
%%     {selection_strategy, available_worker},
%%     {server, (required)},
%%     {path_prefix, ""},
%%     {request_timeout, 2000},
%%     {pool_timeout, 5000}, % waiting for worker - not for all selection strategies
%%     {pool_size, 20},
%%     {http_opts, []}, % passed to fusco
%%     {pool_opts, []} % extra options for worker_pool
%% ]
%%%
%%% @end
%%% Created : 26. Jun 2018 13:07
%%%-------------------------------------------------------------------
-module(mongoose_http_client).
-author("bartlomiej.gorny@erlang-solutions.com").
-include("mongoose.hrl").

%% API
-export([start/0, stop/0, start_pool/2, stop_pool/1, get/3, post/4]).
-export([get_pool/1]). % for backward compatibility

%% Exported for testing
-export([start/1]).

-spec start() -> ok.
start() ->
    mongoose_wpool:ensure_started(),
    mongoose_wpool_http:init(),
    case ejabberd_config:get_local_option(http_connections) of
        undefined -> ok;
        Opts -> start(Opts)
    end.

-spec stop() -> any().
stop() ->
    case ejabberd_config:get_local_option(http_connections) of
        undefined -> ok;
        Opts -> lists:map(fun({Name, _}) -> stop_pool(Name) end, Opts)
    end.

-spec start_pool(atom(), list()) -> ok | {error, already_started}.
start_pool(PoolName, Opts) ->
    case ets:lookup(?MODULE, PoolName) of
        [] ->
            mongoose_wpool:ensure_started(),
            do_start_pool(PoolName, Opts),
            ok;
        _ ->
            {error, already_started}
    end.

-spec stop_pool(atom()) -> ok.
stop_pool(Name) ->
    mongoose_wpool:stop(http, global, Name),
    ok.

-spec get(atom(), binary(), list()) ->
    {ok, {binary(), binary()}} | {error, any()}.
get(Pool, Path, Headers) ->
    make_request(Pool, Path, <<"GET">>, Headers, <<>>).

-spec post(atom(), binary(), list(), binary()) ->
    {ok, {binary(), binary()}} | {error, any()}.
post(Pool, Path, Headers, Query) ->
    make_request(Pool, Path, <<"POST">>, Headers, Query).

get_pool(PoolName) -> PoolName.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


start(Opts) ->
    [start_pool(Name, PoolOpts) || {Name, PoolOpts} <- Opts],
    ok.

do_start_pool(PoolName, Opts) ->
    SelectionStrategy = gen_mod:get_opt(selection_strategy, Opts, available_worker),
    PoolTimeout = gen_mod:get_opt(pool_timeout, Opts, 5000),
    PoolSize = gen_mod:get_opt(pool_size, Opts, 20),
    PoolSettings = [{strategy, SelectionStrategy}, {call_timeout, PoolTimeout},
                    {workers, PoolSize}
                    | gen_mod:get_opt(pool_opts, Opts, [])],
    mongoose_wpool:start(http, global, PoolName, PoolSettings, Opts).

make_request(PoolName, Path, Method, Headers, Query) ->
    case ets:lookup(?MODULE, PoolName) of
        [] ->
            {error, pool_not_started};
        [{_, PathPrefix, RequestTimeout}] ->
            make_request(PoolName, PathPrefix, RequestTimeout, Path,
                         Method, Headers, Query)
    end.

make_request(PoolName, PathPrefix, RequestTimeout, Path, Method, Headers, Query) ->
    FullPath = <<PathPrefix/binary, Path/binary>>,
    Req = {request, FullPath, Method, Headers, Query, 2, RequestTimeout},
    try mongoose_wpool:call(http, global, PoolName, Req) of
        {ok, {{Code, _Reason}, _RespHeaders, RespBody, _, _}} ->
            {ok, {Code, RespBody}};
        {error, timeout} ->
            {error, request_timeout};
        {'EXIT', Reason} ->
            {error, {'EXIT', Reason}};
        {error, Reason} ->
            {error, Reason}
    catch
        exit:timeout ->
            {error, pool_timeout};
        exit:no_workers ->
            {error, pool_down};
        Type:Error ->
            {error, {Type, Error}}
    end.
