-module(gcm_api).
-export([push/4]).

-define(BASEURL, "https://android.googleapis.com/gcm/send").

-type header()  :: {string(), string()}.
-type headers() :: [header(),...].
-type regids()  :: [binary(),...].
-type message() :: [tuple(),...].
-type result()  :: {number(), non_neg_integer(), non_neg_integer(), non_neg_integer(), [any()]}.

-spec push(http_uri:uri(), regids(),message(),string()) -> {'error',any()} | {'noreply','unknown'} | {'ok',result()}.
push(URI, RegIds, Message, Key) ->
    Request = jsx:encode([{<<"registration_ids">>, RegIds}|Message]),
    ApiKey = string:concat("key=", Key),

    try http_request(post, URI,
        [{"Authorization", ApiKey}], <<"application/json">>, Request)
    of
        {ok, 200, _Headers, ClientRef} ->
            {ok, Body} = hackney:body(ClientRef),
            Json = jsx:decode(Body),
            error_logger:info_msg("Result was: ~p~n", [Json]),
            {ok, result_from(Json)};
        {ok, 400, _, ClientRef} ->
            {ok, Body} = hackney:body(ClientRef),
            error_logger:error_msg("Error in request. Reason was: Bad Request - ~p~n", [Body]),
            {error, Body};
        {ok, 401, _, _} ->
            error_logger:error_msg("Error in request. Reason was: authorization error~n", []),
            {error, auth_error};
        {ok, Code, Headers, _} when Code >= 500 andalso Code =< 599 ->
            RetryTime = retry_after_from(Headers),
            error_logger:error_msg("Error in request. Reason was: retry. Will retry in: ~p~n",
                [RetryTime]),
            {error, {retry, RetryTime}};
        {ok, _, _, _Body} ->
            error_logger:error_msg("Error in request. Reason was: timeout~n", []),
            {error, timeout};
        {error, Reason} ->
            error_logger:error_msg("Error in request. Reason was: ~p~n", [Reason]),
            {error, Reason};
        OtherError ->
            error_logger:error_msg("Error in request. Reason was: ~p~n", [OtherError]),
            {noreply, unknown}
    catch
        Exception ->
            error_logger:error_msg("Error in request. Exception ~p while calling URL: ~p~n", [Exception, ?BASEURL]),
            {error, Exception}
    end.

-spec result_from([{binary(),any()}]) -> result().
result_from(Json) ->
    {
      proplists:get_value(<<"multicast_id">>, Json),
      proplists:get_value(<<"success">>, Json),
      proplists:get_value(<<"failure">>, Json),
      proplists:get_value(<<"canonical_ids">>, Json),
      proplists:get_value(<<"results">>, Json)
    }.

-spec retry_after_from(headers()) -> 'no_retry' | non_neg_integer().
retry_after_from(Headers) ->
    case proplists:get_value(<<"retry-after">>, Headers) of
        undefined ->
            no_retry;
        RetryTime_b ->
            RetryTime = binary_to_list(RetryTime_b),
            case string:to_integer(RetryTime) of
                {Time, _} when is_integer(Time) ->
                    Time;
                {error, no_integer} ->
                    Date = qdate:to_unixtime(RetryTime),
                    Date - qdate:unixtime()
            end
    end.

http_request(Method, URL, Headers, ContentType, Body) ->
    hackney:request(Method, URL,
        [{<<"Content-Type">>, ContentType} | Headers], Body, [{pool, gcm}]).
