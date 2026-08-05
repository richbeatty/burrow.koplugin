return {
    VERSION = "0.3.5-beta",
    DISPLAY_VERSION = "0.3.5 beta",
    STORE_ENGINE_VERSION = "1.2.0",

    -- Burrow is tested against KOReader 2026.07.2. Older releases are blocked,
    -- but newer releases and nightlies are allowed with a one-time warning.
    MIN_KOREADER = "2026.07.1",
    MIN_KOREADER_NORMALIZED = 202607010000,
    LAST_TESTED_KOREADER = "2026.07.2",
    LAST_TESTED_KOREADER_NORMALIZED = 202607020000,

    -- Add normalized inclusive ranges here only after a release is confirmed to
    -- break Burrow. A range may also include a human-readable reason.
    KNOWN_INCOMPATIBLE_KOREADER = {},
}
