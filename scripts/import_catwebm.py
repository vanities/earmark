import os, re, json, sys, glob
POSTS = os.path.join(sys.argv[1], "_posts")
STAR = "★"
COMMENT_STARTS = ("the second","the third","the final","the first book","great","love","enjoyed","been","interesting","using","one of","this dude","continuing","wow","incredible","had no","finally","hoping","witty","a wildly","a bit","brando","imo","solid","fast-paced","the premise","the world","the story","carl","abercrombie","dinniman","liked","re-read")

def resolve_links(s):
    s = re.sub(r"\[([^\]]+)\]\[[^\]]*\]", r"\1", s)
    s = re.sub(r"\[([^\]]+)\]\(<?[^)]*>?\)", r"\1", s)
    s = re.sub(r"\[([^\]]+)\]", r"\1", s)
    s = re.sub(r"\]\[[^\]]*\]|\]\([^)]*\)", "", s)
    s = re.sub(r"<[^>]*>|https?://\S+", "", s)
    return s.replace("]", "").replace("[", "")

def clean_title(t):
    t = re.sub(r"[★☆].*$", "", t)
    t = re.sub(r'^["“]|["”]$', "", t.strip())
    # drop a trailing " - lowercase comment" or " – comment"
    t = re.sub(r"\s+[-–—]\s+.*$", "", t)
    t = re.sub(r"\s*[>)\]]+$", "", t)
    return t.strip(" \t:–—-\"'“”")

def clean_author(a):
    a = a.strip()
    # take a run of Name tokens (allow initials like T., M.D., C.S., particles, and/&, commas)
    m = re.match(r"((?:[A-Z][\w.'’-]*|de|van|von|del)(?:[ ,]+(?:and|&|de|van|von|[A-Z][\w.'’-]*)){0,6})", a)
    if not m: return None
    name = re.sub(r"[ ,]+(and)?\s*$", "", m.group(1)).strip(" ,&")
    return name or None

entries = []
for path in sorted(glob.glob(os.path.join(POSTS, "*"))):
    base = os.path.basename(path); mm = re.match(r"(\d{4})-(\d{2})-\d{2}", base)
    if not mm: continue
    year, month = int(mm.group(1)), int(mm.group(2))
    text = open(path, encoding="utf-8", errors="replace").read()
    sec = re.search(r"#+\s*Books[^\n]*\n(.*?)(?:\n#+\s|\n---|\Z)", text, re.S | re.I)
    if not sec: continue
    for raw in sec.group(1).splitlines():
        orig = raw.strip()
        if not orig or orig.startswith(("!","#","<img","(")): continue
        has_star = STAR in orig; is_link = orig.startswith("[")
        if not (has_star or is_link or re.match(r"[A-Z][^\n]{1,70}\s+[Bb]y[:\s]+[A-Z]", orig)): continue
        low = re.sub(r"^\[","",orig).lower()
        if low.startswith(COMMENT_STARTS) and not has_star and not is_link: continue
        rating = orig.count(STAR)
        line = resolve_links(orig)
        parts = re.split(r"\s+[Bb]y[:\s]+", line, maxsplit=1)
        title = clean_title(parts[0])
        author = clean_author(parts[1]) if len(parts) > 1 else None
        if not title or len(title) < 2: continue
        if title.lower().startswith(COMMENT_STARTS) and rating == 0 and not author: continue
        entries.append({"title": title, "author": author, "year": year, "month": month, "rating": rating or None})

def norm(t): return re.sub(r"[^a-z0-9]","",t.lower())
best = {}
for e in entries:
    k = norm(e["title"])
    if len(k) < 3: continue
    prev = best.get(k)
    if prev is None or (e["year"],e["month"]) >= (prev["year"],prev["month"]):
        if prev: e["rating"] = e["rating"] or prev["rating"]; e["author"] = e["author"] or prev["author"]
        best[k] = e
final = sorted(best.values(), key=lambda e:(e["year"],e["month"]))
print(f"{len(entries)} lines → {len(final)} unique books\n")
for e in final:
    print(f"  {e['year']}-{e['month']:02d} {STAR*(e['rating'] or 0):5s} {e['title'][:46]:46s} — {e['author'] or '?'}")
json.dump(final, open(sys.argv[2],"w"), indent=2)
