#!/usr/bin/env python3
"""
Wazuh -> Alertmanager integrator.

Called by wazuh-integratord through the `custom-alertmanager` wrapper for every
alert that passes the filter in the <integration> block of ossec.conf.

Job: translate a Wazuh alert into the Alertmanager schema, then HTTP POST it to
hook_url (alertmanager:9093/api/v2/alerts).

WHY translation is needed:
  The Wazuh and Alertmanager alert formats differ. Wazuh sends a single alert
  object with nested structure (rule/agent/manager). Alertmanager expects an
  `alerts` array with `labels` (for routing/matching) and `annotations` (for the
  message body). If the Wazuh alert is sent as-is, Alertmanager rejects it with
  400 (required fields missing).

LABEL DESIGN:
  `severity` is mapped from rule.level so that routing in alertmanager.yml works.
  The route `severity = "critical"` -> telegram-critical, the rest ->
  telegram-default. The mapping follows Wazuh convention:
    level >= 13  -> critical
    level >= 10  -> warning
    otherwise    -> info  (will not be sent if the level filter in ossec.conf
                           already limits it, but it is kept regardless)

Arguments (from Wazuh):
  sys.argv[1] = alert file path (JSON)
  sys.argv[3] = hook_url
"""

import json
import sys
import urllib.error
import urllib.request


def severity_from_level(level):
    """Map a Wazuh rule.level to an Alertmanager severity label."""
    if level >= 13:
        return "critical"
    if level >= 10:
        return "warning"
    return "info"


def read_alert(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return json.load(fh)


def build_payload(alert):
    """Turn a single Wazuh alert into an Alertmanager body (alerts array)."""
    rule = alert.get("rule", {})
    agent = alert.get("agent", {})
    level = rule.get("level", 0)

    groups = rule.get("groups") or []

    labels = {
        # alertname must be stable so Alertmanager can group.
        # Use the rule id + brief description; the id alone is not informative in the message.
        "alertname": f"Wazuh-{rule.get('id', 'unknown')}",
        "severity": severity_from_level(int(level)),
        "source": "wazuh",
        "scope": "security",
        "wazuh_rule_id": str(rule.get("id", "")),
        "wazuh_level": str(level),
        "agent": agent.get("name", "unknown"),
        "agent_id": str(agent.get("id", "")),
        "agent_ip": agent.get("ip", ""),
        "groups": ",".join(groups),
    }

    annotations = {
        "summary": rule.get("description", "Wazuh alert"),
        # `description` is used by the Telegram template in alertmanager.yml
        "description": rule.get("description", ""),
        "full_log": (alert.get("full_log") or "")[:500],
        "location": alert.get("location", ""),
        "manager": (alert.get("manager") or {}).get("name", ""),
    }

    # Drop empty labels (Alertmanager only rejects an empty-valued label when it
    # is used in a matcher; safer to remove them up front).
    labels = {k: v for k, v in labels.items() if v != ""}
    annotations = {k: v for k, v in annotations.items() if v != ""}

    # IMPORTANT — the POST /api/v2/alerts endpoint takes a BARE ARRAY,
    # not an object wrapped as {"alerts": [...]}.
    #
    # Verified on Alertmanager v0.27.0:
    #   [{"labels": {...}, "annotations": {...}}]   -> HTTP 200
    #   {"alerts": [{...}]}                          -> HTTP 400
    #     "cannot unmarshal object into Go value of type models.PostableAlerts"
    #
    # Go's `PostableAlerts` really is a slice type. The `alerts:` block in the
    # alertmanager.yml YAML is CONFIGURATION, not the HTTP body shape — easy to mix up.
    return [
        {
            "labels": labels,
            "annotations": annotations,
            # startsAt is filled in by Alertmanager itself when omitted.
        }
    ]


def main():
    if len(sys.argv) < 4:
        print(
            "custom-alertmanager: needs 3 arguments (alert_file, api_key, hook_url)",
            file=sys.stderr,
        )
        return 1

    alert_path = sys.argv[1]
    hook_url = sys.argv[3]

    if not hook_url:
        print("custom-alertmanager: hook_url is empty in ossec.conf", file=sys.stderr)
        return 1

    try:
        alert = read_alert(alert_path)
    except Exception as exc:  # noqa: BLE001 - report anything, do not crash silently
        print(f"custom-alertmanager: failed to read alert {alert_path}: {exc}", file=sys.stderr)
        return 1

    payload = build_payload(alert)
    body = json.dumps(payload).encode("utf-8")

    req = urllib.request.Request(
        hook_url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            # Alertmanager replies 200 on success.
            if resp.status >= 300:
                print(
                    f"custom-alertmanager: Alertmanager replied HTTP {resp.status}",
                    file=sys.stderr,
                )
                return 1
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:300]
        print(
            f"custom-alertmanager: HTTP {exc.code} from Alertmanager: {detail}",
            file=sys.stderr,
        )
        return 1
    except Exception as exc:  # noqa: BLE001
        print(f"custom-alertmanager: failed to send to Alertmanager: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
