from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT / "naiveproxy-server-wizard.sh"
BASH = Path(os.environ.get("BASH_BIN", r"C:\Program Files\Git\bin\bash.exe"))


def to_msys(path: Path) -> str:
    value = str(path.resolve()).replace("\\", "/")
    if len(value) >= 3 and value[1] == ":":
        return f"/{value[0].lower()}{value[2:]}"
    return value


def base_plan(**overrides: object) -> dict:
    plan = {
        "schema_version": 1,
        "wizard_version": "0.1.0",
        "server": {
            "domain": "proxy.example.com",
            "listen_port": 443,
            "http3": True,
            "auto_https_redirects": True,
        },
        "tls": {
            "mode": "acme",
            "acme_email": "ops@example.com",
            "certificate": "",
            "private_key": "",
        },
        "decoy": {
            "mode": "static",
            "upstream": "",
            "redirect": "",
            "title": "Web Service",
            "root": "/var/www/naiveproxy-wizard",
        },
        "privacy": {
            "probe_mode": "fallthrough",
            "probe_secret": "",
            "hide_ip": True,
            "hide_via": True,
            "exclude_activity_error_log": True,
        },
        "pac": {"enabled": False, "path": ""},
        "egress": {
            "target_ports_mode": "web",
            "target_ports": [80, 443],
            "acl_mode": "hardened",
            "acl_custom": [],
            "upstream": "",
            "dial_timeout": "30s",
            "max_idle_conns": 256,
            "max_idle_conns_per_host": 8,
        },
        "firewall": {"manage_ufw": True, "open_http_port": True},
        "install_mode": "quick",
        "server_build_mode": "source_patched",
        "upstream_versions": {
            "caddy_core": "v2.11.4",
            "server_release": "v2.11.2-naive",
            "forwardproxy_commit": "d62c80d3dd2c706b6b87579844d2397bddd18317",
            "recommended_client_release": "v150.0.7871.63-1",
        },
    }
    for dotted_key, value in overrides.items():
        target = plan
        parts = dotted_key.split("__")
        for part in parts[:-1]:
            target = target[part]
        target[parts[-1]] = value
    return plan


class WizardTestCase(unittest.TestCase):
    def setUp(self) -> None:
        if not BASH.exists():
            self.skipTest(f"Git Bash not found: {BASH}")
        self.temp = Path(tempfile.mkdtemp(prefix="naive-wizard-test-"))
        self.plan_path = self.temp / "settings.json"
        self.users_path = self.temp / "users.tsv"
        self.write_plan(base_plan())
        self.write_users(
            [
                ("alice", "Abcdefghijk1_234"),
                ("bob", "Zyxwvutsrqp9_876"),
            ]
        )

    def tearDown(self) -> None:
        shutil.rmtree(self.temp, ignore_errors=True)

    def write_plan(self, plan: dict) -> None:
        self.plan_path.write_text(
            json.dumps(plan, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def write_users(self, users: list[tuple[str, str]]) -> None:
        self.users_path.write_text(
            "".join(f"{username}\t{password}\n" for username, password in users),
            encoding="utf-8",
        )

    def run_wizard(
        self,
        *arguments: str,
        check: bool = True,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["NAIVE_WIZARD_TEST_MODE"] = "1"
        if extra_env:
            env.update(extra_env)
        command = [str(BASH), to_msys(SCRIPT), *arguments]
        return subprocess.run(
            command,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=check,
            env=env,
            timeout=60,
        )

    def render_config(self) -> str:
        result = self.run_wizard(
            "--internal-render-config",
            to_msys(self.plan_path),
            to_msys(self.users_path),
        )
        return result.stdout

    def test_version(self) -> None:
        result = self.run_wizard("--version")
        self.assertEqual(result.stdout.strip(), "NaiveProxy Server Wizard 0.1.0")

    def test_bash_syntax(self) -> None:
        result = subprocess.run(
            [str(BASH), "-n", to_msys(SCRIPT)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_settings_and_users_validate(self) -> None:
        result = self.run_wizard(
            "--internal-validate-settings",
            to_msys(self.plan_path),
            to_msys(self.users_path),
        )
        self.assertEqual(result.stdout.strip(), "OK")

    def test_json_boolean_strings_are_rejected(self) -> None:
        self.write_plan(base_plan(server__http3="false"))
        result = self.run_wizard(
            "--internal-validate-settings",
            to_msys(self.plan_path),
            to_msys(self.users_path),
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("JSON boolean", result.stderr)

    def test_existing_tls_source_paths_are_loaded_from_manifest(self) -> None:
        self.write_plan(
            base_plan(
                tls__mode="existing",
                tls__acme_email="",
                tls__certificate="/root/source-fullchain.pem",
                tls__private_key="/root/source-privkey.pem",
            )
        )
        code = (
            "export NAIVE_WIZARD_SOURCE_ONLY=1 NAIVE_WIZARD_TEST_MODE=1; "
            f"source {to_msys(SCRIPT)!r}; "
            f"load_settings {to_msys(self.plan_path)!r}; "
            "printf '%s\\n%s' \"$SOURCE_CERT_PATH\" \"$SOURCE_KEY_PATH\""
        )
        result = subprocess.run(
            [str(BASH), "-lc", code],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=True,
            timeout=30,
        )
        self.assertEqual(
            result.stdout,
            "/root/source-fullchain.pem\n/root/source-privkey.pem",
        )

    def test_non_443_listener_is_rejected(self) -> None:
        self.write_plan(base_plan(server__listen_port=8443))
        result = self.run_wizard(
            "--internal-validate-settings",
            to_msys(self.plan_path),
            to_msys(self.users_path),
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TCP/443", result.stderr)

    def test_duplicate_username_is_rejected(self) -> None:
        self.write_users(
            [
                ("same", "Abcdefghijk1_234"),
                ("same", "Zyxwvutsrqp9_876"),
            ]
        )
        result = self.run_wizard(
            "--internal-validate-settings",
            to_msys(self.plan_path),
            to_msys(self.users_path),
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_default_config_is_authenticated_and_hardened(self) -> None:
        config = self.render_config()
        self.assertIn("order forward_proxy first", config)
        self.assertIn("protocols h1 h2 h3", config)
        self.assertIn(":443, proxy.example.com", config)
        self.assertIn("admin off", config)
        self.assertNotIn("admin 127.0.0.1", config)
        self.assertEqual(config.count("basic_auth "), 2)
        self.assertIn('basic_auth "alice" "Abcdefghijk1_234"', config)
        self.assertIn("probe_resistance", config)
        self.assertIn("ports 80 443", config)
        self.assertIn("169.254.0.0/16", config)
        self.assertIn("fc00::/7", config)
        self.assertIn("exclude http.handlers.forward_proxy", config)
        self.assertIn("root * \"/var/www/naiveproxy-wizard\"", config)
        self.assertIn("file_server", config)

    def test_h2_only_config_disables_h3(self) -> None:
        self.write_plan(base_plan(server__http3=False))
        config = self.render_config()
        self.assertIn("protocols h1 h2", config)
        self.assertNotIn("protocols h1 h2 h3", config)

    def test_reverse_proxy_is_after_forward_proxy(self) -> None:
        self.write_plan(
            base_plan(
                decoy__mode="reverse_proxy",
                decoy__upstream="https://www.example.org",
            )
        )
        config = self.render_config()
        self.assertLess(config.index("forward_proxy {"), config.index("reverse_proxy "))
        self.assertNotIn("file_server", config)

    def test_upstream_omits_acl_and_ports(self) -> None:
        self.write_plan(
            base_plan(
                egress__upstream="https://hop-user:hop-pass@next.example.com:443",
                egress__target_ports_mode="unrestricted",
                egress__target_ports=[],
                egress__acl_mode="plugin_default",
            )
        )
        config = self.render_config()
        self.assertIn(
            'upstream "https://hop-user:hop-pass@next.example.com:443"',
            config,
        )
        self.assertNotIn("\n            ports ", config)
        self.assertNotIn("\n            acl {", config)

    def test_allowlist_ends_with_deny_all(self) -> None:
        self.write_plan(
            base_plan(
                egress__acl_mode="allowlist",
                egress__acl_custom=["example.com", "*.example.net"],
            )
        )
        config = self.render_config()
        self.assertIn("allow example.com *.example.net", config)
        self.assertIn("deny all", config)

    def test_client_bundle_contains_native_and_sing_box_variants(self) -> None:
        output = self.temp / "bundle"
        output.mkdir()
        self.run_wizard(
            "--internal-render-clients",
            to_msys(self.plan_path),
            to_msys(self.users_path),
            to_msys(output),
        )
        native_h2 = json.loads(
            (output / "native-001-alice-h2.json").read_text(encoding="utf-8")
        )
        native_h3 = json.loads(
            (output / "native-001-alice-h3.json").read_text(encoding="utf-8")
        )
        sing_h3 = json.loads(
            (output / "sing-box-001-alice-h3.json").read_text(encoding="utf-8")
        )
        self.assertTrue(native_h2["proxy"].startswith("https://"))
        self.assertTrue(native_h3["proxy"].startswith("quic://"))
        self.assertTrue(sing_h3["outbounds"][0]["quic"])
        self.assertEqual(sing_h3["outbounds"][0]["tls"]["server_name"], "proxy.example.com")

    def test_client_urls_percent_encode_manual_password(self) -> None:
        password = "LongPassword@/==99"
        self.write_users([("encoded-user", password)])
        output = self.temp / "bundle"
        output.mkdir()
        self.run_wizard(
            "--internal-render-clients",
            to_msys(self.plan_path),
            to_msys(self.users_path),
            to_msys(output),
        )
        native = json.loads(
            (output / "native-001-encoded-user-h2.json").read_text(encoding="utf-8")
        )
        self.assertIn("%40%2F%3D%3D", native["proxy"])

    def test_sanitized_report_has_no_credentials_or_upstream_secret(self) -> None:
        secret = "VerySecretPassword99"
        self.write_users([("report-user", secret)])
        self.write_plan(
            base_plan(
                egress__upstream="https://private-user:private-pass@next.example.com",
                egress__target_ports_mode="unrestricted",
                egress__target_ports=[],
                egress__acl_mode="plugin_default",
            )
        )
        output = self.temp / "bundle"
        output.mkdir()
        self.run_wizard(
            "--internal-render-clients",
            to_msys(self.plan_path),
            to_msys(self.users_path),
            to_msys(output),
        )
        report = (output / "install-report.json").read_text(encoding="utf-8")
        self.assertNotIn(secret, report)
        self.assertNotIn("private-pass", report)
        self.assertIn('"upstream_configured": true', report)

    def test_h2_only_bundle_has_no_h3_files(self) -> None:
        self.write_plan(base_plan(server__http3=False))
        output = self.temp / "bundle"
        output.mkdir()
        self.run_wizard(
            "--internal-render-clients",
            to_msys(self.plan_path),
            to_msys(self.users_path),
            to_msys(output),
        )
        self.assertFalse(any("-h3.json" in path.name for path in output.iterdir()))

    def test_static_site_escapes_title_and_has_multiple_assets(self) -> None:
        output = self.temp / "site"
        output.mkdir()
        self.run_wizard(
            "--internal-render-site",
            to_msys(output),
            "<Proxy & Service>",
        )
        index = (output / "index.html").read_text(encoding="utf-8")
        self.assertIn("&lt;Proxy &amp; Service&gt;", index)
        self.assertTrue((output / "about.html").is_file())
        self.assertTrue((output / "assets" / "site.css").is_file())
        self.assertTrue((output / "assets" / "site.js").is_file())
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("assets.chmod(0o755)", source)

    def test_generator_produces_unique_valid_users(self) -> None:
        code = (
            "export NAIVE_WIZARD_SOURCE_ONLY=1; "
            f"source {to_msys(SCRIPT)!r}; "
            "create_generated_users 40 alpha; "
            "validate_user_arrays; "
            "printf '%s\\n' \"${#USERNAMES[@]}\"; "
            "printf '%s\\n' \"${PASSWORDS[@]}\" | sort -u | wc -l"
        )
        result = subprocess.run(
            [str(BASH), "-lc", code],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=True,
            timeout=30,
        )
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        self.assertEqual(lines, ["40", "40"])

    def test_default_runtime_paths_pass_safety_guard(self) -> None:
        code = (
            "export NAIVE_WIZARD_SOURCE_ONLY=1 NAIVE_WIZARD_TEST_MODE=1; "
            f"source {to_msys(SCRIPT)!r}; "
            "assert_runtime_paths; printf OK"
        )
        result = subprocess.run(
            [str(BASH), "-lc", code],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=True,
            timeout=30,
        )
        self.assertEqual(result.stdout, "OK")

    def test_clean_install_creates_service_identity_before_transaction(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        apply_body = source.split("apply_installation() {", 1)[1].split(
            "\n}", 1
        )[0]
        calls = [line.strip() for line in apply_body.splitlines()]
        self.assertLess(
            calls.index("ensure_service_identity"),
            calls.index("begin_transaction"),
        )

    def test_candidate_build_is_not_hidden_in_command_substitution(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("=$(prepare_candidate_binary)", source)
        self.assertNotIn("=$(prepare_source_built_caddy", source)

    def test_uninstall_tracks_removed_firewall_rules_for_rollback(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        remove_body = source.split("remove_all_managed_ufw_rules() {", 1)[
            1
        ].split("\n}", 1)[0]
        self.assertIn('remove_managed_ufw_rule "$rule"', remove_body)
        self.assertNotIn("ufw --force delete", remove_body)

    def test_append_generated_users_survives_strict_mode(self) -> None:
        code = (
            "export NAIVE_WIZARD_SOURCE_ONLY=1; "
            f"source {to_msys(SCRIPT)!r}; "
            "USERNAMES=(existing); PASSWORDS=(ExistingPassword99); "
            "append_generated_users 2 alpha; "
            "printf '%s' \"${#USERNAMES[@]}\""
        )
        result = subprocess.run(
            [str(BASH), "-lc", code],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=True,
            timeout=30,
        )
        self.assertEqual(result.stdout, "3")

    def test_no_standalone_post_increment_under_errexit(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotRegex(source, r"(?m)^\s*\(\([^)]*\+\+\)\)\s*$")

    def test_default_proxy_smoke_is_skipped_for_restrictive_profiles(self) -> None:
        code = (
            "export NAIVE_WIZARD_SOURCE_ONLY=1; "
            f"source {to_msys(SCRIPT)!r}; "
            "UPSTREAM_URL=''; TARGET_PORTS_MODE=custom; TARGET_PORTS='80 8080'; "
            "ACL_MODE=hardened; "
            "can_run_default_proxy_health_check && exit 10; "
            "TARGET_PORTS='80 443'; ACL_MODE=allowlist; "
            "can_run_default_proxy_health_check && exit 11; "
            "ACL_MODE=hardened; can_run_default_proxy_health_check"
        )
        subprocess.run(
            [str(BASH), "-lc", code],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=True,
            timeout=30,
        )

    def test_systemd_candidate_has_service_suffix(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        service_body = source.split("install_candidate_service() {", 1)[
            1
        ].split("\n}", 1)[0]
        self.assertIn("XXXXXX.service", service_body)

    def test_quick_reconfigure_preserves_existing_users(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        quick_body = source.split("collect_quick_configuration() {", 1)[
            1
        ].split("\n}", 1)[0]
        self.assertIn('if [[ "$existing" == \'true\' ]]', quick_body)
        self.assertIn("validate_user_arrays", quick_body)

    def test_decoy_url_rejects_embedded_credentials(self) -> None:
        code = (
            "export NAIVE_WIZARD_SOURCE_ONLY=1; "
            f"source {to_msys(SCRIPT)!r}; "
            "is_valid_decoy_url 'https://user:secret@example.com' && exit 12; "
            "is_valid_decoy_url 'https://example.com/site'"
        )
        subprocess.run(
            [str(BASH), "-lc", code],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=True,
            timeout=30,
        )

    def test_upstream_url_is_prompted_without_echo(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        upstream_body = source.split("collect_upstream() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertIn("UPSTREAM_URL=$(prompt_secret", upstream_body)

    def test_probe_domain_is_prompted_without_echo(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        probe_body = source.split("collect_probe_and_pac() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertIn("PROBE_SECRET=$(prompt_secret", probe_body)

    def test_sensitive_inputs_use_permission_guard(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        settings_body = source.split("load_settings() {", 1)[1].split(
            "\n}", 1
        )[0]
        users_body = source.split("load_users() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertIn("assert_sensitive_file_security", settings_body)
        self.assertIn("assert_sensitive_file_security", users_body)

    def test_failed_rollback_keeps_transaction_marker(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        rollback_body = source.split("rollback_transaction() {", 1)[
            1
        ].split("\n}", 1)[0]
        failed_branch = rollback_body.split("if (( failed != 0 )); then", 1)[1]
        self.assertIn("return 1", failed_branch)
        self.assertLess(
            rollback_body.index('rm -f -- "$TRANSACTION_FILE"'),
            rollback_body.index("TRANSACTION_ARMED=0"),
        )

    def test_restore_and_firewall_rollback_do_not_mask_stale_state(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        restore_body = source.split("restore_target() {", 1)[1].split(
            "\n}", 1
        )[0]
        firewall_body = source.split("rollback_firewall_rules() {", 1)[
            1
        ].split("\n}", 1)[0]
        begin_body = source.split("begin_transaction() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertIn("safe_remove_managed_target", restore_body)
        self.assertIn("|| return 1", restore_body)
        self.assertIn("FIREWALL_RULES_ADDED=()", firewall_body)
        self.assertIn("FIREWALL_RULES_REMOVED=()", begin_body)

    def test_cleanup_requires_process_local_claim(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        runtime_body = source.split("cleanup_runtime_dir() {", 1)[1].split(
            "\n}", 1
        )[0]
        build_body = source.split("cleanup_build_area() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertIn("RUNTIME_CLAIMED == 1", runtime_body)
        self.assertIn("BUILD_CLAIMED == 1", build_body)
        cleanup_body = source.split("cleanup_all() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertIn("cleanup_runtime_dir || failed=1", cleanup_body)
        self.assertIn("cleanup_build_area || failed=1", cleanup_body)
        self.assertIn("exit 1", cleanup_body)

    def test_firewall_transaction_is_write_ahead(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        add_body = source.split("add_managed_ufw_rule() {", 1)[1].split(
            "\n}", 1
        )[0]
        remove_body = source.split("remove_managed_ufw_rule() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertLess(add_body.index("firewall.added"), add_body.index("ufw allow"))
        self.assertLess(
            remove_body.index("firewall.removed"),
            remove_body.index("ufw --force delete"),
        )

    def test_commit_disarms_only_after_marker_and_status_updates(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        commit_body = source.split("commit_transaction() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertLess(
            commit_body.index('rm -f -- "$TRANSACTION_FILE"'),
            commit_body.index("TRANSACTION_COMMITTED=1"),
        )
        self.assertLess(
            commit_body.index("printf '%s"),
            commit_body.index("TRANSACTION_ARMED=0"),
        )

    def test_drift_checks_permissions_and_secret_artifacts(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        write_body = source.split("write_manifest() {", 1)[1].split(
            "\n}", 1
        )[0]
        verify_body = source.split("verify_manifest_drift() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertIn('"$MANAGED_KEY"', write_body)
        self.assertIn('"$OUTPUT_DIR"', write_body)
        self.assertIn('"$CONFIG_DIR"', write_body)
        self.assertIn("add_resource(config_root)", write_body)
        self.assertIn("stat.st_uid", verify_body)
        self.assertIn("stat.st_gid", verify_body)
        self.assertIn("stat.st_mode", verify_body)

    def test_dns_rejects_any_foreign_a_record(self) -> None:
        code = (
            "export NAIVE_WIZARD_SOURCE_ONLY=1 NAIVE_WIZARD_TEST_MODE=1; "
            f"source {to_msys(SCRIPT)!r}; "
            "DOMAIN=proxy.example.com; "
            "resolve_public_ipv4(){ printf '192.0.2.10'; }; "
            "dig(){ if [[ \"$2\" == A ]]; then "
            "printf '192.0.2.10\\n198.51.100.20\\n'; fi; }; "
            "validate_dns"
        )
        result = subprocess.run(
            [str(BASH), "-lc", code],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
            timeout=30,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("посторонний IPv4", result.stderr)

    def test_installed_binary_reuse_checks_requested_version(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        stage_body = source.split("stage_installed_binary() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertIn("CADDY_CORE_VERSION", stage_body)
        self.assertIn("v2.11.2", stage_body)

    def test_caddy_module_check_avoids_pipefail_sigpipe(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        helper = source.split("caddy_has_forwardproxy() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertIn("modules=$(", helper)
        self.assertNotIn("list-modules --versions 2>/dev/null |", source)

    def test_alpn_check_does_not_capture_nul_bytes_in_bash_variable(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        helper = source.split("verify_h2_alpn() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertIn('mktemp "${RUNTIME_DIR}/openssl-alpn.', helper)
        self.assertNotIn("output=$(timeout", helper)

    def test_atomic_install_preserves_existing_parent_mode(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        helper = source.split("install_file_atomically() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertIn('[[ -e "$parent" || -L "$parent" ]]', helper)
        self.assertIn('[[ -d "$parent" && ! -L "$parent" ]]', helper)
        self.assertNotIn('install -d -m 0755 -- "$parent"\n  temp=', helper)

    def test_apt_waits_for_fresh_server_package_lock(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        dependencies = source.split("install_dependencies() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertEqual(dependencies.count("DPkg::Lock::Timeout=300"), 2)

    def test_source_build_reserves_disk_for_cache_and_temporary_swap(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        build = source.split("prepare_source_built_caddy() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertIn("required_free_kib=5242880", build)
        self.assertIn("required_free_kib=3145728", build)
        self.assertLess(
            build.index("required_free_kib=5242880"),
            build.index('fallocate -l 2G "$BUILD_SWAP_FILE"'),
        )

    def test_status_is_not_full_network_diagnosis(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        main_body = source.split("\nmain() {", 1)[1].split("\n}", 1)[0]
        status_branch = main_body.split("--status)", 1)[1].split(
            "--diagnose)", 1
        )[0]
        self.assertIn("show_installation_status", status_branch)
        self.assertNotIn("diagnose_installation", status_branch)


if __name__ == "__main__":
    unittest.main(verbosity=2)
