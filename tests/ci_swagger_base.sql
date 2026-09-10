-- Behavioural probes for the OpenAPI base URL (#70).
--
-- Runs in the stub lane's setup chain (docker/docker-compose-ci.yml), as postgres, after
-- endpoint_schema.sql has created haf_stats_endpoints.root(). psql runs the chain with
-- ON_ERROR_STOP=1, so a RAISE EXCEPTION here fails the job.
--
-- WHY THIS FILE EXISTS. The tavern stage in tests/tavern/rewriter/public_paths.tavern.yaml
-- proves ONE path through root(): the configured value reaches the wire. It cannot reach the
-- other arms, because it would have to re-seed haf_stats_app.app_config and restart PostgREST
-- between requests. Those arms are the ones that matter operationally:
--
--   * haf_api_node passes `--swagger-url=${PUBLIC_HOSTNAME}`, and PUBLIC_HOSTNAME is a BARE
--     HOSTNAME ("your.hostname.com" in its .env.example). If root() took that literally it
--     would publish `servers: [{url: "your.hostname.com"}]` -- not a URL, and worse than the
--     hardcoded value #70 set out to fix. The rejection of hostname-shaped values is the whole
--     reason this change is safe to land WITHOUT a matching haf_api_node MR, so it needs a test
--     that fails if someone "simplifies" the guard away.
--   * A half-installed database (no app_config row, or no table at all) must still serve a
--     document. GET / returning 500 would take the spec down for every consumer. Both are
--     staged for real below -- PostgreSQL DDL is transactional, so even the DROP is undone
--     by the ROLLBACK.
--
-- Everything runs inside ONE transaction that is rolled back, so the row ci_setup.sql seeded
-- ('/ci-base-url', which the tavern stage asserts) survives intact. Without that the DELETE
-- below would strip it and the tavern stage would fail two containers later, blaming root().
BEGIN;

DO $probe$
DECLARE
    _input   TEXT;
    _want    TEXT;
    _got     TEXT;
    _default CONSTANT TEXT := '/haf-stats-api';
    _cases   CONSTANT TEXT[][] := ARRAY[
        -- input                            expected servers[0].url
        ['/haf-stats-api',                  '/haf-stats-api'],
        ['/',                               '/'],                 -- the boundary case the //-rejection must not eat
        ['/some/deep/prefix',               '/some/deep/prefix'],
        ['https://api.example.com/',        'https://api.example.com/'],
        ['https://api.example.com/haf-stats-api', 'https://api.example.com/haf-stats-api'],
        ['http://127.0.0.1:3001/',          'http://127.0.0.1:3001/'],
        -- Everything below must FALL BACK. The first is haf_api_node's live argument.
        ['your.hostname.com',               '/haf-stats-api'],
        ['testapi.hivescan.info',           '/haf-stats-api'],
        ['localhost',                       '/haf-stats-api'],
        ['',                                '/haf-stats-api'],
        ['ftp://example.com',               '/haf-stats-api'],
        ['haf-stats-api',                   '/haf-stats-api'],
        -- Protocol-relative: Swagger UI would resolve these against ANOTHER ORIGIN and
        -- send "Try it out" requests, and any credentials entered, off-site.
        -- An origin with NO PATH. This is what a scheme-prefixed PUBLIC_HOSTNAME would
        -- send, and the node routes only /haf-stats-api/*, so publishing it verbatim
        -- would 404 every generated call.
        ['https://example.com',             '/haf-stats-api'],
        ['http://127.0.0.1:3001',           '/haf-stats-api'],
        ['https://',                        '/haf-stats-api'],
        ['//evil.com',                      '/haf-stats-api'],
        ['//evil.com/haf-stats-api',        '/haf-stats-api'],
        ['///evil.com',                     '/haf-stats-api']
    ];
    _i INT;
BEGIN
    FOR _i IN 1 .. array_length(_cases, 1) LOOP
        _input := _cases[_i][1];
        _want  := _cases[_i][2];

        UPDATE haf_stats_app.app_config SET swagger_base_url = _input;

        SELECT haf_stats_endpoints.root()::jsonb #>> '{servers,0,url}' INTO _got;

        IF _got IS DISTINCT FROM _want THEN
            RAISE EXCEPTION
                'swagger base URL: input % should publish % but published %',
                quote_literal(_input), quote_literal(_want), quote_literal(_got);
        END IF;
    END LOOP;

    -- Exactly one servers entry, always. jsonb_set replaces the array wholesale, so a
    -- regression that appended instead would leave the stale prefix reachable behind the
    -- new one -- and generated clients pick the FIRST entry.
    IF (SELECT jsonb_array_length(haf_stats_endpoints.root()::jsonb -> 'servers')) <> 1 THEN
        RAISE EXCEPTION 'swagger base URL: servers must hold exactly one entry';
    END IF;

    -- A NULL row must fall back, not publish a null url or drop the key.
    UPDATE haf_stats_app.app_config SET swagger_base_url = NULL;
    SELECT haf_stats_endpoints.root()::jsonb #>> '{servers,0,url}' INTO _got;
    IF _got IS DISTINCT FROM _default THEN
        RAISE EXCEPTION 'swagger base URL: NULL should fall back to %, got %',
            quote_literal(_default), quote_literal(_got);
    END IF;

    -- No row at all -- a database installed before app_config was seeded.
    DELETE FROM haf_stats_app.app_config;
    SELECT haf_stats_endpoints.root()::jsonb #>> '{servers,0,url}' INTO _got;
    IF _got IS DISTINCT FROM _default THEN
        RAISE EXCEPTION 'swagger base URL: an empty app_config should fall back to %, got %',
            quote_literal(_default), quote_literal(_got);
    END IF;

    -- No TABLE at all. This is the endpoints-only load: a database that has
    -- haf_stats_endpoints but not the current haf_stats_app, which is exactly what a
    -- hot-patch of endpoint_schema.sql produces. GET / must serve a document, not 500.
    --
    -- An earlier version of this file claimed this arm "a transaction cannot stage"
    -- and grepped root()'s source for the word `undefined_table` instead. That was
    -- wrong: PostgreSQL DDL is transactional, so the DROP and the privileges it
    -- cascades are both undone by the ROLLBACK below -- the same mechanism that already
    -- protects the DELETE above. Staging it tests the behaviour instead of the wording.
    DROP TABLE haf_stats_app.app_config;
    SELECT haf_stats_endpoints.root()::jsonb #>> '{servers,0,url}' INTO _got;
    IF _got IS DISTINCT FROM _default THEN
        RAISE EXCEPTION 'swagger base URL: a MISSING app_config should fall back to %, got %',
            quote_literal(_default), quote_literal(_got);
    END IF;

    -- The document must still be the CURATED one through all of this, not an error shape.
    IF (SELECT haf_stats_endpoints.root()::jsonb #>> '{info,title}')
       IS DISTINCT FROM 'HAF Stats - Blockchain Analytics' THEN
        RAISE EXCEPTION 'swagger base URL: patching servers damaged the document';
    END IF;

    RAISE NOTICE 'swagger base URL probes OK: % accept/reject arms + NULL + missing row + missing table',
        array_length(_cases, 1);
END
$probe$;

ROLLBACK;

-- The table survived the rollback, with its seeded row, for the tavern stage.
DO $after$
DECLARE
    _url TEXT;
BEGIN
    SELECT c.swagger_base_url INTO _url FROM haf_stats_app.app_config AS c;
    IF _url IS DISTINCT FROM '/ci-base-url' THEN
        RAISE EXCEPTION 'the probes did not roll back cleanly: app_config holds %, and the tavern stage two containers later asserts /ci-base-url', quote_nullable(_url);
    END IF;
END
$after$;
