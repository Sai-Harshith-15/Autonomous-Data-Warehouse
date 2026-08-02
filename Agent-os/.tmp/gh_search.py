import json, sys

d = json.load(sys.stdin)
for r in d.get('items', []):
    name = r['full_name']
    stars = r['stargazers_count']
    desc = (r['description'] or 'N/A')[:120]
    lic = r['license']['spdx_id'] if r.get('license') else 'NO LICENSE'
    url = r['html_url']
    print(f"{name} | {stars} | {desc} | {lic} | {url}")
