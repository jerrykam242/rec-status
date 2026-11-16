-- rec.example.com: /__turnstile/logout clears the session and returns to sign-in.
local auth = package.loaded.site_rec_auth
if not auth then
    auth = dofile("/www/common/turnstile/rec_auth.lua")
    package.loaded.site_rec_auth = auth
end

ngx.header["Cache-Control"] = "no-store"
ngx.header["Set-Cookie"] = auth.clear_cookies()
return ngx.redirect("/__turnstile/login?out=1", 303)
