import sys, re
src, dst = sys.argv[1], sys.argv[2]
ps = '{"auths":{"example.com":{"auth":"Zm9vOmJhcg=="},"registry.example.com:8443":{"auth":"Zm9vOmJhcg=="}}}'
ssh = open('/tmp/g4-val/keys/id.pub').read().strip()
ca = open('/tmp/g4-val/keys/ca.pem').read().strip().splitlines()
t = open(src).read()
t = re.sub(r"(?m)^pullSecret:.*$", "pullSecret: '%s'" % ps, t)
t = re.sub(r"(?m)^sshKey:.*$", "sshKey: '%s'" % ssh, t)
# additionalTrustBundle block: replace indented body
def repl(m):
    return m.group(1) + "\n" + "\n".join("  " + l for l in ca) + "\n"
t = re.sub(r"(?m)^(additionalTrustBundle: \|-?)\n((?:  .*\n)+)", repl, t)
t = t.replace("<local_registry>/<local_repository_name>", "registry.example.com:8443/ocp5")
open(dst, 'w').write(t)
