import json

import pytest

from app import config


def _load(api=None, bundle=None):
    env = {}
    if api is not None:
        env["PAGES_API_KEYS"] = json.dumps(api)
    if bundle is not None:
        env["PAGES_BUNDLE_KEYS"] = bundle if isinstance(bundle, str) else json.dumps(bundle)
    return config.load_config(env)


def test_bundle_keys_parse_to_token_map():
    cfg = _load(
        api={"wizard": "tok-w"},
        bundle={"tok-b": {"user": "showcase", "slug": "homelab"}},
    )
    assert cfg.bundle_map == {"tok-b": ("showcase", "homelab")}
    assert cfg.key_map == {"tok-w": "wizard"}


def test_bundle_keys_default_empty():
    assert _load().bundle_map == {}


@pytest.mark.parametrize(
    "bundle",
    [
        "not json",
        ["tok"],
        {"tok": "showcase"},
        {"tok": {"user": "showcase"}},
        {"tok": {"slug": "homelab"}},
        {"tok": {"user": "", "slug": "homelab"}},
        {"tok": {"user": "..", "slug": "homelab"}},
        {"tok": {"user": "a/b", "slug": "homelab"}},
        {"tok": {"user": "showcase", "slug": "../x"}},
        {"tok": {"user": "showcase", "slug": "a..b"}},
        {"tok": {"user": "showcase", "slug": 3}},
        {"": {"user": "showcase", "slug": "homelab"}},
    ],
)
def test_bundle_keys_rejects_malformed(bundle):
    with pytest.raises(config.ConfigError):
        _load(bundle=bundle)


def test_bundle_token_may_not_reuse_an_api_token():
    with pytest.raises(config.ConfigError):
        _load(
            api={"wizard": "same"},
            bundle={"same": {"user": "showcase", "slug": "homelab"}},
        )
