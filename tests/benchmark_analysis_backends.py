#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import tempfile
import textwrap
import time
import urllib.request
from typing import Any


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
VAULT_PATH = pathlib.Path.home() / ".claude" / "api-vault.env"
REPORT_PATH = REPO_ROOT / "docs" / "research" / "2026-03-27-analysis-backend-benchmark.json"


def load_env_file(path: pathlib.Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip()
    return env


SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "required": ["should_speak", "content", "kind", "topic_keywords"],
    "properties": {
        "should_speak": {"type": "boolean"},
        "content": {"type": "string"},
        "kind": {"type": "string", "enum": ["insight", "reply", "summary"]},
        "topic_keywords": {"type": "array", "items": {"type": "string"}},
    },
}


CASE_DEFINITIONS = [
    {
        "name": "summary_case",
        "system_prompt": textwrap.dedent(
            """
            你是会议中的 AI 助手。请基于转写做阶段性小结。
            只返回 JSON：
            {
              "should_speak": true,
              "content": "内容",
              "kind": "summary",
              "topic_keywords": ["关键词"]
            }
            """
        ).strip(),
        "user_content": textwrap.dedent(
            """
            最近 8 分钟会议转写：
            [10:01:12] A：这周末是企业家私董会，我们要让每个人轮流提问。
            [10:02:40] B：现在问题是讨论很容易发散，最后没有真正沉淀。
            [10:03:51] C：我更担心主持人没有一个固定的追问框架，导致问题质量波动很大。
            [10:05:07] A：AI 最低目标是我随时可以提问，它能根据上下文回答。
            [10:06:15] B：最高目标是它能主动指出盲点，不要废话，不要高频输出。
            [10:07:33] C：如果有事实争议，AI 应该自动做后台核查和调研。

            请输出一条适合会议中查看的阶段小结。
            """
        ).strip(),
    },
    {
        "name": "insight_case",
        "system_prompt": textwrap.dedent(
            """
            你是会议中的 AI 助手。请像一个很强的旁听顾问一样思考。
            只返回 JSON：
            {
              "should_speak": true,
              "content": "内容",
              "kind": "insight",
              "topic_keywords": ["关键词"]
            }
            内容必须简洁，但要有洞察，不要复述转写。
            """
        ).strip(),
        "user_content": textwrap.dedent(
            """
            最近 10 分钟会议转写：
            [15:11:02] 主持人：这次私董会最重要的是让提问者真正把问题讲清楚。
            [15:12:18] 企业家甲：但现实是很多提问其实是情绪宣泄，不是真问题。
            [15:13:42] 企业家乙：如果主持人追问太多，会让人有压迫感，现场氛围会变差。
            [15:15:06] 企业家丙：如果不追问，后面的建议又全都是空的，帮不到提问者。
            [15:16:21] 主持人：我们是不是应该先定义“什么叫好问题”？
            [15:17:55] 企业家甲：或者先规定每一轮回答的人只能先澄清，不要直接给建议。
            [15:19:08] 企业家乙：但这样又可能拖慢节奏，时间不够。

            请给出一条最值得插入会议的洞察，重点找盲点、结构性矛盾或决策变量。
            """
        ).strip(),
    },
]


def parse_json_or_none(text: str) -> Any:
    try:
        return json.loads(text)
    except Exception:
        return None


def benchmark_http(case: dict[str, str], env_vars: dict[str, str]) -> dict[str, Any]:
    api_key = env_vars.get("QWEN_API_KEY")
    if not api_key:
        return {"backend": "http", "ok": False, "error": "QWEN_API_KEY missing"}

    body = {
        "model": "qwen/qwen3.5-122b-a10b",
        "messages": [
            {"role": "system", "content": case["system_prompt"]},
            {"role": "user", "content": case["user_content"]},
        ],
        "temperature": 0.2,
        "max_tokens": 1024,
    }
    request = urllib.request.Request(
        "https://integrate.api.nvidia.com/v1/chat/completions",
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    start = time.perf_counter()
    with urllib.request.urlopen(request, timeout=90) as response:
        payload = json.loads(response.read().decode("utf-8"))
    elapsed = time.perf_counter() - start

    raw = payload["choices"][0]["message"]["content"]
    parsed = parse_json_or_none(raw)
    return {
        "backend": "http",
        "ok": True,
        "elapsed_seconds": round(elapsed, 3),
        "raw_text": raw,
        "parsed_json": parsed,
    }


def benchmark_codex(case: dict[str, str]) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="meetingai-codex-bench-") as tmp_dir:
        tmp_path = pathlib.Path(tmp_dir)
        schema_path = tmp_path / "schema.json"
        output_path = tmp_path / "output.json"
        schema_path.write_text(json.dumps(SCHEMA), encoding="utf-8")

        prompt = textwrap.dedent(
            f"""
            你是会议中的 AI 助手。不要运行任何工具，不要读写任何文件，只直接思考并输出结果。

            system prompt:
            {case["system_prompt"]}

            user content:
            {case["user_content"]}
            """
        ).strip()

        command = [
            "codex",
            "-s",
            "read-only",
            "exec",
            "--skip-git-repo-check",
            "--output-schema",
            str(schema_path),
            "-o",
            str(output_path),
            "-",
        ]

        start = time.perf_counter()
        completed = subprocess.run(
            command,
            input=prompt,
            text=True,
            capture_output=True,
            cwd=str(REPO_ROOT),
            timeout=180,
        )
        elapsed = time.perf_counter() - start

        if completed.returncode != 0:
            return {
                "backend": "codex_cli",
                "ok": False,
                "elapsed_seconds": round(elapsed, 3),
                "stdout": completed.stdout,
                "stderr": completed.stderr,
            }

        raw = output_path.read_text(encoding="utf-8").strip()
        parsed = parse_json_or_none(raw)
        return {
            "backend": "codex_cli",
            "ok": True,
            "elapsed_seconds": round(elapsed, 3),
            "raw_text": raw,
            "parsed_json": parsed,
        }


def main() -> None:
    env_vars = load_env_file(VAULT_PATH)
    report: dict[str, Any] = {
        "generated_at_epoch": time.time(),
        "cases": [],
    }

    for case in CASE_DEFINITIONS:
        case_report = {
            "name": case["name"],
            "http": benchmark_http(case, env_vars),
            "codex_cli": benchmark_codex(case),
        }
        report["cases"].append(case_report)

    REPORT_PATH.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(REPORT_PATH)


if __name__ == "__main__":
    main()
