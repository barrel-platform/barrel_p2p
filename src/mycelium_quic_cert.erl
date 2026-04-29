-module(mycelium_quic_cert).

%% X.509 Self-Signed Certificate Generation for QUIC TLS
%%
%% Generates self-signed certificates for QUIC distribution encryption.
%% Uses public_key application for certificate creation.
%%
%% The certificates are self-signed because QUIC/TLS only provides
%% encryption - actual node authentication is done via Erlang cookie
%% (handled by dist_util in erlang_quic).

-include_lib("public_key/include/public_key.hrl").

-export([
    ensure_cert/0,
    ensure_cert/1,
    generate_cert/1,
    get_cert_paths/0
]).

%% Default certificate parameters
-define(DEFAULT_DAYS, 365).
-define(DEFAULT_KEY_BITS, 2048).
-define(DEFAULT_CERT_DIR, "data/quic").

%%====================================================================
%% API
%%====================================================================

%% @doc Ensure QUIC certificates exist, generating them if needed.
%% Uses default directory from application config.
-spec ensure_cert() -> ok | {error, term()}.
ensure_cert() ->
    CertDir = application:get_env(mycelium, quic_cert_dir, ?DEFAULT_CERT_DIR),
    ensure_cert(CertDir).

%% @doc Ensure QUIC certificates exist in the specified directory.
-spec ensure_cert(file:filename()) -> ok | {error, term()}.
ensure_cert(CertDir) ->
    CertFile = filename:join(CertDir, "node.crt"),
    KeyFile = filename:join(CertDir, "node.key"),
    case filelib:is_regular(CertFile) andalso filelib:is_regular(KeyFile) of
        true ->
            %% Certificates exist
            ok;
        false ->
            %% Generate new certificates
            generate_cert(CertDir)
    end.

%% @doc Generate a new self-signed certificate and key.
-spec generate_cert(file:filename()) -> ok | {error, term()}.
generate_cert(CertDir) ->
    %% Ensure directory exists
    ok = filelib:ensure_dir(filename:join(CertDir, "dummy")),

    %% Generate RSA key pair
    case generate_key() of
        {ok, PrivateKey, PublicKey} ->
            %% Create self-signed certificate
            case create_certificate(PrivateKey, PublicKey) of
                {ok, Cert} ->
                    %% Write files
                    CertFile = filename:join(CertDir, "node.crt"),
                    KeyFile = filename:join(CertDir, "node.key"),
                    case write_cert_files(CertFile, KeyFile, Cert, PrivateKey) of
                        ok ->
                            logger:info("QUIC certificates generated in ~s", [CertDir]),
                            ok;
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% @doc Get the paths to the certificate and key files.
-spec get_cert_paths() -> {CertFile :: file:filename(), KeyFile :: file:filename()}.
get_cert_paths() ->
    CertDir = application:get_env(mycelium, quic_cert_dir, ?DEFAULT_CERT_DIR),
    {filename:join(CertDir, "node.crt"), filename:join(CertDir, "node.key")}.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @private
%% Generate an RSA key pair.
generate_key() ->
    try
        PrivateKey = public_key:generate_key({rsa, ?DEFAULT_KEY_BITS, 65537}),
        #'RSAPrivateKey'{modulus = N, publicExponent = E} = PrivateKey,
        PublicKey = #'RSAPublicKey'{modulus = N, publicExponent = E},
        {ok, PrivateKey, PublicKey}
    catch
        _:Reason ->
            {error, {key_generation_failed, Reason}}
    end.

%% @private
%% Create a self-signed X.509 certificate.
create_certificate(PrivateKey, PublicKey) ->
    try
        %% Get node name for CN
        NodeName = case node() of
            nonode@nohost -> "mycelium-node";
            Node -> atom_to_list(Node)
        end,

        %% Build subject
        Subject = {rdnSequence, [
            [#'AttributeTypeAndValue'{
                type = ?'id-at-commonName',
                value = {utf8String, list_to_binary(NodeName)}
            }],
            [#'AttributeTypeAndValue'{
                type = ?'id-at-organizationName',
                value = {utf8String, <<"Mycelium">>}
            }]
        ]},

        %% Validity period
        Now = calendar:universal_time(),
        NotBefore = format_time(Now),
        NotAfter = format_time(add_days(Now, ?DEFAULT_DAYS)),

        Validity = #'Validity'{
            notBefore = {utcTime, NotBefore},
            notAfter = {utcTime, NotAfter}
        },

        %% Serial number (random)
        Serial = rand:uniform(16#7FFFFFFF),

        %% Subject public key info
        SubjectPKInfo = #'SubjectPublicKeyInfo'{
            algorithm = #'AlgorithmIdentifier'{
                algorithm = ?'rsaEncryption',
                parameters = 'NULL'
            },
            subjectPublicKey = public_key:der_encode('RSAPublicKey', PublicKey)
        },

        %% TBS Certificate
        TBSCert = #'TBSCertificate'{
            version = v3,
            serialNumber = Serial,
            signature = #'AlgorithmIdentifier'{
                algorithm = ?'sha256WithRSAEncryption',
                parameters = 'NULL'
            },
            issuer = Subject,
            validity = Validity,
            subject = Subject,
            subjectPublicKeyInfo = SubjectPKInfo,
            extensions = create_extensions()
        },

        %% Sign the certificate
        TBSDer = public_key:der_encode('TBSCertificate', TBSCert),
        Signature = public_key:sign(TBSDer, sha256, PrivateKey),

        %% Build final certificate
        Cert = #'Certificate'{
            tbsCertificate = TBSCert,
            signatureAlgorithm = #'AlgorithmIdentifier'{
                algorithm = ?'sha256WithRSAEncryption',
                parameters = 'NULL'
            },
            signature = Signature
        },

        {ok, Cert}
    catch
        _:Reason ->
            {error, {certificate_creation_failed, Reason}}
    end.

%% @private
%% Create X.509 v3 extensions.
create_extensions() ->
    [
        %% Basic Constraints: CA:FALSE
        #'Extension'{
            extnID = ?'id-ce-basicConstraints',
            critical = true,
            extnValue = public_key:der_encode('BasicConstraints',
                #'BasicConstraints'{cA = false})
        },
        %% Key Usage: Digital Signature, Key Encipherment
        #'Extension'{
            extnID = ?'id-ce-keyUsage',
            critical = true,
            extnValue = public_key:der_encode('KeyUsage',
                [digitalSignature, keyEncipherment])
        },
        %% Extended Key Usage: TLS Server Auth, TLS Client Auth
        #'Extension'{
            extnID = ?'id-ce-extKeyUsage',
            critical = false,
            extnValue = public_key:der_encode('ExtKeyUsageSyntax',
                [?'id-kp-serverAuth', ?'id-kp-clientAuth'])
        }
    ].

%% @private
%% Write certificate and key to PEM files.
write_cert_files(CertFile, KeyFile, Cert, PrivateKey) ->
    try
        %% Encode certificate to DER
        CertDer = public_key:der_encode('Certificate', Cert),
        CertPem = public_key:pem_encode([{'Certificate', CertDer, not_encrypted}]),

        %% Encode private key to DER
        KeyDer = public_key:der_encode('RSAPrivateKey', PrivateKey),
        KeyPem = public_key:pem_encode([{'RSAPrivateKey', KeyDer, not_encrypted}]),

        %% Write files
        ok = file:write_file(CertFile, CertPem),
        ok = file:write_file(KeyFile, KeyPem),

        %% Set restrictive permissions on key file
        file:change_mode(KeyFile, 8#600),
        ok
    catch
        _:Reason ->
            {error, {file_write_failed, Reason}}
    end.

%% @private
%% Format datetime for X.509 UTCTime (YYMMDDHHMMSSZ).
format_time({{Year, Month, Day}, {Hour, Min, Sec}}) ->
    %% UTCTime uses 2-digit year
    Y = Year rem 100,
    lists:flatten(io_lib:format("~2..0w~2..0w~2..0w~2..0w~2..0w~2..0wZ",
                                [Y, Month, Day, Hour, Min, Sec])).

%% @private
%% Add days to a datetime.
add_days(DateTime, Days) ->
    Seconds = calendar:datetime_to_gregorian_seconds(DateTime),
    NewSeconds = Seconds + (Days * 24 * 60 * 60),
    calendar:gregorian_seconds_to_datetime(NewSeconds).
