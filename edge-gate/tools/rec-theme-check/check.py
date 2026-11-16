# rec.example.com theme check: does the Carbon theme (public/rec/theme.css + shell.js) still fit
# the recorder's WebUI? Run by rec-theme-check.sh inside the Playwright image. It talks to the
# recorder directly (127.0.0.1:11419, Basic auth) and adds the theme the way nginx does.
# Exit 0 = fits, 1 = something the theme relies on changed, 2 = could not test (recorder down ...).
import os, re, sys, asyncio
from playwright.async_api import async_playwright

BASE = "http://127.0.0.1:11419"
REC = "/work/rec"          # = /opt/1panel/www/common/turnstile/public/rec
user, pw = os.environ["REC_AUTH"].split(":", 1)
HEAD = '<link rel="stylesheet" href="/__turnstile/rec/theme.css"><script src="/__turnstile/rec/shell.js"></script>'
ANCHOR = re.compile(r'<meta charset="?UTF-8"?>', re.I)   # what sub_filter in rec.conf looks for
fails = []

def check(ok, what):
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok: fails.append(what)

async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        ctx = await b.new_context(viewport={"width": 1280, "height": 800},
                                  http_credentials={"username": user, "password": pw})
        # 1. nginx can only add the theme if the page still has <meta charset="UTF-8">.
        for path in ("/", "/ui/", "/file/", "/player/"):
            try:
                r = await ctx.request.get(BASE + path)
            except Exception as e:
                print("cannot reach recorder:", e); sys.exit(2)
            if r.status in (401, 502, 503): print("recorder answered", r.status, "on", path); sys.exit(2)
            check(r.status == 200 and bool(ANCHOR.search(await r.text())), f"{path} has <meta charset> for nginx to inject after")

        async def serve(route):
            name = route.request.url.split("/__turnstile/rec/")[1].split("?")[0]
            ext = name.rsplit(".", 1)[-1]
            ct = {"css": "text/css", "js": "application/javascript", "woff2": "font/woff2", "svg": "image/svg+xml"}.get(ext, "application/octet-stream")
            await route.fulfill(path=os.path.join(REC, name), content_type=ct)
        await ctx.route("**/__turnstile/rec/**", serve)
        async def inject(route):
            r = await route.fetch()
            if route.request.resource_type != "document":
                return await route.fulfill(response=r)
            t = (await r.body()).decode("utf-8", "replace")
            t = ANCHOR.sub(lambda m: m.group(0) + HEAD, t, count=1)
            await route.fulfill(response=r, body=t, headers={**r.headers, "content-type": "text/html; charset=utf-8"})
        await ctx.route(lambda u: "/__turnstile/" not in u, inject)

        page = await ctx.new_page()
        js = page.evaluate
        # 2. WebUI room list, dark (the default).
        await page.goto(BASE + "/ui/recorder/local/rooms", wait_until="networkidle")
        try:
            await page.wait_for_selector(".n-layout-header", timeout=15000)
        except Exception:
            check(False, "WebUI has a Naive UI header (.n-layout-header)")
        else:
            await page.wait_for_timeout(1500)
            check(await js("document.documentElement.dataset.recPage") == "ui", "shell.js recognised the WebUI")
            check(await js("!!document.querySelector('.n-layout[class*=\"__layout-dark\"]')"), "dark/light still detectable from the layout class")
            check(await js("Math.round(document.querySelector('.n-layout-header').getBoundingClientRect().height)") == 48, "header is the 48px Carbon header")
            check(await js("!!document.querySelector('.n-layout-header .rec-shell__actions')"), "Sign out sits in the WebUI header")
            check("IBM Plex" in await js("getComputedStyle(document.body).fontFamily"), "IBM Plex font applied")
            check(await js("getComputedStyle(document.querySelector('.n-layout-header')).backgroundColor") == "rgb(22, 22, 22)", "header colour is Carbon Gray 100")
            names = await js("[...document.querySelectorAll('.n-button')].map(b => b.className).join(' ')")
            check(bool(re.search(r"__button-\w+-[a-z]+", names)), "Naive buttons still carry hash classes (__button-dark-xxxx)")
            add = await js("""(() => { const b = [...document.querySelectorAll('.n-button')].find(b => b.textContent.includes('添加房间'));
                                        return b ? getComputedStyle(b).backgroundColor : null })()""")
            check(add == "rgb(15, 98, 254)", f"'添加房间' is the blue primary button (got {add})")
            quat = await js("""(() => { const b = document.querySelector('.n-button[class*="hl"]');
                                        return b ? getComputedStyle(b).backgroundColor : 'none' })()""")
            check(quat in ("rgba(0, 0, 0, 0)", "none"), f"quaternary (⋮) buttons are ghost buttons (got {quat})")
        # 3. Static pages.
        for path, sel in (("/", ".rec-shell"), ("/file/", ".rec-page-head"), ("/player/", ".rec-shell")):
            await page.goto(BASE + path, wait_until="networkidle")
            check(await js(f"!!document.querySelector('{sel}')"), f"{path} has the Carbon shell")
        await b.close()
    print("RESULT", "fits" if not fails else f"{len(fails)} check(s) failed")
    sys.exit(1 if fails else 0)

asyncio.run(main())
