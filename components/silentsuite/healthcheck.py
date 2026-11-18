# Container healthcheck for silentsuite (#192): exit 0 only on exactly 200
# from the API's readiness endpoint. Upstream's "any status below 500" probe
# also passes on a 301 redirect loop or a 400 Host rejection. A file, run as
# HealthCmd=["python","/healthcheck.py"], so no shell or quoting is involved:
# an inline `python -c "..."` HealthCmd reached bow's /bin/sh as
# "unterminated quoted string" and the container never became healthy.
import http.client
import sys

try:
    conn = http.client.HTTPConnection("localhost", 3735, timeout=5)
    conn.request("GET", "/api/v1/authentication/is_etebase/")
    sys.exit(0 if conn.getresponse().status == 200 else 1)
except OSError:
    sys.exit(1)
