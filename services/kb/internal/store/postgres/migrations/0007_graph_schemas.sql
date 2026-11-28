-- Graph schemas (ADR 0030, section 5). Applied only when schemas are enabled (and the graph is on). Idempotent.
-- {{schema}} is a validated, quoted identifier.
--
-- One row per collection: the canonical body (kept as text, so that its SHA-256 can be checked), the version and the SHA-256 of the body.
CREATE TABLE IF NOT EXISTS {{schema}}.graph_schemas (
    collection text        PRIMARY KEY,
    version    integer     NOT NULL CHECK (version >= 1),
    sha256     text        NOT NULL,
    body       text        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);
