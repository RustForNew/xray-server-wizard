from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit


PROJECT_DIR = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT_DIR / "xray-server-wizard.sh"
UUID_1 = "11111111-1111-4111-8111-111111111111"
UUID_2 = "22222222-2222-4222-8222-222222222222"

PROFILES = [
    *(('vless', transport, 'reality') for transport in ('tcp', 'xhttp', 'grpc')),
    *(('vless', transport, 'tls') for transport in ('tcp', 'xhttp', 'grpc', 'ws')),
    *(('trojan', transport, 'reality') for transport in ('tcp', 'xhttp', 'grpc')),
    *(('trojan', transport, 'tls') for transport in ('tcp', 'xhttp', 'grpc', 'ws')),
    ('hysteria2', 'hysteria2', 'tls'),
]


def find_bash() -> str:
    explicit = os.environ.get("BASH_BIN")
    candidates = [
        explicit,
        shutil.which("bash"),
        r"C:\Program Files\Git\bin\bash.exe",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return str(candidate)
    raise unittest.SkipTest("bash not found")


def find_xray() -> str | None:
    explicit = os.environ.get("XRAY_BIN")
    candidates = [explicit, shutil.which("xray")]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return str(candidate)
    return None


def find_nginx() -> str | None:
    explicit = os.environ.get("NGINX_BIN")
    candidates = [explicit, shutil.which("nginx")]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return str(candidate)
    return None


def base_env(protocol: str, transport: str, security: str, cert: str = "cert.pem", key: str = "key.pem") -> dict[str, str]:
    if security == "tls" and transport == "tcp":
        site_mode = "fallback"
    elif security == "tls" and transport in ("xhttp", "grpc", "ws"):
        site_mode = "reverse-proxy"
    elif security == "tls" and transport == "hysteria2":
        site_mode = "parallel"
    else:
        site_mode = "none"
    server_security = "none" if site_mode == "reverse-proxy" else security
    xray_listen = "127.0.0.1" if site_mode == "reverse-proxy" else "0.0.0.0"
    xray_port = "18080" if site_mode == "reverse-proxy" else "24443"
    env = os.environ.copy()
    env.update(
        {
            "MSYS2_ENV_CONV_EXCL": "*",
            "MSYS_NO_PATHCONV": "1",
            "WZ_PROTOCOL": protocol,
            "WZ_TRANSPORT": transport,
            "WZ_SECURITY": security,
            "WZ_SERVER_SECURITY": server_security,
            "WZ_PORT": "24443",
            "WZ_XRAY_LISTEN": xray_listen,
            "WZ_XRAY_PORT": xray_port,
            "WZ_SITE_MODE": site_mode,
            "WZ_INTERNAL_PORT": "18080",
            "WZ_SITE_ROOT": "/var/www/xray-server-wizard",
            "WZ_ENABLE_IPV6": "0",
            "WZ_CLIENT_HOST": "vpn.example.com",
            "WZ_SNI": "www.microsoft.com",
            "WZ_PATH": "/assets/test",
            "WZ_SERVICE_NAME": "grpc-test",
            "WZ_XHTTP_MODE": "stream-one",
            "WZ_TLS_CERT": cert,
            "WZ_TLS_KEY": key,
            "WZ_REALITY_TARGET": "www.microsoft.com:443",
            "WZ_REALITY_PRIVATE_KEY": "mDYcP66qsTv2uAdJWCjmHrqriEReqV9EgW8fm4zP_VI",
            "WZ_REALITY_PUBLIC_KEY": "Pygm0-VejeeAh6R6nZydvu5fYep51S9QvuI0wSyMkkM",
            "WZ_SHORT_ID": "0123456789abcdef",
            "WZ_FINGERPRINT": "chrome",
            "WZ_NAME_PREFIX": "Test VPN",
            "WZ_CREDENTIALS": f"{UUID_1}\n{UUID_2}",
        }
    )
    return env


def run_internal(command: str, env: dict[str, str]) -> str:
    result = subprocess.run(
        [find_bash(), str(SCRIPT), command],
        cwd=PROJECT_DIR,
        env=env,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if result.returncode != 0:
        raise AssertionError(f"{command} failed:\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}")
    return result.stdout


def collect_auto_profile_for_test(profile_choice: int, security_choice: int | None = None) -> tuple[str, ...]:
    env = os.environ.copy()
    env.update({"MSYS2_ENV_CONV_EXCL": "*", "MSYS_NO_PATHCONV": "1", "XRAY_WIZARD_SOURCE_ONLY": "1"})
    bash_code = r'''
source "$1"
TEST_PROFILE_CHOICE="$2"
TEST_SECURITY_CHOICE="$3"
menu() {
  if [[ "$1" == "Теперь выберите защиту транспорта" ]]; then
    printf '%s' "$TEST_SECURITY_CHOICE"
  else
    printf '%s' "$TEST_PROFILE_CHOICE"
  fi
}
collect_client_count() { CLIENT_COUNT=10; }
detect_public_ip() { printf '203.0.113.10'; }
collect_domain() { DOMAIN='vpn.example.com'; CLIENT_HOST="$DOMAIN"; SNI="$DOMAIN"; }
random_hex() { printf 'abc123'; }
collect_auto_profile
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$MODE" "$PROTOCOL" "$TRANSPORT" "$SECURITY" "$CLIENT_COUNT" "$CLIENT_HOST" "$XHTTP_MODE"
'''
    result = subprocess.run(
        [find_bash(), "-c", bash_code, "_", str(SCRIPT), str(profile_choice), str(security_choice or "")],
        cwd=PROJECT_DIR,
        env=env,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if result.returncode != 0:
        raise AssertionError(f"auto collection failed:\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}")
    return tuple(result.stdout.splitlines()[-1].split("\t"))


class WizardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.bash = find_bash()
        cls.xray = find_xray()
        cls.nginx = find_nginx()
        cls.temp_dir = tempfile.TemporaryDirectory(prefix="xray-wizard-tests-")
        cls.temp_path = Path(cls.temp_dir.name)
        (cls.temp_path / "logs").mkdir()
        (cls.temp_path / "temp").mkdir()
        cls.cert_path = cls.temp_path / "cert.crt"
        cls.key_path = cls.temp_path / "cert.key"
        if cls.xray:
            prefix = cls.temp_path / "cert"
            result = subprocess.run(
                [cls.xray, "tls", "cert", "--domain=example.com", f"--file={prefix}"],
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
            )
            if result.returncode != 0:
                raise AssertionError(f"cannot generate test certificate: {result.stderr}")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp_dir.cleanup()

    def test_bash_syntax(self) -> None:
        result = subprocess.run(
            [self.bash, "-n", str(SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_auto_vless_tcp_reality_returns_success_after_client_count(self) -> None:
        result = collect_auto_profile_for_test(1, 1)
        self.assertEqual(result, ("auto", "vless", "tcp", "reality", "10", "203.0.113.10", "auto"))

    def test_auto_profile_then_security_selection(self) -> None:
        tls = collect_auto_profile_for_test(1, 2)
        self.assertEqual(tls, ("auto", "vless", "tcp", "tls", "10", "vpn.example.com", "auto"))
        trojan = collect_auto_profile_for_test(6, 1)
        self.assertEqual(trojan, ("auto", "trojan", "xhttp", "reality", "10", "203.0.113.10", "auto"))
        xhttp_tls = collect_auto_profile_for_test(2, 2)
        self.assertEqual(xhttp_tls, ("auto", "vless", "xhttp", "tls", "10", "vpn.example.com", "auto"))
        websocket = collect_auto_profile_for_test(4)
        self.assertEqual(websocket, ("auto", "vless", "ws", "tls", "10", "vpn.example.com", "auto"))
        hysteria = collect_auto_profile_for_test(9)
        self.assertEqual(hysteria, ("auto", "hysteria2", "hysteria2", "tls", "10", "vpn.example.com", "auto"))

    def test_reality_target_self_guard_only_blocks_same_server_port(self) -> None:
        env = os.environ.copy()
        env.update({"MSYS2_ENV_CONV_EXCL": "*", "MSYS_NO_PATHCONV": "1", "XRAY_WIZARD_SOURCE_ONLY": "1"})
        bash_code = r'''
source "$1"
PORT=443
resolve_host_addresses() {
  case "$1" in
    self.example) printf '203.0.113.10\n' ;;
    external.example) printf '198.51.100.20\n' ;;
  esac
}
collect_self_addresses() { printf '127.0.0.1\n203.0.113.10\n'; }
reality_target_points_to_self 'self.example:443' || exit 10
if reality_target_points_to_self 'self.example:8443'; then exit 11; fi
if reality_target_points_to_self 'external.example:443'; then exit 12; fi
printf 'guard-ok\n'
'''
        result = subprocess.run(
            [find_bash(), "-c", bash_code, "_", str(SCRIPT)],
            cwd=PROJECT_DIR,
            env=env,
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("guard-ok", result.stdout)

    def test_all_supported_configs_have_expected_shape(self) -> None:
        for protocol, transport, security in PROFILES:
            with self.subTest(protocol=protocol, transport=transport, security=security):
                env = base_env(protocol, transport, security, str(self.cert_path), str(self.key_path))
                config = json.loads(run_internal("--internal-render-config", env))
                inbound = config["inbounds"][0]
                expected_protocol = "hysteria" if protocol == "hysteria2" else protocol
                expected_network = {
                    "tcp": "raw",
                    "xhttp": "xhttp",
                    "grpc": "grpc",
                    "ws": "websocket",
                    "hysteria2": "hysteria",
                }[transport]
                self.assertEqual(inbound["protocol"], expected_protocol)
                self.assertEqual(inbound["streamSettings"]["network"], expected_network)
                expected_security = "none" if security == "tls" and transport in ("xhttp", "grpc", "ws") else security
                self.assertEqual(inbound["streamSettings"]["security"], expected_security)
                credential_key = "users" if protocol == "hysteria2" else "clients"
                self.assertEqual(len(inbound["settings"][credential_key]), 2)
                if security == "tls" and transport == "tcp":
                    self.assertEqual(inbound["settings"]["fallbacks"], [{"dest": "127.0.0.1:18080", "xver": 0}])
                    self.assertEqual(inbound["streamSettings"]["tlsSettings"]["alpn"], ["http/1.1"])
                elif security == "tls" and transport in ("xhttp", "grpc", "ws"):
                    self.assertEqual(inbound["listen"], "127.0.0.1")
                    self.assertEqual(inbound["port"], 18080)
                    self.assertNotIn("tlsSettings", inbound["streamSettings"])
                if protocol == "vless" and transport == "tcp":
                    self.assertEqual(inbound["settings"]["clients"][0]["flow"], "xtls-rprx-vision")
                elif protocol == "vless":
                    self.assertNotIn("flow", inbound["settings"]["clients"][0])

    @unittest.skipUnless(find_xray(), "set XRAY_BIN to validate configs with Xray")
    def test_all_supported_configs_are_accepted_by_xray(self) -> None:
        assert self.xray is not None
        for index, (protocol, transport, security) in enumerate(PROFILES):
            with self.subTest(protocol=protocol, transport=transport, security=security):
                env = base_env(protocol, transport, security, str(self.cert_path), str(self.key_path))
                config_path = self.temp_path / f"config-{index}.json"
                config_path.write_text(run_internal("--internal-render-config", env), encoding="utf-8")
                result = subprocess.run(
                    [self.xray, "run", "-test", "-config", str(config_path)],
                    check=False,
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_vless_xhttp_reality_link(self) -> None:
        env = base_env("vless", "xhttp", "reality")
        line = run_internal("--internal-render-links", env).splitlines()[0]
        credential, uri = line.split("\t", 1)
        parsed = urlsplit(uri)
        query = parse_qs(parsed.query)
        self.assertEqual(credential, UUID_1)
        self.assertEqual(parsed.scheme, "vless")
        self.assertEqual(parsed.hostname, "vpn.example.com")
        self.assertEqual(parsed.port, 24443)
        self.assertEqual(query["type"], ["xhttp"])
        self.assertEqual(query["security"], ["reality"])
        self.assertEqual(query["path"], ["/assets/test"])
        self.assertEqual(query["mode"], ["stream-one"])
        self.assertEqual(query["pbk"], [env["WZ_REALITY_PUBLIC_KEY"]])
        self.assertEqual(unquote(parsed.fragment), "Test VPN-01")

    def test_trojan_grpc_tls_link(self) -> None:
        env = base_env("trojan", "grpc", "tls")
        _, uri = run_internal("--internal-render-links", env).splitlines()[0].split("\t", 1)
        parsed = urlsplit(uri)
        query = parse_qs(parsed.query)
        self.assertEqual(parsed.scheme, "trojan")
        self.assertEqual(query["type"], ["grpc"])
        self.assertEqual(query["security"], ["tls"])
        self.assertEqual(query["serviceName"], ["grpc-test"])
        self.assertEqual(query["alpn"], ["h2"])
        self.assertNotIn("flow", query)

    def test_hysteria2_link(self) -> None:
        env = base_env("hysteria2", "hysteria2", "tls")
        _, uri = run_internal("--internal-render-links", env).splitlines()[0].split("\t", 1)
        parsed = urlsplit(uri)
        query = parse_qs(parsed.query)
        self.assertEqual(parsed.scheme, "hysteria2")
        self.assertEqual(query["sni"], ["www.microsoft.com"])
        self.assertEqual(query["alpn"], ["h3"])

    def test_two_credentials_produce_two_unique_links(self) -> None:
        env = base_env("vless", "tcp", "reality")
        lines = run_internal("--internal-render-links", env).splitlines()
        self.assertEqual(len(lines), 2)
        self.assertNotEqual(lines[0], lines[1])
        self.assertIn(UUID_1, lines[0])
        self.assertIn(UUID_2, lines[1])

    def test_tls_tcp_nginx_uses_plaintext_fallback_only(self) -> None:
        env = base_env("vless", "tcp", "tls")
        config = run_internal("--internal-render-nginx", env)
        self.assertIn("listen 127.0.0.1:18080;", config)
        self.assertNotIn("listen 24443 ssl", config)
        self.assertIn("return 301 https://$host:24443$request_uri;", config)

    def test_tls_websocket_nginx_terminates_tls_and_proxies_upgrade(self) -> None:
        env = base_env("trojan", "ws", "tls")
        config = run_internal("--internal-render-nginx", env)
        self.assertIn("listen 24443 ssl http2;", config)
        self.assertIn("location ^~ /assets/test", config)
        self.assertIn("proxy_pass http://127.0.0.1:18080;", config)
        self.assertIn('proxy_set_header Connection "upgrade";', config)

    def test_tls_grpc_and_xhttp_nginx_use_grpc_pass(self) -> None:
        for protocol, transport in (("trojan", "grpc"), ("vless", "xhttp")):
            with self.subTest(protocol=protocol, transport=transport):
                env = base_env(protocol, transport, "tls")
                config = run_internal("--internal-render-nginx", env)
                expected_route = "/grpc-test" if transport == "grpc" else "/assets/test"
                self.assertIn(f"location ^~ {expected_route}", config)
                self.assertIn("grpc_pass grpc://127.0.0.1:18080;", config)
                self.assertNotIn("proxy_pass http://127.0.0.1:18080;", config)

    def test_hysteria2_nginx_owns_tcp_side_of_public_port(self) -> None:
        env = base_env("hysteria2", "hysteria2", "tls")
        config = run_internal("--internal-render-nginx", env)
        self.assertIn("listen 24443 ssl http2;", config)
        self.assertNotIn("proxy_pass", config)
        self.assertNotIn("grpc_pass", config)

    def test_nginx_adds_ipv6_listeners_when_dns_has_aaaa(self) -> None:
        env = base_env("vless", "ws", "tls")
        env["WZ_ENABLE_IPV6"] = "1"
        config = run_internal("--internal-render-nginx", env)
        self.assertIn("listen [::]:80;", config)
        self.assertIn("listen [::]:24443 ssl http2;", config)

    @unittest.skipUnless(find_nginx(), "set NGINX_BIN to validate generated sites with Nginx")
    def test_all_tls_sites_are_accepted_by_nginx(self) -> None:
        assert self.nginx is not None
        tls_profiles = [profile for profile in PROFILES if profile[2] == "tls"]
        for index, (protocol, transport, security) in enumerate(tls_profiles):
            with self.subTest(protocol=protocol, transport=transport):
                env = base_env(protocol, transport, security, self.cert_path.as_posix(), self.key_path.as_posix())
                env["WZ_SITE_ROOT"] = self.temp_path.as_posix()
                site = run_internal("--internal-render-nginx", env)
                config_path = self.temp_path / f"nginx-{index}.conf"
                config_path.write_text(f"events {{}}\nhttp {{\n{site}\n}}\n", encoding="utf-8")
                result = subprocess.run(
                    [self.nginx, "-t", "-p", self.temp_path.as_posix() + "/", "-c", config_path.as_posix()],
                    check=False,
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
