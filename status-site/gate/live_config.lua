-- live status site: settings. Public values only; secrets are separate root-only files.
return {
    -- Where the secrets, the template and this file live (path inside the container).
    dir = "/www/sites/live/gate/",

    -- ESA AI captcha: 身份标 (top right of the ESA "AI 验证码" page) and the rule's 场景 ID.
    captcha_prefix = "esa-xxxxxxxxxx",
    captcha_scene = "SCENE_ID",
    captcha_region = "cn",
    -- ESA verifies the token itself and rejects bad ones, but ONLY while "拦截空 Token" is on in
    -- the ESA rule (with it off, ESA checked nothing, 2026-11-13). true = accept requests ESA let
    -- through. Set false to refuse all sign-ins (e.g. if that switch is ever turned off).
    captcha_trust_esa = true,
    -- If ESA forwards a verdict header, only these values count as a pass.
    captcha_pass_header = "x-captcha-verify-code",
    captcha_pass_values = { T001 = true },

    -- Passing the captcha signs the visitor in for a fixed sess_ttl seconds, counted from the
    -- captcha: reloads, new tabs and browser restarts in that window need no captcha, and
    -- activity does not extend it. After that the captcha is required again. entry_ttl is the
    -- one-time pass that carries the captcha result from /__gate/verify to "/".
    entry_ttl = 60,
    sess_ttl = 600,

    -- Recording requests (form on the status page; worker on the recorder host).
    data_dir = "/www/sites/live/data/",          -- requests.json, archive.json (not web-served)
    public_url = "https://rec-status.example.com", -- base of the review links in admin emails
    request_per_session = 3,   -- submissions per 10-minute sign-in
    request_per_hour = 20,     -- submissions per hour, whole site
    request_max_open = 30,     -- refuse new ones while this many await review
    request_keep_days = 30,    -- delete a request this long after its last change
    review_days = 7,           -- review links in the admin email stay valid this long
    -- After submitting, the visitor's page waits request_wait seconds for the admin. Approved in
    -- that time: the page shows the download link once the worker has made it (it keeps checking
    -- for up to request_watch seconds). Otherwise the page says the request is reviewed manually.
    request_wait = 300,
    request_watch = 1200,

    -- Static asset version; bump after editing anything in index/assets/.
    asset_v = "14",

    -- Privacy policy version the request form's consents refer to (stored with each request).
    policy_version = "2026-11-17",
}
