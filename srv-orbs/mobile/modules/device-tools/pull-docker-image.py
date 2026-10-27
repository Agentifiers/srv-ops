#!/usr/bin/env python3
"""Fetch one platform of a Docker Hub image, pinned by manifest digest, into a
`docker load`-able docker-archive tarball, without a Docker daemon.

  pull-docker-image.py <repo> <index-or-manifest-digest> <tag> <blob-cache-dir> <out.tar>

Every manifest and blob is verified against its sha256 digest; blobs are cached
in <blob-cache-dir>/sha256/<hex> so rebuilds are offline. Layers stay gzipped:
`docker load` decompresses them.
"""
import hashlib
import io
import json
import os
import sys
import tarfile
import urllib.request

REGISTRY = "https://registry-1.docker.io"
INDEX_TYPES = (
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
)
MANIFEST_TYPES = (
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
)
PLATFORM = ("linux", "amd64")


def token(repo):
    url = f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull"
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)["token"]


def get(url, tok, accept=None):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"})
    if accept:
        req.add_header("Accept", ", ".join(accept))
    return urllib.request.urlopen(req, timeout=600)


def verify(data, digest):
    algo, hexsum = digest.split(":", 1)
    if algo != "sha256" or hashlib.sha256(data).hexdigest() != hexsum:
        sys.exit(f"digest mismatch for {digest}")


def manifest(repo, digest, tok):
    with get(f"{REGISTRY}/v2/{repo}/manifests/{digest}", tok, INDEX_TYPES + MANIFEST_TYPES) as r:
        body = r.read()
    verify(body, digest)
    return json.loads(body)


def blob(repo, digest, tok, cache):
    path = os.path.join(cache, "sha256", digest.split(":", 1)[1])
    if os.path.exists(path):
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        if "sha256:" + h.hexdigest() == digest:
            return path
        os.unlink(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    h = hashlib.sha256()
    with get(f"{REGISTRY}/v2/{repo}/blobs/{digest}", tok) as r, open(path + ".part", "wb") as f:
        for chunk in iter(lambda: r.read(1 << 20), b""):
            h.update(chunk)
            f.write(chunk)
    if "sha256:" + h.hexdigest() != digest:
        os.unlink(path + ".part")
        sys.exit(f"digest mismatch for blob {digest}")
    os.rename(path + ".part", path)
    return path


def main():
    repo, digest, tag, cache, out = sys.argv[1:]
    tok = token(repo)
    m = manifest(repo, digest, tok)
    if m.get("mediaType") in INDEX_TYPES or "manifests" in m:
        picks = [d for d in m["manifests"]
                 if (d.get("platform", {}).get("os"), d.get("platform", {}).get("architecture")) == PLATFORM]
        if len(picks) != 1:
            sys.exit(f"no unique {PLATFORM} manifest in {digest}")
        m = manifest(repo, picks[0]["digest"], tok)
    config = blob(repo, m["config"]["digest"], tok, cache)
    layers = [blob(repo, l["digest"], tok, cache) for l in m["layers"]]

    entries = {"Config": os.path.basename(config) + ".json",
               "RepoTags": [f"{repo}:{tag}"],
               "Layers": [os.path.basename(l) + ".tar.gz" for l in layers]}
    tmp = out + ".part"
    with tarfile.open(tmp, "w", format=tarfile.PAX_FORMAT) as t:
        meta = json.dumps([entries]).encode()
        info = tarfile.TarInfo("manifest.json")
        info.size = len(meta)
        t.addfile(info, io.BytesIO(meta))
        t.add(config, arcname=entries["Config"])
        for path, name in zip(layers, entries["Layers"]):
            t.add(path, arcname=name)
    os.chmod(tmp, 0o644)
    os.rename(tmp, out)


if __name__ == "__main__":
    main()
