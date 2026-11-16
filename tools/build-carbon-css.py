"""Build carbon.css for the rec.example.com sign-in page.

Keeps only the rules of Carbon's compiled bundle.css whose selectors use classes
from the page (plus element / :root rules), then prepends the theme tokens the kept
rules read (white on :root, g100 under [data-theme="g100"]), resolved from tokens.json.
usage: python3 -I build.py <design-system project dir> <html> <extra css> <out css>
"""
import json, re, sys

proj, html_path, extra_css_path, out_path = sys.argv[1:5]
css = open(proj + "/components/bundle.css", encoding="utf-8-sig").read()
tokens = json.load(open(proj + "/tokens.json"))

used = set()
for src in (open(html_path).read(), open(extra_css_path).read()):
    for m in re.finditer(r'class="([^"]*)"', src):
        used.update(m.group(1).split())
    used.update(re.findall(r"\.(cds--[\w-]+)", src))
# Classes the Lua renderer adds at run time.
used.update(sys.argv[5].split() if len(sys.argv) > 5 else [])

# --- split the bridge rule off, drop the font @import ---
css = re.sub(r"@import url\([^)]*\);", "", css)
b0 = css.index(":root,[data-theme]{")
b1 = css.index("}", b0)
bridge = dict(re.findall(r"--cds-([\w-]+):var\(--([\w-]+)\)", css[b0:b1]))
css = css[:b0] + css[b1 + 1:]
css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)


def blocks(s):
    """Yield (prelude, body) for each top-level block; body None for ;-statements."""
    i, n = 0, len(s)
    while i < n:
        j = i
        depth = 0
        quote = None
        while j < n:
            c = s[j]
            if quote:
                if c == "\\":
                    j += 1
                elif c == quote:
                    quote = None
            elif c in "\"'":
                quote = c
            elif c == "{":
                break
            elif c == ";" and depth == 0:
                break
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            j += 1
        if j >= n:
            return
        prelude = s[i:j].strip()
        if s[j] == ";":
            yield prelude, None
            i = j + 1
            continue
        k = j + 1
        depth = 1
        quote = None
        while k < n and depth:
            c = s[k]
            if quote:
                if c == "\\":
                    k += 1
                elif c == quote:
                    quote = None
            elif c in "\"'":
                quote = c
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            k += 1
        yield prelude, s[j + 1:k - 1]
        i = k


def split_selectors(sel):
    out, depth, cur = [], 0, ""
    for c in sel:
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        if c == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += c
    out.append(cur)
    return [x.strip() for x in out if x.strip()]


def strip_not(sel):
    # :not(.x) never requires .x on the page; drop its contents before checking.
    out, i = "", 0
    while i < len(sel):
        if sel.startswith(":not(", i):
            depth, j = 1, i + 5
            while j < len(sel) and depth:
                depth += {"(": 1, ")": -1}.get(sel[j], 0)
                j += 1
            i = j
        else:
            out += sel[i]
            i += 1
    return out


def keep_selector(sel):
    s = strip_not(sel)
    s = re.sub(r"\[[^\]]*\]", "", s)          # attribute values may contain dots
    classes = re.findall(r"\.(-?[_a-zA-Z][\w-]*)", s)
    if any(c not in used for c in classes):
        return False
    if re.search(r"\b(table|th|td|tr|thead|tbody|select|textarea|option|fieldset|legend)\b", s) and not classes:
        return True
    return True


keyframes = {}


def prune(s):
    out = []
    for prelude, body in blocks(s):
        if body is None:
            continue
        if prelude.startswith("@keyframes") or prelude.startswith("@-webkit-keyframes"):
            keyframes[prelude.split()[-1]] = prelude + "{" + body + "}"
            continue
        if prelude.startswith("@font-face"):
            continue
        if prelude.startswith("@"):
            inner = prune(body)
            if inner:
                out.append(prelude + "{" + inner + "}")
            continue
        sels = [x for x in split_selectors(prelude) if keep_selector(x)]
        if sels:
            out.append(",".join(sels) + "{" + body.strip() + "}")
    return "".join(out)


kept = prune(css)
names = set(re.findall(r"animation(?:-name)?:\s*([\w-]+)", kept))
kept += "".join(v for k, v in keyframes.items() if k in names)

# --- tokens ---
extra = open(extra_css_path).read()
refs = set(re.findall(r"var\(--cds-([\w-]+)", kept + extra))
defined = set(re.findall(r"--cds-([\w-]+)\s*:", kept + extra))
color = {t["name"]: t["value"] for t in tokens["color"]["tokens"]}
plain = {}
for fam, v in tokens.items():
    if isinstance(v, dict) and "tokens" in v and fam != "color":
        for t in v["tokens"]:
            plain[t["name"]] = t["value"]


def resolve(name, theme, seen=()):
    v = color[name]
    if isinstance(v, dict):
        v = v.get(theme, v.get("white"))
    m = re.fullmatch(r"\{([\w.-]+)\}", str(v))
    if m and m.group(1) not in seen:
        return resolve(m.group(1), theme, seen + (name,))
    return v


root, dark = [], []
for r in sorted(refs - defined):
    tok = bridge.get(r, r)
    if tok in color:
        w, d = resolve(tok, "white"), resolve(tok, "g100")
        root.append(f"--cds-{r}:{w}")
        if d != w:
            dark.append(f"--cds-{r}:{d}")
    elif tok in plain:
        root.append(f"--cds-{r}:{plain[tok]}")

head = ("/* Carbon (@carbon/styles 1.119.0, Apache-2.0) trimmed to the classes the live status\n"
        "   pages use, with the theme tokens it reads. Generated by build.py; do not edit. */\n")
head += ":root{" + ";".join(root) + "}\n"
head += '[data-theme="g100"]{color-scheme:dark;' + ";".join(dark) + "}\n"
open(out_path, "w").write(head + kept + "\n")
print(len(used), "classes;", len(kept), "bytes kept;", len(root), "tokens;", len(dark), "dark overrides")
print("unresolved:", sorted(r for r in refs - defined if bridge.get(r, r) not in color and bridge.get(r, r) not in plain)[:80])
