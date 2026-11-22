import json, os, sys, urllib.request, hashlib
# Key comes from the environment only. Never commit it.
KEY = os.environ.get('ENDZONE_API_KEY', '')
# Raw paid responses stay private (outside git).
RAW = os.environ.get('ENDZONE_RAW_DIR', 'endzone-raw')
def call(tool, body, save=None):
    req = urllib.request.Request(f'https://mcp.endzoneapi.com/v1/{tool}', data=json.dumps(body).encode(),
        headers={'Content-Type':'application/json','x-api-key':KEY,
                 'x-idempotency-key': hashlib.sha1((tool+json.dumps(body,sort_keys=True)).encode()).hexdigest()})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            hdrs = {k:v for k,v in r.headers.items() if k.lower().startswith('x-credits')}
            data = json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {'_http': e.code, '_body': e.read().decode()[:300]}
    if save:
        json.dump(data, open(os.path.join(RAW, save), 'w'))
    data['_hdrs'] = hdrs
    return data
